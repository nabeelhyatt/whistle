// LegacySpeechTranscriber.swift
// The TESTED SHIPPING transcription path for v1 (TECH-SPEC §4.1/§4.1b):
// `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, driven by
// task-cycling with segment stitching, EXACTLY per §4.1b:
//
//   - `committedTranscript` (immutable, finalized segments joined with a
//     single space) + `liveSegment` (current task's volatile hypothesis).
//   - On `isFinal` or task error, the final text is appended to
//     `committedTranscript` and a fresh recognition task starts
//     immediately on the *same running* audio tap — the engine never stops
//     between segments.
//   - The UI binds to `committed + " " + live` (see `TranscriptUpdate`).
//
// The recognition-task layer (SFSpeechRecognizer / task creation) sits
// behind `SpeechRecognitionEngine`, a small protocol, so the stitching
// logic above can be unit-tested with a FAKE engine — no mic, no TCC, no
// real SFSpeechRecognizer involved (plan U7 requirement: "the
// recognition-task layer is injectable ... the stitching logic must be
// unit-testable with a FAKE recognizer").

import Foundation
import Speech

// MARK: - Injectable recognition-task layer

/// One volatile or final hypothesis from a recognition task, decoupled
/// from `SFSpeechRecognitionResult` so tests never have to construct a
/// real (largely un-constructible) `SFSpeechRecognitionResult`.
public struct SpeechRecognitionEvent: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// One outcome of a recognition task's lifetime: a stream of
/// hypotheses/finals, or an error that ends the task (§4.1b: "on ...  task
/// error, ... immediately start a fresh recognition task").
public enum SpeechRecognitionTaskOutcome: Sendable {
    case event(SpeechRecognitionEvent)
    case error(Error)
}

/// Abstraction over "start a recognition task against the live audio tap
/// and give me a stream of results." `LiveSpeechRecognitionEngine` wraps
/// the real `SFSpeechRecognizer`; `FakeSpeechRecognitionEngine` (test-only,
/// declared in the test target) scripts a sequence of outcomes without any
/// microphone or TCC involvement.
///
/// Each call to `startTask()` represents one "segment" in §4.1b's
/// task-cycling model — the engine returns a fresh `AsyncStream` per call,
/// and the owner (`LegacySpeechTranscriber`) is responsible for calling it
/// again after a final/error to start the next segment.
public protocol SpeechRecognitionEngine: Sendable {
    /// Feeds one audio buffer into whatever request backs the current
    /// task. No-ops if no task is active yet (a task may still be
    /// warming up asynchronously).
    func appendAudio(_ buffer: AVAudioPCMBuffer)

    /// Starts a new recognition task/segment and returns a stream of its
    /// outcomes. The stream finishes after the first `.error` or after a
    /// `.event` with `isFinal == true` — mirroring how a real
    /// `SFSpeechRecognitionTask` stops delivering results once finalized.
    func startTask() -> AsyncStream<SpeechRecognitionTaskOutcome>

    /// Ends the current task's request (analogous to
    /// `SFSpeechAudioBufferRecognitionRequest.endAudio()`), signalling no
    /// more audio is coming for this segment so it can finalize.
    func endCurrentTask()

    /// Cancels everything — called on `stop()`.
    func cancelAll()
}

