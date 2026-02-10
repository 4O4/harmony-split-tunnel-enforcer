import Foundation

final class SplitTunnelEngine {
    static let shared = SplitTunnelEngine()

    private let pfAnchor = "com.apple/p81split"
    private let resolverDir = "/etc/resolver"
    private let logFile = "/tmp/harmony-split-tunnel-enforcer.log"
    private let sudoersFile = "/etc/sudoers.d/harmony-split-tunnel"

    private var sudoInstalled = false

    private init() {
        sudoInstalled = testSudoAccess()
    }

    // MARK: - Passwordless sudo setup

    /// Install sudoers rule so route/pfctl/tee don't need password prompts.
    /// Requires one initial password prompt via osascript.
    func ensureSudoAccess() -> (success: Bool, message: String) {
        if sudoInstalled { return (true, "Already installed") }

        // Test if we already have passwordless access
        if testSudoAccess() {
            sudoInstalled = true
            return (true, "Already have access")
        }

        log("Installing passwordless sudo rule (one-time setup)...")

        let sudoersContent = "%admin ALL=(root) NOPASSWD: /sbin/route, /sbin/pfctl, /usr/bin/tee /etc/resolver/*, /bin/rm -f /etc/resolver/*, /bin/mkdir -p /etc/resolver"

        let script = "echo '\(sudoersContent)' > \(sudoersFile) && chmod 0440 \(sudoersFile)"

        let result = runOsascript(script: script)
        if result.success {
            sudoInstalled = true
            log("Sudo rule installed at \(sudoersFile)")
        }
        return result
    }

    private func testSudoAccess() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", "route", "-n", "get", "default"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Public API

    /// Apply split tunnel: zero-gap approach
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

        // Ensure we have sudo access
        let access = ensureSudoAccess()
        if !access.success { return access }

        let realIf = state.realInterface ?? "en0"
        let vpnDNS = state.vpnDNS ?? vpnGw

        log("=== Enforcing split tunnel ===")
        log("VPN: \(vpnIf) gw=\(vpnGw) dns=\(vpnDNS)")
        log("Real: \(realIf) gw=\(state.realGateway ?? "?")")
        log("Routes: \(config.intranetRoutes)")
        log("Domains: \(config.intranetDomains)")

        var commands: [String] = []

        // Step 1: Add intranet CIDR routes via VPN (BEFORE deleting catch-all)
        for route in config.intranetRoutes {
            commands.append("sudo route -n add -net \(route) -interface \(vpnIf) 2>/dev/null || true")
        }

        // Step 2: Resolve intranet domain IPs via VPN DNS and add host routes
        var resolvedIPs: [String] = []
        for domain in config.intranetDomains {
            let ips = resolveDomain(domain, dnsServer: vpnDNS)
            resolvedIPs.append(contentsOf: ips)
            for ip in ips {
                commands.append("sudo route -n add -host \(ip) -interface \(vpnIf) 2>/dev/null || true")
            }
            let wildcardIPs = resolveDomain("*.\(domain)", dnsServer: vpnDNS)
            resolvedIPs.append(contentsOf: wildcardIPs)
            for ip in wildcardIPs {
                commands.append("sudo route -n add -host \(ip) -interface \(vpnIf) 2>/dev/null || true")
            }
        }
        resolvedIPs = Array(Set(resolvedIPs))

        // Step 3: Delete catch-all routes (AFTER adding specific routes — zero gap)
        commands.append("sudo route -n delete -net 0.0.0.0/1 -interface \(vpnIf) 2>/dev/null || true")
        commands.append("sudo route -n delete -net 128.0.0.0/1 -interface \(vpnIf) 2>/dev/null || true")

        // Step 4: DNS resolver files
        commands.append("sudo mkdir -p \(resolverDir)")
        for domain in config.intranetDomains {
            let content = "nameserver \(vpnDNS)\nsearch_order 1\ntimeout 2"
            commands.append("echo '\(content)' | sudo tee \(resolverDir)/\(domain) > /dev/null")
        }

        // Step 5: pf rules
        var pfRules = "# Split Tunnel Enforcer — pf rules\n"
        if !resolvedIPs.isEmpty {
            let ipList = resolvedIPs.joined(separator: ", ")
            pfRules += "table <p81_intranet> { \(ipList) }\n"
            pfRules += "block drop out quick on \(realIf) from any to <p81_intranet>\n"
        }
        for route in config.intranetRoutes {
            pfRules += "block drop out quick on \(realIf) from any to \(route)\n"
        }

        let pfFile = "/tmp/p81split-pf.conf"
        commands.append("echo '\(pfRules)' > \(pfFile)")
        commands.append("sudo pfctl -a '\(pfAnchor)' -f \(pfFile) 2>/dev/null || true")
        commands.append("sudo pfctl -e 2>/dev/null || true")

        let script = commands.joined(separator: "\n")
        log("Executing \(commands.count) commands...")

        let result = runShell(script: script)
        if result.success {
            log("Split tunnel enforced successfully")
            return (true, "Split tunnel enforced")
        } else {
            log("Failed: \(result.message)")
            return (false, result.message)
        }
    }

    /// Restore full tunnel: re-add catch-all routes, remove pf/dns/intranet routes
    func restore(state: VPNState, config: Config) -> (success: Bool, message: String) {
        log("=== Restoring full tunnel ===")

        let access = ensureSudoAccess()
        if !access.success { return access }

        guard let vpnIf = state.vpnInterface else {
            return (false, "Cannot determine VPN interface")
        }

        let vpnGw = state.vpnGateway ?? ""

        var commands: [String] = []

        // Re-add catch-all routes to restore full tunnel
        if vpnGw.isEmpty {
            commands.append("sudo route -n add -net 0.0.0.0/1 -interface \(vpnIf) 2>/dev/null || true")
            commands.append("sudo route -n add -net 128.0.0.0/1 -interface \(vpnIf) 2>/dev/null || true")
        } else {
            commands.append("sudo route -n add -net 0.0.0.0/1 \(vpnGw) 2>/dev/null || true")
            commands.append("sudo route -n add -net 128.0.0.0/1 \(vpnGw) 2>/dev/null || true")
        }

        // Remove pf rules
        commands.append("sudo pfctl -a '\(pfAnchor)' -F all 2>/dev/null || true")

        // Remove DNS resolver files
        for domain in config.intranetDomains {
            commands.append("sudo rm -f \(resolverDir)/\(domain)")
        }

        // Remove intranet-specific routes (VPN catch-all now covers them)
        for route in config.intranetRoutes {
            commands.append("sudo route -n delete -net \(route) -interface \(vpnIf) 2>/dev/null || true")
        }

        // Clean up temp file
        commands.append("rm -f /tmp/p81split-pf.conf")

        let script = commands.joined(separator: "\n")
        let result = runShell(script: script)

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

    // MARK: - Execution

    /// Run shell script using sudo (passwordless after setup)
    private func runShell(script: String) -> (success: Bool, message: String) {
        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (false, "Failed to run: \(error)")
        }

        if proc.terminationStatus == 0 {
            return (true, "OK")
        } else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            return (false, errStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Run via osascript with admin privileges (only for initial sudo setup)
    private func runOsascript(script: String) -> (success: Bool, message: String) {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let proc = Process()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        proc.standardOutput = FileHandle.nullDevice
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
