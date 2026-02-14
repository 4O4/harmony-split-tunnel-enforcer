import Foundation

final class SplitTunnelEngine {
    static let shared = SplitTunnelEngine()

    private let pfAnchor = "com.apple/p81split"
    private let resolverDir = "/etc/resolver"
    private let logFile = "/tmp/harmony-split-tunnel-enforcer.log"
    private let sudoersFile = "/etc/sudoers.d/harmony-split-tunnel"

    private var sudoInstalled = false
    private let logQueue = DispatchQueue(label: "com.harmony.splittunnel.log")
    private let logFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

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

        let sudoersContent = "# Harmony Split Tunnel Enforcer - grants %admin passwordless access to network tools\n%admin ALL=(root) NOPASSWD: /sbin/route, /sbin/pfctl, /usr/bin/tee /etc/resolver/*, /bin/rm -f /etc/resolver/*, /bin/mkdir -p /etc/resolver"

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

    // MARK: - Counter-routes

    private let counterNets = ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"]

    /// Install /2 counter-routes via real gateway so personal traffic always bypasses VPN.
    /// These are more specific than VPN's /1 catch-all routes, so they win in the routing table.
    func installCounterRoutes(realGateway: String) -> (success: Bool, message: String) {
        let access = ensureSudoAccess()
        if !access.success { return access }

        guard let safeGw = InputValidation.validateIPv4(realGateway) else {
            return (false, "Invalid gateway: \(realGateway)")
        }

        log("Installing counter-routes via \(safeGw)")
        var commands: [String] = []
        for net in counterNets {
            commands.append("sudo route -n delete -net \(net) 2>&1 || true")
            commands.append("sudo route -n add -net \(net) \(safeGw) 2>&1 || true")
        }
        let result = runShell(script: commands.joined(separator: "\n"))
        if result.success {
            log("Counter-routes installed")
        } else {
            log("Counter-routes failed: \(result.message)")
        }
        return result
    }

    /// Remove /2 counter-routes
    func removeCounterRoutes() -> (success: Bool, message: String) {
        let access = ensureSudoAccess()
        if !access.success { return access }

        log("Removing counter-routes")
        var commands: [String] = []
        for net in counterNets {
            commands.append("sudo route -n delete -net \(net) 2>&1 || true")
        }
        return runShell(script: commands.joined(separator: "\n"))
    }

    // MARK: - Public API

