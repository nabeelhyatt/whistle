---
title: "fix: Wire SyncEngine so captures actually reach the Conductor API"
type: fix
status: active
date: 2026-07-11
origin: live debugging session — user-reported "sending captures but no worktree opens"
---

# fix: Wire SyncEngine so captures actually reach the Conductor API

## Summary

Submitting a capture in the panel does not open a Conductor workspace/worktree, and fails silently. Root cause, confirmed by direct code reading (not inference): `SyncEngine` — the component that drains the local capture queue and calls Convex's `captures.create` mutation — is fully implemented and unit-tested in `packages/whistle-core` but is **never instantiated or run anywhere in the app target** (`apps/macos/Whistle/WhistleApp.swift`). A submitted capture is written to local SQLite as `queued` and sits there forever; the Convex pipeline and the Conductor `POST /v0/workspaces` call are never reached. Once reconnected, failures anywhere in the chain also need to be visible — today there is no logging on the sync-drain failure path, none in the Convex backend, and the "local retry" UI affordance for a stuck capture renders as an empty view.

This plan wires `SyncEngine` into the app lifecycle, adds logging at the points that are currently silent, and wires the dead retry button. No product behavior changes — this is closing a construction gap in already-designed, already-tested infrastructure (TECH-SPEC calls this step "plan U8").

---

## Problem Frame

The intended pipeline is:

```
Capture Panel submit → local SQLite queue (CaptureStore, pending_captures table)
  → SyncEngine.drainOnce() → Convex `captures.create` mutation
  → Convex `pipeline.submit` action → conductorClient.createWorkspace()
  → POST /v0/workspaces (Conductor API)
```

`grep -rn "SyncEngine(" apps/macos` returns zero results. `WhistleApp.swift`'s `applicationDidFinishLaunching` wires up every other subsystem (auth, status item, `ProjectsSyncCoordinator`, `HistoryViewModel`, `CapturePanelController`) but never constructs a `SyncEngine` or calls `drainOnce()`/`runForever()`. The Conductor-call layer itself (`conductorClient.ts`, `pipeline.ts`) is well-built — proper status checks, typed errors, idempotent workspace-ready polling — it is simply never reached.

Full research trail: two `Explore` passes (Conductor API integration trace; retry-UI + TECH-SPEC wiring intent) plus a design pass, all with file:line citations, cross-checked by direct reads of `WhistleApp.swift`, `SyncEngine.swift`, `CapturePanelController.swift`, and `pipeline.ts` in this session.

---

## Requirements

- R1. A submitted capture must reach Convex's `captures.create` mutation without requiring a network state change or app restart, so the Conductor pipeline actually runs.
- R2. `SyncEngine` failures (queue-read errors, screenshot upload errors, `captures.create` errors) must be visible in a developer-facing log (Console.app / `log stream`), matching the existing `NSLog` convention already used by `LiveConvexService`.
- R3. Conductor API / Convex pipeline failures must be visible in the Convex dashboard's live function logs, not only queryable after the fact via DB fields.
- R4. A capture stuck in local `syncFailed` state must have a working manual retry affordance in History (today `.localRetry` renders `EmptyView()`).

**Non-goals:** no product-behavior change to the capture flow itself, no new UI, no periodic background timer (retries happen on launch / network-change / submit / manual retry, matching the existing affordance model — see Risks).

---

## Scope Boundaries

In scope: SyncEngine construction/lifecycle wiring, SyncEngine logging seam, Convex backend error logging, `.localRetry` button wiring.

### Deferred to Follow-Up Work

- `HistoryWindow.swift`'s other fire-and-forget `try? await` calls (`openDeepLink`, `archive`, server-side `retry`) that silently discard errors — lower priority, `LiveConvexService` already NSLogs these mutation failures generically, so this is marginal added value, not a correctness gap. Address in a separate pass if it proves confusing in practice.
- Adding a periodic timer for `syncFailed` retries — the spec's affordance model (retry on network-change/submit/manual-click) is intentional; revisit only if manual retries prove insufficient in the field.

