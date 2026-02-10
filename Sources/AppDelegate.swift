import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let vpnDetector = VPNDetector()
    private let routeMonitor = RouteMonitor()
    private let config = Config.shared
    private let engine = SplitTunnelEngine.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusTitle()

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Setup popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: StatusView(
                vpnDetector: vpnDetector,
                config: config,
                onApply: { [weak self] in self?.applyOnce() },
                onRestore: { [weak self] in self?.restore() },
                onQuit: { [weak self] in self?.quit() }
            )
        )

        // Start VPN polling
        vpnDetector.startPolling()

        // Update title when state changes
        vpnDetector.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)

        // Setup route monitor
        routeMonitor.onCatchAllRouteAdded = { [weak self] in
            guard let self = self else { return }
            // Debounce: wait a moment for routes to stabilize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.vpnDetector.refresh()
                if self.config.autoApply && self.vpnDetector.state.hasCatchAll {
                    self.engine.log("Route monitor: catch-all detected, auto-enforcing...")
                    self.applyOnce()
                }
            }
        }
        routeMonitor.onRouteDeleted = { [weak self] in
            self?.vpnDetector.refresh()
        }
        routeMonitor.start()

        engine.log("Harmony Split Tunnel Enforcer started")

        // Auto-enforce on startup if VPN is already in full tunnel mode
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let state = VPNDetector.detect()
            if self.config.autoApply && state.hasCatchAll {
                self.engine.log("Startup: VPN full tunnel detected, auto-enforcing...")
                let result = self.engine.applyOnce(state: state, config: self.config)
                DispatchQueue.main.async {
                    self.vpnDetector.refresh()
                    if !result.success {
                        self.showAlert(title: "Tunnel Enforcer Error", message: result.message)
                    }
                }
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateStatusTitle() {
        statusItem.button?.title = vpnDetector.state.menuBarIcon
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
                // Focus the popover
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q"))

        // Set target for all items
        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset menu so left-click still works
        statusItem.menu = nil
    }

    // MARK: - Actions

    private func applyOnce() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let state = VPNDetector.detect()
            let result = self.engine.applyOnce(state: state, config: self.config)
            DispatchQueue.main.async {
                self.vpnDetector.refresh()
                if !result.success {
                    self.showAlert(title: "Tunnel Enforcer Error", message: result.message)
                }
            }
        }
    }

    private func restore() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let state = VPNDetector.detect()
            let result = self.engine.restore(state: state, config: self.config)
            DispatchQueue.main.async {
                self.vpnDetector.refresh()
                if !result.success {
                    self.showAlert(title: "Restore Error", message: result.message)
                }
            }
        }
    }

    private func quit() {
        // Clean up before quitting
        routeMonitor.stop()
        vpnDetector.stopPolling()
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
}

import Combine
