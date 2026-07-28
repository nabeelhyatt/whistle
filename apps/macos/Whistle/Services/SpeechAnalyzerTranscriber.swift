// SpeechAnalyzerTranscriber.swift
// macOS 26+ path (TECH-SPEC §4.1/§4.1b): the native `SpeechAnalyzer` /
// `SpeechTranscriber` API supports long-form sessions with volatile +
// finalized results *without* the task-cycling §4.1b requires for
// `SFSpeechRecognizer` — no artificial segment restarts are needed here.
//
// RUNTIME-VERIFIED on macOS 26 (Tahoe): this path now actually executes on
// a macOS 26 host, and running it exposed two real bugs the original
// macOS-15-host implementation couldn't have caught:
//   1. CRASH (fixed): `AudioEngineTap` installs its tap in the input
//      node's NATIVE format — Float32 @ 48kHz. Handing that straight to
//      `AnalyzerInput(buffer:)` hits an internal Speech-framework
//      precondition, "Audio sample data must be 16-bit signed integers",
//      which is an UNCATCHABLE SIGTRAP (not a throwable error) — it killed
//      the app outright. `LiveSpeechAnalyzerEngine` now queues buffers
//      until it learns the analyzer's required format
//      (`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, which
//      is the Int16 format the precondition demands) and converts every
//      buffer through `AudioBufferConverter` before it ever reaches
//      `AnalyzerInput`.
//   2. Locale never reserved (fixed): the engine never called
//      `AssetInventory.reserve(locale:)` before starting analysis, logging
//      "Cannot use modules with unallocated locales ... This will be an
//      error in a future release!" — now reserved once per session before
//      `analyzer.start(inputSequence:)`.
// The macOS 26.2 SDK (present in this Xcode install) is used to compile
// this file behind `#available(macOS 26, *)`, and the API surface below
// was read directly from the SDK's Speech.swiftinterface
// (MacOSX26.2.sdk/.../Speech.framework/.../arm64e-apple-macos.swiftinterface)
// rather than guessed from memory.
//
// API surface actually found in the SDK (summarized from the
// swiftinterface read above):
//   - `SpeechTranscriber(locale:preset:)` is a `SpeechModule` you hand to
//     `SpeechAnalyzer(modules:options:)`.
//   - `SpeechAnalyzer.start(inputSequence:)` consumes an
//     `AsyncSequence<AnalyzerInput>` (wrapping `AVAudioPCMBuffer`), fed
//     with an `AsyncStream` we control from the audio tap.
//   - `static SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:) async -> AVAudioFormat?`
//     returns the (Int16) format the analyzer's precondition requires —
//     the root-cause fix for the crash described above.
//   - `AssetInventory.reserve(locale:) async throws -> Bool` reserves the
//     locale's assets for use; must be awaited before `analyzer.start`.
//   - `SpeechTranscriber.results` is `AsyncSequence<SpeechTranscriber.Result, Error>`.
//     Each `Result` carries `range: CMTimeRange`, `resultsFinalizationTime: CMTime`,
//     and `text: AttributedString` — there is no `isFinal` boolean on the
//     result itself. Finality is determined by comparing a result's
//     `range` against the analyzer's `volatileRange` (nil/empty once a
//     range has been finalized) — the WWDC24/25 sample pattern: results
//     are volatile while inside `volatileRange` and finalized once that
//     range moves past them (see the classification in `startAnalysis`
//     below). `CMTimeRange` is a plain C struct bridged into Swift with
//     only `start`/`duration` fields — it has no `.end` property or
//     comparison operators, so the end time and comparison both go
//     through `CMTimeRangeGetEnd`/`CMTimeCompare` (verified against
//     CoreMedia's CMTimeRange.h/CMTime.h and CoreMedia.apinotes' Swift
//     name mappings, since the .swiftinterface for the ObjC/C-based
//     CoreMedia framework doesn't itself list Swift-visible symbols).
//   - `AssetInventory.status(forModules:)` / `assetInstallationRequest(supporting:)`
//     is the in-app model-download surface (§4.1b macOS 26+ path).
//
// The recognition-task layer here is injectable the same way as
// `LegacySpeechTranscriber`'s (`SpeechAnalyzerResultsEngine` protocol), so
// `TranscriptStitchingTests` can drive this actor's segment-stitching
// contract with a fake results sequence — no real `SpeechAnalyzer`, no
// mic, no TCC, and (crucially, since not every host running these tests is
// macOS 26) no macOS 26 requirement to run the tests.

