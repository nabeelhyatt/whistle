---
title: "Fix ordered, session-safe audio ingress for transcription"
date: 2026-07-28
plan_depth: standard
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: docs/BACKLOG.md
---

# Fix ordered, session-safe audio ingress for transcription

## Goal Capsule

Determine whether the known “transcription repeats itself” complaint is caused by unordered mic-buffer delivery on macOS 26. If reproduction confirms that hypothesis, replace the per-buffer task fan-out with one bounded FIFO ingress path per capture session, shared by the SpeechAnalyzer and legacy recognizers.

The backlog’s reproduce-first instruction is authoritative. A failed reproduction ends this work without changing the recording hot path; a confirmed reproduction requires deterministic regression coverage and real macOS 26 validation. Preserve the existing `TranscriptUpdate` committed/live contract, native-format conversion boundary, locale lifecycle, and capture queue behavior.

---

## Product Contract

### Summary

Whistle must deliver microphone buffers to each active recognizer in tap-callback order and must never allow a delayed buffer from a stopped capture to enter a later capture. The audio callback stays lightweight; expensive conversion and framework calls remain off the real-time callback.

### Problem Frame

Both transcribers create an independent unstructured task for every microphone callback. Swift does not provide a FIFO contract for those tasks as they enter an actor. The macOS 26 path now has a stateful streaming converter whose correct operation depends on ordered input, and a delayed callback can also read the next session’s engine after a rapid Clear/restart.

### Requirements

- **R1 — Reproduction gate.** On physical macOS 26 hardware, reproduce or eliminate the ordering hypothesis before changing the audio ingress path. Record the setup, spoken marker phrases, Clear/restart timing, and outcome in the backlog item or a linked solution note.
- **R2 — Ordered ingress after confirmation.** A confirmed issue uses exactly one session-owned, bounded FIFO consumer between the audio tap and each transcriber actor; it preserves tap delivery order before either recognizer receives a buffer.
- **R3 — Stale-session exclusion.** Stopping, failing, or replacing a capture invalidates its ingress before teardown. Buffered or late callbacks from that session are discarded and cannot reach a newly started engine.
- **R4 — Real-time and existing contracts.** The tap callback only performs bounded enqueue work. It must not perform analyzer conversion, `AnalyzerInput` yielding, or Speech-framework request work. The existing macOS 26 pending-format queue, Int16 conversion, locale reservation/release, result handling, and `TranscriptUpdate` semantics remain unchanged.
- **R5 — Deterministic proof and hardware QA.** Tests drive labelled buffers through a controllable audio-tap fake and assert order plus restart isolation without sleeps. A macOS 26 manual pass covers normal dictation, rapid Clear/restart, and the existing long-dictation scenario.

### Acceptance Examples

- **AE1 — Ordered burst:** When one active capture receives labelled buffers A, B, C from its tap, its recognition engine observes A, B, C in that order.
- **AE2 — Rapid restart:** When capture one is stopped or cleared with work still queued and capture two begins immediately, no buffer emitted through capture one’s callback reaches capture two’s engine.
- **AE3 — Repeated speech:** On macOS 26, a scripted set of distinctive phrases plus repeated Clear/restart does not duplicate or reorder phrases after the confirmed fix.

### Scope Boundaries

This plan is limited to the P1 audio-ordering hypothesis and the stale-session risk discovered in the same ingress path. It does not redesign transcription readiness, add a setup timeout, change locale ownership, expose an engine choice, persist audio, or fold in the separate P2 testability work for `LiveSpeechAnalyzerEngine`’s format and asset lifecycle.

### Key Decision

- **KD1 — Reproduce before changing the hot path** *(session-settled: user-approved — chosen over a proactive ingress rewrite: the repeat complaint is established but its cause is not yet confirmed).* This keeps a performance-sensitive change evidence-led while giving the investigation an explicit success and stop condition. Governs R1–R2.

---

## Planning Contract

### Key Technical Decisions

- **KTD1 — Use a single session-owned FIFO consumer, not direct engine work in the tap callback.** Direct synchronous delivery would preserve order but would also run conversion/yield work in the real-time callback on macOS 26 and invoke the legacy Speech request there. A bounded bridge lets the callback return promptly while one consumer serially reaches the actor.
- **KTD2 — Bind delivery to a capture epoch.** The actor accepts a buffer only when its token matches the active session. Invalidate the token before stopping the tap or awaiting engine teardown, then finish/cancel the old ingress so a rapid restart cannot adopt delayed old work.
- **KTD3 — Apply the ingress policy to both transcribers.** The unsafe task-per-buffer pattern is identical in both paths. Share the bridge/lifecycle behavior while leaving their engine-specific result and finalization logic independent.
- **KTD4 — Bound buffering and make overflow observable.** Use a small, explicit capacity appropriate for short scheduling bursts; preserve FIFO for accepted buffers, discard according to one documented policy when saturated, and emit a diagnostic for loss. Do not use an unbounded stream as a workaround.

