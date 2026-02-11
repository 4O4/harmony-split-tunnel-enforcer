import SwiftUI

struct StatusView: View {
    @ObservedObject var vpnDetector: VPNDetector
    @ObservedObject var config: Config
    var onApply: () -> Void
    var onRestore: () -> Void
    var onQuit: () -> Void

    @State private var newDomain = ""
    @State private var newRoute = ""
    @State private var showingDomainEditor = false
    @State private var showingRouteEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(nsImage: PopoverIcon.build(status: statusColor == .green ? .enforced : statusColor == .orange ? .fullTunnel : .disconnected))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Text("Split Tunnel ")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.green)
                        Text("Enforcer")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text("for Harmony")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }

            Divider()

            // VPN Status
            VStack(alignment: .leading, spacing: 4) {
                Text(vpnDetector.state.statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let iface = vpnDetector.state.vpnInterface {
                    Text("Interface: \(iface)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let gw = vpnDetector.state.vpnGateway {
                    Text("VPN Gateway: \(gw)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let realGw = vpnDetector.state.realGateway {
                    Text("Real Gateway: \(realGw)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Action buttons
            HStack {
                if vpnDetector.state.hasCatchAll {
                    Button("Enforce Split Tunnel") { onApply() }
                        .buttonStyle(.borderedProminent)
                } else if vpnDetector.state.splitActive {
                    Button("Remove Enforcement") { onRestore() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Enforce Split Tunnel") { onApply() }
                        .buttonStyle(.bordered)
                        .disabled(!vpnDetector.state.connected)
                }

                Spacer()

                Button("Refresh") { vpnDetector.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            // Auto-apply toggle
            Toggle("Auto-apply on VPN connect", isOn: $config.autoApply)
                .controlSize(.small)

            Divider()

            // Domains section
            DisclosureGroup("Intranet Domains (\(config.intranetDomains.count))", isExpanded: $showingDomainEditor) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(config.intranetDomains, id: \.self) { domain in
                        HStack {
                            Text(domain)
                                .font(.caption.monospaced())
                            Spacer()
                            Button(action: { removeDomain(domain) }) {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        TextField("new.domain.com", text: $newDomain)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit { addDomain() }
                        Button(action: addDomain) {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(newDomain.isEmpty)
                    }
                }
                .padding(.leading, 8)
            }
            .font(.subheadline)

            // Routes section
            DisclosureGroup("Intranet Routes (\(config.intranetRoutes.count))", isExpanded: $showingRouteEditor) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(config.intranetRoutes, id: \.self) { route in
                        HStack {
                            Text(route)
                                .font(.caption.monospaced())
                            Spacer()
                            Button(action: { removeRoute(route) }) {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        TextField("e.g. 10.0.0.0/8", text: $newRoute)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit { addRoute() }
                        Button(action: addRoute) {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(newRoute.isEmpty)
                    }
                }
                .padding(.leading, 8)
            }
            .font(.subheadline)

            Divider()

            // Footer
            HStack {
                Button("View Log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: SplitTunnelEngine.shared.logFilePath))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Spacer()

                Button("Quit") { onQuit() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var statusColor: Color {
        if vpnDetector.state.splitActive { return .green }
        if vpnDetector.state.hasCatchAll { return .orange }
        if vpnDetector.state.connected { return .blue }
        return .gray
    }

    private func addDomain() {
        guard let d = InputValidation.validateDomain(newDomain),
              !config.intranetDomains.contains(d) else { newDomain = ""; return }
        config.intranetDomains.append(d)
        newDomain = ""
    }

    private func removeDomain(_ domain: String) {
        config.intranetDomains.removeAll { $0 == domain }
    }

    private func addRoute() {
        guard let r = InputValidation.validateCIDR(newRoute),
              !config.intranetRoutes.contains(r) else { newRoute = ""; return }
        config.intranetRoutes.append(r)
        newRoute = ""
    }

    private func removeRoute(_ route: String) {
        config.intranetRoutes.removeAll { $0 == route }
    }
}