import Foundation

#if canImport(Speech)
    import Speech
#endif

// MARK: - Injectable results layer

/// One `SpeechTranscriber.Result`-equivalent event, decoupled from the
/// real SDK type so tests can script results without needing a live
/// `SpeechAnalyzer`/`SpeechTranscriber` (which requires macOS 26 hardware
/// and a downloaded model to construct meaningfully).
public struct SpeechAnalyzerResultEvent: Equatable, Sendable {
    public let text: String
    /// True once this result's time range is no longer inside the
    /// analyzer's volatile range — i.e. it will not change further.
    public let isFinalized: Bool

    public init(text: String, isFinalized: Bool) {
        self.text = text
        self.isFinalized = isFinalized
    }
}

public enum SpeechAnalyzerOutcome: Sendable {
    case event(SpeechAnalyzerResultEvent)
    case error(Error)
}

/// Abstraction over "run the analyzer and give me a stream of transcriber
/// results." `LiveSpeechAnalyzerEngine` (real, macOS 26+ only) wraps
/// `SpeechAnalyzer` + `SpeechTranscriber`; `FakeSpeechAnalyzerEngine`
/// (test-only) scripts a sequence of `SpeechAnalyzerOutcome`s.
///
/// Unlike the legacy engine, macOS 26's `SpeechAnalyzer` does not need
/// task-cycling (§4.1b: "supports long-form sessions natively"), so this
/// protocol models a single long-lived results stream rather than
/// per-segment restarts.
public protocol SpeechAnalyzerResultsEngine: Sendable {
    /// Feeds one audio buffer to the running analysis.
    func appendAudio(buffer: AVAudioPCMBuffer)

    /// Starts analysis and returns the results stream. Runs until
    /// `finish()` is called or an error terminates it.
    func startAnalysis() -> AsyncStream<SpeechAnalyzerOutcome>

    /// Signals end of input and lets the analyzer finalize any remaining
    /// volatile range (`finalizeAndFinishThroughEndOfInput`), then ends
    /// the stream.
    func finish() async

    /// Hard-stop, used if `stop()` is called abnormally.
    func cancel()
}

#if canImport(AVFoundation)
    import AVFoundation
#endif

#if canImport(CoreMedia)
    import CoreMedia
#endif

/// Errors specific to `LiveSpeechAnalyzerEngine`'s own setup steps (as
/// opposed to errors thrown by `SpeechAnalyzer`/`AssetInventory`
/// themselves, which are surfaced as-is).
enum LiveSpeechAnalyzerEngineError: Error {
    /// `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` returned
    /// nil — there is no format this analyzer/transcriber combination can
    /// accept, so analysis cannot start at all.
    case noCompatibleAudioFormat
    /// `AssetInventory.reserve(locale:)` declined the reservation without
    /// throwing, so the analyzer must not start against that locale.
    case localeReservationFailed
}

@available(macOS 26, *)
final class LiveSpeechAnalyzerEngine: SpeechAnalyzerResultsEngine, @unchecked Sendable {
    /// Bound on how many pre-format-discovery buffers get queued before the
    /// oldest is dropped. `AudioEngineTap` installs its tap with a
    /// bufferSize of 4096 frames (≈85ms at the typical 48kHz native rate),
    /// so 64 buffers is ≈5.5s of audio — comfortably longer than analyzer
    /// setup (locale reservation + format lookup) should ever take, while
    /// still bounding memory if setup stalls.
    private static let maxPendingBuffers = 64

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    /// Guards `analyzerFormat` and `pendingBuffers`. `appendAudio` is a
    /// synchronous, non-async protocol method invoked from the owning
    /// actor as buffers arrive off the mic tap, while `analyzerFormat` is
    /// discovered and published from the async setup `Task` in
    /// `startAnalysis()` — an `NSLock` (rather than actor isolation) is
    /// what keeps those two call paths from racing on the same state.
    private let stateLock = NSLock()
    /// The Int16 format `SpeechAnalyzer.bestAvailableAudioFormat` reports
    /// once setup completes (see file header — this is the root-cause
    /// fix). `nil` until then: `appendAudio` has nothing to convert TO yet,
    /// so it queues instead.
    private var analyzerFormat: AVAudioFormat?
    /// Buffers received before `analyzerFormat` is known, replayed in
    /// order through the converter once it is. Bounded by
    /// `maxPendingBuffers` so a slow/stalled setup can't grow this
    /// unboundedly.
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private let bufferConverter = AudioBufferConverter()
    private var didLogConversionFailure = false
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    /// True only while this engine owns a successful locale reservation.
    /// Access is serialized by `stateLock` because setup and teardown run
    /// from separate tasks. Every release goes through
    /// `releaseReservedLocale()` — called by `finish()`/`cancel()`, and by
    /// the setup task itself at each early exit that happens before
    /// `analyzer.start`. That helper reads-and-clears this flag under the
    /// lock, so the release is idempotent no matter how many callers race
    /// it or when in setup/analysis it lands.
    private var hasReservedLocale = false
    private var isClosed = false

