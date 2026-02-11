import Foundation
import Combine

struct VPNState {
    var connected: Bool = false
    var splitActive: Bool = false
    var vpnInterface: String? = nil
    var vpnGateway: String? = nil
    var realGateway: String? = nil
    var realInterface: String? = nil
    var hasCatchAll: Bool = false
    var vpnDNS: String? = nil

    var statusText: String {
        if !connected { return "SASE Disconnected" }
        if splitActive { return "Split Enforced" }
        if hasCatchAll { return "Full Tunnel — Not Enforced" }
        return "SASE Connected"
    }

    var menuBarIcon: String {
        if !connected { return "HE" }
        if splitActive { return "HE \u{2713}" }    // checkmark — split enforced
        if hasCatchAll { return "HE \u{26A0}" }     // warning — full tunnel
        return "HE"
    }
}

final class VPNDetector: ObservableObject {
    @Published var state = VPNState()

    private var timer: Timer?

    func startPolling(interval: TimeInterval = 4.0) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let newState = Self.detect()
            DispatchQueue.main.async {
                guard let self = self else { return }
                let old = self.state
                self.state = newState
                // Log state transitions
                if old.connected != newState.connected || old.hasCatchAll != newState.hasCatchAll || old.splitActive != newState.splitActive || old.vpnInterface != newState.vpnInterface {
                    SplitTunnelEngine.shared.log("[VPNDetector] State changed: connected=\(newState.connected) hasCatchAll=\(newState.hasCatchAll) splitActive=\(newState.splitActive) vpnIf=\(newState.vpnInterface ?? "nil") vpnGw=\(newState.vpnGateway ?? "nil") realGw=\(newState.realGateway ?? "nil") realIf=\(newState.realInterface ?? "nil")")
                }
            }
        }
    }

    static func detect() -> VPNState {
        var s = VPNState()

        guard let output = Self.run("/usr/sbin/netstat", ["-rnf", "inet"]) else { return s }
        let lines = output.components(separatedBy: "\n")

        // Parse routing table
        // Look for: destination gateway flags refs use mtu netif expire
        var catchAllInterfaces: [String] = []

        for line in lines {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4 else { continue }

            let dest = cols[0]
            let gateway = cols[1]
            // macOS netstat format: Destination Gateway Flags Netif [Expire]
            // Netif is at index 3; if Expire exists it's at index 4
            let netif = cols[3]

            // Detect catch-all VPN routes (0/1 and 128.0/1)
            if dest == "0/1" || dest == "128.0/1" {
                if netif.hasPrefix("utun") {
                    s.hasCatchAll = true
                    s.vpnInterface = netif
                    s.vpnGateway = gateway
                    catchAllInterfaces.append(netif)
                }
            }

            // Default route — real gateway (prefer en* over bridge/vmnet/etc)
            if dest == "default" && !netif.hasPrefix("utun") {
                let isPhysical = netif.hasPrefix("en")
                let currentIsPhysical = s.realInterface?.hasPrefix("en") ?? false
                if s.realInterface == nil || (isPhysical && !currentIsPhysical) {
                    s.realGateway = gateway
                    s.realInterface = netif
                }
            }

            // Detect any utun interface with routes (VPN tunnel)
            if netif.hasPrefix("utun") && s.vpnInterface == nil {
                s.vpnInterface = netif
            }
            // Capture VPN gateway if it's an IP address on a utun interface
            if netif.hasPrefix("utun") && s.vpnGateway == nil && gateway.contains(".") && !gateway.hasPrefix("utun") {
                s.vpnGateway = gateway
            }
        }

        // VPN connected if we have a utun interface
        s.connected = s.vpnInterface != nil

        // Split tunnel is active if VPN connected but NO catch-all routes
        s.splitActive = s.connected && !s.hasCatchAll

        // Try to detect VPN DNS from scutil
        if let vpnIf = s.vpnInterface {
            s.vpnDNS = Self.detectVPNDNS(interface: vpnIf)
        }

        return s
    }

    private static func detectVPNDNS(interface: String) -> String? {
        // Try scutil --dns to find DNS for VPN interface
        guard let output = run("/usr/sbin/scutil", ["--dns"]) else { return nil }

        let blocks = output.components(separatedBy: "resolver #")
        for block in blocks {
            if block.contains(interface) || block.contains("Supplemental") {
                // Extract nameserver line
                for line in block.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("nameserver[0]") || trimmed.hasPrefix("nameserver :") {
                        let parts = trimmed.split(separator: ":")
                        if let ip = parts.last?.trimmingCharacters(in: .whitespaces), !ip.isEmpty {
                            return ip
                        }
                    }
                }
            }
        }

        // Fallback: look for DNS on utun in ifconfig
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
