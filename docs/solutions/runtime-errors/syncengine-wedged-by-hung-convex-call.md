---
title: "SyncEngine permanently wedged by hung Convex network call"
date: 2026-07-13
category: docs/solutions/runtime-errors
module: "WhistleCore/SyncEngine + ConvexService"
problem_type: runtime_error
component: service_object
symptoms:
  - "Captures sit in .queued state for 20+ hours with zero sync attempts despite app running continuously"
  - "Quit-and-relaunch immediately drains and syncs all pending captures"
  - "No crash, same PID throughout — isDraining reentrancy guard stays stuck true permanently"
  - "Every subsequent submit-triggered drain silently no-ops for the rest of that process life"
root_cause: async_timing
resolution_type: code_fix
severity: critical
tags:
  - sync-engine
  - convex
  - timeout
  - reentrancy
  - swift-concurrency
  - wedge
  - periodic-drain
related_components:
  - tooling
---

# SyncEngine permanently wedged by hung Convex network call

## Problem

`SyncEngine`'s reentrancy guard (`isDraining`) became permanently stuck `true`, silently disabling all sync for the rest of the process's life. Two real captures sat in `.queued` state for 20+ hours before a relaunch fixed them instantly — no crash, no error, just perpetual silence.

## Symptoms

- Captures accumulate in `.queued` with zero sync attempts visible in logs
- Manual `.localRetry` clicks produce log activity but nothing syncs
- A fresh quit-and-relaunch immediately drains the queue successfully
- `ps` confirms the same PID throughout — the process never crashed

## What Didn't Work

- **Assuming `drainOnce()` would fail loudly**: the reentrancy guard returns `[]` silently; there was no log to distinguish "queue empty" from "drain coalesced" from "guard stuck."
- **First `withTimeout` implementation using `withThrowingTaskGroup`**: this was believed to bound the hang but Swift's `withThrowingTaskGroup` (SE-0304) cannot return from the group until all child tasks complete or cancel. The convex-swift FFI bindings do not check Swift cooperative cancellation, so the timer child fired and cancelled, but the operation child never responded — the group waited forever. The "fix" didn't fix the wedge.
- **Only timing out mutations/actions but not `loginFromCache`**: the initial fix missed `ensureAuthAttached()`, which calls `loginFromCache()` — a network-touching call with its own potential to hang indefinitely and wedge the guard on the same path. (session history)
- **Relying on trigger-based drains to self-heal**: no proactive periodic retry existed. `SyncBackoff` is defined in `SyncEngine.swift` but has zero call sites — the periodic-timer half was never built.

## Solution

### 1. Rewrite `withTimeout` using unstructured `Task` + `CheckedContinuation`

The fix is in `ConvexService.swift` (see `LiveConvexService.withTimeout`). Instead of `withThrowingTaskGroup`, run the operation in an unstructured `Task` that races against a timer via a single-resume continuation (`TimeoutState`). Whichever finishes first resumes the continuation; the other's result is silently dropped:

```swift
// TimeoutState<T>: single-resume arbiter — first caller wins, second is dropped
private final class TimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func finish(_ outcome: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = outcome
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: outcome)
    }
    // ...
}

static func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let state = TimeoutState<T>()
        state.register(continuation)
        // Operation task — runs freely, result delivered when done
        Task { state.finish(await Result { try await operation() }) }
        // Timer task — fires after timeout, delivers requestFailed error
        Task {
            try? await Task.sleep(for: timeout)
            state.finish(.failure(ConvexServiceError.requestFailed("operation timed out after \(timeout)")))
        }
    }
}
```

Key property: returns the instant the timer fires **regardless of whether the hung operation ever checks cancellation**. The timed-out operation task remains suspended and retains captured state until the underlying call settles; if it never settles, repeated retries can accumulate leaked tasks. This bounds the caller's wait but does not reclaim the underlying work.

### 2. Wrap all three network-touching paths

```swift
private static let authedCallTimeout: Duration = .seconds(15)

private func authedMutation<T: Decodable>(_ name: String, with args: ...) async throws -> T {
    try await ensureAuthAttached()  // also wrapped — see below
    do {
        return try await Self.withTimeout(Self.authedCallTimeout) {
            try await self.client.mutation(name, with: args)
        }
    } catch {
        NSLog("Whistle: Convex mutation %@ failed: %@", name, String(describing: error))
        throw Self.mapAuthError(error)
    }
}

private func authedAction<T: Decodable>(_ name: String, with args: ...) async throws -> T {
    try await ensureAuthAttached()
    do {
        return try await Self.withTimeout(Self.authedCallTimeout) {
            try await self.client.action(name, with: args)
        }
    } catch {
        NSLog("Whistle: Convex action %@ failed: %@", name, String(describing: error))
        throw Self.mapAuthError(error)
    }
}
```

Also wrap `loginFromCache()` inside `ensureAuthAttached` — a hung auth-attach would wedge `isDraining` on the same path before the mutation even starts. `authedQuery`'s one-shot query path shares the same `withTimeout` mechanism indirectly, via `firstValue(from:timeout:)` (default 10s, vs. 15s for mutations/actions).

### 3. Add `recoverStrandedSyncing()` (launch-time cleanup)

`drainPass` marks a draft `.syncing` *before* the awaited network call. If the process is killed mid-call, that draft is frozen `.syncing` forever — even a relaunch won't pick it up because `drainPass` only fetches `.queued`/`.syncFailed`. Call once at launch before the first drain:

