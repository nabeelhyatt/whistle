// AnalyzerAudioFeed.swift
// Pure, non-macOS-26-gated audio state machine extracted from
// `LiveSpeechAnalyzerEngine` (see SpeechAnalyzerTranscriber.swift's file
// header for the SIGTRAP crash this pins the fix for). This type owns the
// entire pre-analyzer pipeline: queue-until-format-known, bounded
// drop-oldest, in-order drain, and per-buffer conversion — everything that
// must run correctly *before* a buffer is allowed to become an
// `AnalyzerInput` (a macOS-26-only type that stays inside the gated
// engine).
//
// Deliberately depends on nothing beyond Foundation/AVFoundation so
// `AnalyzerAudioFeedTests` can exercise the SIGTRAP-guard invariants
// (queueing, FIFO drain, drop-oldest, and — the single most important
// property — "every yielded buffer is already in the activated format") on
// any host, without macOS 26 or a real `SpeechAnalyzer`.

import AVFoundation
import Foundation

/// Owns the pending-buffer queue + conversion pipeline that used to live
/// directly on `LiveSpeechAnalyzerEngine` as `analyzerFormat`,
/// `pendingBuffers`, `bufferConverter`, and `didLogConversionFailure`.
///
/// Contract (unchanged from the engine's prior inline implementation):
/// - Before `activate(format:)`: buffers are FIFO-queued, oldest dropped
///   past `maxPendingBuffers`.
/// - After `activate(format:)`: buffers are converted to the activated
///   format and yielded to the sink inline.
/// - After `close()`/`closeDrainingTail()`: buffers are dropped.
/// - A conversion failure drops the buffer and reports through
///   `onConversionFailure` EXACTLY ONCE per feed lifetime, whether it
///   happens on the live path or the tail-drain path.
///
/// All sink calls happen while holding the internal lock — this is the same
/// "hold the lock across convert+yield" contract the engine previously
/// documented on `yieldConvertedLocked`: it's what stops a fresh `append`
/// from leapfrogging an in-flight `activate` drain.
final class AnalyzerAudioFeed: @unchecked Sendable {
    private let maxPendingBuffers: Int
    private let converter: AudioBufferConverter
    private let onConversionFailure: @Sendable (Error) -> Void

    private let lock = NSLock()
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var format: AVAudioFormat?
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var isClosed = false
    private var didReportConversionFailure = false

    init(
        maxPendingBuffers: Int = 64,
        converter: AudioBufferConverter = AudioBufferConverter(),
        onConversionFailure: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.maxPendingBuffers = maxPendingBuffers
        self.converter = converter
        self.onConversionFailure = onConversionFailure
    }

    /// Sets (or clears, with `nil`) where converted buffers go. Cleared by
    /// `close()`.
    func setSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    /// Pre-activation: FIFO-queues `buffer`, evicting the oldest once the
    /// queue exceeds `maxPendingBuffers`. Post-activation: converts to the
    /// activated format and yields inline. After `close()`: drops the
    /// buffer. On conversion failure: drops the buffer and reports via
    /// `onConversionFailure` at most once for this feed's lifetime.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        guard let format else {
            pendingBuffers.append(buffer)
            if pendingBuffers.count > maxPendingBuffers {
                pendingBuffers.removeFirst()
            }
            return
        }
        yieldConvertedLocked(buffer, targetFormat: format)
    }

    /// Publishes `format` and drains any queued buffers, in FIFO order,
    /// through the converter into the sink — all under one lock, so
    /// `append` can't leapfrog the drain. Returns `false` (and yields
    /// nothing) if the feed is already closed.
    @discardableResult
    func activate(format: AVAudioFormat) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return false }
        self.format = format
        let queuedBuffers = pendingBuffers
        pendingBuffers = []
        for queuedBuffer in queuedBuffers {
            yieldConvertedLocked(queuedBuffer, targetFormat: format)
        }
        return true
    }

    /// The `finish()` path: if activated, yields the converter's tail via
    /// `AudioBufferConverter.finish(convertingTo:)`, then closes.
    func closeDrainingTail() {
        lock.lock()
        defer { lock.unlock() }
        if let format, !isClosed {
            do {
                for buffer in try converter.finish(convertingTo: format) {
                    sink?(buffer)
                }
            } catch {
                reportConversionFailureLocked(error)
            }
        }
        closeLocked()
    }

    /// The `cancel()` path: drops the queue, clears format/sink, marks
    /// closed. Does not touch the converter tail.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    /// MUST be called with `lock` held.
    private func yieldConvertedLocked(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        do {
            let converted = try converter.convert(buffer, to: targetFormat)
            sink?(converted)
        } catch {
            reportConversionFailureLocked(error)
        }
    }

    /// MUST be called with `lock` held.
    private func reportConversionFailureLocked(_ error: Error) {
        guard !didReportConversionFailure else { return }
        didReportConversionFailure = true
        onConversionFailure(error)
    }

    /// MUST be called with `lock` held.
    private func closeLocked() {
        isClosed = true
        pendingBuffers = []
        format = nil
        sink = nil
    }
}
