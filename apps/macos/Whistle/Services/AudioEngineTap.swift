// AudioEngineTap.swift
// Shared `AVAudioEngine` input-tap wrapper used by both transcriber
// implementations.
//
// IMPORTANT (mic-permission fix): prewarm() must NOT touch the input node.
// Accessing `engine.inputNode` (and installing a tap on it) activates the
// microphone hardware and triggers the "…would like to access the
// microphone" TCC prompt. Doing that at transcriber-construction /
// §4.2-prewarm time means the prompt can fire before the user has ever
// asked to record — and on an ad-hoc-signed Debug build (whose code
// signature, and therefore TCC grant, changes on every rebuild) that
// manifested as an endless prompt loop where "Allow" never sticks. So ALL
// input-node access is now deferred to `start()`, which only runs when a
// real capture actually begins recording. prewarm() is reduced to a cheap,
// mic-free no-op (the engine object itself is already constructed as a
// stored property; constructing it does not touch the mic).
//
// No audio is ever persisted to disk (TECH-SPEC §9/PRD non-goals) — buffers
// are handed straight to the `onBuffer` callback and never written out.

import AVFoundation
import Foundation

/// Minimal seam over the audio input tap so transcribers can be constructed
/// and driven in tests with a fake that records whether the
/// microphone-activating path (`start`) was ever hit — without touching
/// real TCC state. `AudioEngineTap` is the production implementation.
public protocol AudioTapping: AnyObject {
    /// Cheap, mic-free warm-up. Must NEVER touch the microphone / trigger a
    /// permission prompt.
    func prewarm()
    /// Begins recording: this is the ONLY method allowed to activate the
    /// microphone hardware (and thus trigger the TCC prompt on first use).
    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func stop()
}

/// Thin wrapper around `AVAudioEngine` so `LegacySpeechTranscriber` /
/// `SpeechAnalyzerTranscriber` don't each duplicate tap-install/engine
/// lifecycle logic. Not an actor itself — it's always driven from inside
/// the owning transcriber actor (TECH-SPEC §4.1 concurrency note), which is
/// what actually serializes access.
public final class AudioEngineTap: AudioTapping {
    private let engine = AVAudioEngine()
    private var isTapInstalled = false
    private(set) var isRunning = false

    public init() {}

    /// Deliberately does NO microphone-touching work (see the file header):
    /// it must not access `engine.inputNode` or install a tap, because both
    /// activate the mic and trigger the TCC prompt. The engine is already
    /// constructed; the real tap install + engine start happen in `start()`
    /// when a capture actually begins. Kept as a method (rather than
    /// removed) so the prewarm call site / intent stays explicit and the
    /// `AudioTapping` seam is uniform.
    public func prewarm() {
        // Intentionally empty: defer ALL input-node access to start().
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
