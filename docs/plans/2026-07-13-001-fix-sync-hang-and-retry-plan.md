---
title: "fix: prevent SyncEngine from silently wedging, add periodic retry safety net"
type: fix
status: active
date: 2026-07-13
origin: live debugging session — captures silently stopped syncing after the app ran for a while, fixed by relaunch
---

# fix: prevent SyncEngine from silently wedging, add periodic retry safety net

## Summary

Two real captures sat in local `.queued` state for 20+ hours with **zero** sync attempts, despite Whistle running continuously and each submit supposedly triggering an immediate drain. A fresh quit+relaunch drained and synced both instantly. The process never crashed (confirmed via `ps` — same PID, continuously alive) and the wiring that routes every submit through `onCaptureSubmitted` → `drainOnce()` is structurally sound (verified by reading `CapturePanelController.swift` — it's a single persistent controller instance, not recreated per-trigger).

The most plausible mechanism: `SyncEngine`'s reentrancy guard (`isDraining`, added in the prior PR) is only reset via `defer` when a `drainOnce()` call *returns*. Neither `authedMutation` nor `authedAction` in `ConvexService.swift` has any timeout — confirmed by reading the file; only the one-shot query path (`firstValue(from:timeout:)`) has one, via a `withThrowingTaskGroup` race against `Task.sleep`. If a mutation call (e.g. `capturesCreate`) ever hangs instead of failing (a dropped connection with no error, a sleep/wake or wifi-handoff edge case), that one `drainOnce()` call suspends forever, `isDraining` stays stuck `true` permanently, and every subsequent submit-triggered drain silently no-ops for the rest of that process's life — indistinguishable from "stopped working after a while" from the outside.

Separately: **no proactive periodic retry exists today.** `SyncBackoff` (a backoff-delay calculator) is defined in `SyncEngine.swift` but is dead code — confirmed via repo-wide grep, it has zero call sites. The design was always "the app target wires a periodic timer or connectivity callback" (per `SyncEngine`'s own doc comments), but that periodic-timer half was never actually built — retries only happen on launch, network-path-change, submit, or the manual `.localRetry` click. If a trigger-based path silently fails for any reason (the wedge above, or something else), nothing else will ever retry it.

## Requirements

- R1. A hung Convex network call must not permanently disable syncing for the rest of the process's life — it must fail (and be retried) instead of blocking forever.
- R2. There must be a periodic safety-net drain independent of submit/network-change triggers, so a one-off trigger failure self-heals within a bounded time instead of requiring a manual relaunch.
- R3. It must be possible to tell, from logs alone, whether a submit actually triggered a drain attempt — closing the remaining silent-no-op gaps (the coalescing branch currently logs nothing either).

**Non-goals:** replacing `SyncBackoff`'s unused per-attempt backoff curve with something smarter (out of scope — the periodic safety net uses a simple fixed interval; wiring real backoff into it is a fine follow-up, not required here). No change to the reentrancy-guard design itself (`isDraining`/`rerunRequested` stay as-is) — the fix is making the thing it guards against (a hang) impossible, not removing the guard.

## Key Technical Decisions

1. **Add a timeout wrapper to `authedMutation`/`authedAction`, mirroring the existing `firstValue(from:timeout:)` pattern** (`ConvexService.swift`) rather than inventing a new mechanism. Extract a shared generic helper (`withTimeout(_:operation:)`) both `firstValue` and the mutation/action wrappers can call, instead of duplicating the race plumbing three times. **Important:** the race itself cannot use `withThrowingTaskGroup`'s "cancel the loser" shape — a task group cannot return until every child task has finished or cancelled (SE-0304), and the convex-swift 0.8.1 FFI call (`uniffiRustCallAsync`) never checks `Task.isCancelled`, so a genuinely hung call would keep a group child running forever and the group would never return, reintroducing the exact permanent wedge this plan exists to fix. Instead, race an unstructured `Task` running `operation` against a timer `Task`, with a single-resume `CheckedContinuation` (guarded by a small `TimeoutState` arbiter) delivering whichever finishes first. This returns the instant the timer fires — regardless of whether the hung operation ever observes cancellation — at the cost of leaking the abandoned operation task in the background until the underlying call eventually settles on its own.
2. **Timeout at the `ConvexService` layer, not inside `SyncEngine`.** Every Convex call in the app benefits from this (settings updates, retries, template edits — not just the sync path), and it keeps `SyncEngine` itself unchanged (it already correctly treats any thrown error from `syncOne` as a normal failure — `catch`, increment attempt, mark `.syncFailed`, log). A timeout that surfaces as a thrown `ConvexServiceError` needs no new handling there.
3. **Periodic safety net as a second, independent loop, not a rewrite of `runForever()`.** Add a small `runPeriodicDrain(interval:)` method that just does `while true { try? await Task.sleep(...); _ = await drainOnce() }`, started as its own `Task` alongside the existing `Task { await syncEngine.runForever() }` in `WhistleApp.swift`. `drainOnce()`'s own coalescing guard already makes it safe for two independent loops to both call it — no new synchronization needed. This is simpler and lower-risk than merging the periodic tick into `runForever()`'s existing (tested) `for await` loop over `pathUpdates()`. Default interval: 3 minutes — cheap when the queue is empty (one SQLite read, early return), frequent enough to self-heal a wedge or missed trigger without meaningful battery/network cost.
4. **Log the two remaining silent paths** in `drainOnce()`: the coalescing branch (`if isDraining { rerunRequested = true; return [] }` — currently logs nothing) and the fire point in `CapturePanelController.handleSubmit()` (currently nothing logs that a submit actually invoked `onCaptureSubmitted`). Together with the offline-path log added yesterday, this makes every early-return in the drain path observable, so a future recurrence is diagnosable from `log show` alone rather than requiring live instrumentation again.

## Implementation Units

### U1. Add a timeout to `authedMutation`/`authedAction`

**Goal:** A hung Convex mutation/action call fails after a bounded time instead of suspending forever and permanently wedging `SyncEngine`'s reentrancy guard.

**Requirements:** R1.

**Files:**
- Modify: `packages/whistle-core/Sources/WhistleCore/ConvexService.swift`

**Approach:** Extract a small generic helper near `firstValue(from:timeout:)`, e.g.:
```swift
static func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T
```
implemented as an unstructured `Task` running `operation`, raced against a timer `Task`, with a single-resume `CheckedContinuation` (via a small `TimeoutState` arbiter) delivering whichever finishes first. **Not** a `withThrowingTaskGroup` race: a task group cannot yield until every child completes or cancels, and the convex-swift FFI call never observes Swift cancellation, so a group-based race against a genuinely hung call would never return — reintroducing the permanent `isDraining` wedge this plan exists to fix. The unstructured-task shape sidesteps that: it returns the instant the timer fires no matter what the operation task is doing, leaving that task to leak harmlessly in the background until the underlying call eventually settles. Wrap `client.mutation(name, with: args)` and `client.action(name, with: args)` in `authedMutation`/`authedAction` with this helper. Default timeout: 15 seconds (generous enough for a real slow network, short enough that a genuine hang self-resolves quickly relative to how long this one sat wedged). On timeout, throw the same kind of `ConvexServiceError` the existing query timeout uses, so `NSLog("Whistle: Convex mutation %@ failed: %@", ...)` still fires for it like any other failure.

**Patterns to follow:** `firstValue(from:timeout:)` (same file, ~10 lines above the sync/one-shot-query section) shares this same `withTimeout` helper, not a task-group shape.

**Test scenarios:**
- A mutation whose underlying `client.mutation` call never resolves times out and throws within roughly the configured timeout window (not immediately, not hanging past it) — use a fake/delayed operation, not a real network call, to keep this deterministic.
- A mutation that resolves quickly still returns its real value unaffected by the timeout wrapper (no regression to the happy path).
- A mutation that throws its own error (not a timeout) still surfaces that original error, not a timeout error.
- Existing `authedMutation`/`authedAction` callers (settings update, capture create, etc.) are unaffected — full existing test suite still passes.

**Verification:** `swift test` in `packages/whistle-core`.

---

### U2. Periodic safety-net drain

**Goal:** A capture that misses every trigger-based drain (submit, network-change, launch) still syncs within a bounded time, without requiring a manual relaunch.

**Requirements:** R2.

**Dependencies:** None (independent of U1, though U1 is what makes this actually close the loop rather than just polling a permanently-wedged actor).

**Files:**
- Modify: `packages/whistle-core/Sources/WhistleCore/SyncEngine.swift`
- Modify: `apps/macos/Whistle/WhistleApp.swift`

**Approach:** Add `public func runPeriodicDrain(interval: Duration = .seconds(180)) async { while true { try? await Task.sleep(for: interval); _ = await drainOnce() } }` to `SyncEngine`. In `WhistleApp.swift`, right alongside the existing `Task { await syncEngine.runForever() }`, add `Task { await syncEngine.runPeriodicDrain() }`. No changes to `runForever()` itself.

**Test scenarios:**
- `runPeriodicDrain` calls `drainOnce()` roughly every `interval` (use a short interval like a few milliseconds in the test and a fake clock/short sleep, asserting at least 2-3 drain calls happen over a bounded test window — mirror the existing `SyncEngineTests` style of injecting fakes rather than sleeping real wall-clock seconds where avoidable).
- Overlapping with a concurrent `drainOnce()` call from another source (e.g. a simulated submit trigger) coalesces correctly via the existing `isDraining` guard — no double-processing (this should fall out of the existing coalescing test's guarantees, but worth a quick assertion that `runPeriodicDrain` doesn't bypass it).

**Verification:** `swift test` in `packages/whistle-core`; manually confirm via `log show` that `"Whistle: SyncEngine draining"` (or a no-op empty-queue tick, silently) appears roughly every 3 minutes during a real run.

---

### U3. Close the remaining silent-no-op logging gaps

**Goal:** Every early-return path in the drain flow is observable from `log show` alone.

**Requirements:** R3.

**Dependencies:** None.

**Files:**
- Modify: `packages/whistle-core/Sources/WhistleCore/SyncEngine.swift`
- Modify: `apps/macos/Whistle/Capture/CapturePanelController.swift`

**Approach:** In `SyncEngine.drainOnce()`, add a log line in the coalescing branch (`if isDraining { rerunRequested = true; return [] }`) — e.g. `logger("Whistle: SyncEngine drain already in flight, requesting rerun")`. In `CapturePanelController.handleSubmit()`, log immediately before calling `onCaptureSubmitted(clientId)` (this lives in the app target, not `WhistleCore`, so use `NSLog` directly matching that file's existing convention, e.g. the trigger-timing log already in this file) — e.g. `NSLog("Whistle: capture submitted, clientId=%@", clientId)`.

**Test scenarios:**
- `drainOnce()` coalescing branch: existing coalescing test (`testConcurrentDrainOnceCallsDoNotDoubleProcessSameDraft`) already exercises this path — extend its logger assertion to also check for the new "already in flight" message on the coalesced call.
- No test needed for the `NSLog` in `CapturePanelController` (no existing test target exercises `handleSubmit()`'s internals at that granularity, and `NSLog` output isn't asserted anywhere else in this file's tests) — verify manually via `log show` after a real submit.

**Verification:** `swift test` in `packages/whistle-core`; manual `log show` check after a real capture submit shows the new "capture submitted" line immediately followed by either a drain or an "already in flight" line.

---

## Verification (end-to-end)

1. `swift test` in `packages/whistle-core` — all tests including new U1/U2/U3 coverage pass.
2. Build and install the app; submit several captures in quick succession and confirm via `log show` that each submit logs, each drain attempt logs, and nothing silently disappears.
3. Leave the app running for an extended period (hours) without relaunching and confirm captures still sync — the real test this whole plan exists for, since the original bug only manifested after "a while." If feasible, simulate a hang directly (e.g., temporarily point `CONVEX_URL` at an address that accepts a connection but never responds) to confirm U1's timeout actually fires and recovers within the expected window, rather than only relying on waiting for a natural recurrence.
4. Confirm the periodic drain log line appears on its own (not just submit-triggered) roughly every 3 minutes during an idle period with no captures pending.
