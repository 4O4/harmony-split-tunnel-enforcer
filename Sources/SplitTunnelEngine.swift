import Foundation

final class SplitTunnelEngine {
    static let shared = SplitTunnelEngine()

    private let pfAnchor = "com.apple/p81split"
    private let resolverDir = "/etc/resolver"
    private let logFile = "/tmp/harmony-split-tunnel-enforcer.log"

    private init() {}

    // MARK: - Public API

    /// Apply split tunnel: zero-gap approach
    /// 1. Add intranet routes FIRST (via VPN)
    /// 2. Resolve intranet domain IPs via VPN DNS
    /// 3. Add host routes for resolved IPs
    /// 4. Delete catch-all 0/1 and 128.0/1
    /// 5. Setup DNS resolver files
    /// 6. Setup pf rules
    func applyOnce(state: VPNState, config: Config) -> (success: Bool, message: String) {
        guard state.connected else {
            return (false, "VPN not connected")
        }
        guard state.hasCatchAll else {
            return (false, "No catch-all routes found — already split or not full tunnel")
        }
        guard let vpnIf = state.vpnInterface, let vpnGw = state.vpnGateway else {
            return (false, "Cannot determine VPN interface/gateway")
        }

        let realGw = state.realGateway ?? ""
        let realIf = state.realInterface ?? "en0"
        let vpnDNS = state.vpnDNS ?? vpnGw

        log("=== Enforcing split tunnel ===")
        log("VPN: \(vpnIf) gw=\(vpnGw) dns=\(vpnDNS)")
        log("Real: \(realIf) gw=\(realGw)")
        log("Routes: \(config.intranetRoutes)")
        log("Domains: \(config.intranetDomains)")

        // Build the privileged script
        var commands: [String] = []

        // Step 1: Add intranet CIDR routes via VPN (BEFORE deleting catch-all)
        for route in config.intranetRoutes {
            commands.append("route -n add -net \(route) -interface \(vpnIf) 2>/dev/null || true")
        }

        // Step 2: Resolve intranet domain IPs via VPN DNS and add host routes
        var resolvedIPs: [String] = []
        for domain in config.intranetDomains {
            let ips = resolveDomain(domain, dnsServer: vpnDNS)
            resolvedIPs.append(contentsOf: ips)
            for ip in ips {
                commands.append("route -n add -host \(ip) -interface \(vpnIf) 2>/dev/null || true")
            }
            // Also resolve wildcard (common subdomains)
            let wildcardIPs = resolveDomain("*.\(domain)", dnsServer: vpnDNS)
            resolvedIPs.append(contentsOf: wildcardIPs)
            for ip in wildcardIPs {
                commands.append("route -n add -host \(ip) -interface \(vpnIf) 2>/dev/null || true")
            }
        }
        resolvedIPs = Array(Set(resolvedIPs)) // dedupe

        // Step 3: Delete catch-all routes (AFTER adding specific routes — zero gap)
        commands.append("route -n delete -net 0.0.0.0/1 -interface \(vpnIf) 2>/dev/null || true")
        commands.append("route -n delete -net 128.0.0.0/1 -interface \(vpnIf) 2>/dev/null || true")

        // Step 4: DNS resolver files
        commands.append("mkdir -p \(resolverDir)")
        for domain in config.intranetDomains {
            let resolverFile = "\(resolverDir)/\(domain)"
            let content = "nameserver \(vpnDNS)\\nsearch_order 1\\ntimeout 2"
            commands.append("printf '\(content)\\n' > \(resolverFile)")
        }

        // Step 5: pf rules
        var pfRules = "# Harmony Split Tunnel Enforcer — pf rules\\n"
        if !resolvedIPs.isEmpty {
            let ipList = resolvedIPs.joined(separator: ", ")
            pfRules += "table <p81_intranet> { \(ipList) }\\n"
            pfRules += "block drop out quick on \(realIf) from any to <p81_intranet>\\n"
        }
        for route in config.intranetRoutes {
            pfRules += "block drop out quick on \(realIf) from any to \(route)\\n"
        }

        let pfFile = "/tmp/p81split-pf.conf"
        commands.append("printf '\(pfRules)' > \(pfFile)")
        // Load the anchor rules
        commands.append("pfctl -a '\(pfAnchor)' -f \(pfFile) 2>/dev/null || true")
        commands.append("pfctl -e 2>/dev/null || true")

        // Execute all privileged commands in one batch
        let script = commands.joined(separator: "\n")
        log("Executing \(commands.count) privileged commands...")

        let result = runPrivileged(script: script)
        if result.success {
            log("Split tunnel enforced successfully")
            return (true, "Split tunnel enforced")
        } else {
            log("Failed: \(result.message)")
            return (false, result.message)
        }
    }

    /// Restore full tunnel: undo everything
    func restore(state: VPNState, config: Config) -> (success: Bool, message: String) {
        log("=== Restoring full tunnel ===")

        var commands: [String] = []

        // Remove pf rules
        commands.append("pfctl -a '\(pfAnchor)' -F all 2>/dev/null || true")

        // Remove DNS resolver files
        for domain in config.intranetDomains {
            commands.append("rm -f \(resolverDir)/\(domain)")
        }

        // Remove intranet routes (they'll be re-added by VPN if full tunnel is restored)
        if let vpnIf = state.vpnInterface {
            for route in config.intranetRoutes {
                commands.append("route -n delete -net \(route) -interface \(vpnIf) 2>/dev/null || true")
            }
        }

        // Clean up temp file
        commands.append("rm -f /tmp/p81split-pf.conf")

        let script = commands.joined(separator: "\n")
        let result = runPrivileged(script: script)

        if result.success {
            log("Full tunnel restored")
            return (true, "Full tunnel restored")
        } else {
            log("Restore failed: \(result.message)")
            return (false, result.message)
        }
    }

    // MARK: - DNS Resolution

    private func resolveDomain(_ domain: String, dnsServer: String) -> [String] {
        // Use dig to resolve via VPN DNS
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        proc.arguments = ["+short", "+time=2", "+tries=1", "@\(dnsServer)", domain, "A"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            log("dig failed for \(domain): \(error)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let ips = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValidIPv4($0) }

        if !ips.isEmpty {
            log("Resolved \(domain) -> \(ips.joined(separator: ", "))")
        }
        return ips
    }

    private func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - Privileged Execution

    private func runPrivileged(script: String) -> (success: Bool, message: String) {
        // Use osascript to run with admin privileges — single password prompt
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = """
        do shell script "\(escaped)" with administrator privileges
        """

        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (false, "Failed to launch osascript: \(error)")
        }

        if proc.terminationStatus == 0 {
            return (true, "OK")
        } else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            if errStr.contains("User canceled") || errStr.contains("-128") {
                return (false, "User cancelled authentication")
            }
            return (false, errStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Logging

    func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        print(line, terminator: "")

        // Also append to log file (non-privileged)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let fh = FileHandle(forWritingAtPath: logFile) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
            }
        }
    }

    var logFilePath: String { logFile }
}
