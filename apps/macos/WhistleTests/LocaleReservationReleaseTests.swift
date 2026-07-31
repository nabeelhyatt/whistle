// LocaleReservationReleaseTests.swift
// Covers `LocaleReservationRelease`, the pure BCP-47 matching logic
// extracted from `LiveSpeechAnalyzerEngine.releaseReservedLocale()`
// (SpeechAnalyzerTranscriber.swift). No `AssetInventory` (macOS 26-only)
// involved -- pure `Locale` comparisons only.

import XCTest
@testable import Whistle

final class LocaleReservationReleaseTests: XCTestCase {
    func testReleasesTheExactReservedMemberNotTheRequestedLocale() {
        let requested = Locale(identifier: "en-US")
        let reservedMember = Locale(identifier: "en_US")
        let reserved = [reservedMember]

        let result = LocaleReservationRelease.localesToRelease(requested: requested, reserved: reserved)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.identifier, "en_US")
    }

    func testNonMatchingReservedLocalesAreNotReleased() {
        let requested = Locale(identifier: "en-US")
        let reserved = [Locale(identifier: "fr-FR")]

        let result = LocaleReservationRelease.localesToRelease(requested: requested, reserved: reserved)

        XCTAssertTrue(result.isEmpty)
    }

    /// Pins the current release-all-matches behavior -- a known P1
    /// limitation (docs/BACKLOG.md: "Release the exact locale reservation
    /// variant returned by Speech"): if multiple reserved members share the
    /// requested locale's BCP-47 identifier, ALL of them are released, even
    /// though only one may be owned by this session. Deliberately not
    /// fixed here -- each concurrency/ownership change to this engine gets
    /// its own manually-verified state.
    func testAllBcp47MatchingMembersAreReleased() {
        let requested = Locale(identifier: "en-US")
        let reserved = [Locale(identifier: "en_US"), Locale(identifier: "en-US")]

        let result = LocaleReservationRelease.localesToRelease(requested: requested, reserved: reserved)

        XCTAssertEqual(result.count, 2)
    }
}