### High-Level Technical Design

The design is directional; the implementation may choose the smallest Swift type that satisfies this lifecycle.

```mermaid
sequenceDiagram
    participant Tap as AVAudio input tap
    participant Ingress as Session FIFO bridge
    participant Actor as Transcriber actor
    participant Engine as Recognition engine

    Tap->>Ingress: enqueue buffer with session token
    Ingress->>Actor: one ordered consumer delivers buffer
    Actor->>Actor: token equals active session?
    Actor->>Engine: append accepted buffer

    Actor->>Ingress: invalidate and finish on stop/error
    Tap-->>Ingress: late old-session buffer
    Ingress-->>Actor: discard; never reaches new engine
```

### Constraints and Research

- The existing `LiveSpeechAnalyzerEngine` deliberately serializes conversion and pending-format draining with a lock. This change establishes order *before* that engine; it must not bypass or duplicate its format queue.
- `AudioEngineTap` invokes its handler directly from AVFoundation’s input tap. The handler therefore must not perform work likely to block audio rendering.
- `CaptureViewModel.clear()` intentionally stops and recreates transcription, making session identity part of the observable correctness boundary.
- Existing asynchronous-test guidance prohibits sleep-based assertions. Fakes must expose awaitable observation points instead.

### Risks and Mitigations

- **Hypothesis is wrong:** R1 makes the no-code outcome explicit and retains the observation for the next diagnosis.
- **Consumer falls behind:** bounded buffering and overflow diagnostics prevent unbounded memory use; hardware QA checks for missed words and audio glitches.
- **Teardown race:** epoch invalidation precedes cancellation/engine finish, and the restart-isolation test holds this ordering contract.
- **Apple runtime behavior:** unit tests prove Whistle’s delivery semantics only; a real macOS 26 capture remains mandatory because Speech framework failures are not fully simulable.

---

## Implementation Units

### U1. Establish the macOS 26 reproduction decision

**Goal:** Produce a clear go/no-go record for the backlog’s ordering hypothesis without altering production audio delivery.

**Requirements:** R1, AE3.

**Files:** `docs/BACKLOG.md`; optionally `docs/solutions/` if the run establishes a reusable diagnosis; `docs/MANUAL-QA.md` only if the scenario needs a durable checklist addition.

**Approach:** On a macOS 26 machine using the SpeechAnalyzer path and installed assets, run a controlled spoken-marker script at ordinary pace and under rapid Clear/restart. Include a continuous multi-minute pass, capture the resulting transcript and relevant unified-log window, and classify the result as reproduced, not reproduced, or blocked by an independently observable failure. If not reproduced, update the P1 record with enough hardware/OS/build context to prevent a speculative rewrite and stop this plan’s code units.

**Test scenarios:**

- A normal marker sequence remains ordered and contains no duplicate phrase.
- Clear during active speech followed immediately by a new marker sequence does not reintroduce old text.
- The existing long-dictation scenario remains part of the run, rather than treating a short smoke test as conclusive quality evidence.

**Verification:** The recorded result makes the evidence threshold and next action unambiguous: no code change when not reproduced; proceed to U2 when reproduced.

### U2. Add ordered, session-bound audio ingress after confirmation

**Goal:** Replace per-buffer unstructured tasks with a shared, bounded FIFO bridge that protects both recognizers from reordering and stale-session delivery.

**Requirements:** R2, R3, R4.

**Files:** `apps/macos/Whistle/Services/SpeechAnalyzerTranscriber.swift`; `apps/macos/Whistle/Services/LegacySpeechTranscriber.swift`; add a focused ingress helper under `apps/macos/Whistle/Services/`; `apps/macos/project.yml` if this unit changes app behavior.

**Dependencies:** U1 must reproduce the issue.

**Approach:** Start one ingress bridge and consumer for each capture before installing the tap callback. The callback enqueues only to that bridge; the consumer is the sole path that calls the actor’s feed operation. Associate ingress and feed delivery with a monotonic capture epoch, invalidate it before every normal stop and error teardown, then finish/cancel the bridge and prevent old buffered values from being used after restart. Reuse the same lifecycle policy in both transcribers, but do not merge their engine protocols or result-processing logic. If behavior changes, bump the macOS marketing version exactly once as required by the repository instructions.

