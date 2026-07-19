---
title: "History window stuck 'Queued' forever — ServerCaptureRecord Convex decode mismatch"
date: 2026-07-19
category: docs/solutions/integration-issues
module: "WhistleCore/ServerCaptureRecord + ConvexService"
problem_type: integration_issue
component: service_object
symptoms:
  - "History window shows every capture as 'Queued' forever, never transitioning to synced/failed status"
  - "captures:listRecent Convex subscription payload triggers a keyNotFound decoding error on every delivery"
  - "Combine publisher fails on first decode error, terminating the AsyncStream with no values ever delivered"
  - "history_cache stays empty even though captures exist server-side, so synced local drafts render with their default local status"
root_cause: wrong_api
resolution_type: code_fix
severity: critical
tags:
  - convex
  - codable
  - json-decoder
  - wire-contract
  - server-capture-record
  - swift
  - history-window
related_components:
  - tooling
---

# History window stuck 'Queued' forever — ServerCaptureRecord Convex decode mismatch

## Problem

Every capture in Whistle's macOS History window was stuck displaying the "Queued" chip forever, even for captures whose server-side pipeline had actually progressed through `creating` → `agentWorking` → `ready`. This was not a cosmetic delay — `history_cache` (the local GRDB mirror that the History UI reads from, `CaptureStore.swift:80-100`) never received a single row from the server, on any account, across four PRs (#9, #11, #12, #13) and several weeks of attempted fixes.

## Symptoms

- History rows never advance past the "Queued" chip (`StatusPresentation.swift:69`, `present(localState:serverRecord:isOnline:)`), regardless of real server-side progress.
- `history_cache` (GRDB table, `CaptureStore.swift:186-190`) stays empty indefinitely — `cachedHistory()` (`CaptureStore.swift:369-376`) returns `[]` even hours after a successful capture.
- The `captures:listRecent` Convex subscription produces no values at all after its first (failed) decode attempt; no crash, no visible error surfaced to the user — the AsyncStream bridge simply finishes silently (`ConvexService.swift:750-761`, the `receiveCompletion: .failure` branch calls `continuation.finish()` after only an `NSLog`).
- `projects:list` (a different subscription) works fine in the same app, which made the bug look client-wide-healthy and pointed investigation at sync/lifecycle plumbing rather than decoding.

## What Didn't Work

Four PRs fixed real, adjacent problems without touching the actual root cause, because none of them decoded a realistic Convex JSON payload:

- **PR #9** — wired up `SyncEngine` so captures actually reach the Conductor API. Necessary, but captures still never showed progress in History.
- **PR #11** — fixed hung Convex calls and nil-vs-null argument encoding (`ConvexService.swift:624-652`, the `capturesCreateArgs` omit-vs-null fix). Real bug, unrelated to the read path.
- **PR #12** — fixed reauthentication UX for signed-out captures. Real bug, unrelated.
- **PR #13** — built roughly 1,612 lines of subscription-lifecycle machinery (a supervisor, generation fencing, transport rotation) around the still-undiagnosed decode failure, on branch `nabeelhyatt/fix-stuck-queued-submit`. It was closed unmerged and the branch quarantined, because none of that machinery could fix a subscription whose payload could never decode in the first place — restarting a subscription that will fail identically on every reconnect just restarts the failure.

The reason tests passed through all four PRs: every existing test constructed `ServerCaptureRecord` values directly in Swift and fed them through fake `AsyncStream`s. Nothing in the suite ever decoded realistic Convex-shaped JSON, so the decode bug had zero test surface. `projects:list` worked in production purely because `packages/backend/convex` (via `projects.ts`) happens to return a plain `{id, name, gitRemote}` DTO that already matches `Project`'s synthesized `Codable` (`Models.swift:197-207`) — masking the fact that the *general* pattern (decode a raw Convex document straight into a client model) is unsafe.

## Solution

Root cause, in `packages/backend/convex/captures.ts:71-99`: `listRecent`/`list`/`get` return raw Convex documents (`return rows...` / `return row`) straight from `ctx.db`. Convex keys a document's id as `_id` (plus a `_creationTime` Convex adds itself) and encodes numbers as float64, occasionally boxed as `{"$float": "<base64 LE Float64>"}` when it must disambiguate a float from a bigint on the wire.

