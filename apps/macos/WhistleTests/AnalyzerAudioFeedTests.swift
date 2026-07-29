// AnalyzerAudioFeedTests.swift
// Covers `AnalyzerAudioFeed` in isolation: the pre-analyzer queue/convert/
// drain state machine extracted from `LiveSpeechAnalyzerEngine`
// (SpeechAnalyzerTranscriber.swift). No mic/TCC, no `SpeechAnalyzer`,
// nothing macOS-26-gated — this is what pins the v1.0.9 SIGTRAP fix (see
// docs/solutions/runtime-errors/speechanalyzer-sigtrap-float32-audio-macos26.md)
// with a suite that runs on any host, per docs/BACKLOG.md's P2 item calling
// out that the engine previously had zero automated coverage.
//
// All assertions here are fully synchronous: `AnalyzerAudioFeed`'s sink is
// invoked inline, under its internal lock, from whichever thread calls
// `append`/`activate`/`closeDrainingTail` -- there is no async boundary to
// wait across, so (per
// docs/solutions/test-failures/async-fake-sleep-race-flaky-tests.md) no
// `Whistle_waitUntil` and no `Task.sleep` are used or needed anywhere in
// this file.

import AVFoundation
import XCTest
@testable import Whistle

/// Records buffers handed to the feed's sink, in delivery order. A tiny
/// lock-protected `@unchecked Sendable` recorder, mirroring the convention
/// used by `FakeSpeechAnalyzerEngineState` in TranscriptStitchingTests.swift
/// -- even though every call in these tests is synchronous and
/// single-threaded, the sink closure itself is typed `@Sendable`.
private final class RecordingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    var received: [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); buffers.append(buffer); lock.unlock()
    }
}

final class AnalyzerAudioFeedTests: XCTestCase {
    // MARK: - Test helpers (mirrors AudioBufferConverterTests.swift's private helpers --
    // not accessible cross-file, so duplicated here at matching semantics)

