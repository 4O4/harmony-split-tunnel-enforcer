# Harmony Split Tunnel Enforcer

A native macOS menubar app that enforces split tunneling for Harmony SASE (formerly Perimeter 81 / Check Point) VPN.

![Menubar icon with green status dot, next to Harmony SASE](screenshot.png)

## Problem

Harmony SASE supports split tunneling as an admin-configurable policy, but when the policy is set to full tunnel, all traffic routes through the VPN -- including personal browsing, streaming, and non-corporate services. There is no client-side option to override this.

## What It Does

Harmony Split Tunnel Enforcer removes the VPN's catch-all routes (`0.0.0.0/1` and `128.0.0.0/1`), keeping only intranet-bound traffic on the VPN tunnel. Internet traffic flows through your normal gateway.

When enforcing split tunnel it:

1. **Adds intranet CIDR routes** via the VPN interface (before touching catch-all routes -- zero gap)
2. **Resolves intranet domain IPs** via the VPN's DNS server and adds host routes for them
3. **Deletes catch-all routes** (`0/1` and `128.0/1`) from the VPN interface
4. **Creates `/etc/resolver/` files** for intranet domains so DNS queries still go through VPN DNS
5. **Installs `pf` firewall rules** (under anchor `com.apple/p81split`) that block intranet traffic from leaking out the real interface

All privileged operations run in a single `osascript` batch with one admin password prompt.

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+ (Xcode 15+ or standalone Swift toolchain)
- Harmony SASE / Perimeter 81 VPN client

## Building

### Release binary

```sh
swift build -c release
```

Binary is at `.build/release/HarmonySplitTunnelEnforcer`.

### macOS .app bundle

```sh
./bundle.sh
```

Produces `Harmony Split Tunnel Enforcer.app` with `LSUIElement = true` (no Dock icon).

## Running

```sh
.build/release/HarmonySplitTunnelEnforcer
```

Or from the .app bundle:

```sh
open "Harmony Split Tunnel Enforcer.app"
```

## Menubar States

| Icon | Meaning |
|------|---------|
| **HE** | SASE disconnected |
| **HE &#x26A0;** | Full tunnel detected -- not yet enforced |
| **HE &#x2713;** | Split tunnel enforced |

Left-click opens a popover with status and controls. Right-click opens a quick-action menu.

## Configuration

### Config file

Create a JSON config file at one of these locations (first match wins):

1. `~/.config/harmony-split-tunnel/config.json`
2. `~/.harmony-split-tunnel.json`
3. `/etc/harmony-split-tunnel/config.json`

See [`config.example.json`](config.example.json) for the format:

```json
{
  "intranetDomains": [
    "internal.corp.example.com",
    "wiki.example.com"
  ],
  "intranetRoutes": [
    "10.0.0.0/8"
  ],
  "autoApply": true
}
```

### UI

Domains and routes can also be edited in the popover UI. Changes persist in UserDefaults and take priority over the config file on subsequent launches.

| Field | Description |
|-------|-------------|
| **Intranet Domains** | Hostnames resolved via VPN DNS with per-domain `/etc/resolver/` files |
| **Intranet Routes** | CIDR ranges routed through the VPN interface |
| **Auto-apply** | Automatically enforce split tunnel when VPN connects (default: on) |

## How It Works

**VPN Detection** -- `VPNDetector` parses `netstat -rnf inet` every 4s, looking for `utun` interfaces with catch-all routes. Prefers `en*` interfaces over virtual bridges for real gateway detection.

**Route Monitoring** -- `RouteMonitor` runs `route -n monitor` in the background. When catch-all routes appear (VPN reconnect), it triggers auto-enforcement.

**Zero-Gap Enforcement** -- Intranet routes are added *before* catch-all routes are deleted, ensuring no window where intranet traffic is unroutable.

**pf Firewall** -- Rules under the `com.apple/p81split` anchor block intranet traffic from leaking via the real interface if routes are disrupted.

**DNS** -- Per-domain files in `/etc/resolver/` direct macOS to use VPN DNS for intranet lookups.

## Log

Operations are logged to `/tmp/harmony-split-tunnel-enforcer.log`, accessible via "View Log" in the app.

## Project Structure

```
Package.swift               SwiftPM manifest (macOS 13+)
bundle.sh                   Builds release + creates .app bundle
config.example.json         Example configuration file
Sources/
  main.swift                Entry point, NSApplication accessory setup
  AppDelegate.swift         Menubar item, popover, auto-enforce wiring
  StatusView.swift           SwiftUI popover UI
  SplitTunnelEngine.swift   Route manipulation, DNS resolvers, pf rules
  RouteMonitor.swift        Real-time route table monitoring
  VPNDetector.swift          VPN state detection via netstat/scutil
  Config.swift              Config file + UserDefaults persistence
```

## License

MIT