```swift
// In WhistleApp.swift, before any drain-triggering Task is started:
Task { [weak syncEngine] in
    await syncEngine?.recoverStrandedSyncing()
    _ = await syncEngine?.drainOnce()
}
```

```swift
// SyncEngine.swift
public func recoverStrandedSyncing() async {
    let stranded: [CaptureDraft]
    do {
        stranded = try store.drafts(in: [.syncing])
    } catch {
        logger("Whistle: SyncEngine failed to read stranded .syncing drafts: \(error)")
        return
    }
    for draft in stranded {
        do {
            try store.updateLocalState(clientId: draft.clientId, to: .queued, localError: nil)
            logger("Whistle: SyncEngine recovered stranded .syncing draft \(draft.clientId) -> .queued")
        } catch {
            logger("Whistle: SyncEngine failed to recover stranded .syncing draft \(draft.clientId): \(error)")
        }
    }
}
```

### 4. Periodic safety-net drain (`runPeriodicDrain`)

A periodic loop independent of all trigger-based paths guarantees a capture is retried within `interval` even if every trigger silently fails:

```swift
// SyncEngine.swift
public func runPeriodicDrain(
    interval: Duration = .seconds(180),
    gate: @escaping @Sendable () async -> Bool = { true }
) async {
    while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        if Task.isCancelled { break }
        guard await gate() else { continue }
        _ = await drainOnce()
    }
}
```

```swift
// WhistleApp.swift
Task { [weak self] in
    await syncEngine.runPeriodicDrain(gate: {
        await MainActor.run { self?.authController?.state == .signedIn }
    })
}
```

`gate` was added after the fact: at the time, `AuthController.signOut()` only flipped local state — nothing detached the Convex websocket's attached auth — so an ungated periodic tick after sign-out would upload any still-queued captures under the previous session. `signOut()` has since been fixed to clear provider credentials and call `ConvexServiceProtocol.detachAuth()` (which resets the attach-once gate), but the drain gate stays as defense in depth and keeps the periodic loop consistent with every other trigger, all of which route through `drainSyncIfSignedIn()`.

Safe to run concurrently with trigger-based drains — the `isDraining`/`rerunRequested` coalescing guard handles overlap.

### 5. Close silent no-op log gaps

Added log lines in `drainOnce()` for both the offline early-return and the coalescing branch (`isDraining` already true), so every path in the drain flow is observable from `log show` alone.

## Why This Works

The root cause is a chain: `authedMutation` (and later `loginFromCache`) had no timeout → the convex-swift FFI can hang without error on a dropped connection that stays "connected" at the OS level → a single hanging `drainOnce()` call suspends indefinitely → `isDraining` stays `true` permanently via `defer` never firing → every subsequent drain silently returns `[]` forever.

The `withThrowingTaskGroup` approach failed because Swift's structured concurrency requires all child tasks to complete before the group yields — `withThrowingTaskGroup` cancels the child operation when the timer fires, but a non-cooperative FFI call ignores Swift cancellation. The unstructured-`Task` + `CheckedContinuation` approach sidesteps this: the timer's `Task` delivers its result to the continuation regardless of what the operation `Task` is doing; the operation task becomes an abandoned background task that keeps its captured state alive until the underlying call settles — which bounds the caller's wait but does not reclaim that work, so a call that never settles leaks for good.

The periodic drain (`runPeriodicDrain`) is intentionally a separate loop from `WhistleApp`'s own network-path-triggered loop (its `pathUpdates()` iteration calling `drainSyncIfSignedIn()` — `SyncEngine` is never driven via its own `runForever()` in the app target) — so a hung or absent network monitor can never suppress the periodic retry too.

## Prevention

- **Always bound network calls with a real timeout** when the underlying FFI does not guarantee cooperative cancellation. `withThrowingTaskGroup` is not sufficient for non-cooperative callers — use the unstructured-`Task` + continuation race instead.
- **Test that the timeout genuinely returns promptly when the operation ignores cancellation.** `ConvexTimeoutTests.testReturnsPromptlyWhenOperationIgnoresCancellation` is the regression guard: it passes a hung, cancellation-ignoring closure and asserts the call returns within a short window (52ms vs a 15s timeout, using a shorter timeout in tests). Without this test, the `withThrowingTaskGroup` version would have passed all "timeout works" tests that used cooperative operations.
- **Audit every path that holds the reentrancy guard**, not just the obvious one. `ensureAuthAttached`/`loginFromCache` was a second wedge vector missed in the initial fix.
- **Nil optional fields should be omitted from Convex mutation args, not sent as `null`**. The backend's `v.optional(...)` validator only accepts the key being absent; sending `null` causes `ArgumentValidationError` (confirmed the root cause of a separate class of sync failures). Extract arg-building to pure static functions so nil-omit encoding is unit-testable without a live client: `ConvexArgEncodingTests` covers `capturesCreateArgs` and `settingsUpdateArgs`.

## Related Issues

- PR #10 — `fix: wire SyncEngine so captures actually reach the Conductor API` (initial wiring + reentrancy guard)
- The subsequent commit on the same branch addresses the P1 correctness findings from the code review of PR #10
- [History window stuck 'Queued' forever — ServerCaptureRecord Convex decode mismatch](../integration-issues/history-window-stuck-queued-convex-decode-mismatch.md) — a *different* root cause behind the same "stuck Queued" symptom (dead decode on the subscription read path vs this doc's hung call on the write path). An engineer debugging one should check the other.
