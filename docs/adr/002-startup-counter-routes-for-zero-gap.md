# ADR-002: Install counter-routes at startup, not at enforcement time

## Status

Accepted

## Context

Counter-routes (ADR-001) prevent personal traffic from routing through VPN. The question is *when* to install them.

### Option A: During enforcement only

Install counter-routes as part of the `applyOnce()` enforcement flow, alongside intranet routes and catch-all deletion.

### Option B: At app startup

Install counter-routes immediately when the app launches, before VPN connects.

## Decision

**Option B: At app startup.**

## Rationale

Enforcement is event-driven — it fires after detecting catch-all routes with a 0.5s debounce plus a 2s startup delay. If counter-routes are only installed during enforcement, there is a window (potentially seconds) where the VPN's catch-all routes are active and personal traffic leaks through the corporate tunnel.

Installing at startup means counter-routes are in the routing table *before* VPN connects. When VPN adds catch-all routes, they lose to the already-present `/2` routes. Zero timing gap.

The counter-routes are harmless when no VPN is active — traffic already routes through the real interface, and the counter-routes just provide redundant paths to the same gateway.

## Consequences

- Counter-routes require the real gateway IP, which is detected at startup via the routing table
- Counter-routes must be refreshed during enforcement (gateway may have changed since startup)
- Counter-routes must be updated when the real gateway changes (detected via VPNDetector state)
- Counter-routes are removed on app exit and reinstalled on next launch