---

## Context & Research

- **`packages/whistle-core/Sources/WhistleCore/SyncEngine.swift`**: `actor SyncEngine` with `init(store:convex:uploader:networkMonitor:)`, `drainOnce() async -> [String]` (safe to call anytime/offline), `runForever() async` (loops on `networkMonitor.pathUpdates()`, draining on every `online` event), and `NWPathMonitorNetworkMonitor` (production `NetworkMonitoring`, already implemented). Doc comment explicitly defers scheduling to "the app target (e.g. a periodic timer or connectivity callback)" — this was designed to be wired externally, not a regression.
- **`packages/whistle-core/Tests/WhistleCoreTests/SyncEngineTests.swift`**: constructs `SyncEngine` with fakes (`FakeNetworkMonitor`), calls `drainOnce()` directly — canonical construction pattern for new unit tests.
- **`apps/macos/Whistle/WhistleApp.swift`**: `applicationDidFinishLaunching` (`AppDelegate`) is the sole wiring point for app-lifetime singletons; `ProjectsSyncCoordinator` (`Task { await projectsSyncCoordinator.start() }`) is the direct pattern to mirror for `SyncEngine`. **Critical trap**: `showOnboardingIfNeeded()` *reassigns* `capturePanelController.onCaptureSubmitted` outright to advance the onboarding wizard — on first run, a naive reassignment would silently clobber a drain-trigger closure.
- **`apps/macos/Whistle/Capture/CapturePanelController.swift:125`**: `public var onCaptureSubmitted: (String) -> Void = { _ in }`, fired from `handleSubmit()` after a successful local save — confirmed present, already threading a `clientId`.
- **`apps/macos/Whistle/Capture/CaptureViewModel.swift`**: `submit()` deliberately does zero network I/O ("NO network on the submit path, ever") — this contract must not be violated; the drain trigger belongs in the app-target wiring, not inside `submit()`.
- **`apps/macos/Whistle/History/HistoryRow.swift` (lines ~96-108)** / **`packages/whistle-core/Sources/WhistleCore/StatusPresentation.swift` (lines ~15-23)**: `.serverRetry` already has a working `Button("Retry", action: onRetry)`; `.localRetry` falls into the same case arm as `.automatic, .none` → `EmptyView()`. `.localRetry` is documented as "re-run the local SyncEngine drain for this capture" — distinct from server-side `captures.retry`.
- **`packages/backend/convex/conductorClient.ts`**: `conductorFetch` (single fetch entrypoint) already classifies errors (`auth`/`workspaceSetup`/`network`/`duplicateMessage`) and throws `ConductorApiError`, but has zero `console.*` calls.
- **`packages/backend/convex/pipeline.ts`**: `handleTransientOrTerminal` (~line 435) is the shared transient/terminal decision point for `submit`'s outer catch — currently silent. Three additional silent `void err` catches in `awaitWorkspaceReady`, `watch`, `watchdog`.
- No `docs/solutions/` directory exists yet in this repo (nothing to check for prior institutional learnings on this exact gap).

---

## Key Technical Decisions

