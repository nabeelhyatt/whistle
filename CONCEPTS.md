# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## WhistleCore sync domain

### CaptureDraft

A capture as it exists purely on-device, before any server record exists. Owns the local lifecycle state and retry counter. The `clientId` (a UUID minted on device) is the idempotency key — it is never regenerated for an existing draft; the server deduplicates on `(userId, clientId)`.

*Avoid:* local capture, pending capture.

A CaptureDraft is distinct from `ServerCaptureRecord` — the server-side record only appears once `captures.create` succeeds and `SyncEngine` updates the draft's `serverId`. A draft can exist indefinitely without a server counterpart (offline, auth failure, repeated sync errors).

### LocalCaptureState

The local (on-device) lifecycle of a CaptureDraft: `.draft` → `.queued` → `.syncing` → `.synced` or `.syncFailed`. Transitions live in `CaptureStore`.

Non-obvious invariant: `.syncing` means "a network call is in flight in this process." A draft found in `.syncing` at launch is necessarily stranded (the prior process died mid-call) and must be reverted to `.queued` before the first drain — see `SyncEngine.recoverStrandedSyncing()`. A `.syncFailed` draft is user-visible and can be re-enqueued via manual retry; a `.queued` draft is silently retried by any drain pass.

*Avoid:* sync state, upload state.

### SyncEngine

The Swift `actor` in WhistleCore that drains the local capture queue to the Convex backend. Manages an `isDraining` reentrancy guard so concurrent drain requests coalesce (the second caller sets `rerunRequested = true` and returns; the first caller re-runs once when it finishes). Runs two independent, auth-gated loops via `WhistleApp.swift` — `SyncEngine`'s own `runForever()` is defined but not called by the app target. Instead: an auth-gated `pathUpdates()` loop that calls `drainSyncIfSignedIn()` on every network-path change, and the (also auth-gated) `runPeriodicDrain(gate:)` (time-based safety net, fires every 3 minutes).

SyncEngine does not own authentication — it calls `ConvexService` methods that attach auth internally. An `notAuthenticated` error from a sync attempt reverts the draft to `.queued` (not `.syncFailed`) so the next authenticated drain picks it up without burning a retry.

### CaptureStore

The GRDB-backed SQLite store for on-device capture data. Manages four tables: `pending_captures` (the offline-first queue of CaptureDrafts), `history_cache` (a local mirror of recent server records for offline History), `projects_snapshot` (last-fetched project list for the project picker), and `app_state` (a key/value table for small app-level state such as last-used project). Screenshot bytes are stored as on-disk temp files referenced by path, not as SQLite blobs.

### ConvexService

The protocol (`ConvexServiceProtocol`) and its live implementation (`LiveConvexService`) wrapping the convex-swift FFI. Handles authenticated mutations, actions, and queries against the Convex backend. All authenticated call paths are bounded by the shared `withTimeout(_:operation:)` helper — a non-cooperative FFI call that ignores Swift cancellation is raced against an unstructured timer `Task` via a single-resume `CheckedContinuation`. `authedMutation`, `authedAction`, and `ensureAuthAttached`'s `loginFromCache()` attach call it directly (15s); `authedQuery` calls it indirectly via `firstValue(from:timeout:)` (10s default), which is cancellation-aware on the query path so `withTimeout` also tears down the underlying subscription on timeout, not just the caller's wait.

### ServerCaptureRecord

The server-side capture record, mirroring the Convex `captures` table (TECH-SPEC §5). Distinct from CaptureDraft — a ServerCaptureRecord only exists after `captures.create` succeeds on the server. Carries `CaptureServerStatus` (pipeline lifecycle: `.queued` → `.creating` → `.sending` → `.agentWorking` → `.ready`/`.readyUnverified`/`.failed`) and `CaptureErrorCode` (`.auth`, `.workspaceSetup`, `.network`, `.stalled`, `.unknown`). `SyncEngine` does not create or update ServerCaptureRecords directly; they arrive via Convex subscriptions that `CaptureStore` caches in `history_cache`.

Non-obvious invariant: a ServerCaptureRecord has two distinct serialized shapes that must never be coupled. On the wire, Convex delivers raw documents (id keyed as `_id`, timestamps as milliseconds-since-epoch numbers), which are decoded through a dedicated wire-twin intermediary and mapped in one place. On disk, the record's own Codable shape is the `history_cache` cache format (`id`-keyed, ISO-8601 dates) — changing it to match the wire shape would silently corrupt previously cached rows, so wire-contract changes always go through the twin, never the record itself.

## Transcription domain

### Committed / Live transcript

The two-part contract every transcriber publishes: **committed** is finalized text that will never change; **live** is the current in-flight hypothesis, which later updates may revise or replace wholesale. The UI always renders committed followed by live.

Non-obvious rules: live hypotheses are non-monotonic (a revision can rewrite earlier words, not just extend), so consumers must replace the live segment rather than append to it; and stopping a capture mid-utterance folds the live hypothesis into committed rather than dropping it.

### Task-cycling

The legacy speech path's (macOS 14–15) named process for long dictation sessions: recognition is deliberately restarted in segments because the OS recognizer cannot sustain long-form sessions, and each finalized segment is stitched onto the committed transcript with a single-space join. The macOS 26 analyzer path supports long-form sessions natively and does not task-cycle — finality there is derived per result from the analyzer's volatile time range instead of per segment.

*Avoid:* segment restarts, recognizer recycling.
