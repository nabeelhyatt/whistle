// AudioBufferConverter.swift
// Converts native mic buffers (Float32 @ hardware sample rate) into
// whatever PCM format a downstream consumer requires, so that consumer
// never has to trust the tap's native format.
//
// Why this exists: `AudioEngineTap` installs its tap in the input node's
// NATIVE format (Float32, hardware sample rate — typically 48kHz), per its
// own file header ("conversion belongs downstream"). macOS 26's
// `SpeechAnalyzer` requires Int16 samples — its `AnalyzerInput(buffer:)`
// path has an internal precondition, "Audio sample data must be 16-bit
// signed integers", that fires as an UNCATCHABLE SIGTRAP if a Float32
// buffer is handed to it directly (confirmed crash, see
// SpeechAnalyzerTranscriber.swift's file header). This converter is what
// stands between the native tap and that precondition.
//
// Pattern follows Apple's WWDC25 "SpokenWordTranscriber" sample's
// `BufferConverter`: lazily build one `AVAudioConverter`, reuse it across
// calls, and only rebuild it if the input format actually changes (mic
// route changes, etc. are rare mid-session but not impossible). Conversion
// failures are surfaced as thrown errors, never as a crash — callers are
// expected to drop the buffer and keep running.

import AVFoundation
import Foundation

/// Errors this converter can throw. Callers should treat all of these as
/// "drop this buffer, do not crash" — none of them should ever propagate
/// as an app-terminating failure.
public enum AudioBufferConverterError: Error {
    /// `AVAudioConverter(from:to:)` returned nil for the requested
    /// input/output format pair.
    case converterCreationFailed
    /// The output buffer couldn't be allocated at the computed capacity.
    case outputBufferAllocationFailed
    /// `AVAudioConverter.convert(to:error:withInputFrom:)` itself failed;
    /// the associated error is whatever the converter reported.
    case conversionFailed(Error)
}

/// Converts `AVAudioPCMBuffer`s from whatever format the mic tap hands us
/// into a target format a downstream consumer (here, `SpeechAnalyzer` via
/// `SpeechAnalyzer.bestAvailableAudioFormat`) requires.
///
/// Not thread-safe on its own — callers that touch this from multiple
/// threads must serialize access themselves (`LiveSpeechAnalyzerEngine`
/// does this with its own lock).
final class AudioBufferConverter {
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?

    /// Converts `buffer` to `outputFormat`. If `buffer.format` already
    /// equals `outputFormat`, returns `buffer` unchanged (fast path — no
    /// allocation, no conversion work).
    ///
    /// Lazily creates one `AVAudioConverter` for the (input, output) format
    /// pair and reuses it across calls; only recreates it if either format
    /// changes from the previous call (e.g. the input node's native format
    /// changed after a route change).
    func convert(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        if inputFormat == outputFormat {
            return buffer
        }

        let converter = try converter(from: inputFormat, to: outputFormat)

        let outputFrameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(outputFrameCapacity, 1)
        ) else {
            throw AudioBufferConverterError.outputBufferAllocationFailed
        }

        // One-shot input block per Apple's sample pattern: hand the
        // converter the whole input buffer exactly once (`.haveData`),
        // then report `.noDataNow` on every subsequent pull so the
        // converter knows not to ask again for this call.
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw AudioBufferConverterError.conversionFailed(conversionError ?? NSError(
                domain: "AudioBufferConverter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter.convert failed with no error detail"]
            ))
        }

        return outputBuffer
    }

    /// Returns the cached converter if `inputFormat`/`outputFormat` match
    /// the last call, otherwise builds (and caches) a new one.
    private func converter(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converterInputFormat == inputFormat, converterOutputFormat == outputFormat {
            return converter
        }

        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioBufferConverterError.converterCreationFailed
        }
        newConverter.primeMethod = .none
        converter = newConverter
        converterInputFormat = inputFormat
        converterOutputFormat = outputFormat
        return newConverter
    }
}
