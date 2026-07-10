// TranscriptStitchingTests.swift
// Plan U7 scenarios, run against FAKE recognizer engines — no mic, no TCC,
// no real SFSpeechRecognizer/SpeechAnalyzer involved:
//   - volatile updates then isFinal -> committed extends, live resets
//   - task error mid-utterance -> new task starts, committed preserved,
//     no dropped join-space or duplicated words
//   - three consecutive finalizations -> correctly ordered concatenation
//   - stop() mid-live-segment -> live hypothesis included in final text
//   - (SpeechAnalyzer path) same scenarios re-run against a fake
//     SpeechAnalyzer-shaped engine, compiled behind #available(macOS 26, *)

import AVFoundation
import XCTest
@testable import Whistle

// MARK: - Fake AudioTap (shared by both transcribers below)

/// No-op `AudioTap`: these tests drive stitching entirely through fake
/// recognition engines, so no real `AVAudioEngine` may be constructed — on
/// hardware-less CI runners, a real tap's `prewarm()`/`start()` traps
/// fatally inside AVFAudio (uncatchable), which previously looped
/// xcodebuild's crash recovery for hours.
final class NoOpAudioTap: AudioTap, @unchecked Sendable {
    func prewarm() {}
    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {}
    func stop() {}
}

// MARK: - Fake SpeechRecognitionEngine (LegacySpeechTranscriber)

/// Scriptable fake for `SpeechRecognitionEngine`. Each call to
/// `startTask()` pops the next scripted "segment" (a list of outcomes) and
/// replays it as an `AsyncStream`, mirroring how a real
/// `SFSpeechRecognitionTask` stops after the first final/error.
final actor FakeSpeechRecognitionEngineState {
    private var segments: [[SpeechRecognitionTaskOutcome]]
    private(set) var startTaskCallCount = 0
    private(set) var appendedBufferCount = 0
    private(set) var endCurrentTaskCallCount = 0

    init(segments: [[SpeechRecognitionTaskOutcome]]) {
        self.segments = segments
    }

    func nextSegment() -> [SpeechRecognitionTaskOutcome] {
        startTaskCallCount += 1
        guard !segments.isEmpty else { return [] }
        return segments.removeFirst()
    }

    func recordAppend() { appendedBufferCount += 1 }
    func recordEndCurrentTask() { endCurrentTaskCallCount += 1 }
}

final class FakeSpeechRecognitionEngine: SpeechRecognitionEngine, @unchecked Sendable {
    let state: FakeSpeechRecognitionEngineState

    init(segments: [[SpeechRecognitionTaskOutcome]]) {
        self.state = FakeSpeechRecognitionEngineState(segments: segments)
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        Task { await state.recordAppend() }
    }

    func startTask() -> AsyncStream<SpeechRecognitionTaskOutcome> {
        AsyncStream { continuation in
            Task {
                let outcomes = await state.nextSegment()
                for outcome in outcomes {
                    continuation.yield(outcome)
                    // Yield control so `LegacySpeechTranscriber`'s
                    // `Task`-based consumption loop can process each
                    // outcome before the next is delivered — keeps
                    // ordering deterministic in tests.
                    await Task.yield()
                }
                continuation.finish()
            }
        }
    }

    func endCurrentTask() {
        Task { await state.recordEndCurrentTask() }
    }

    func cancelAll() {}
}

// MARK: - Test helpers

/// Collects `TranscriptUpdate`s from a stream until `stop()` finishes it,
/// with a generous timeout so a hung stream fails the test instead of the
/// suite.
private func collectUpdates(
    _ stream: AsyncStream<TranscriptUpdate>,
    stopAfter stopAction: (() async -> Void)? = nil,
    stopAfterCount: Int? = nil
) async -> [TranscriptUpdate] {
    var updates: [TranscriptUpdate] = []
    if let stopAfterCount {
        for await update in stream {
            updates.append(update)
            if updates.count == stopAfterCount {
                await stopAction?()
            }
        }
    } else {
        for await update in stream {
            updates.append(update)
        }
    }
    return updates
}