    init(locale: Locale) {
        self.locale = locale
    }

    func appendAudio(buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return }
        guard let format = analyzerFormat else {
            pendingBuffers.append(buffer)
            if pendingBuffers.count > Self.maxPendingBuffers {
                pendingBuffers.removeFirst()
            }
            return
        }
        yieldConvertedLocked(buffer, targetFormat: format)
    }

    /// Converts `buffer` to `targetFormat` — the Int16 format the
    /// analyzer's precondition requires (see file header) — and yields it
    /// as `AnalyzerInput`. Never crashes: a conversion failure drops the
    /// buffer and logs once, per the "conversion failure -> drop buffer,
    /// never crash" contract.
    ///
    /// MUST be called with `stateLock` held: `bufferConverter` is not
    /// thread-safe, and holding the lock across convert+yield is also what
    /// keeps `appendAudio` (owning-actor context) from yielding a fresh
    /// buffer ahead of older ones while `startAnalysis()`'s setup Task is
    /// still draining the pending queue.
    private func yieldConvertedLocked(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        do {
            let converted = try bufferConverter.convert(buffer, to: targetFormat)
            inputContinuation?.yield(AnalyzerInput(buffer: converted))
        } catch {
            if !didLogConversionFailure {
                didLogConversionFailure = true
                NSLog("LiveSpeechAnalyzerEngine: dropping audio buffer(s) after conversion failure: \(error)")
            }
        }
    }

    func startAnalysis() -> AsyncStream<SpeechAnalyzerOutcome> {
        AsyncStream { continuation in
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .progressiveTranscription
            )
            self.transcriber = transcriber
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.stateLock.lock()
            self.inputContinuation = inputContinuation
            self.stateLock.unlock()

            let setupTask = Task {
                // (a) Reserve the locale's assets before starting analysis
                // -- fixes the "Cannot use modules with unallocated
                // locales" warning (see file header). A throw here means
                // the session can't proceed; end gracefully (committed
                // text is preserved by the existing `.error` handling in
                // `SpeechAnalyzerTranscriber.handle`) rather than starting
                // the analyzer against an unreserved locale.
                do {
                    guard try await AssetInventory.reserve(locale: self.locale) else {
                        continuation.yield(.error(LiveSpeechAnalyzerEngineError.localeReservationFailed))
                        continuation.finish()
                        return
                    }
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                    return
                }
                self.stateLock.lock()
                self.hasReservedLocale = true
                self.stateLock.unlock()
                guard !Task.isCancelled, !self.checkIsClosed() else {
                    await self.releaseReservedLocale()
                    return
                }

                // (b) THE ROOT-CAUSE FIX: discover the Int16 format the
                // analyzer's precondition requires (see file header)
                // before any buffer is allowed to reach `AnalyzerInput`.
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    continuation.yield(.error(LiveSpeechAnalyzerEngineError.noCompatibleAudioFormat))
                    continuation.finish()
                    await self.releaseReservedLocale()
                    return
                }
                guard !Task.isCancelled, !self.checkIsClosed() else { return }

                // (c) Publish the format and drain whatever `appendAudio`
                // queued while setup was still in flight, all in one
                // critical section: `appendAudio` blocks on the lock until
                // the drain completes, so queued buffers can't be
                // leapfrogged by a newer one and the converter is never
                // touched from two threads at once.
                self.stateLock.lock()
                guard !self.isClosed else {
                    self.stateLock.unlock()
                    await self.releaseReservedLocale()
                    return
                }
                self.analyzerFormat = format
                let queuedBuffers = self.pendingBuffers
                self.pendingBuffers = []
                for queuedBuffer in queuedBuffers {
                    self.yieldConvertedLocked(queuedBuffer, targetFormat: format)
                }
                self.stateLock.unlock()

                // (d) Only now start the analyzer against the (converted)
                // input stream.
                self.stateLock.lock()
                guard !Task.isCancelled, !self.isClosed else {
                    self.stateLock.unlock()
                    await self.releaseReservedLocale()
                    return
                }
                self.stateLock.unlock()
                do {
                    try await analyzer.start(inputSequence: inputStream)
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
            self.stateLock.lock()
            if self.isClosed {
                self.stateLock.unlock()
                setupTask.cancel()
            } else {
                self.setupTask = setupTask
                self.stateLock.unlock()
            }

            let resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        // No `isFinal` field on `SpeechTranscriber.Result`
                        // (per the SDK surface above); a result is
                        // finalized once it no longer overlaps the
                        // analyzer's current volatile range. `CMTimeRange`
                        // is a plain C struct (start/duration only, no
                        // `.end` computed property in the Swift overlay —
                        // verified against the macOS 26.2 SDK's
                        // CMTimeRange.h) — the end time and the comparison
                        // both go through the C functions
                        // (`CMTimeRangeGetEnd`, `CMTimeCompare`) rather than
                        // Swift operators.
                        let volatileRange = await analyzer.volatileRange
                        let isFinalized: Bool
                        if let volatileRange {
                            let resultEnd = CMTimeRangeGetEnd(result.range)
                            isFinalized = CMTimeCompare(resultEnd, volatileRange.start) <= 0
                        } else {
                            isFinalized = true
                        }
                        let event = SpeechAnalyzerResultEvent(
                            text: String(result.text.characters),
                            isFinalized: isFinalized
                        )
                        continuation.yield(.event(event))
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
            self.stateLock.lock()
            if self.isClosed {
                self.stateLock.unlock()
                resultsTask.cancel()
            } else {
                self.resultsTask = resultsTask
                self.stateLock.unlock()
            }
        }
    }

    func finish() async {
        stateLock.lock()
        isClosed = true
        pendingBuffers = []
        let setupTask = setupTask
        self.setupTask = nil
        let resultsTask = resultsTask
        self.resultsTask = nil
        let continuation = inputContinuation
        if let format = analyzerFormat, let continuation {
            do {
                for buffer in try bufferConverter.finish(convertingTo: format) {
                    continuation.yield(AnalyzerInput(buffer: buffer))
                }
            } catch {
                if !didLogConversionFailure {
                    didLogConversionFailure = true
                    NSLog("LiveSpeechAnalyzerEngine: dropping converter tail after conversion failure: \(error)")
                }
            }
        }
        analyzerFormat = nil
        inputContinuation = nil
        stateLock.unlock()
        setupTask?.cancel()
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        await releaseReservedLocale()
    }

    func cancel() {
        stateLock.lock()
        isClosed = true
        pendingBuffers = []
        analyzerFormat = nil
        let setupTask = setupTask
        self.setupTask = nil
        let resultsTask = resultsTask
        self.resultsTask = nil
        let continuation = inputContinuation
        inputContinuation = nil
        stateLock.unlock()
        setupTask?.cancel()
        resultsTask?.cancel()
        continuation?.finish()
        Task {
            await self.releaseReservedLocale()
        }
    }

    /// Reads `isClosed` by taking `stateLock` itself — so, unlike the
    /// `...Locked` helpers above, callers must NOT already hold the lock
    /// (`stateLock` is a non-recursive `NSLock`; re-entering it deadlocks
    /// the mic path).
    private func checkIsClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isClosed
    }

    private func releaseReservedLocale() async {
        stateLock.lock()
        let shouldReleaseLocale = hasReservedLocale
        hasReservedLocale = false
        stateLock.unlock()
        if shouldReleaseLocale {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }
}

