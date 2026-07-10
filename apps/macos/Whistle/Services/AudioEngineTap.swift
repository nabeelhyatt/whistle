// AudioEngineTap.swift
// Shared `AVAudioEngine` input-tap wrapper used by both transcriber
// implementations. Implements the §4.2 latency budget's "prewarmed audio
// engine" pattern: the engine is built and the tap installed at init time,
// but the engine itself is not *running* until `start()` is called — so
// `TranscriptionService.start()` only has to start a already-built engine
// (~50 ms) rather than construct the whole audio graph on first use.
//
// No audio is ever persisted to disk (TECH-SPEC §9/PRD non-goals) — buffers
// are handed straight to the `onBuffer` callback and never written out.

import AVFoundation
import Foundation

/// Injection seam for the audio-capture layer, mirroring how
/// `SpeechRecognitionEngine` / `SpeechAnalyzerResultsEngine` abstract the
/// recognition layer — lets tests inject a no-op tap so no real
/// `AVAudioEngine` is ever touched (hardware-less CI runners have no input
/// device, and a real engine's `prewarm()`/`start()` traps fatally deep
/// inside AVFAudio rather than throwing, which no test-side do/catch can
/// recover from).
public protocol AudioTap: AnyObject {
    func prewarm()
    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func stop()
}

/// Thin wrapper around `AVAudioEngine` so `LegacySpeechTranscriber` /
/// `SpeechAnalyzerTranscriber` don't each duplicate tap-install/engine
/// lifecycle logic. Not an actor itself — it's always driven from inside
/// the owning transcriber actor (TECH-SPEC §4.1 concurrency note), which is
/// what actually serializes access.
public final class AudioEngineTap: AudioTap {
    private let engine = AVAudioEngine()
    private var isTapInstalled = false
    private(set) var isRunning = false

    public init() {}

    /// Installs the input tap immediately (prewarm) but does not start the
    /// engine. Safe to call once, at owner-init time.
    public func prewarm() {
        guard !isTapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Install with a no-op callback for now; `start(onBuffer:)` below
        // swaps in the real callback before starting the engine. Installing
        // here (rather than deferring to `start`) is what makes `start`
        // itself cheap.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
        isTapInstalled = true
    }

    /// The native input format, exposed so callers (`SFSpeechAudioBufferRecognitionRequest`,
    /// `SpeechAnalyzer.bestAvailableAudioFormat`) can align their request's
    /// expected format.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Starts the engine (or is a no-op if already running) and routes
    /// every subsequent input buffer to `onBuffer`. The tap is re-installed
    /// with the real callback here to avoid capturing stale callbacks
    /// across repeated stop/start cycles within the same transcriber
    /// lifetime (task-cycling per §4.1b re-uses the *engine*, not this
    /// method, across segments — this is only called once per capture
    /// session).
    public func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            onBuffer(buffer, time)
        }
        isTapInstalled = true
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Stops the engine and removes the tap entirely (end of capture
    /// session — not used between task-cycling segments, since §4.1b
    /// requires the engine to never stop between segments).
    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isTapInstalled = false
        isRunning = false
    }
}
