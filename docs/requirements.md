# Requirements

## Motivation

The user runs a corporate VPN (Harmony SASE / Perimeter 81 / Check Point) that installs **catch-all routes** (`0.0.0.0/1` and `128.0.0.0/1` via the utun interface). These routes force *all* traffic — including personal browsing, streaming, etc. — through the corporate VPN tunnel.

**The goal is to prevent personal traffic from routing through the corporate VPN.** Only intranet traffic (specific CIDRs and domains configured by the user) should go through VPN. Everything else should use the real network interface (e.g., en0).

There are two reasons for this:

- **Performance**: Routing all traffic through the corporate gateway adds latency, reduces bandwidth, and creates a bottleneck. Video calls, streaming, large downloads, and latency-sensitive applications all suffer unnecessarily when they could use the direct internet connection.
- **Privacy**: Personal browsing activity, DNS queries, and traffic patterns are visible to the corporate network when all traffic routes through VPN. Users should not have to expose personal activity to corporate monitoring just to access a few intranet resources.

This is the opposite of a traditional VPN kill switch. We are *not* trying to protect corporate/intranet traffic from leaking to the internet. We are keeping non-intranet traffic off the corporate network for performance and privacy.

## Functional requirements

### Split tunnel enforcement

- Remove VPN catch-all routes so personal traffic uses the real interface
- Add specific routes for intranet CIDRs via the VPN interface
- Resolve intranet domain names via VPN DNS and add host routes for them
- Configure `/etc/resolver/` files so intranet domain DNS goes through VPN DNS
- Install pf firewall rules to block intranet traffic on the real interface (defense-in-depth for intranet routing, not related to the primary privacy goal)

### Zero-gap protection

Personal traffic must never route through VPN, not even briefly. This means:

- **Counter-routes** (`/2` routes via real gateway) must be installed at app startup, before VPN connects — not just at enforcement time
- When VPN reconnects and re-adds catch-all routes, the counter-routes must already be in place so personal traffic is never exposed
- There must be no timing window where personal traffic could leak through VPN

### Auto-enforcement

- Detect when VPN connects and adds catch-all routes (via route monitor + polling)
- Automatically re-enforce split tunnel when catch-all routes reappear
- Re-apply when config changes (domains/routes edited) while split tunnel is active

### Lifecycle cleanup

The app must restore clean network state in all exit scenarios:

| Scenario | What happens |
|----------|-------------|
| **User quits app** (VPN still connected, split active) | Full restore: re-add catch-all routes, remove pf/resolver/counter-routes/intranet routes |
| **User quits app** (VPN disconnected) | Remove any remaining pf rules, resolver files, counter-routes |
| **VPN disconnects** while split is active | Remove stale resolver files, pf rules, temp files. Reinstall counter-routes for continued protection |
| **App crashes** (SIGKILL, segfault) | On next launch: detect orphaned pf rules, clean up, then install counter-routes |
| **System SIGTERM** | Handled via `applicationShouldTerminate` — same as user quit |

### Configuration

- Editable in the UI: intranet domains, intranet CIDR routes, auto-apply toggle
- Optional JSON config file as bootstrap/defaults (seeds UserDefaults on first launch)
- Config file paths: `~/.config/harmony-split-tunnel/config.json`, `~/.harmony-split-tunnel.json`, `/etc/harmony-split-tunnel/config.json`
- "Reset Config" reloads from config file, discarding UserDefaults overrides

### Update checking

- Notify-only update checker via GitHub Releases API
- No auto-download or auto-install — user clicks through to the release page

## Non-functional requirements

- macOS 13+ (Ventura), Swift 5.9+
- No external dependencies — Apple frameworks only
- Menubar-only app (no dock icon, no main window)
- One-time sudo setup via osascript admin prompt, then passwordless via sudoers rule
- All user-controlled values validated against shell injection before use

## Limitations

- **VPN interface renumbering**: If VPN reconnects on a different utun (e.g., utun3 -> utun4), counter-routes on the old interface are stale. New rules are installed when auto-enforce fires, but there is a brief gap. This is unavoidable without a separate daemon.
- **Config file not watched**: Changes to the JSON config file after first launch have no effect unless the user clicks "Reset Config". UserDefaults takes precedence.
- **Single VPN assumption**: The app assumes one VPN connection at a time. Multiple simultaneous VPNs are not supported.
- **IPv4 only**: No IPv6 split tunnel support.
- **Ad-hoc signing only**: No notarization or Developer ID signing in the default build.
