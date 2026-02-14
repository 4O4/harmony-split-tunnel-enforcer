# ADR-003: Different cleanup strategies per lifecycle event

## Status

Accepted

## Context

The app modifies system state (routes, pf rules, resolver files). When the app exits or VPN disconnects, this state must be cleaned up. Different scenarios require different cleanup approaches because the VPN interface may or may not be available.

## Decision

Three cleanup paths:

### 1. Full restore (`engine.restore()`) — VPN still connected

Used when: user quits the app while split tunnel is enforced.

- Re-add catch-all routes via VPN interface (restores full tunnel)
- Remove pf rules, resolver files, counter-routes, intranet routes, temp file
- Requires VPN interface to be available (for route commands)

### 2. Cleanup (`engine.cleanup()`) — VPN interface gone

Used when: VPN disconnects while split was active, or crash recovery on next launch.

- Remove pf rules, resolver files, counter-routes, temp file
- Does NOT touch routes (VPN interface is gone, OS already cleaned up interface-bound routes)
- Does NOT re-add catch-all (no interface to route through)

### 3. Counter-route removal (`engine.removeCounterRoutes()`) — nothing else to clean

Used when: app quits normally with no split tunnel active and no orphaned rules.

- Only removes the `/2` counter-routes
- Everything else is already clean

## Rationale

A single cleanup function would either need the VPN interface (unavailable after disconnect) or skip route operations (incomplete when VPN is up). Separate paths handle each case correctly.

Industry precedent: Mullvad VPN uses a similar pattern with its "target state" cache to determine the correct cleanup path on daemon restart.

## Consequences

- `applicationShouldTerminate` must detect which path to take based on current state
- Crash recovery on startup checks `hasOrphanedRules()` to detect whether cleanup is needed
- VPN disconnect detection tracks state transitions (`splitActive` → `!connected`)
