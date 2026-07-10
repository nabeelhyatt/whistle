// SpeechAnalyzerTranscriber.swift
// macOS 26+ path (TECH-SPEC §4.1/§4.1b): the native `SpeechAnalyzer` /
// `SpeechTranscriber` API supports long-form sessions with volatile +
// finalized results *without* the task-cycling §4.1b requires for
// `SFSpeechRecognizer` — no artificial segment restarts are needed here.
//
// RUNTIME-UNVERIFIED: this host is macOS 15.7.3. The macOS 26.2 SDK
// (present in this Xcode install) is used to compile this file behind
// `#available(macOS 26, *)`, and the API surface below was read directly
// from the SDK's Speech.swiftinterface
// (MacOSX26.2.sdk/.../Speech.framework/.../arm64e-apple-macos.swiftinterface)
// rather than guessed from memory. It compiles, and its segment-stitching
// contract is exercised against a FAKE results sequence in
// `TranscriptStitchingTests`, but real on-device behavior — model
// download, volatile-range timing, actual audio-driven results — has never
// run. See docs/MANUAL-QA.md (U12): "SpeechAnalyzerTranscriber — requires
// a macOS 26 machine."
//
// API surface actually found in the SDK (summarized from the
// swiftinterface read above):
//   - `SpeechTranscriber(locale:preset:)` is a `SpeechModule` you hand to
//     `SpeechAnalyzer(modules:options:)`.
//   - `SpeechAnalyzer.start(inputSequence:)` consumes an
//     `AsyncSequence<AnalyzerInput>` (wrapping `AVAudioPCMBuffer`), fed
//     with an `AsyncStream` we control from the audio tap.
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
// mic, no TCC, and (crucially, since this host can't even construct a real
// `SpeechAnalyzer` at runtime pre-macOS 26) no macOS 26 requirement to run
// the tests.

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

@available(macOS 26, *)
final class LiveSpeechAnalyzerEngine: SpeechAnalyzerResultsEngine, @unchecked Sendable {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    init(locale: Locale) {
        self.locale = locale
    }

    func appendAudio(buffer: AVAudioPCMBuffer) {
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
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
            self.inputContinuation = inputContinuation

            Task {
                do {
                    try await analyzer.start(inputSequence: inputStream)
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                    return
                }
            }

            Task {
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
        }
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() {
        inputContinuation?.finish()
        inputContinuation = nil
    }
}

// MARK: - SpeechAnalyzerTranscriber

/// macOS 26+ transcriber. An actor per TECH-SPEC §4.1's concurrency note,
/// matching `LegacySpeechTranscriber`. Implements the same
/// `TranscriptUpdate` contract: `committed` accumulates finalized result
/// text, `live` holds the newest not-yet-finalized result text.
///
/// RUNTIME-UNVERIFIED on this host (see file header) — the engine
/// (`SpeechAnalyzerResultsEngine`) is injectable so this actor's
/// committed/live bookkeeping is still exercised by
/// `TranscriptStitchingTests` via a fake engine, without requiring macOS
/// 26 or a real `SpeechAnalyzer`.
public actor SpeechAnalyzerTranscriber: TranscriptionService {
    private let locale: Locale
    private let audioTap: any AudioTap
    private let engineFactory: () -> any SpeechAnalyzerResultsEngine

    private var engine: (any SpeechAnalyzerResultsEngine)?
    private var committedTranscript = ""
    private var liveSegment = ""
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var resultsTask: Task<Void, Never>?

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        audioTap: any AudioTap = AudioEngineTap(),
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
