# ADR-005: No auto-enforce suppression after VPN disconnect cleanup

## Status

Accepted

## Context

After a **manual restore** (user clicks "Remove Enforcement"), `suppressAutoEnforce` is set to `true` for 5 seconds. This prevents the route monitor from immediately re-triggering enforcement as VPN routes stabilize.

The question is whether the same suppression should apply after **VPN disconnect cleanup**.

## Decision

**Do not suppress auto-enforce after VPN disconnect cleanup.**

## Rationale

VPN reconnection can happen within seconds of disconnect. If auto-enforce is suppressed for 5 seconds after disconnect, the VPN may reconnect and add catch-all routes during the suppression window. The auto-enforce debounce fires but is suppressed, and the user ends up in full tunnel mode with no enforcement.

This was observed in practice: VPN disconnected at T+0, cleanup ran and set `suppressAutoEnforce = true`, VPN reconnected at T+2, catch-all routes added, auto-enforce debounce fired at T+2.5 and was suppressed. The user's traffic was routing through VPN with no enforcement.

The 5-second suppression is only needed for manual restore because the user explicitly chose to disable enforcement and the route changes from restore itself could trigger false RTM_ADD events. VPN disconnect cleanup generates RTM events from counter-route reinstallation, but these are harmless — the debounce checks `hasCatchAll` and won't auto-enforce if there are no catch-all routes.

## Consequences

- VPN reconnection after disconnect immediately triggers auto-enforce (desired behavior)
- Route events from counter-route reinstallation during cleanup may trigger a debounce cycle, but it correctly finds no catch-all routes and skips enforcement
