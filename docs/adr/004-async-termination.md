# ADR-004: Async termination via applicationShouldTerminate

## Status

Accepted

## Context

On app quit, we need to run cleanup shell commands (route, pfctl, rm). These are synchronous and can take several hundred milliseconds. Running them on the main thread blocks the UI — the popover freezes, the cursor becomes a spinner, and the app appears hung.

### Option A: applicationWillTerminate (synchronous)

Run cleanup in `applicationWillTerminate`. Simple, but blocks the main thread.

### Option B: applicationShouldTerminate with .terminateLater (async)

Return `.terminateLater` from `applicationShouldTerminate`, run cleanup on a background queue, then call `NSApp.reply(toApplicationShouldTerminate: true)` to complete termination.

## Decision

**Option B: Async termination.**

## Rationale

Option A was implemented first and caused a visible UI hang — the popover stayed visible, the cursor became a spinner, and the app appeared unresponsive for the duration of the shell commands. This is a poor user experience for a menubar app.

Option B closes the popover immediately, then runs cleanup in the background. The user sees the app disappear instantly while cleanup happens behind the scenes.

macOS routes SIGTERM through the NSApplication run loop, so `applicationShouldTerminate` covers both user-initiated quit and system shutdown. Only SIGKILL bypasses it (handled by crash recovery on next launch, see ADR-003).

## Consequences

- The popover is explicitly closed (`popover.performClose`) before dispatching to background
- Route monitor and VPN detector are stopped before background dispatch to prevent callbacks during cleanup
- Termination is slightly delayed (shell command execution time) but the delay is invisible to the user