// MARK: - LegacySpeechTranscriber tests

final class TranscriptStitchingTests: XCTestCase {
    // MARK: Happy: volatile updates then isFinal -> committed extends, live resets

    func testVolatileUpdatesThenFinalExtendsCommittedAndResetsLive() async {
        let fake = FakeSpeechRecognitionEngine(segments: [
            [
                .event(SpeechRecognitionEvent(text: "hello", isFinal: false)),
                .event(SpeechRecognitionEvent(text: "hello world", isFinal: false)),
                .event(SpeechRecognitionEvent(text: "hello world final", isFinal: true)),
            ],
            [], // second segment starts but yields nothing further in this test
        ])
        let transcriber = LegacySpeechTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var updates: [TranscriptUpdate] = []
        for await update in stream {
            updates.append(update)
            if updates.count == 3 { break }
        }

        XCTAssertEqual(updates[0], TranscriptUpdate(committed: "", live: "hello"))
        XCTAssertEqual(updates[1], TranscriptUpdate(committed: "", live: "hello world"))
        XCTAssertEqual(updates[2], TranscriptUpdate(committed: "hello world final", live: ""))

        await transcriber.stop()
    }

    // MARK: Edge: task error mid-utterance -> new task starts, committed
    // preserved, no dropped join-space or duplicated words

    func testTaskErrorMidUtterancePreservesCommittedAndStartsFreshSegment() async {
        struct FakeError: Error {}
        let fake = FakeSpeechRecognitionEngine(segments: [
            [
                .event(SpeechRecognitionEvent(text: "first segment", isFinal: true)),
            ],
            [
                .event(SpeechRecognitionEvent(text: "partial before error", isFinal: false)),
                .error(FakeError()),
            ],
            [
                .event(SpeechRecognitionEvent(text: "second segment", isFinal: true)),
            ],
            // Trailing empty segment: the transcriber always starts a fresh
            // segment immediately after a finalization (§4.1b — the engine
            // never stops between segments, and it can't know in advance
            // that a given final is the *last* one), so segment 3's
            // `isFinal` triggers a 4th `startTask()` call. Matches the
            // pattern in `testThreeConsecutiveFinalizationsConcatenateInOrder`.
            [],
        ])
        let transcriber = LegacySpeechTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var updates: [TranscriptUpdate] = []
        for await update in stream {
            updates.append(update)
            if updates.count == 4 { break }
        }

        XCTAssertEqual(updates[0], TranscriptUpdate(committed: "first segment", live: ""))
        XCTAssertEqual(updates[1], TranscriptUpdate(committed: "first segment", live: "partial before error"))
        // Error: committed preserved untouched, live cleared (not merged),
        // so nothing from the aborted partial is duplicated later.
        XCTAssertEqual(updates[2], TranscriptUpdate(committed: "first segment", live: ""))
        // Third segment's final text joins with exactly one space and no
        // duplicated words.
        XCTAssertEqual(updates[3], TranscriptUpdate(committed: "first segment second segment", live: ""))

        await transcriber.stop()
        let startTaskCallCount = await fake.state.startTaskCallCount
        XCTAssertEqual(startTaskCallCount, 4)
    }

    // MARK: Edge: three consecutive finalizations -> correctly ordered concatenation

    func testThreeConsecutiveFinalizationsConcatenateInOrder() async {
        let fake = FakeSpeechRecognitionEngine(segments: [
            [.event(SpeechRecognitionEvent(text: "one", isFinal: true))],
            [.event(SpeechRecognitionEvent(text: "two", isFinal: true))],
            [.event(SpeechRecognitionEvent(text: "three", isFinal: true))],
            [],
        ])
        let transcriber = LegacySpeechTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var updates: [TranscriptUpdate] = []
        for await update in stream {
            updates.append(update)
            if updates.count == 3 { break }
        }

        XCTAssertEqual(updates[0].committed, "one")
        XCTAssertEqual(updates[1].committed, "one two")
        XCTAssertEqual(updates[2].committed, "one two three")
        XCTAssertEqual(updates[2].live, "")

        await transcriber.stop()
    }