`ServerCaptureRecord` (`Models.swift:107-139`) declared `public var id: String` with no `CodingKeys`, so its synthesized `Codable` expects a JSON key literally named `id`. convex-swift 0.8.1's `subscribe(to:with:yielding:)` (`ConvexService.swift:15-21`) decodes every payload with a vanilla `JSONDecoder` — no custom key strategy. Every real `captures:listRecent` snapshot therefore threw `keyNotFound("id")` on the very first decode attempt. That decode failure surfaces through the Combine publisher as a `.failure`, and the bridge in `LiveConvexService.asyncStream` (`ConvexService.swift:728-778`) maps *any* completion — success or failure — straight to `continuation.finish()` after one `NSLog` (`ConvexService.swift:751-759`). No retry, no value, ever, for the life of that subscription. A locally-synced draft with no matching server record then falls through `StatusPresentation.present`'s `.synced` case (`StatusPresentation.swift:74-78`), which renders "Queued" — permanently, because the server-record branch (`presentServer`, `StatusPresentation.swift:85`) never runs.

Underneath that showstopper sat a second, silent bug: `capturedAt`/`messageSentAt`/`openedAt`/`archivedAt` are `Date` on `ServerCaptureRecord`, but the wire value is milliseconds-since-epoch (the client's own `capturesCreateArgs` sends `input.capturedAt.timeIntervalSince1970 * 1000`, `ConvexService.swift:643`). Vanilla `JSONDecoder`'s default `Date` strategy (`.deferredToDate`) reads a bare number as `secondsSinceReferenceDate` — i.e. seconds since 2001, not 1970 — so even after fixing the `id` key, dates would have decoded as a plausible-looking but wrong `Date` with no error at all. A third landmine: `attempt: Int` can arrive `$float`-boxed, and a single record with an unrecognized `status`/`errorCode` string (schema drift) would throw and kill the *entire* array decode, freezing every other row in the same snapshot.

The fix (PR #15, merged) introduces a wire-shape twin DTO that never touches the public model's `Codable` contract:

```swift
// ServerCaptureRecordWire.swift:38-79
struct ServerCaptureRecordWire: Decodable, @unchecked Sendable {
    var id: String
    ...
    @ConvexFloat var capturedAt: Double
    var status: String        // raw String, not CaptureServerStatus directly
    var errorCode: String?    // raw String?, not CaptureErrorCode? directly
    @ConvexFloat var attempt: Double
    @OptionalConvexFloat var messageSentAt: Double?
    @OptionalConvexFloat var openedAt: Double?
    @OptionalConvexFloat var archivedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case userId, clientId, transcript, notes, screenshotId, projectId,
             projectName, agent, model, capturedAt, status, errorCode, error,
             attempt, workspaceId, workspaceName, sessionId, deepLink,
             messageSentAt, clarifyingQuestions, agentSummary, openedAt, archivedAt
        // `_creationTime` intentionally unmapped; JSONDecoder ignores
        // keys with no matching CodingKey.
    }
}
```

and maps it onto the public model explicitly (`ServerCaptureRecordWire.swift:95-128`):

```swift
var asRecord: ServerCaptureRecord {
    ServerCaptureRecord(
        id: id,
        ...
        capturedAt: Date(timeIntervalSince1970: capturedAt / 1000),   // NOT timeIntervalSinceReferenceDate
        status: CaptureServerStatus(rawValue: status) ?? .queued,     // drift-tolerant
        errorCode: errorCode.map { CaptureErrorCode(rawValue: $0) ?? .unknown },
        ...
        attempt: Int(exactly: attempt.rounded()) ?? 0,                // non-finite-safe
        messageSentAt: messageSentAt.map { Date(timeIntervalSince1970: $0 / 1000) },
        openedAt: openedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
        archivedAt: archivedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    )
}
```

`@ConvexFloat`/`@OptionalConvexFloat` are property wrappers supplied by the convex-swift dependency's `ConvexMobile` module (in the convex-swift 0.8.1 package source, `Sources/ConvexMobile/Decoding.swift` lines 56 and 83 — an SPM checkout fetched at build time, not a file in this repo) that accept either a bare JSON number or the `{"$float": "<base64>"}` boxed form — both paths are exercised directly in the test suite (`ServerCaptureRecordWireTests.swift:269-327`).

Every decode site that previously decoded `ServerCaptureRecord` directly now decodes `ServerCaptureRecordWire` and maps: `capturesListRecent` (the subscription, `ConvexService.swift:654-682`), `capturesList` (`ConvexService.swift:684-689`), and `capturesGet` (`ConvexService.swift:691-703`).

`ServerCaptureRecord`'s own synthesized `Codable` was deliberately left untouched. `CaptureStore`'s `HistoryCacheRow` (`CaptureStore.swift:84-100`) round-trips `ServerCaptureRecord` through its own `id`-keyed, iso8601-dated `JSONEncoder`/`JSONDecoder` (`CaptureStore.swift:209-219`) as its on-disk cache format — changing the public struct's coding keys or date strategy to match the wire shape would have silently corrupted every previously-cached row on the next app launch.

## Why This Works

The bug was a decode-contract mismatch three layers deep (key name, then date epoch, then float-boxing/enum drift), and it manifested as total, silent subscription death because convex-swift's Combine-to-completion path collapses any decode failure into the same `.failure` case as a real network failure, and the app's own bridge (`ConvexService.swift:728-778`) treats every completion as terminal. No amount of retry/supervisor/transport-rotation logic (PR #13's approach) can fix a subscription that will throw on its very first payload every single time it (re)connects — the only fix is making the decode succeed. Separating the wire shape into its own DTO means the fix is additive: the public `ServerCaptureRecord` contract that `CaptureStore.history_cache` already depends on for its persisted cache format is never touched, so there is no risk of corrupting existing cached rows while fixing the live wire decode. Falling back to `.queued`/`.unknown` on unrecognized enum strings, instead of throwing, converts "one bad payload freezes the whole list" into "one row's chip is momentarily wrong" — exactly the containment a decode failure inside a batch array needs.

Verified live on 2026-07-19: `history_cache` populated for the first time ever, and a real capture was observed transitioning Queued → Creating workspace → Agent working → Ready end to end in the History UI.

## Prevention

- For any Swift type that is decoded from a Convex subscription or query result (not just constructed by client code), write a test that decodes an inline, hand-shaped JSON literal matching Convex's *actual* wire format — not a JSON literal derived by re-serializing the Swift struct. `ServerCaptureRecordWireTests.swift:30-98` (`testDecodesFullRealisticDocument`) is the pattern: literal `_id`, a literal `_creationTime` the client doesn't consume, and millisecond-epoch floats for every date field.
- Add a `$float`-boxed variant test for every `Double`/`Date`-backed field that a query might return, both required (`testDecodesDollarFloatBoxedCapturedAt`, `ServerCaptureRecordWireTests.swift:269-291`) and optional (`testDecodesDollarFloatBoxedMessageSentAt`, `ServerCaptureRecordWireTests.swift:301-327`) — the two code paths are written separately and one having coverage does not imply the other does.
- Add a same-batch-mixed-validity test for any decode of an array from a live subscription: `testWholeBatchSurvivesOneRecordWithAnUnrecognizedStatus` (`ServerCaptureRecordWireTests.swift:226-264`) decodes two records, one with a recognized `status` and one with a schema-drifted value, and asserts the batch still fully decodes with the drifted row degraded rather than the whole array thrown away.
- Never decode a raw Convex document straight into a client-facing/persisted model type. Introduce a private "wire" twin DTO with explicit `CodingKeys` (`_id`, not `id`) and epoch-aware date handling, and map it onto the public model in one place. If the public model is also used as a durable on-disk cache format (as `ServerCaptureRecord` is via `HistoryCacheRow`), this separation is not optional — coupling the live wire contract to the persisted cache format risks silently corrupting previously-cached rows the next time the wire format is touched.
- Add a regression test locking the cache round-trip contract itself, independent of the wire decode: `testServerCaptureRecordCacheRoundTripStillWorks` (`ServerCaptureRecordWireTests.swift:331-368`) encodes/decodes a `ServerCaptureRecord` through the exact iso8601 `JSONEncoder`/`JSONDecoder` pair `CaptureStore.makeEncoder()`/`makeDecoder()` use (`CaptureStore.swift:209-219`), so a future change to the wire-side DTO can't accidentally also change the public struct's own coding behavior without a test failing.
- When a subscription's Combine publisher completes with `.failure` (`ConvexService.swift:751-759`), treat that as materially different from a clean `.finished` — at minimum log loudly enough to be caught in review/monitoring; a decode failure disguised as an ordinary stream completion is what let this bug hide for four PRs.

## Related Issues

- PR #15 (merged) — the fix described here.
- PR #13 (`nabeelhyatt/fix-stuck-queued-submit`, closed unmerged) — subscription-lifecycle machinery built around the undiagnosed decode bug; quarantined rather than merged once the real root cause was found.
- PR #9, #11, #12 — adjacent, real fixes (SyncEngine wiring, hung-call/arg-encoding, reauth UX) that did not address this bug.
- [SyncEngine permanently wedged by hung Convex network call](../runtime-errors/syncengine-wedged-by-hung-convex-call.md) — a *different* way captures get stuck showing "Queued" (hung FFI call wedging SyncEngine's drain, write path) vs this doc (dead decode on the subscription read path). An engineer debugging one should check the other.
- `docs/BACKLOG.md` — "Old synced drafts beyond `captures.listRecent(limit: 100)`": a third, still-open way a synced draft can show a stale status on the same History surface (pagination window, not decode).