**Test scenarios:**

- A burst emitted in tap order reaches a recording analyzer fake in that exact order.
- The same order property holds for the legacy fake.
- A late callback and buffered items from the first session are rejected after stop/Clear and cannot append to the replacement engine.
- Saturation follows the documented policy and produces a diagnosable event without blocking the tap callback.
- Engine errors and ordinary stop both close the active ingress, with no remaining consumer feeding a later session.

**Verification:** Focused ingress tests pass repeatedly without fixed sleeps; a full app build and test run compiles both availability paths.

### U3. Harden regression seams and complete the post-fix hardware pass

**Goal:** Make order and restart isolation observable in CI while recording the real-device evidence the Apple framework requires.

**Requirements:** R5, AE1, AE2, AE3.

**Files:** `apps/macos/WhistleTests/TranscriptStitchingTests.swift`; add a narrow ingress-focused test file if that keeps stitching tests cohesive; `docs/MANUAL-QA.md`; `docs/BACKLOG.md`; optionally `docs/solutions/` for a confirmed cause/fix.

**Dependencies:** U2.

**Approach:** Extend or add a controllable fake tap that retains the session callback and emits identifiable buffers on demand. Upgrade fake engines from append counts to ordered, awaitable records, using continuations or the repository poller instead of timing sleeps. Add the focused macOS 26 Clear/restart procedure to manual QA, update the backlog item with the decision and evidence, and capture a solution note only if the diagnosis is confirmed and reusable.

**Test scenarios:**

- Tests await the exact number of observed appends before asserting order.
- Tests intentionally retain an old callback across a simulated restart and prove it cannot affect the new session.
- Tests run the two recognizer paths independently so shared ingress does not mask a path-specific regression.

**Verification:** The targeted tests withstand a repeated no-rebuild run; the macOS 26 QA pass verifies both normal and stress capture behavior without duplicated or reordered phrases.

---

## Verification Contract

- Regenerate the macOS Xcode project from `apps/macos/project.yml`, then build and run the Whistle test scheme through the repository’s required `xcodebuild` flow with the explicit Xcode developer directory.
- Run the focused ingress/transcription tests repeatedly after one build-for-testing pass, following the repository’s deterministic-async-test guidance; do not validate task scheduling with a sleep.
- Run the full Whistle macOS unit suite to catch actor-isolation and availability-path compilation regressions.
- On physical macOS 26 hardware, complete U1 before code changes and, after a confirmed fix, repeat the marker, rapid Clear/restart, and long-dictation scenarios in `docs/MANUAL-QA.md`.
- Inspect the final diff to verify no code path bypasses `LiveSpeechAnalyzerEngine`’s existing Int16 conversion or its pending-format ordering lock.

---

## Definition of Done

- The P1 hypothesis has a durable macOS 26 evidence record.
- If it did not reproduce, no speculative ingress rewrite or version bump is shipped, and the backlog explains why the item stopped.
- If it reproduced, both transcribers use a bounded, session-bound FIFO ingress path; the real-time callback contains no recognizer or converter work.
- Accepted buffers are deterministically FIFO, old-session buffers cannot enter a new capture, and saturation is bounded and diagnosable.
- Unit tests cover order, stop/error closure, rapid restart isolation, and both transcriber paths without fixed sleeps.
- The required full test suite and post-fix macOS 26 manual QA pass succeed, including long dictation and rapid Clear/restart.
- The macOS marketing version is patch-bumped only when U2 ships app-behavior code, and no abandoned experimental ingress code remains.

---

## Sources

- `docs/BACKLOG.md` — P1 reproduce-first scope and existing P0/P1/P2 boundaries.
- `CONCEPTS.md` — committed/live transcript and legacy task-cycling contracts.
- `apps/macos/Whistle/Services/AudioEngineTap.swift` — direct input-tap callback boundary.
- `apps/macos/Whistle/Services/SpeechAnalyzerTranscriber.swift` — per-buffer task entry and stateful conversion/queue invariants.
- `apps/macos/Whistle/Services/LegacySpeechTranscriber.swift` — matching per-buffer task pattern and task-cycling behavior.
- `apps/macos/Whistle/Capture/CaptureViewModel.swift` — Clear’s stop-and-restart lifecycle.
- `docs/solutions/runtime-errors/speechanalyzer-sigtrap-float32-audio-macos26.md` — conversion and queue-ordering runtime constraints.
- `docs/solutions/test-failures/async-fake-sleep-race-flaky-tests.md` — deterministic async-test requirements.
