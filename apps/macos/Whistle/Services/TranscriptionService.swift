// TranscriptionService.swift
// The `TranscriptionService` protocol (TECH-SPEC §4.1 module table + §4.1b)
// and the shared value types both transcriber implementations
// (`LegacySpeechTranscriber`, `SpeechAnalyzerTranscriber`) publish through.
//
// Concurrency (TECH-SPEC §4.1 concurrency note): every conforming
// implementation is an **actor** so that audio-tap callbacks and
// start()/stop() calls serialize safely without manual locking. The
// factory (`TranscriptionServiceFactory`) picks the implementation at
// runtime via `#available`.

import Foundation

/// A single transcript change the UI should render. `committed` is the
/// immutable, finalized text accumulated so far (segments joined with a
/// single space, per §4.1b); `live` is the current in-flight hypothesis.
/// The UI binds to `committed + " " + live` (§4.1b) — this struct always
/// carries both so a subscriber never has to remember prior state.
public struct TranscriptUpdate: Equatable, Sendable {
    public let committed: String
    public let live: String

    public init(committed: String, live: String) {
        self.committed = committed
        self.live = live
    }

    /// The text the UI should actually display: committed text plus the
    /// live hypothesis, joined the same way §4.1b specifies for internal
    /// segment stitching (single space, and only when both sides are
    /// non-empty).
    public var displayText: String {
        TranscriptStitcher.join(self.committed, self.live)
    }
}

/// The per-OS speech transcriber contract (TECH-SPEC §4.1 module table).
/// `start()` returns a stream of `TranscriptUpdate`s; `stop()` ends the
/// session and yields one final update whose `live` has been folded into
/// `committed` (the "stop() mid-live-segment" plan scenario).
public protocol TranscriptionService: Actor {
    func start() -> AsyncStream<TranscriptUpdate>
    func stop() async
}

/// Per-OS model availability, exposed as a small surface for onboarding
/// (U10) to consume (TECH-SPEC §4.1b):
///   - macOS 14–15: `SFSpeechRecognizer.supportsOnDeviceRecognition` — no
///     programmatic download; onboarding guides the user to System
///     Settings → Keyboard → Dictation.
///   - macOS 26+: `AssetInventory`-backed download, progress reported
///     in-app.
public enum SpeechModelAvailability: Equatable, Sendable {
    /// On-device recognition is ready to use right now.
    case available
    /// Not available, and there is nothing this app can do to fix it
    /// programmatically — the user must act in System Settings (macOS
    /// 14–15 dictation model toggle).
    case unavailableRequiresSystemSettings
    /// Not installed yet, but this app can trigger an in-app download
    /// (macOS 26+ `AssetInventory`).
    case downloadable
    /// Currently downloading (macOS 26+).
    case downloading
}

/// Factory: picks the concrete `TranscriptionService` implementation at
/// runtime. `LegacySpeechTranscriber` is the tested shipping path for this
/// host (macOS 15.7.3); `SpeechAnalyzerTranscriber` compiles behind
/// `#available(macOS 26, *)` against the macOS 26 SDK present in Xcode
/// 26.3/26.2 but is runtime-unverified here (TECH-SPEC §4.1/§13 U7).
public enum TranscriptionServiceFactory {
    public static func make(locale: Locale = Locale(identifier: "en-US")) -> any TranscriptionService {
        if #available(macOS 26, *) {
            return SpeechAnalyzerTranscriber(locale: locale)
        } else {
            return LegacySpeechTranscriber(locale: locale)
        }
    }

    /// Availability check surface consumed by onboarding (U10, §4.1b).
    public static func checkAvailability(locale: Locale = Locale(identifier: "en-US")) async -> SpeechModelAvailability {
        if #available(macOS 26, *) {
            return await SpeechAnalyzerTranscriber.checkAvailability(locale: locale)
        } else {
            return LegacySpeechTranscriber.checkAvailability(locale: locale)
        }
    }
}

/// Pure segment-stitching helper shared by every transcriber
/// implementation and by `TranscriptUpdate.displayText` — kept as a free
/// function so `TranscriptStitchingTests` can validate join behavior
/// (including the "no dropped join-space or duplicated words" scenario)
/// without needing a recognizer at all.
public enum TranscriptStitcher {
    /// Joins committed and live text with a single space, per §4.1b,
    /// trimming so an empty side never introduces a stray leading/trailing
    /// space.
    public static func join(_ committed: String, _ live: String) -> String {
        switch (committed.isEmpty, live.isEmpty) {
        case (true, true): return ""
        case (true, false): return live
        case (false, true): return committed
        case (false, false): return committed + " " + live
        }
    }
}
