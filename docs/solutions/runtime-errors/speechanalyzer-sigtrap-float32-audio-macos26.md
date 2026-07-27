---
title: "SpeechAnalyzer SIGTRAP on macOS 26 — Float32 mic buffers fed to Int16-only AnalyzerInput"
date: 2026-07-27
category: docs/solutions/runtime-errors
module: "Whistle/Services (SpeechAnalyzerTranscriber + AudioEngineTap)"
problem_type: runtime_error
component: service_object
symptoms:
  - "App crashes seconds after starting a capture on macOS 26 (Tahoe), right after the mic-permission prompt"
  - "Crash report: EXC_BREAKPOINT (SIGTRAP) in Speech framework, SpeechRecognizerWorker.preRunRecognition() under SpeechAnalyzer.processInput"
  - "Unified log at crash time: Failed precondition — Audio sample data must be 16-bit signed integers"
  - "Unified log warning: Cannot use modules with unallocated locales … This will be an error in a future release!"
root_cause: wrong_api
resolution_type: code_fix
severity: critical
tags:
  - speech-analyzer
  - macos-26
  - avaudioconverter
  - audio-format
  - sigtrap
  - asset-inventory
---

# SpeechAnalyzer SIGTRAP on macOS 26 — Float32 mic buffers fed to Int16-only AnalyzerInput

## Problem

The first time the macOS 26 `SpeechAnalyzer` transcription path ever executed (the dev/user machine upgraded to Tahoe 26.5.2, flipping the `#available(macOS 26, *)` factory branch), every capture crashed the shipped app. The code had been written against the macOS 26 SDK on a macOS 15 host and was explicitly tagged RUNTIME-UNVERIFIED — compile-time correctness and fake-engine unit tests could not catch a runtime data-format contract.

## Symptoms

- App dies with `EXC_BREAKPOINT (SIGTRAP)` shortly after audio starts flowing; crashing thread is entirely inside Apple's Speech framework (`SpeechRecognizerWorker.preRunRecognition()`), with no app frames.
- The decisive evidence is in the unified log, not the crash report: `Failed precondition: Audio sample data must be 16-bit signed integers` (`log show --predicate 'process == "Whistle"'` around the crash timestamp).
- Secondary warning in the same log: `Cannot use modules with unallocated locales … This will be an error in a future release!`
- The mic-permission prompt appearing just before the crash was a red herring — merely the fresh post-OS-upgrade TCC grant.

## What Didn't Work

- **Relying on the engine's error handling.** `analyzer.start(inputSequence:)` was already wrapped in do/catch with a graceful `.error` path — but Apple enforces the sample-format contract with a `preconditionFailure` inside the framework, which is an uncatchable trap, not a thrown error. No amount of catching helps; the data must be correct *before* it reaches `AnalyzerInput`.
- **Guessing API names from memory.** The locale-allocation API is `AssetInventory.reserve(locale:)` — not `allocate` — confirmed by reading the SDK's `Speech.swiftmodule/arm64e-apple-macos.swiftinterface` directly. The repo convention of reading the swiftinterface rather than trusting recall is what kept the fix right on the first try.

## Solution

Fixed in PR #26 (v1.0.10). Two required pieces, both in `apps/macos/Whistle/Services/`:

1. **Convert every buffer to the analyzer's required format.** `AudioEngineTap` taps the input node in its *native* format (Float32 @ hardware rate — correct; non-native taps are unreliable on macOS). Conversion belongs downstream: `LiveSpeechAnalyzerEngine` asks the framework for the format it actually wants, then converts each buffer through a new `AudioBufferConverter` (one reused `AVAudioConverter`, `primeMethod = .none` — Apple's WWDC25 SpokenWordTranscriber pattern) before wrapping it in `AnalyzerInput`:

   ```swift
   // setup task, before analyzer.start:
   _ = try await AssetInventory.reserve(locale: locale)          // fixes the locale warning
   guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { … }

   // per buffer (under one lock — see below):
   let converted = try bufferConverter.convert(buffer, to: format)
   inputContinuation?.yield(AnalyzerInput(buffer: converted))
   ```

2. **Handle the setup/streaming race.** The audio tap starts feeding buffers before the async format lookup resolves. Buffers arriving pre-format are queued (bounded, drop-oldest) and drained in order once the format is known. The queue publish + drain and every convert+yield happen under a single `NSLock` critical section: `AVAudioConverter` is not thread-safe, and without the lock a fresh buffer from the tap could leapfrog older queued ones mid-drain.

Failure policy throughout: setup failures (reserve throws, no compatible format, `analyzer.start` throws) yield `.error` and end the session gracefully with committed text preserved; per-buffer conversion failures drop the buffer and log once. Nothing in the audio path is allowed to crash.

## Why This Works

`SpeechTranscriber`/`SpeechAnalyzer` require Int16 PCM input and enforce it with an internal precondition rather than a thrown error, so the only correct place to satisfy the contract is upstream of `AnalyzerInput`. `bestAvailableAudioFormat(compatibleWith:)` returns exactly the format the precondition demands, and `AVAudioConverter` handles both the sample-format (Float32→Int16) and sample-rate conversion. Reserving the locale via `AssetInventory.reserve(locale:)` satisfies the module/locale allocation contract that Apple currently logs as a warning and has announced will become a hard error.

## Prevention

- `AudioBufferConverterTests` (4 cases) run in CI with no mic/TCC: format/rate conversion output, same-format passthrough identity, non-integer rate ratios, and converter reuse across sequential buffers.
- **Availability-gated code is unverified code.** A path behind `#available(macOS N, *)` written on an older host will run for the first time on end-user machines the day they upgrade. Track such paths explicitly (this one was tagged RUNTIME-UNVERIFIED in the file header + MANUAL-QA U12) and treat "first host with the new OS" as a mandatory QA event — run the manual pass the same day the hardware becomes available, before users hit it.
- **Debugging recipe that worked:** crash report (`~/Library/Logs/DiagnosticReports/*.ips`) names the trapping framework function; the unified log around the crash timestamp names the actual precondition message. For Speech/AVFoundation SIGTRAPs, always pull both — the log line is usually the root cause in plain English.

## Related Issues

- PR #26 — the fix (`AudioBufferConverter.swift`, `LiveSpeechAnalyzerEngine` rework, run-dev.sh Debug-dylib re-sign)
- `docs/MANUAL-QA.md` U12 — macOS 26 dictation pass; transcript *quality* on this path is still unmeasured (relevant to the pending STT vendor decision)
- Distinct tooling gotcha found during verification (not documented separately yet): Developer-ID re-signing a Debug `.app` without re-signing Xcode's `Whistle.debug.dylib` makes dyld abort at launch with a Team-ID mismatch — fixed in `apps/macos/Scripts/run-dev.sh`
