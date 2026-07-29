---
title: "TypeWhisper analysis — Apple Speech reliability patterns for Whistle"
date: 2026-07-28
status: reference
upstream:
  repository: https://github.com/TypeWhisper/typewhisper-mac
  commit: bea4f2d6ce77bf89482636720ef53190b966e530
---

# TypeWhisper analysis — Apple Speech reliability patterns for Whistle

## Purpose and boundary

This is a source-based comparison of TypeWhisper's Apple Speech implementation and Whistle's current macOS 26 path. It is input to the [speech roadmap](plans/2026-07-28-001-typewhisper-speech-roadmap.md), not a proposal to copy TypeWhisper or to broaden Whistle v1.

Whistle remains a capture app: it opens a capture panel, produces editable context for a Conductor workspace, and queues offline. The current v1 scope discards microphone audio after transcription and excludes cloud transcription and bundled `whisper.cpp` ([PRD](PRD.md#scope-boundaries-non-goals-for-v1)); this analysis treats audio retention as a revisitable product tradeoff, not a blocker on future engine or recovery work. TypeWhisper is a general-purpose dictation product with paste-at-cursor, multiple engines, a plugin SDK, and optional recovery-audio storage ([README](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/README.md)). Those different goals matter more than any code resemblance.

## Evidence standard

**Verified** statements below were inspected in TypeWhisper commit [`bea4f2d`](https://github.com/TypeWhisper/typewhisper-mac/tree/bea4f2d6ce77bf89482636720ef53190b966e530). They describe its source, not an assertion that the behavior is correct on every macOS release. **Recommendations** are explicit judgments for Whistle.

## What TypeWhisper does with Apple Speech

| Area | Verified TypeWhisper behavior | Whistle position and recommendation |
| --- | --- | --- |
| Model catalog | Its `SpeechAnalyzerPlugin` enumerates `SpeechTranscriber.supportedLocales`, presents each as a system-managed model, and persists the selected locale/model. | Whistle needs only the configured capture locale, not a general catalog UI. Keep its focused onboarding path; add a testable locale-selection/ownership seam only if per-language selection becomes a product requirement. |
| Install and reserve | On selection it requests `AssetInventory.assetInstallationRequest`, exposes progress, waits for installation, then reserves the locale. It releases the stored locale when unloading/deactivating. [Source](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK/Plugins/SpeechAnalyzerPlugin/SpeechAnalyzerPlugin.swift#L263-L316) | This validates the lifecycle shape, but not Whistle's exact ownership semantics. Complete Whistle's P0 readiness work first: no live mic UI until preparation/install succeeds, and retain the exact reservation identity needed for safe release. See [BACKLOG](BACKLOG.md). |
| Analyzer input | For both batch and live paths it creates a `SpeechAnalyzer`, sets `AnalysisContext`, asks `bestAvailableAudioFormat`, and converts samples before yielding `AnalyzerInput`. [Source](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK/Plugins/SpeechAnalyzerPlugin/SpeechAnalyzerPlugin.swift#L404-L457) | Whistle already learned the hard runtime constraint: raw Float32 mic buffers can trap Apple Speech. Preserve Whistle's native-tap then convert-before-`AnalyzerInput` approach; do not substitute TypeWhisper's `[Float]` boundary without a measured reason. [Solution note](solutions/runtime-errors/speechanalyzer-sigtrap-float32-audio-macos26.md) |
| Live transcript | Its live session holds one analyzer, `AsyncStream<AnalyzerInput>`, and result task; volatile results call a progress handler while final results are appended. `finish()` closes the input and finalizes; `cancel()` closes input and cancels the result task. [Source](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK/Plugins/SpeechAnalyzerPlugin/SpeechAnalyzerPlugin.swift#L499-L577) | Whistle's committed-plus-live `TranscriptUpdate` contract is the right narrower abstraction. Continue to preserve the live segment on stop/error as specified in [TECH-SPEC §4.1b](TECH-SPEC.md#41b-transcription-design-the-hard-part). |
| Contextual vocabulary | It extracts dictionary terms from a prompt, caps Apple Speech context to 100 terms, and adds them to `AnalysisContext`. [Source](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK/Plugins/SpeechAnalyzerPlugin/SpeechAnalyzerPlugin.swift#L206-L236) | This is a plausible future quality lever for project names, repository terms, and agent vocabulary. Do not add it until the benchmark proves it reduces correction burden; define its privacy and source-of-terms policy with that work. |
| Engine boundary | TypeWhisper exposes `LiveTranscriptionSession` and a capability-rich plugin protocol, so several engines can stream, finish, cancel, and report model metadata. [Source](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/TypeWhisperPlugin.swift#L602-L610) | This supports a future small capability boundary in Whistle, but its plugin host is far beyond Whistle's present need. Do not introduce plugins, manifests, or independently installable providers. |

## Reliability patterns worth carrying forward

### Readiness is an externally visible state

TypeWhisper does not treat “start requested” and “microphone is producing usable audio” as equivalent. Its dictation view model emits the recording cue only after the first buffer arrives, and maintains `isRecordingInputReady`; its [audio tests](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperTests/AudioEngineRecoverySupportTests.swift) cover delayed input, cancellation during preparation, and startup races. This is stronger than a spinner: it prevents sound, accessibility announcements, and user expectations from claiming recording has begun before it is true. [Source](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisper/ViewModels/DictationViewModel.swift#L842-L914)

**Recommendation:** Whistle should publish preparation/readiness through its existing `SpeechAnalyzerResultsEngine → SpeechAnalyzerTranscriber → TranscriptionService → CaptureViewModel` path. The capture panel may be visible immediately, but “Listening” and the hot mic must start only after the speech model, locale reservation, analyzer format, and input path are ready. Installation/setup failure must produce an actionable type-only/error state, never a healthy-looking empty transcript. This is the existing P0 requirement, not a new feature.

### Audio failure requires a bounded, observable recovery path

TypeWhisper has extensive handling for route changes, Bluetooth startup, device compatibility, format changes, and a recovery circuit breaker. Its [recovery test suite](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperTests/AudioEngineRecoverySupportTests.swift) exercises the route/device policy and failure classifications. That depth reflects a mature dictation product, not a baseline Whistle must match.

**Recommendation:** take the principle, not the full device manager. Whistle should first guarantee ordered buffer delivery, timeout bounded analyzer setup, a visible error for setup/format failure, preserved editable text, and clear manual macOS 26 QA. Add device-route recovery only after real Whistle telemetry or reproducible reports establish the need. The current suspected out-of-order Task hop is higher priority than speculative Bluetooth policy ([BACKLOG](BACKLOG.md)).

### Interaction feedback is part of correctness

TypeWhisper distinguishes recording, processing, and error, announces status for accessibility, offers cancellation, and is designed to paste into the original application ([state orchestration](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisper/ViewModels/DictationViewModel.swift), [product description](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/README.md)). Whistle's user flow is intentionally different: its non-activating capture panel must accept typing without unexpectedly changing the frontmost app, then submit or dismiss cleanly.

**Recommendation:** carry forward explicit state and cancellation semantics, but retain Whistle's panel/focus design. Do not add automatic paste, clipboard replacement, or a global dictation overlay. Manual QA should verify status text, Escape behavior, partial-text preservation, VoiceOver announcements where applicable, and original-app focus after submit/cancel; see [TECH-SPEC §4](TECH-SPEC.md#4-macos-app) and `MANUAL-QA.md`.

## Test lessons, separated from implementation

TypeWhisper's useful lesson is not that it has a very large test suite. It is that the difficult behavior is extracted into plain, fake-driven decisions:

- Apple Speech locale selection has [focused tests](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK/Plugins/SpeechAnalyzerPlugin/Tests/AppleSpeechModelSelectionTests.swift) for exact locale, language fallback, persisted choice, and no-model failure.
- Its [audio recovery suite](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperTests/AudioEngineRecoverySupportTests.swift) tests transitions and policies—format mismatch, disconnect/startup cancellation, circuit-breaker behavior, and readiness deadlines—without requiring a microphone for every case.
- Its [live protocol](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/TypeWhisperPlugin.swift#L602-L610) isolates `appendAudio`, `finish`, and `cancel`, letting a host own UI orchestration rather than expose Speech framework types everywhere.

Whistle already has good low-level conversion tests and transcript-stitching tests, but the real `LiveSpeechAnalyzerEngine` orchestration is untested. The gap is documented precisely in [BACKLOG](BACKLOG.md). The next tests should be small and deterministic: a FIFO/drop-oldest pending-buffer type; an injectable analyzer-input sink that asserts converted Int16 buffers; a controllable preparation result for ready, install failure, timeout, and cancellation; and the existing hardware manual test for the Apple runtime contract. No fake suite can prove an undocumented framework precondition safe on a new macOS release.

## Explicit non-transfers

- **Plugin platform:** TypeWhisper's [manifests and host services](https://github.com/TypeWhisper/typewhisper-mac/tree/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisperPluginSDK) serve a broad desktop product. They add lifecycle, compatibility, security, and settings costs without solving a current Whistle problem.
- **Paste-at-cursor:** TypeWhisper is explicitly designed to paste into the active application ([README](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/README.md)); Whistle creates an editable capture with screenshot/project context. Silently pasting raw text into a third-party app is the wrong completion model and requires broader Accessibility/clipboard failure handling.
- **Audio recovery retention:** TypeWhisper's [recovery-audio store](https://github.com/TypeWhisper/typewhisper-mac/blob/bea4f2d6ce77bf89482636720ef53190b966e530/TypeWhisper/Services/DictationRecoveryAudioStore.swift) retains WAV data. It is not part of Whistle v1, but it is a valid future recovery option to evaluate against disk footprint, retention/deletion controls, user expectations, and recovery benefit rather than reject by default.
- **Cloud engines and broad settings:** TypeWhisper exposes many external providers through its plugin catalog. These introduce credentials, network/privacy policy, support matrix, and user-choice complexity; they are out of Whistle v1.

## Decision

Use TypeWhisper as a reference for readiness, explicit lifecycle states, narrow test seams, and future capability boundaries. Do not copy its product surface or plugin architecture. The only path to alternate local engines is the controlled benchmark and decision gate in the [roadmap](plans/2026-07-28-001-typewhisper-speech-roadmap.md).