    /// Apply split tunnel: zero-gap approach
    func applyOnce(state: VPNState, config: Config.ConfigSnapshot, force: Bool = false) -> (success: Bool, message: String) {
        guard state.connected else {
            return (false, "VPN not connected")
        }
        if !force {
            guard state.hasCatchAll else {
                return (false, "No catch-all routes found — already split or not full tunnel")
            }
        }
        guard let vpnIf = state.vpnInterface, let vpnGw = state.vpnGateway else {
            return (false, "Cannot determine VPN interface/gateway")
        }

        // Ensure we have sudo access
        let access = ensureSudoAccess()
        if !access.success { return access }

        // Validate all interpolated values (defense-in-depth against shell injection)
        guard let safeVpnIf = InputValidation.validateInterface(vpnIf) else {
            return (false, "Invalid VPN interface name: \(vpnIf)")
        }
        let safeRealIf = InputValidation.validateInterface(state.realInterface ?? "en0") ?? "en0"
        let safeVpnDNS = InputValidation.validateIPv4(state.vpnDNS ?? vpnGw) ?? InputValidation.validateIPv4(vpnGw) ?? vpnGw
        let validRoutes = config.intranetRoutes.compactMap { InputValidation.validateCIDR($0) }
        let validDomains = config.intranetDomains.compactMap { InputValidation.validateDomain($0) }

        log("=== Enforcing split tunnel ===")
        log("VPN: \(safeVpnIf) gw=\(vpnGw) dns=\(safeVpnDNS)")
        log("Real: \(safeRealIf) gw=\(state.realGateway ?? "?")")
        log("Routes: \(validRoutes)")
        log("Domains: \(validDomains)")

        var commands: [String] = []

        // Step 1: Add intranet CIDR routes via VPN (BEFORE deleting catch-all)
        for route in validRoutes {
            commands.append("sudo route -n add -net \(route) -interface \(safeVpnIf) 2>&1 || true")
        }

        // Step 2: Resolve intranet domain IPs via VPN DNS and add host routes
        var resolvedIPs: [String] = []
        for domain in validDomains {
            let ips = resolveDomain(domain, dnsServer: safeVpnDNS)
            resolvedIPs.append(contentsOf: ips)
            for ip in ips {
                commands.append("sudo route -n add -host \(ip) -interface \(safeVpnIf) 2>&1 || true")
            }
        }
        resolvedIPs = Array(Set(resolvedIPs))

        // Step 2.5: Refresh counter-routes via real gateway (keeps personal traffic on en0)
        if let realGw = state.realGateway, let safeRealGw = InputValidation.validateIPv4(realGw) {
            for net in counterNets {
                commands.append("sudo route -n delete -net \(net) 2>&1 || true")
                commands.append("sudo route -n add -net \(net) \(safeRealGw) 2>&1 || true")
            }
        }

        // Step 3: Delete catch-all routes (AFTER adding specific routes — zero gap)
        commands.append("sudo route -n delete -net 0.0.0.0/1 -interface \(safeVpnIf) 2>&1 || true")
        commands.append("sudo route -n delete -net 128.0.0.0/1 -interface \(safeVpnIf) 2>&1 || true")

        // Step 4: DNS resolver files
        commands.append("sudo mkdir -p \(resolverDir)")
        for domain in validDomains {
            let content = "nameserver \(safeVpnDNS)\nsearch_order 1\ntimeout 2"
            commands.append("echo '\(content)' | sudo tee \(resolverDir)/\(domain) > /dev/null")
        }

        // Step 5: pf rules
        var pfRules = "# Harmony Split Tunnel Enforcer — pf rules\n"
        if !resolvedIPs.isEmpty {
            let ipList = resolvedIPs.joined(separator: ", ")
            pfRules += "table <p81_intranet> { \(ipList) }\n"
            pfRules += "block drop out quick on \(safeRealIf) from any to <p81_intranet>\n"
        }
        for route in validRoutes {
            pfRules += "block drop out quick on \(safeRealIf) from any to \(route)\n"
        }

        let pfFile = "/tmp/p81split-pf.conf"
        commands.append("echo '\(pfRules)' > \(pfFile)")
        commands.append("sudo pfctl -a '\(pfAnchor)' -f \(pfFile) 2>&1 || true")
        commands.append("sudo pfctl -e 2>&1 || true")

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
    func restore(state: VPNState, config: Config.ConfigSnapshot) -> (success: Bool, message: String) {
        log("=== Restoring full tunnel ===")

        let access = ensureSudoAccess()
        if !access.success { return access }

        guard let vpnIf = state.vpnInterface,
              let safeVpnIf = InputValidation.validateInterface(vpnIf) else {
            return (false, "Cannot determine VPN interface")
        }

        let vpnGw = state.vpnGateway ?? ""
        let validDomains = config.intranetDomains.compactMap { InputValidation.validateDomain($0) }
        let validRoutes = config.intranetRoutes.compactMap { InputValidation.validateCIDR($0) }

        var commands: [String] = []

        // Re-add catch-all routes to restore full tunnel
        if vpnGw.isEmpty {
            commands.append("sudo route -n add -net 0.0.0.0/1 -interface \(safeVpnIf) 2>&1 || true")
            commands.append("sudo route -n add -net 128.0.0.0/1 -interface \(safeVpnIf) 2>&1 || true")
        } else {
            let safeGw = InputValidation.validateIPv4(vpnGw) ?? vpnGw
            commands.append("sudo route -n add -net 0.0.0.0/1 \(safeGw) 2>&1 || true")
            commands.append("sudo route -n add -net 128.0.0.0/1 \(safeGw) 2>&1 || true")
        }

        // Remove pf rules
        commands.append("sudo pfctl -a '\(pfAnchor)' -F all 2>&1 || true")

        // Remove DNS resolver files
        for domain in validDomains {
            commands.append("sudo rm -f \(resolverDir)/\(domain)")
        }

        // Remove counter-routes (restoring full tunnel means VPN handles all traffic)
        for net in counterNets {
            commands.append("sudo route -n delete -net \(net) 2>&1 || true")
        }

        // Remove intranet-specific routes (VPN catch-all now covers them)
        for route in validRoutes {
            commands.append("sudo route -n delete -net \(route) -interface \(safeVpnIf) 2>&1 || true")
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

    /// Cleanup without VPN interface info (for VPN disconnect / crash recovery).
    /// Removes pf rules, resolver files, counter-routes, and temp file.
    func cleanup(config: Config.ConfigSnapshot) -> (success: Bool, message: String) {
        log("=== Cleaning up split tunnel artifacts ===")

        let access = ensureSudoAccess()
        if !access.success { return access }

        let validDomains = config.intranetDomains.compactMap { InputValidation.validateDomain($0) }

        var commands: [String] = []

        // Remove pf rules
        commands.append("sudo pfctl -a '\(pfAnchor)' -F all 2>&1 || true")

        // Remove DNS resolver files
        for domain in validDomains {
            commands.append("sudo rm -f \(resolverDir)/\(domain)")
        }

        // Remove counter-routes
        for net in counterNets {
            commands.append("sudo route -n delete -net \(net) 2>&1 || true")
        }

        // Clean up temp file
        commands.append("rm -f /tmp/p81split-pf.conf")

        let script = commands.joined(separator: "\n")
        let result = runShell(script: script)

        if result.success {
            log("Cleanup completed")
        } else {
            log("Cleanup failed: \(result.message)")
        }
        return result
    }

    /// Check if our pf anchor has any rules loaded (detects crash leftovers).
    func hasOrphanedRules() -> Bool {
        guard sudoInstalled || testSudoAccess() else { return false }

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", "pfctl", "-a", pfAnchor, "-sr"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !output.isEmpty
    }

    // MARK: - DNS Resolution

    private func resolveDomain(_ domain: String, dnsServer: String) -> [String] {
        guard let safeDomain = InputValidation.validateDomain(domain) else {
            log("Skipping invalid domain: \(domain)")
            return []
        }
        let safeDNS = InputValidation.validateIPv4(dnsServer) ?? dnsServer

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        proc.arguments = ["+short", "+time=2", "+tries=1", "@\(safeDNS)", safeDomain, "A"]
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
        InputValidation.validateIPv4(s) != nil
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

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !outStr.isEmpty {
            log("[shell] \(outStr)")
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
        let date = Date()
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let ts = self.logFormatter.string(from: date)
            let line = "[\(ts)] \(message)\n"
            print(line, terminator: "")
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: self.logFile) {
                if let fh = FileHandle(forWritingAtPath: self.logFile) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: self.logFile, contents: data)
            }
        }
    }

    var logFilePath: String { logFile }
}
