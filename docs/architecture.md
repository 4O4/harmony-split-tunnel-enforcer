# Architecture

## Routing fundamentals

macOS uses longest-prefix-match routing: more specific routes win. The VPN exploits this by adding two `/1` routes instead of a single `default` route:

```
0.0.0.0/1     via utun3   ← more specific than default (0.0.0.0/0)
128.0.0.0/1   via utun3   ← more specific than default
default       via en0     ← loses to /1 routes
```

We exploit the same principle at two levels:

1. **Counter-routes** (`/2`) beat VPN catch-all (`/1`) — personal traffic stays on en0
2. **Intranet routes** (`/8`, `/16`, etc.) beat counter-routes (`/2`) — intranet traffic goes through VPN

```
10.0.0.0/8        via utun3   ← intranet, most specific, wins
0.0.0.0/2         via en0     ← counter-route, beats /1
64.0.0.0/2        via en0     ← counter-route, beats /1
128.0.0.0/2       via en0     ← counter-route, beats /1
192.0.0.0/2       via en0     ← counter-route, beats /1
0.0.0.0/1         via utun3   ← VPN catch-all, loses to /2
128.0.0.0/1       via utun3   ← VPN catch-all, loses to /2
default           via en0     ← default, least specific
```

## Enforcement flow

Order matters — this prevents traffic leaks:

1. Add intranet CIDR routes via VPN interface
2. Resolve intranet domain IPs via VPN DNS, add host routes
3. Refresh counter-routes via real gateway (ensures they point to current gateway)
4. Delete catch-all routes (`0/1`, `128.0/1`) from VPN interface
5. Write `/etc/resolver/{domain}` files for DNS
6. Install `pf` firewall rules under `com.apple/p81split` anchor

Counter-routes are installed *before* catch-all deletion (step 3 before step 4) so personal traffic is always protected, even if a race condition prevents step 4 from completing.

## Counter-routes lifecycle

```
App starts
  └─ Detect real gateway
  └─ Install /2 counter-routes ← protection active immediately

VPN connects (catch-all routes added)
  └─ Counter-routes already in place ← zero leak window
  └─ Auto-enforce fires (0.5s debounce)
      └─ Adds intranet routes via utun
      └─ Refreshes counter-routes (gateway may have changed)
      └─ Deletes catch-all routes

VPN reconnects (catch-all routes re-added by SASE)
  └─ Counter-routes still in place ← personal traffic safe
  └─ Auto-enforce fires again

Gateway changes (Wi-Fi → Ethernet)
  └─ Detected via VPNDetector state change
  └─ Counter-routes reinstalled with new gateway

VPN disconnects
  └─ Cleanup: remove pf, resolver, temp files
  └─ Reinstall counter-routes ← ready for next VPN connection

App quits
  └─ Full restore or cleanup depending on VPN state
  └─ Counter-routes removed (app is exiting)

App crashes
  └─ On next launch: detect orphaned pf rules
  └─ Clean up, then install fresh counter-routes
```

## pf firewall rules

The pf rules under `com.apple/p81split` anchor serve a **different purpose** than counter-routes:

```
block drop out quick on en0 from any to <p81_intranet>
block drop out quick on en0 from any to 10.0.0.0/8
```

These block **intranet** traffic from going out the **real interface**. This is defense-in-depth for intranet routing correctness — if an intranet route is somehow missing, pf prevents the traffic from escaping to the internet. **These rules do not protect personal traffic** — that is handled entirely by counter-routes.

Why not pf rules on utun to block personal traffic? Because pf drops packets — it doesn't reroute them. Blocking personal traffic on utun would cause connection failures, not fallback to en0. Counter-routes solve this at the routing layer instead, where traffic naturally flows to the correct interface.

## Termination handling

`applicationShouldTerminate` returns `.terminateLater` to run cleanup asynchronously on a background queue, preventing the UI from hanging. Once cleanup completes, it calls `NSApp.reply(toApplicationShouldTerminate: true)` to finalize termination.

This covers user-initiated quit and system SIGTERM. SIGKILL cannot be caught — crash recovery on next launch handles that case.

## Auto-enforce suppression

After a **manual restore** (user clicks "Remove Enforcement"), auto-enforce is suppressed for 5 seconds to let routes stabilize. Without this, the route monitor would immediately re-trigger enforcement.

After a **VPN disconnect**, auto-enforce is *not* suppressed. The VPN may reconnect quickly (within seconds), and we want auto-enforce to fire immediately when catch-all routes reappear.

## Thread safety

- `RouteMonitor`: `_process` and `_isRunning` behind a `DispatchQueue` sync lock
- `Config.ConfigSnapshot`: main-thread snapshot for passing config to background threads
- `SplitTunnelEngine.log()`: serial `DispatchQueue` for file writes
- `VPNDetector.detect()`: runs on background queue, publishes state on main thread
- All shell commands in `SplitTunnelEngine` are synchronous within their dispatch context