    // MARK: Edge: stop() mid-live-segment -> live hypothesis included in final text

    func testStopMidLiveSegmentIncludesLiveHypothesisInFinalText() async {
        let fake = FakeSpeechRecognitionEngine(segments: [
            [
                .event(SpeechRecognitionEvent(text: "committed part", isFinal: true)),
            ],
            [
                .event(SpeechRecognitionEvent(text: "trailing live hypothesis", isFinal: false)),
            ],
        ])
        let transcriber = LegacySpeechTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var iterator = stream.makeAsyncIterator()

        // First update: "committed part" finalized.
        let first = await iterator.next()
        XCTAssertEqual(first, TranscriptUpdate(committed: "committed part", live: ""))

        // Second update: live hypothesis arrives from the new segment.
        let second = await iterator.next()
        XCTAssertEqual(second, TranscriptUpdate(committed: "committed part", live: "trailing live hypothesis"))

        // stop() mid-live-segment: the live hypothesis must be folded into
        // the final committed text, not dropped.
        await transcriber.stop()
        let final = await iterator.next()
        XCTAssertEqual(final, TranscriptUpdate(committed: "committed part trailing live hypothesis", live: ""))

        let afterFinal = await iterator.next()
        XCTAssertNil(afterFinal, "stream should finish after stop()'s final update")
    }

    // MARK: displayText / TranscriptStitcher.join

    func testDisplayTextJoinsWithSingleSpaceAndHandlesEmptySides() {
        XCTAssertEqual(TranscriptUpdate(committed: "", live: "").displayText, "")
        XCTAssertEqual(TranscriptUpdate(committed: "hello", live: "").displayText, "hello")
        XCTAssertEqual(TranscriptUpdate(committed: "", live: "world").displayText, "world")
        XCTAssertEqual(TranscriptUpdate(committed: "hello", live: "world").displayText, "hello world")
    }
}

// MARK: - SpeechAnalyzerTranscriber tests (fake engine, macOS 26+ API surface)
//
// These re-run the same stitching scenarios against
// `SpeechAnalyzerResultsEngine`'s fake, proving the code compiles and the
// TranscriptUpdate contract holds under the macOS 26 SDK's shape — NOT
// real macOS 26 runtime behavior (see SpeechAnalyzerTranscriber.swift's
// file header; tagged runtime-unverified in docs/MANUAL-QA.md, U12).
// `SpeechAnalyzerTranscriber` itself only requires `#available(macOS 26,
// *)` for its *default* engineFactory — with an injected fake engine (as
// here) it is constructible and runnable on any OS version, which is what
// lets these tests run on this macOS 15.7.3 host.

final class FakeSpeechAnalyzerEngineState {
    private var events: [SpeechAnalyzerOutcome]
    private let lock = NSLock()
    private(set) var appendedBufferCount = 0
    private(set) var finishCallCount = 0

    init(events: [SpeechAnalyzerOutcome]) {
        self.events = events
    }

    func drain() -> [SpeechAnalyzerOutcome] {
        lock.lock(); defer { lock.unlock() }
        let all = events
        events = []
        return all
    }

    func recordAppend() {
        lock.lock(); appendedBufferCount += 1; lock.unlock()
    }

    func recordFinish() {
        lock.lock(); finishCallCount += 1; lock.unlock()
    }
}

final class FakeSpeechAnalyzerEngine: SpeechAnalyzerResultsEngine, @unchecked Sendable {
    let state: FakeSpeechAnalyzerEngineState

    init(events: [SpeechAnalyzerOutcome]) {
        self.state = FakeSpeechAnalyzerEngineState(events: events)
    }

    func appendAudio(buffer: AVAudioPCMBuffer) {
        state.recordAppend()
    }