1. **Construct `SyncEngine` in `applicationDidFinishLaunching` with `NWPathMonitorNetworkMonitor` + `Task { await syncEngine.runForever() }`, AND also trigger an immediate `drainOnce()` from `onCaptureSubmitted`.** Neither alone is sufficient: `runForever()`'s monitor yields current state at subscription time, so it covers the at-launch case (flushing anything stranded from a prior session), but `NWPathMonitor` may not emit another event for hours on a stable connection — a capture submitted mid-session needs the post-submit trigger to sync without an arbitrary wait. The trigger is wired in `AppDelegate`, not inside `CaptureViewModel.submit()`, preserving submit's "no network on this path" contract and keeping scheduling ownership in the app target as `SyncEngine`'s own doc comment prescribes.
2. **Logging via an injected seam (`logger` closure, default `{ NSLog(...) }`), not a hardcoded `NSLog` call.** `SyncEngine.swift` already treats every side-effecting dependency (`uploader`, `networkMonitor`) as an injected, test-fakeable seam, and it's documented as platform-logging-agnostic ("No AppKit/UIKit"). A defaulted closure parameter keeps every existing call site (including `SyncEngineTests.swift`) unchanged while making failures visible by default via the same `NSLog` convention `LiveConvexService` already uses.
3. **Convex backend logging centralized at two chokepoints**: `conductorFetch` (every Conductor HTTP error passes through here) and `pipeline.ts`'s failure-decision points (`handleTransientOrTerminal` plus the three silent catches). Convex dashboard function logs show `console.*` output in real time; today's DB-field-only recording (`status: "failed"`, `errorCode`) is queryable but not visible as it happens.
4. **Wire `.localRetry` to a full `drainOnce()`, not a per-row targeted retry.** `drainOnce()` already re-attempts every `.queued`/`.syncFailed` draft, is idempotent, and the server dedupes on `(userId, clientId)` — draining everything on a manual retry click is simpler than adding per-capture targeting and has no downside.

---

## Open Questions

### Resolved during planning
- Whether a periodic timer is needed for `syncFailed` retries: no — launch, network-change, submit, and manual retry cover the affordance model as designed (see Scope Boundaries).
- Whether the post-submit drain trigger belongs in `CaptureViewModel` or the app target: app target (`AppDelegate`), to preserve `submit()`'s no-network-on-this-path contract.

### Deferred to implementation
- Whether to add the optional actor-reentrancy guard in `SyncEngine` (coalescing overlapping `drainOnce()` calls) — correctness does not depend on it (server-side dedupe on `clientId` makes overlap safe), but it avoids a wasted duplicate screenshot upload. Include if low-risk during implementation; skip without re-planning if it complicates the actor's state.

---

## Implementation Units

> Execution order: U2 → U1 → U4 (U1 depends on U2's logger existing as a default param, though technically independent; U4 depends on U1's `syncEngine` instance existing in `AppDelegate`). U3 is independent (Convex/TypeScript, no dependency on the Swift changes) and can run in parallel with U1/U2.

### U1. Construct and start `SyncEngine` in the app lifecycle

**Goal:** A submitted capture reaches Convex `captures.create` without requiring a network-state change or restart.

**Requirements:** R1.

**Dependencies:** U2 (logger default param should exist first, though not strictly blocking).

**Files:**
- Modify: `apps/macos/Whistle/WhistleApp.swift`

**Approach:** In `AppDelegate`, add `private var syncEngine: SyncEngine?`. In `applicationDidFinishLaunching`, right after the existing `ProjectsSyncCoordinator` block, construct `SyncEngine(store: store, convex: convexService, networkMonitor: NWPathMonitorNetworkMonitor())`, store it, and start `Task { await syncEngine.runForever() }`. In the `capturePanel` wiring block, set `capturePanel.onCaptureSubmitted = { [weak syncEngine] _ in Task { await syncEngine?.drainOnce() } }`. Fix the onboarding clobber in `showOnboardingIfNeeded()`: capture the existing `onCaptureSubmitted` closure and call it before `viewModel?.noteTestCaptureSubmitted()`, rather than replacing it outright.

**Test scenarios:**
- Integration/manual: submit a capture while online → History row transitions from "Queued" to a server-driven status within one drain cycle; the capture appears in the Convex `captures` table; a real Conductor workspace opens via the deep link.
- Integration/manual: complete onboarding's guided test capture on a fresh install (first run) → confirm the test capture still reaches Convex AND the onboarding wizard still advances to the screenshot-upsell step (regression check for the composition fix — this is the scenario most likely to silently break if the clobber fix is done wrong).
- Manual: submit a capture while offline → row shows `syncFailed` (not stuck `queued` forever, not crashed); reconnecting network drains it automatically.