/// Real `SFSpeechRecognizer`-backed engine. On-device recognition is
/// required per §4.1b ("`requiresOnDeviceRecognition = true`").
final class LiveSpeechRecognitionEngine: SpeechRecognitionEngine, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let lock = NSLock()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?

    init(locale: Locale) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = currentRequest
        lock.unlock()
        request?.append(buffer)
    }

    func startTask() -> AsyncStream<SpeechRecognitionTaskOutcome> {
        AsyncStream { continuation in
            guard let recognizer else {
                continuation.yield(.error(TranscriptionError.recognizerUnavailable))
                continuation.finish()
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true

            lock.lock()
            currentRequest = request
            lock.unlock()

            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    continuation.yield(.error(error))
                    continuation.finish()
                    self?.clearIfCurrent(request: request)
                    return
                }
                guard let result else { return }
                let event = SpeechRecognitionEvent(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                )
                continuation.yield(.event(event))
                if result.isFinal {
                    continuation.finish()
                    self?.clearIfCurrent(request: request)
                }
            }

            lock.lock()
            currentTask = task
            lock.unlock()
        }
    }

    func endCurrentTask() {
        lock.lock()
        let request = currentRequest
        lock.unlock()
        request?.endAudio()
    }

    func cancelAll() {
        lock.lock()
        let task = currentTask
        currentRequest = nil
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func clearIfCurrent(request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        if currentRequest === request {
            currentRequest = nil
            currentTask = nil
        }
        lock.unlock()
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
}

// MARK: - LegacySpeechTranscriber

/// The tested shipping transcriber. An actor per TECH-SPEC §4.1's
/// concurrency note: audio-tap callbacks and start()/stop() calls
/// serialize safely without manual locking.
public actor LegacySpeechTranscriber: TranscriptionService {
    private let locale: Locale
    private let engineFactory: () -> any SpeechRecognitionEngine
    private let audioTap: AudioEngineTap

    private var recognitionEngine: (any SpeechRecognitionEngine)?
    private var committedTranscript = ""
    private var liveSegment = ""
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var segmentTask: Task<Void, Never>?
    private var isStopping = false

    /// `engineFactory` is the injection seam plan U7 calls for: production
    /// code passes a closure that builds `LiveSpeechRecognitionEngine`;
    /// tests pass a closure that returns a scripted
    /// `FakeSpeechRecognitionEngine`, so the segment-stitching logic below
    /// runs with no mic and no TCC at all.
    public init(
        locale: Locale = Locale(identifier: "en-US"),
        audioTap: AudioEngineTap = AudioEngineTap(),
        engineFactory: (() -> any SpeechRecognitionEngine)? = nil
    ) {
        self.locale = locale
        self.audioTap = audioTap
        self.engineFactory = engineFactory ?? { LiveSpeechRecognitionEngine(locale: locale) }
        self.audioTap.prewarm()
    }

    public func start() -> AsyncStream<TranscriptUpdate> {
        committedTranscript = ""
        liveSegment = ""
        isStopping = false

        let engine = engineFactory()
        recognitionEngine = engine

        let (stream, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        self.continuation = continuation

        do {
            try audioTap.start { [weak self] buffer, _ in
                guard let self else { return }
                Task { await self.feed(buffer) }
            }
        } catch {
            // Mic/tap failure: emit whatever we have and end quietly. The
            // caller (CaptureViewModel, U8) is responsible for falling
            // back to type-only mode; this service never crashes.
            continuation.yield(TranscriptUpdate(committed: committedTranscript, live: liveSegment))
            continuation.finish()
            return stream
        }

        beginSegment(with: engine)
        return stream
    }

    public func stop() async {
        isStopping = true
        segmentTask?.cancel()
        recognitionEngine?.endCurrentTask()
        recognitionEngine?.cancelAll()
        audioTap.stop()

        // §4.1b / plan scenario: "stop() mid-live-segment -> live
        // hypothesis included in final text." Fold whatever volatile text
        // remains into committed before emitting the last update.
        if !liveSegment.isEmpty {
            committedTranscript = TranscriptStitcher.join(committedTranscript, liveSegment)
            liveSegment = ""
        }
        continuation?.yield(TranscriptUpdate(committed: committedTranscript, live: liveSegment))
        continuation?.finish()
        continuation = nil
        recognitionEngine = nil
    }

    // MARK: - Segment/task cycling (§4.1b)

    private func beginSegment(with engine: any SpeechRecognitionEngine) {
        let outcomes = engine.startTask()
        segmentTask = Task { [weak self] in
            for await outcome in outcomes {
                guard let self else { return }
                await self.handle(outcome, engine: engine)
            }
        }
    }

    private func handle(_ outcome: SpeechRecognitionTaskOutcome, engine: any SpeechRecognitionEngine) {
        guard !isStopping else { return }

        switch outcome {
        case .event(let event):
            if event.isFinal {
                // Finalize this segment: fold into committed, reset live,
                // and immediately start a fresh task on the same running
                // tap — the engine is never stopped here.
                committedTranscript = TranscriptStitcher.join(committedTranscript, event.text)
                liveSegment = ""
                emitCurrentState()
                beginSegment(with: engine)
            } else {
                liveSegment = event.text
                emitCurrentState()
            }

        case .error:
            // Task error mid-utterance (§4.1b): whatever volatile text we
            // had is lost (the underlying task can't finalize it), but
            // committedTranscript is preserved untouched, and a fresh task
            // starts immediately on the same tap. This matches the plan's
            // "committed text preserved, no dropped join-space or
            // duplicated words" — since liveSegment is simply cleared, not
            // merged, nothing gets duplicated on the next segment's first
            // event.
            liveSegment = ""
            emitCurrentState()
            beginSegment(with: engine)
        }
    }

    private func emitCurrentState() {
        continuation?.yield(TranscriptUpdate(committed: committedTranscript, live: liveSegment))
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        recognitionEngine?.appendAudio(buffer)
    }

    // MARK: - Availability (§4.1b model availability paths)

    /// macOS 14–15 path: `SFSpeechRecognizer.supportsOnDeviceRecognition`.
    /// There is no programmatic download — onboarding (U10) guides the
    /// user to System Settings → Keyboard → Dictation when this returns
    /// `.unavailableRequiresSystemSettings`.
    public static func checkAvailability(locale: Locale) -> SpeechModelAvailability {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailableRequiresSystemSettings
        }
        return recognizer.supportsOnDeviceRecognition
            ? .available
            : .unavailableRequiresSystemSettings
    }
}
