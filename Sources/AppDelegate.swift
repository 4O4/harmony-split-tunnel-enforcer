import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let vpnDetector = VPNDetector()
    private let routeMonitor = RouteMonitor()
    private let config = Config.shared
    private let engine = SplitTunnelEngine.shared
    private let updateChecker = UpdateChecker()

    private var cancellables = Set<AnyCancellable>()

    /// Suppress auto-enforce briefly after a manual restore
    private var suppressAutoEnforce = false
    /// Debounce work item for route monitor events
    private var pendingAutoEnforce: DispatchWorkItem?
    /// Track previous VPN state for disconnect detection
    private var previousState = VPNState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 16)
        updateStatusTitle()

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: StatusView(
                vpnDetector: vpnDetector,
                config: config,
                updateChecker: updateChecker,
                onApply: { [weak self] in self?.applyOnce() },
                onRestore: { [weak self] in self?.restore() },
                onCheckForUpdates: { [weak self] in
                    self?.updateChecker.checkNow()
                },
                onQuit: { [weak self] in self?.quit() }
            )
        )

        vpnDetector.startPolling()

        vpnDetector.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self = self else { return }
                self.updateStatusTitle()

                let old = self.previousState
                self.previousState = newState

                // Detect VPN disconnect while split was active → cleanup
                if old.splitActive && !newState.connected {
                    self.engine.log("[AppDelegate] VPN disconnected while split was active, cleaning up...")
                    let snap = self.config.snapshot()
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = self.engine.cleanup(config: snap)
                        // Reinstall counter-routes for continued protection
                        if let gw = newState.realGateway {
                            _ = self.engine.installCounterRoutes(realGateway: gw)
                        }
                        DispatchQueue.main.async {
                            self.vpnDetector.refresh()
                        }
                    }
                }

                // Detect real gateway change → update counter-routes
                if let newGw = newState.realGateway, newGw != old.realGateway, old.realGateway != nil {
                    self.engine.log("[AppDelegate] Real gateway changed (\(old.realGateway ?? "nil") → \(newGw)), updating counter-routes")
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = self.engine.installCounterRoutes(realGateway: newGw)
                    }
                }
            }
            .store(in: &cancellables)

        // Re-apply split tunnel when config changes while already enforced
        Publishers.Merge(
            config.$intranetDomains.dropFirst().map { _ in () },
            config.$intranetRoutes.dropFirst().map { _ in () }
        )
        .debounce(for: .seconds(1.0), scheduler: RunLoop.main)
        .sink { [weak self] in
            guard let self = self else { return }
            guard self.vpnDetector.state.splitActive else { return }
            self.engine.log("[AppDelegate] Config changed while split active, re-applying...")
            self.applyOnce(force: true)
        }
        .store(in: &cancellables)

        // Route monitor — debounced, suppressed after manual restore
        routeMonitor.onRouteAdded = { [weak self] in
            guard let self = self else { return }
            // Don't reset debounce if one is already pending — fire on first event, not last
            if self.pendingAutoEnforce != nil {
                return
            }
            self.engine.log("[AppDelegate] RTM_ADD received, scheduling check (0.5s)")
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingAutoEnforce = nil
                guard !self.suppressAutoEnforce else {
                    self.engine.log("[AppDelegate] Debounce fired: suppressed (manual restore in progress)")
                    self.vpnDetector.refresh()
                    return
                }
                // Synchronous detect to avoid race with async refresh
                let state = VPNDetector.detect()
                self.engine.log("[AppDelegate] Debounce fired: autoApply=\(self.config.autoApply) hasCatchAll=\(state.hasCatchAll) connected=\(state.connected) vpnIf=\(state.vpnInterface ?? "nil")")
                if self.config.autoApply && state.hasCatchAll {
                    self.engine.log("[AppDelegate] Auto-enforcing...")
                    self.applyOnce()
                } else {
                    self.vpnDetector.refresh()
                }
            }
            self.pendingAutoEnforce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        routeMonitor.onRouteDeleted = { [weak self] in
            self?.engine.log("[AppDelegate] RTM_DELETE received, refreshing state")
            self?.vpnDetector.refresh()
        }
        routeMonitor.start()

        engine.log("Harmony Split Tunnel Enforcer started")

        // Startup: crash recovery + counter-routes + auto-enforce
        let startupSnap = config.snapshot()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let state = VPNDetector.detect()

            // Crash recovery: clean up orphaned pf rules from a previous crash
            if !state.connected && self.engine.hasOrphanedRules() {
                self.engine.log("Startup: Orphaned pf rules detected (previous crash?), cleaning up...")
                _ = self.engine.cleanup(config: startupSnap)
            }

            // Install counter-routes immediately for privacy protection
            if let gw = state.realGateway {
                self.engine.log("Startup: Installing counter-routes via \(gw)")
                _ = self.engine.installCounterRoutes(realGateway: gw)
            }
        }

        // Auto-enforce on startup if VPN is already in full tunnel mode (delayed to let routes settle)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let state = VPNDetector.detect()
            if startupSnap.autoApply && state.hasCatchAll {
                self.engine.log("Startup: VPN full tunnel detected, auto-enforcing...")
                let result = self.engine.applyOnce(state: state, config: startupSnap)
                DispatchQueue.main.async {
                    self.vpnDetector.refresh()
                    if !result.success {
                        self.showAlert(title: "Tunnel Enforcer Error", message: result.message)
                    }
                }
            }
        }

        // Check for updates after startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.updateChecker.checkNow()
            self?.updateChecker.startPolling()
        }
    }

    private func updateStatusTitle() {
        let image = MenuBarIcon.forState(vpnDetector.state)
        statusItem.button?.image = image
        statusItem.button?.title = ""
    }

    @objc private func togglePopover() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            if popover.isShown {
                popover.performClose(nil)
            } else if let button = statusItem.button {
                vpnDetector.refresh()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: vpnDetector.state.statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        if vpnDetector.state.hasCatchAll {
            menu.addItem(NSMenuItem(title: "Enforce Split Tunnel", action: #selector(menuApply), keyEquivalent: "e"))
        } else if vpnDetector.state.splitActive {
            menu.addItem(NSMenuItem(title: "Remove Enforcement", action: #selector(menuRestore), keyEquivalent: "d"))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "View Log", action: #selector(menuViewLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Check for Updates", action: #selector(menuCheckForUpdates), keyEquivalent: "u"))

        if let update = updateChecker.availableUpdate {
            let updateItem = NSMenuItem(title: "Update Available: v\(update.version)", action: #selector(menuOpenUpdate), keyEquivalent: "")
            updateItem.attributedTitle = NSAttributedString(
                string: "Update Available: v\(update.version)",
                attributes: [.foregroundColor: NSColor.systemBlue]
            )
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Actions

    private func applyOnce(force: Bool = false) {
        let snap = config.snapshot()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let state = VPNDetector.detect()
            let result = self.engine.applyOnce(state: state, config: snap, force: force)
            DispatchQueue.main.async {
                self.vpnDetector.refresh()
                if !result.success {
                    self.showAlert(title: "Tunnel Enforcer Error", message: result.message)
                }
            }
        }
    }

    private func restore() {
        // Suppress auto-enforce so the route monitor doesn't immediately re-apply
        suppressAutoEnforce = true

        let snap = config.snapshot()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let state = VPNDetector.detect()
            let result = self.engine.restore(state: state, config: snap)
            DispatchQueue.main.async {
                self.vpnDetector.refresh()
                if !result.success {
                    self.showAlert(title: "Restore Error", message: result.message)
                }
                // Re-enable auto-enforce after a delay (let routes stabilize)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.suppressAutoEnforce = false
                    self.engine.log("Auto-enforce re-enabled")
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        popover.performClose(nil)
        routeMonitor.stop()
        vpnDetector.stopPolling()
        updateChecker.stopPolling()

        engine.log("[AppDelegate] App terminating, restoring network state...")
        let snap = config.snapshot()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let state = VPNDetector.detect()

            if state.splitActive {
                self.engine.log("[AppDelegate] Split active, restoring full tunnel...")
                _ = self.engine.restore(state: state, config: snap)
            } else if self.engine.hasOrphanedRules() {
                self.engine.log("[AppDelegate] Orphaned rules found, cleaning up...")
                _ = self.engine.cleanup(config: snap)
            } else {
                _ = self.engine.removeCounterRoutes()
            }

            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func menuApply() { applyOnce() }
    @objc private func menuRestore() { restore() }
    @objc private func menuQuit() { quit() }

    @objc private func menuViewLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: engine.logFilePath))
    }

    @objc private func menuCheckForUpdates() {
        updateChecker.checkNow()
    }

    @objc private func menuOpenUpdate() {
        if let update = updateChecker.availableUpdate {
            NSWorkspace.shared.open(update.url)
        }
    }
}