    /// Builds a Float32, non-interleaved buffer of `frameCount` frames at
    /// `sampleRate`. Frame counts are chosen per-test to be distinct so
    /// identity survives conversion (frame count is preserved 1:1 when
    /// input/output sample rates match).
    private func makeFloat32Buffer(
        sampleRate: Double,
        channels: AVAudioChannelCount = 1,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameCount, 1)) else {
            fatalError("failed to construct Float32 test buffer")
        }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else {
            fatalError("expected non-interleaved float channel data")
        }
        let frequency = 440.0
        for channel in 0..<Int(channels) {
            let samples = channelData[channel]
            for frame in 0..<Int(frameCount) {
                let t = Double(frame) / sampleRate
                samples[frame] = Float(sin(2 * Double.pi * frequency * t))
            }
        }
        return buffer
    }

    private func int16Format(sampleRate: Double, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            fatalError("failed to construct Int16 target format")
        }
        return format
    }

    // MARK: - Pre-activation queueing

    func testNoBufferReachesSinkBeforeActivation() {
        let feed = AnalyzerAudioFeed()
        let sink = RecordingSink()
        feed.setSink { sink.record($0) }

        feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: 100))
        feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: 200))

        XCTAssertTrue(sink.received.isEmpty, "no buffer should reach the sink before activate(format:)")
    }

    // MARK: - FIFO drain on activation

    func testActivateDrainsQueuedBuffersInFIFOOrder() {
        let feed = AnalyzerAudioFeed()
        let sink = RecordingSink()
        feed.setSink { sink.record($0) }

        for frameCount: AVAudioFrameCount in [100, 200, 300] {
            feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: frameCount))
        }

        let activated = feed.activate(format: int16Format(sampleRate: 16000))

        XCTAssertTrue(activated)
        XCTAssertEqual(sink.received.map { Int($0.frameLength) }, [100, 200, 300])
    }

    // MARK: - Bounded queue, drop-oldest

    func testQueueDropsOldestBeyondSixtyFourBuffers() {
        let feed = AnalyzerAudioFeed()
        let sink = RecordingSink()
        feed.setSink { sink.record($0) }

        // Tag each appended buffer with a distinct frameLength (index + 1)
        // so identity survives the same-sample-rate conversion below.
        for index in 0..<70 {
            feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: AVAudioFrameCount(index + 1)))
        }

        feed.activate(format: int16Format(sampleRate: 16000))

        XCTAssertEqual(sink.received.count, 64, "the queue should be bounded to 64 buffers")
        // 70 appended, 6 evicted oldest-first -> the surviving oldest is
        // appended index 6 (frameLength 7).
        XCTAssertEqual(sink.received.first.map { Int($0.frameLength) }, 7)
        XCTAssertEqual(sink.received.last.map { Int($0.frameLength) }, 70)
    }

    // MARK: - The SIGTRAP-guard test: every yielded buffer is already converted

    func testEveryYieldedBufferIsInActivatedInt16Format() {
        let feed = AnalyzerAudioFeed()
        let sink = RecordingSink()
        feed.setSink { sink.record($0) }

        // Pre-activation: queued at the mic's native Float32 @ 48kHz.
        feed.append(makeFloat32Buffer(sampleRate: 48000, frameCount: 4096))
        feed.append(makeFloat32Buffer(sampleRate: 48000, frameCount: 4096))

        let activatedFormat = int16Format(sampleRate: 16000)
        feed.activate(format: activatedFormat)

        // Post-activation: appended live, same native Float32 @ 48kHz.
        feed.append(makeFloat32Buffer(sampleRate: 48000, frameCount: 4096))

        XCTAssertEqual(sink.received.count, 3)
        for buffer in sink.received {
            XCTAssertEqual(
                buffer.format.commonFormat, .pcmFormatInt16,
                "every buffer that reaches the sink must already be Int16 -- this is the SIGTRAP-prevention contract"
            )
            XCTAssertEqual(buffer.format, activatedFormat)
        }
    }

    // MARK: - Post-activation append yields immediately, in order

    func testAppendAfterActivationYieldsImmediatelyInOrder() {
        let feed = AnalyzerAudioFeed()
        let sink = RecordingSink()
        feed.setSink { sink.record($0) }

        feed.activate(format: int16Format(sampleRate: 16000))

        for frameCount: AVAudioFrameCount in [10, 20, 30] {
            feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: frameCount))
        }

        XCTAssertEqual(sink.received.map { Int($0.frameLength) }, [10, 20, 30])
    }

    // MARK: - close()

    func testCloseDropsQueueAndIgnoresLaterAppendsAndRefusesActivation() {
        let feed = AnalyzerAudioFeed()
        let sink = RecordingSink()
        feed.setSink { sink.record($0) }

        feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: 100))
        feed.close()
        feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: 200))

        XCTAssertTrue(sink.received.isEmpty, "close() must drop the queue and ignore later appends")

        let activated = feed.activate(format: int16Format(sampleRate: 16000))
        XCTAssertFalse(activated, "activate(format:) must refuse once closed")
        XCTAssertTrue(sink.received.isEmpty)
    }

    // MARK: - closeDrainingTail()

    // NOTE on what this does and does NOT pin. It asserts that everything the
    // tail path emits is in the activated format, and that the feed is closed
    // afterwards. It does NOT assert that a tail buffer was emitted at all:
    // whether 44.1kHz -> 16kHz leaves resampler-delay frames is an
    // `AVAudioConverter` implementation detail, so a test demanding a non-empty
    // tail would be asserting Apple's behavior, not ours. Pinning the tail
    // yield itself needs a seam -- `AnalyzerAudioFeed`'s `converter:` init
    // parameter already exists, but `AudioBufferConverter` is a concrete
    // `final class`, so a fake can't be substituted yet. Until then the
    // deterministic half is asserted below rather than left to a vacuous
    // `allSatisfy` over a possibly-empty array.
    func testCloseDrainingTailKeepsEveryYieldedBufferInActivatedFormatAndCloses() {
        let feed = AnalyzerAudioFeed()
        let sink = RecordingSink()
        feed.setSink { sink.record($0) }

        let outputFormat = int16Format(sampleRate: 16000)
        feed.activate(format: outputFormat)
        // 44.1kHz -> 16kHz is a non-integer ratio, mirroring
        // AudioBufferConverterTests.testFinishDrainsOrResetsTheResamplerAfterANonIntegerRatioBuffer
        // -- this is what can leave resampler-delay frames for the tail to drain.
        feed.append(makeFloat32Buffer(sampleRate: 44100, frameCount: 4096))

        let countBeforeClose = sink.received.count
        XCTAssertEqual(countBeforeClose, 1, "the post-activation append should have yielded one converted buffer")

        feed.closeDrainingTail()

        let afterClose = sink.received
        XCTAssertFalse(afterClose.isEmpty, "non-empty is required or the format assertion below passes vacuously")
        XCTAssertGreaterThanOrEqual(afterClose.count, countBeforeClose, "the tail path must never drop already-yielded buffers")
        for buffer in afterClose {
            XCTAssertEqual(
                buffer.format, outputFormat,
                "every buffer the tail path emits must already be in the activated format"
            )
        }

        // closeDrainingTail() must leave the feed closed, not merely drained.
        XCTAssertFalse(feed.activate(format: outputFormat), "the feed must be closed after closeDrainingTail()")
        feed.append(makeFloat32Buffer(sampleRate: 16000, frameCount: 128))
        XCTAssertEqual(sink.received.count, afterClose.count, "no buffer may be accepted after closeDrainingTail()")

        // A plain close() (no prior activation) must never drain a tail.
        let neverActivatedFeed = AnalyzerAudioFeed()
        let neverActivatedSink = RecordingSink()
        neverActivatedFeed.setSink { neverActivatedSink.record($0) }
        neverActivatedFeed.close()
        XCTAssertTrue(neverActivatedSink.received.isEmpty)
    }

    // NOTE: a `testConversionFailureDropsBufferAndReportsExactlyOnce` case
    // was considered (mutation-testable conversion-failure path) but cut:
    // there is no deterministic, fixture-based way to make
    // `AudioBufferConverter.convert` throw (it only throws on
    // `AVAudioConverter` construction/conversion failures driven by the
    // underlying framework, not on any input this suite can construct), so
    // a test for it could not reliably go red on a real regression -- see
    // this file's mandate that a test unable to fail on the bug it claims
    // to guard should not be added.
}
