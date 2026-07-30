// LocaleReservationRelease.swift
// Pure locale-matching logic extracted from
// `LiveSpeechAnalyzerEngine.releaseReservedLocale()`
// (SpeechAnalyzerTranscriber.swift), so it can be unit-tested without
// `AssetInventory` (macOS 26-only).

import Foundation

enum LocaleReservationRelease {
    /// Pins current behavior: release exact members of `reserved` whose
    /// BCP-47 identifier equals the requested locale's. (Known P1
    /// limitation, docs/BACKLOG.md: variants whose BCP-47 differs leak, and
    /// all matching members are released even if another session owns one.)
    static func localesToRelease(requested: Locale, reserved: [Locale]) -> [Locale] {
        let wanted = requested.identifier(.bcp47)
        return reserved.filter { $0.identifier(.bcp47) == wanted }
    }
}
