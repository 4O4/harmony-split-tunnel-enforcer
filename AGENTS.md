# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project

Harmony Split Tunnel Enforcer — a native macOS menubar app (Swift, SwiftUI) that enforces split tunneling for Harmony SASE (formerly Perimeter 81 / Check Point) VPN. It removes the VPN's catch-all routes and keeps only intranet traffic on the VPN tunnel.

Platform: macOS 13+ (Ventura). Swift 5.9+. No external dependencies — only Apple frameworks (AppKit, SwiftUI, Foundation, Combine).

## Build & Run

```sh
swift build                    # debug build
swift build -c release         # release build
./bundle.sh                    # release build + create .app bundle
open "Harmony Split Tunnel Enforcer.app"
```

No tests exist. No linter is configured.

## Architecture

All source is in `Sources/`. Nine files, ~1000 lines total.

### Singletons & wiring

- `Config.shared` — observable config (Combine `@Published`), persists to UserDefaults
- `SplitTunnelEngine.shared` — route/firewall/DNS manipulation via `Process` calls to system tools
- `VPNDetector` — polls `netstat -rnf inet` every 4s, publishes `VPNState`
- `RouteMonitor` — long-running `route -n monitor` process, fires callbacks on RTM_ADD/RTM_DELETE
- `AppDelegate` — owns all the above, manages menubar status item + NSPopover

`AppDelegate` subscribes to `VPNDetector.$state` for UI updates and wires `RouteMonitor` callbacks for auto-enforcement.

### Enforcement flow (zero-gap)

Order matters — this prevents traffic leaks:

1. Add intranet CIDR routes via VPN interface
2. Resolve intranet domain IPs via VPN DNS, add host routes
3. Delete catch-all routes (`0/1`, `128.0/1`) from VPN interface
4. Write `/etc/resolver/{domain}` files for DNS
5. Install `pf` firewall rules under `com.apple/p81split` anchor

Restore reverses this: re-add catch-all, flush pf, remove resolver files, delete intranet routes.

### Config precedence

UserDefaults (UI edits) > config file (JSON) > hardcoded defaults.

Config file search paths: `~/.config/harmony-split-tunnel/config.json`, `~/.harmony-split-tunnel.json`, `/etc/harmony-split-tunnel/config.json`.

### Thread safety patterns

- `RouteMonitor`: `_process` and `_isRunning` behind a `DispatchQueue` sync lock
- `Config.ConfigSnapshot`: main-thread snapshot for passing config to background threads safely
- `SplitTunnelEngine.log()`: serial `DispatchQueue` for file writes
- `VPNDetector.detect()` runs on background queue, publishes state on main thread

### Security: shell injection prevention

All user-controlled values (domains, CIDRs, IPs, interface names) are validated through `InputValidation` regex checks before shell interpolation. This is defense-in-depth — values are validated both at Config load time and again before command construction in `SplitTunnelEngine`.

### Privilege escalation

One-time `osascript` admin prompt installs a passwordless sudoers rule at `/etc/sudoers.d/harmony-split-tunnel`. Scope: `route`, `pfctl`, `tee /etc/resolver/*`, `rm -f /etc/resolver/*`, `mkdir -p /etc/resolver`. All subsequent operations use `sudo -n` (non-interactive).

### Debounce & suppression (AppDelegate)

- RTM_ADD events debounced with 0.5s delay; first event starts timer, subsequent events within window are ignored
- After manual restore, auto-enforce is suppressed for 5s to let routes stabilize
- Startup auto-enforce fires 2s after launch

### Log

Written to `/tmp/harmony-split-tunnel-enforcer.log` with ISO8601 timestamps.

## Key files

| File | Role |
|------|------|
| `Sources/AppDelegate.swift` | App lifecycle, menubar, popover, event coordination |
| `Sources/VPNDetector.swift` | VPN state detection via netstat parsing |
| `Sources/SplitTunnelEngine.swift` | Route/firewall/DNS commands, sudo setup, logging |
| `Sources/RouteMonitor.swift` | Real-time route change monitoring |
| `Sources/Config.swift` | Config loading, UserDefaults persistence, ConfigSnapshot |
| `Sources/InputValidation.swift` | Regex validators for domains, CIDRs, IPs, interfaces |
| `Sources/StatusView.swift` | SwiftUI popover UI |
| `Sources/MenuBarIcon.swift` | Programmatic menubar icon with status dots |
| `Sources/main.swift` | App entry point |

## CI/CD

`.github/workflows/release.yml` triggers on version tags (`v*`). Builds universal binary (arm64 + x86_64), creates DMG, ad-hoc signs, creates GitHub release, updates Homebrew tap.