// MARK: - SpeechAnalyzerTranscriber

/// macOS 26+ transcriber. An actor per TECH-SPEC §4.1's concurrency note,
/// matching `LegacySpeechTranscriber`. Implements the same
/// `TranscriptUpdate` contract: `committed` accumulates finalized result
/// text, `live` holds the newest not-yet-finalized result text.
///
/// RUNTIME-VERIFIED on macOS 26 (see file header for the format-conversion
/// and locale-reservation fixes that verification surfaced) — the engine
/// (`SpeechAnalyzerResultsEngine`) is still injectable so this actor's
/// committed/live bookkeeping can also be exercised by
/// `TranscriptStitchingTests` via a fake engine, without requiring macOS
/// 26 or a real `SpeechAnalyzer`.
public actor SpeechAnalyzerTranscriber: TranscriptionService {
    private let locale: Locale
    private let audioTap: any AudioTapping
    private let engineFactory: () -> any SpeechAnalyzerResultsEngine

    private var engine: (any SpeechAnalyzerResultsEngine)?
    private var committedTranscript = ""
    private var liveSegment = ""
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var resultsTask: Task<Void, Never>?

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        audioTap: any AudioTapping = AudioEngineTap(),
        engineFactory: (() -> any SpeechAnalyzerResultsEngine)? = nil
    ) {
        self.locale = locale
        self.audioTap = audioTap
        if let engineFactory {
            self.engineFactory = engineFactory
        } else if #available(macOS 26, *) {
            self.engineFactory = { LiveSpeechAnalyzerEngine(locale: locale) }
        } else {
            // Never actually invoked pre-macOS 26 in production (the
            // factory in TranscriptionService.swift only constructs this
            // type behind `#available(macOS 26, *)`); guarded here so the
            // type still compiles and is constructible for tests on this
            // host with an injected fake.
            self.engineFactory = { fatalError("SpeechAnalyzerTranscriber requires macOS 26 or an injected engineFactory") }
        }
        self.audioTap.prewarm()
    }

    public func start() -> AsyncStream<TranscriptUpdate> {
        committedTranscript = ""
        liveSegment = ""

        let engine = engineFactory()
        self.engine = engine

        let (stream, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        self.continuation = continuation

        do {
            try audioTap.start { [weak self] buffer, _ in
                guard let self else { return }
                Task { await self.feed(buffer) }
            }
        } catch {
            continuation.yield(TranscriptUpdate(committed: committedTranscript, live: liveSegment))
            continuation.finish()
            return stream
        }

        let outcomes = engine.startAnalysis()
        resultsTask = Task { [weak self] in
            for await outcome in outcomes {
                guard let self else { return }
                await self.handle(outcome)
            }
        }

        return stream
    }

    public func stop() async {
        resultsTask?.cancel()
        await engine?.finish()
        audioTap.stop()

        // Same contract as LegacySpeechTranscriber: stop() mid-live-segment
        // folds the live hypothesis into committed rather than dropping it.
        if !liveSegment.isEmpty {
            committedTranscript = TranscriptStitcher.join(committedTranscript, liveSegment)
            liveSegment = ""
        }
        continuation?.yield(TranscriptUpdate(committed: committedTranscript, live: liveSegment))
        continuation?.finish()
        continuation = nil
        engine = nil
    }

    private func handle(_ outcome: SpeechAnalyzerOutcome) {
        switch outcome {
        case .event(let event):
            if event.isFinalized {
                committedTranscript = TranscriptStitcher.join(committedTranscript, event.text)
                liveSegment = ""
            } else {
                liveSegment = event.text
            }
            continuation?.yield(TranscriptUpdate(committed: committedTranscript, live: liveSegment))

        case .error:
            // SpeechAnalyzer sessions don't need task-cycling (§4.1b), so
            // an error here ends the session rather than spawning a new
            // segment; committed text is preserved and surfaced as-is.
            liveSegment = ""
            continuation?.yield(TranscriptUpdate(committed: committedTranscript, live: liveSegment))
            continuation?.finish()
            continuation = nil
            audioTap.stop()
            engine?.cancel()
            engine = nil
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        engine?.appendAudio(buffer: buffer)
    }

    // MARK: - Availability (§4.1b macOS 26+ path: AssetInventory download)

    @available(macOS 26, *)
    public static func checkAvailability(locale: Locale) async -> SpeechModelAvailability {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return .available
        case .downloading:
            return .downloading
        case .supported:
            return .downloadable
        case .unsupported:
            return .unavailableRequiresSystemSettings
        @unknown default:
            return .unavailableRequiresSystemSettings
        }
    }
}
