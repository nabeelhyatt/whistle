---
title: "research: TypeWhisper-informed speech reliability and engine roadmap"
type: research-roadmap
status: proposed
date: 2026-07-28
---

# TypeWhisper-informed speech reliability and engine roadmap

## Summary

TypeWhisper is useful evidence that an Apple Speech dictation app needs explicit model lifecycle, input readiness, failure states, and test seams. It is not a blueprint for Whistle's product. This roadmap protects Whistle v1 first, then uses a measured benchmark—not intuition—to decide whether a local alternate engine, recovery-audio policy, or a small multi-engine boundary is justified.

Companion reference: [TypeWhisper analysis](../TYPEWHISPER-ANALYSIS.md). Existing active/deferred work remains in [BACKLOG](../BACKLOG.md); this plan groups it without reopening shipped fixes.

## Horizon 1 — make Apple Speech honest and failure-safe

### 1. Preparation and ready contract

Implement the existing P0 readiness design: `TranscriptionService` must distinguish preparing from ready; `CaptureViewModel.isListening` and microphone start occur only after model install/preparation, locale reservation, analyzer-format lookup, and session startup have succeeded.

- **Required behavior:** panel may open promptly, but it must not claim it is listening or silently discard opening speech while setup is pending. Cancellation during preparation leaves no live audio session. A failed/cancelled install transitions to a clear type-only/error state with any typed content intact.
- **Test seam:** inject a controllable preparation result and verify delayed success, install failure, timeout, and cancel-vs-ready races without sleeps.
- **Manual QA:** clean macOS 26 host with a missing model; slow/offline install; immediate cancel; first spoken words after ready. Confirm no opening loss and no false “Listening.”

### 2. Bound setup and preserve ownership

Implement the existing timeout/observability and exact-reservation follow-ups.

- **Required behavior:** `AssetInventory.reserve` and compatible-format lookup have bounded deadlines. Timeout/no-format/setup error completes the transcript stream with an actionable error, releases only Whistle's own reservation, and preserves committed text. Buffer drops or conversion failures are observable in UI/logs rather than silent degradation.
- **Test seam:** fake AssetInventory/analyzer setup that can delay, fail, return a locale variant, or report another session's reservation.
- **Manual QA:** force the failure paths where practical on macOS 26; inspect unified logs as required by the [SIGTRAP solution](../solutions/runtime-errors/speechanalyzer-sigtrap-float32-audio-macos26.md).

### 3. Serialize audio and test the real boundary

Resolve the existing ordered-buffer investigation before changing the hot path.

- **Required behavior:** audio reaches the stateful converter/analyzer in tap order. Reproduce the known repeated-transcription report first; if confirmed, replace the unstructured per-buffer Task hop with synchronous engine feeding or one serialized stream consumer, and decide the same policy for legacy speech.
- **Test seam:** extract a plain pending-buffer queue (FIFO and drop-oldest) and introduce an analyzer-input sink fake. Assert queue/drain order and that every engine-yielded buffer is the analyzer-required Int16 format.
- **Manual QA:** sustained macOS 26 dictation across pauses and a long capture; check for repeated, omitted, or reordered words.

**Acceptance gate for Horizon 1:** all seams have deterministic unit coverage; app tests remain green; the macOS 26 manual capture matrix passes; and a failure cannot leave the UI advertising a live capture with no transcript/error.

## Horizon 2 — evaluate, do not assume, alternate local engines

Run this only after Horizon 1. It is a product/quality experiment, not a shipping commitment.

### Candidates and constraints

Compare Apple Speech with one WhisperKit candidate and one Parakeet/Core ML candidate. Each candidate must be fully local at runtime, provide a usable macOS distribution/license, and run on the target hardware without cloud credentials. Reject a candidate before benchmark if it fails any constraint. Audio recovery retention is measured separately as a workflow choice, not used to exclude a candidate.

### Fixed benchmark protocol

Use the same prompts and capture workflow across engines:

| Prompt group | Representative content |
| --- | --- |
| Product capture | A 30–60 second feature idea with punctuation, a project name, and a question for the agent. |
| Engineering capture | A bug report with identifiers, file paths, version numbers, and code-like tokens. |
| Natural long form | A 3–5 minute uninterrupted explanation with pauses and self-corrections. |
| Adverse input | Quiet speech, moderate background noise, Bluetooth/USB mic, route change, and model-not-ready/failure paths where supported. |

For each OS/hardware/engine combination, record at least five runs per prompt group and capture:

- time from trigger to truthful ready/live indication;
- time from stop to editable final text;
- user correction burden: word-level corrections plus whether names/identifiers were usable without correction;
- failure/recovery rate: setup, model, route, crash, empty/duplicated/reordered output, and whether partial text survived;
- peak memory, average/peak CPU, energy impact, and model download/disk footprint.
- if recovery audio is trialed: recovery success after a forced recognition failure, retained-audio size, deletion/expiry behavior, and the clarity of the user-facing retention state.

Test on the oldest supported Intel or Apple-Silicon configuration applicable to the candidate, a baseline Apple Silicon Mac, and the macOS 26 Apple Speech host. Include the currently supported macOS 14–15 legacy path and macOS 26 path where hardware is available. Record OS version, language/locale, mic, power state, and candidate/model version for every run.

### Decision record

Create a short dated decision record with raw measurements and one result:

- **Keep Apple Speech only** if no candidate materially lowers correction burden or latency without materially worsening resource use, model distribution, or reliability.
- **Prototype one alternate engine** only if it improves correction burden by at least 25% *and* meets the current ready/failure contract with no unresolved license or distribution issue. The prototype is behind a development-only factory choice; it ships to no user.
- **Decide recovery-audio policy separately:** retain nothing, retain only failed/cancelled sessions, or retain user-selected sessions. Any candidate policy needs an explicit size limit, expiry/deletion behavior, and visible state; it does not require a multi-engine decision.
- **Stop and investigate** if Apple Speech or a candidate produces data loss, repeat/reorder errors, crashes, or a false-ready state. Correctness outranks a performance win.

Do not use benchmark results to introduce cloud transcription, plugins, or an engine picker. Audio retention follows its separate policy decision above.

## Horizon 3 — smallest future multi-engine boundary

Only begin this horizon after a documented Horizon 2 prototype decision. Keep the public behavior stable: `TranscriptUpdate` remains committed plus volatile live text; `CaptureDraft`, offline queueing, and the submission pipeline do not know the engine.

### Required capability boundary

Evolve the internal transcription seam so an engine can report and perform:

- availability and explicit preparation/readiness, including model-install progress where meaningful;
- start/stream, ordered audio acceptance, finalization, and cancellation;
- language/model availability and optional contextual vocabulary with declared limits;
- typed failures that distinguish unavailable, preparation/install, input/audio, recognition, and cancelled states.

The factory selects one configured implementation. The capture UI consumes the normalized readiness/status and `TranscriptUpdate`; it must not receive engine-specific model types. Keep `AudioEngineTap` ownership centralized unless a candidate's input contract requires a separately justified adapter.

### Explicit deferrals

Do not add a user-facing engine picker, plugin manifests/SDK, cloud providers, per-app dictation profiles, or broad model manager. Audio-file recovery is a separate product decision after its Horizon 2 measurement; it does not depend on alternate-engine adoption.

**Acceptance gate for Horizon 3:** a fake alternate engine can satisfy the capability contract and all capture/transcript tests without changing sync/storage behavior; real-engine integration passes the Horizon 1 failure and manual-QA matrix before any user-facing choice is proposed.

## Non-goals

This roadmap does not change Whistle v1's Apple-Speech-only product boundary, focus/panel behavior, or release version. The current no-audio-retention behavior remains unchanged here, but is explicitly eligible for a later measured product decision. This does not make TypeWhisper a dependency or copy its plugin architecture.