**Verification:** Build and run the macOS app; drive the two integration scenarios above manually (AppKit app-lifecycle wiring is not practically unit-testable in this codebase's existing test setup — no `AppDelegate` test target exists today).

---

### U2. Add a logger seam and failure visibility to `SyncEngine`

**Goal:** `SyncEngine` failures are visible in Console.app / `log stream` instead of only written to local SQLite.

**Requirements:** R2.

**Dependencies:** none.

**Files:**
- Modify: `packages/whistle-core/Sources/WhistleCore/SyncEngine.swift`
- Modify/extend: `packages/whistle-core/Tests/WhistleCoreTests/SyncEngineTests.swift`

**Approach:** Add `private let logger: @Sendable (String) -> Void` and an init parameter `logger: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }` as the last (defaulted) parameter, so existing call sites are unaffected. In `drainOnce()`: log when a non-empty batch starts draining (count), log each successful sync (`clientId` → `serverId`), log each failure (`clientId` + error) alongside the existing `updateLocalState(..., localError:)` call, and log the currently-silent `store.drafts(...)` read failure before returning early. Prefix messages `"Whistle: SyncEngine ..."` to match `ConvexService.swift`'s existing convention. Optionally add the reentrancy-coalescing guard from Open Questions in the same pass if it stays simple.

**Test scenarios:**
- Happy path: `drainOnce()` with one queued draft and a succeeding fake `convex`/`uploader` → injected test logger receives a "synced `<clientId>`" message.
- Failure path: fake `convex.capturesCreate` throws → logger receives a "sync failed for `<clientId>`" message; local state moves to `.syncFailed` (existing assertion, now also check the log).
- Edge case: empty queue (`store.drafts(in:)` returns `[]`) → logger receives no drain-start message.
- Error path: `store.drafts(in:)` throws → logger receives a message describing the read failure (currently silent — new coverage).
- Concurrency (if the coalescing guard is added): two `drainOnce()` calls fired back-to-back against the same queued draft do not both call `convex.capturesCreate` for it.

**Verification:** `swift test` in `packages/whistle-core`.

---

### U3. Add error logging in the Convex backend Conductor-call path

**Goal:** Conductor API / pipeline failures appear in the Convex dashboard's live function logs.

**Requirements:** R3.

**Dependencies:** none (independent of U1/U2/U4).

**Files:**
- Modify: `packages/backend/convex/conductorClient.ts`
- Modify: `packages/backend/convex/pipeline.ts`

**Approach:** In `conductorFetch`: add `console.error` on the network-level catch (method, path, error message) and on the `!res.ok` branch (method, path, status, `errorClass`) — never log the API key or request body. In `pipeline.ts`: add a small `logPipelineError(stage, captureId, err, extra?)` helper; call it from `handleTransientOrTerminal` (log the decision taken — reschedule-with-backoff vs. terminal), and replace the three silent `void err` catches (`awaitWorkspaceReady`, `watch`, `watchdog`) with calls to it, preserving existing reschedule/patch behavior exactly.

**Test scenarios:**
- `conductorFetch` receiving a network-level throw (e.g. fetch rejects) → `console.error` called with method/path/message.
- `conductorFetch` receiving a non-2xx response → `console.error` called with status and `errorClass`.
- `pipeline.submit` hitting an auth-class `ConductorApiError` → terminal `failed`/`auth` patch, and the new log call fires with that decision.
- `pipeline.submit` hitting a transient error under `MAX_SUBMIT_ATTEMPTS` → attempt incremented, reschedule occurs, and the log call records "rescheduling" rather than "terminal."
- Each of `awaitWorkspaceReady`, `watch`, `watchdog`'s catch blocks logs on the existing failure paths already covered by that file's test suite (no new failure paths introduced — verifying the logging call doesn't change existing pass/reschedule/patch behavior).

**Verification:** Run the `packages/backend` test suite; then `npx convex dev`, submit a capture with a deliberately invalid API key, and confirm the error appears in the Convex dashboard's live function logs.

---

### U4. Wire the dead `.localRetry` button

**Goal:** A capture stuck in local `syncFailed` state has a working manual retry.

**Requirements:** R4.

**Dependencies:** U1 (needs `syncEngine` to exist in `AppDelegate`).

**Files:**
- Modify: `apps/macos/Whistle/History/HistoryWindow.swift`
- Modify: `apps/macos/Whistle/History/HistoryRow.swift`
- Modify: `apps/macos/Whistle/WhistleApp.swift`

**Approach:** Add `public var onLocalRetryRequested: () -> Void = {}` and a `localRetry(_:)` method to `HistoryViewModel`, mirroring the existing `onOpenSettings`-style closure. In `HistoryRow.swift`, split the `.localRetry, .automatic, .none` case so `.localRetry` gets its own `Button("Retry", action: onLocalRetry)`, matching the existing `.serverRetry` button; add the `onLocalRetry: () -> Void = {}` param and pass it through from the `HistoryWindow` view body. In `WhistleApp.swift` (after both `historyViewModel` and `syncEngine` exist), wire `historyViewModel.onLocalRetryRequested = { [weak syncEngine] in Task { await syncEngine?.drainOnce() } }`.

**Test scenarios:**
- A row with `.localRetry` affordance renders a visible "Retry" button, not `EmptyView()`.
- Clicking that button invokes `onLocalRetry`, which invokes `HistoryViewModel.onLocalRetryRequested`.
- Integration/manual: a manually-stuck (`syncFailed`) capture, after clicking Retry, triggers `syncEngine.drainOnce()` and (if now online) transitions out of `syncFailed`.

**Verification:** Existing `HistoryRow`/`HistoryViewModel` test target (view-model level assertions on the closure wiring) plus one manual click-through.

---

## Risks and Edge Cases

- **Onboarding clobber** (`showOnboardingIfNeeded()`): the highest-risk trap in this plan. U1's fix is mandatory — without it, first-run captures (including the onboarding wizard's own guided test capture) regress to never-syncing, i.e. exactly today's bug, just reintroduced by unrelated onboarding code.
- **Actor isolation**: `AppDelegate`/`HistoryViewModel` are `@MainActor`; all `SyncEngine` calls must go through `Task { await ... }`, never called synchronously from UI closures.
- **Duplicate drains**: a network-change-triggered drain and a post-submit-triggered drain can interleave. Server-side `(userId, clientId)` dedupe makes this correctness-safe (worst case: one wasted duplicate screenshot upload); the optional U2 coalescing guard eliminates even that, but is not required for correctness.
- **`NWPathMonitorNetworkMonitor.lastStatus` defaults `true`** before the first real `NWPath` callback, so a genuinely-offline launch may attempt one doomed drain before self-healing on the real online event (the draft lands in `syncFailed`, which `drainOnce()` already retries). Expected; will show as an initial log burst on offline launches — not a bug.
- **Auth race at launch**: `auth.resolveInitialState()` runs concurrently with the new launch-time drain; the very first drain attempt may fire before Convex auth attaches and fail, then succeed on the next trigger. Same self-healing path as above.

---

## Verification (end-to-end)

1. `swift test` in `packages/whistle-core` (U2).
2. Convex backend test suite (U3), then `npx convex dev` with a deliberately bad API key to confirm live dashboard logging.
3. Build and run the macOS app; submit a capture; watch `log stream --predicate 'eventMessage CONTAINS "Whistle:"'` for the new drain/synced/failed log lines (U1, U2).
4. Confirm the History row moves from "Queued" to a server status and a real Conductor workspace/worktree opens via the deep link (U1) — this is the direct fix for the reported symptom.
5. Manually force a `syncFailed` row (e.g. submit while offline, keep offline) and click the new Retry button; confirm it re-triggers a drain (U4).
