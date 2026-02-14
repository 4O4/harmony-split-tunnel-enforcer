# ADR-001: Counter-routes over pf rules for privacy protection

## Status

Accepted

## Context

When Harmony SASE re-adds catch-all routes (`0/1`, `128.0/1`), personal traffic briefly routes through the corporate VPN before our app detects and removes them (~0.5s debounce window). We needed a mechanism to prevent personal traffic from ever touching the VPN tunnel.

Two approaches were considered:

### Option A: pf rules on utun interface

Block non-intranet traffic on the VPN interface:

```
pass out quick on utun3 from any to <intranet_cidrs>
block drop out quick on utun3 from any to any
```

### Option B: Counter-routes via real gateway

Install `/2` routes via en0 gateway that are more specific than VPN's `/1` catch-all:

```
0.0.0.0/2     via en0 gateway
64.0.0.0/2    via en0 gateway
128.0.0.0/2   via en0 gateway
192.0.0.0/2   via en0 gateway
```

## Decision

**Option B: Counter-routes.**

## Rationale

pf drops packets — it does not reroute them. When pf blocks a packet on utun, the packet is simply discarded. The OS does not reconsider routing and try another interface. This means Option A would cause personal traffic to **fail** (timeouts, connection errors) rather than **flow through en0**.

Counter-routes solve the problem at the routing layer. Traffic to non-intranet destinations naturally routes to en0 because `/2` routes are more specific than `/1` routes. There are no dropped packets, no timeouts, and no connectivity interruption.

This is the same "more specific route wins" technique that VPNs themselves use (`/1` routes to beat `default`). We go one level deeper (`/2` to beat `/1`).

## Consequences

- Personal traffic flows uninterrupted through en0, even when catch-all routes are present
- Counter-routes must be managed across the app lifecycle (install at startup, refresh on enforcement, clean up on exit)
- If the real gateway changes (network switch), counter-routes must be updated
- The existing en0 pf rules remain for a different purpose: blocking intranet traffic from escaping to the internet (defense-in-depth)