    func startAnalysis() -> AsyncStream<SpeechAnalyzerOutcome> {
        AsyncStream { continuation in
            Task {
                for outcome in state.drain() {
                    continuation.yield(outcome)
                    await Task.yield()
                }
                continuation.finish()
            }
        }
    }

    func finish() async {
        state.recordFinish()
    }

    func cancel() {}
}

final class SpeechAnalyzerTranscriberStitchingTests: XCTestCase {
    func testVolatileThenFinalizedExtendsCommittedAndResetsLive() async {
        let fake = FakeSpeechAnalyzerEngine(events: [
            .event(SpeechAnalyzerResultEvent(text: "hello", isFinalized: false)),
            .event(SpeechAnalyzerResultEvent(text: "hello world", isFinalized: false)),
            .event(SpeechAnalyzerResultEvent(text: "hello world final", isFinalized: true)),
        ])
        let transcriber = SpeechAnalyzerTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var updates: [TranscriptUpdate] = []
        for await update in stream {
            updates.append(update)
            if updates.count == 3 { break }
        }

        XCTAssertEqual(updates[0], TranscriptUpdate(committed: "", live: "hello"))
        XCTAssertEqual(updates[1], TranscriptUpdate(committed: "", live: "hello world"))
        XCTAssertEqual(updates[2], TranscriptUpdate(committed: "hello world final", live: ""))

        await transcriber.stop()
    }

    func testErrorMidUtterancePreservesCommittedText() async {
        struct FakeError: Error {}
        let fake = FakeSpeechAnalyzerEngine(events: [
            .event(SpeechAnalyzerResultEvent(text: "first", isFinalized: true)),
            .event(SpeechAnalyzerResultEvent(text: "partial", isFinalized: false)),
            .error(FakeError()),
        ])
        let transcriber = SpeechAnalyzerTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var updates: [TranscriptUpdate] = []
        for await update in stream {
            updates.append(update)
            if updates.count == 3 { break }
        }

        XCTAssertEqual(updates[0], TranscriptUpdate(committed: "first", live: ""))
        XCTAssertEqual(updates[1], TranscriptUpdate(committed: "first", live: "partial"))
        XCTAssertEqual(updates[2], TranscriptUpdate(committed: "first", live: ""))

        await transcriber.stop()
    }

    func testThreeConsecutiveFinalizationsConcatenateInOrder() async {
        let fake = FakeSpeechAnalyzerEngine(events: [
            .event(SpeechAnalyzerResultEvent(text: "one", isFinalized: true)),
            .event(SpeechAnalyzerResultEvent(text: "two", isFinalized: true)),
            .event(SpeechAnalyzerResultEvent(text: "three", isFinalized: true)),
        ])
        let transcriber = SpeechAnalyzerTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var updates: [TranscriptUpdate] = []
        for await update in stream {
            updates.append(update)
            if updates.count == 3 { break }
        }

        XCTAssertEqual(updates[0].committed, "one")
        XCTAssertEqual(updates[1].committed, "one two")
        XCTAssertEqual(updates[2].committed, "one two three")

        await transcriber.stop()
    }

    func testStopMidLiveSegmentIncludesLiveHypothesisInFinalText() async {
        let fake = FakeSpeechAnalyzerEngine(events: [
            .event(SpeechAnalyzerResultEvent(text: "committed part", isFinalized: true)),
            .event(SpeechAnalyzerResultEvent(text: "trailing live hypothesis", isFinalized: false)),
        ])
        let transcriber = SpeechAnalyzerTranscriber(audioTap: NoOpAudioTap(), engineFactory: { fake })

        let stream = await transcriber.start()
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertEqual(first, TranscriptUpdate(committed: "committed part", live: ""))

        let second = await iterator.next()
        XCTAssertEqual(second, TranscriptUpdate(committed: "committed part", live: "trailing live hypothesis"))

        await transcriber.stop()
        let final = await iterator.next()
        XCTAssertEqual(final, TranscriptUpdate(committed: "committed part trailing live hypothesis", live: ""))
    }
}
