// AudioBufferConverterTests.swift
// Covers `AudioBufferConverter` in isolation: pure `AVAudioConverter`
// plumbing, no mic/TCC and no `SpeechAnalyzer` involved (all buffers here
// are synthesized in-test). This is the fix for the macOS 26 crash
// documented in `SpeechAnalyzerTranscriber.swift`'s file header — Speech
// requires Int16 samples and traps (uncatchably) on Float32 input, so this
// converter is what stands between the mic tap's native Float32 buffers
// and `AnalyzerInput`.

import AVFoundation
import XCTest
@testable import Whistle

final class AudioBufferConverterTests: XCTestCase {
    // MARK: - Test helpers

    /// Builds a Float32, non-interleaved buffer of `frameCount` frames at
    /// `sampleRate`, filled with a simple sine wave so the buffer has real
    /// (non-silent) sample data to convert.
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
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
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

    private func assertContainsNonZeroInt16Samples(
        _ buffer: AVAudioPCMBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let channelData = buffer.int16ChannelData else {
            XCTFail("expected Int16 channel data", file: file, line: line)
            return
        }

        let frameLength = Int(buffer.frameLength)
        let containsNonZeroSample = (0..<Int(buffer.format.channelCount)).contains { channel in
            let samples = channelData[channel]
            return (0..<frameLength).contains { samples[$0] != 0 }
        }

        XCTAssertTrue(
            containsNonZeroSample,
            "converted sine-wave buffer should contain non-zero Int16 samples",
            file: file,
            line: line
        )
    }

    // MARK: - Float32 48kHz mono -> Int16 16kHz

    func testFloat32ToInt16DownsampleProducesExpectedFormatAndFrameCount() throws {
        let converter = AudioBufferConverter()
        let inputBuffer = makeFloat32Buffer(sampleRate: 48000, frameCount: 4096)
        let outputFormat = int16Format(sampleRate: 16000)

        let outputBuffer = try converter.convert(inputBuffer, to: outputFormat)

        XCTAssertEqual(outputBuffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(outputBuffer.format.sampleRate, 16000)
        XCTAssertEqual(outputBuffer.format.channelCount, 1)

        let expectedFrames = 4096.0 * 16000.0 / 48000.0
        XCTAssertLessThanOrEqual(
            abs(Double(outputBuffer.frameLength) - expectedFrames),
            2,
            "expected ~\(expectedFrames) frames, got \(outputBuffer.frameLength)"
        )
        assertContainsNonZeroInt16Samples(outputBuffer)
    }

    // MARK: - Same-format passthrough (identity)

    func testSameFormatPassthroughReturnsTheSameBufferUnchanged() throws {
        let converter = AudioBufferConverter()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!
        let inputBuffer = makeFloat32Buffer(sampleRate: 48000, frameCount: 4096)

        let outputBuffer = try converter.convert(inputBuffer, to: format)

        XCTAssertTrue(
            outputBuffer === inputBuffer,
            "same-format conversion must be a fast-path identity return, not a copy"
        )
    }

    // MARK: - Float32 44.1kHz -> Int16 16kHz (non-integer ratio)

    func testFloat32ToInt16NonIntegerRatioDoesNotTruncate() throws {
        let converter = AudioBufferConverter()
        let inputBuffer = makeFloat32Buffer(sampleRate: 44100, frameCount: 4096)
        let outputFormat = int16Format(sampleRate: 16000)

        let outputBuffer = try converter.convert(inputBuffer, to: outputFormat)

        XCTAssertEqual(outputBuffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(outputBuffer.format.sampleRate, 16000)

        // 4096 * 16000 / 44100 = 1486.05... -- a non-integer ratio. The
        // output capacity is computed with `.rounded(.up)` specifically so
        // this case never truncates a partial frame away; allow the same
        // small tolerance as the other conversion tests for the
        // converter's own internal rounding.
        let expectedFrames = 4096.0 * 16000.0 / 44100.0
        XCTAssertGreaterThan(outputBuffer.frameLength, 0)
        XCTAssertLessThanOrEqual(
            abs(Double(outputBuffer.frameLength) - expectedFrames),
            2,
            "expected ~\(expectedFrames) frames, got \(outputBuffer.frameLength)"
        )
    }

    // MARK: - Repeated conversions reuse the converter

    func testThreeSequentialConversionsReuseTheConverterAndProduceConsistentOutput() throws {
        let converter = AudioBufferConverter()
        let outputFormat = int16Format(sampleRate: 16000)
        let expectedFramesPerCall = 4096.0 * 16000.0 / 48000.0

        var totalOutputFrames: AVAudioFrameCount = 0
        for _ in 0..<3 {
            let inputBuffer = makeFloat32Buffer(sampleRate: 48000, frameCount: 4096)
            let outputBuffer = try converter.convert(inputBuffer, to: outputFormat)

            XCTAssertEqual(outputBuffer.format.commonFormat, .pcmFormatInt16)
            XCTAssertEqual(outputBuffer.format.sampleRate, 16000)
            XCTAssertLessThanOrEqual(
                abs(Double(outputBuffer.frameLength) - expectedFramesPerCall),
                2,
                "each of the 3 sequential conversions (same in/out format, reused converter) should " +
                    "produce ~\(expectedFramesPerCall) frames, got \(outputBuffer.frameLength)"
            )
            totalOutputFrames += outputBuffer.frameLength
        }

        let expectedTotal = expectedFramesPerCall * 3
        XCTAssertLessThanOrEqual(
            abs(Double(totalOutputFrames) - expectedTotal),
            6,
            "total frames across 3 reused-converter calls should track 3x a single call"
        )
    }
}
