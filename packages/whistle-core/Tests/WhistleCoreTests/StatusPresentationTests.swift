// StatusPresentationTests.swift
// Every row of the TECH-SPEC §4.4 status-presentation mapping table,
// parameterized, plus the openedAt de-emphasis flag.

import Foundation
import XCTest
@testable import WhistleCore

final class StatusPresentationTests: XCTestCase {
    private struct Row {
        let name: String
        let localState: LocalCaptureState
        let isOnline: Bool
        let serverStatus: CaptureServerStatus?
        let errorCode: CaptureErrorCode?
        let expectedChip: String
        let expectedAffordance: CaptureAffordance
    }

    // The §4.4 table, verbatim:
    // | Local state | Server status | Chip | Affordance |
    private static let rows: [Row] = [
        Row(
            name: "queued (offline)",
            localState: .queued, isOnline: false, serverStatus: nil, errorCode: nil,
            expectedChip: "Waiting for network", expectedAffordance: .automatic
        ),
        Row(
            name: "queued/syncing (online)",
            localState: .queued, isOnline: true, serverStatus: nil, errorCode: nil,
            expectedChip: "Queued", expectedAffordance: .none
        ),
        Row(
            name: "syncing (online)",
            localState: .syncing, isOnline: true, serverStatus: nil, errorCode: nil,
            expectedChip: "Queued", expectedAffordance: .none
        ),
        Row(
            name: "syncFailed",
            localState: .syncFailed, isOnline: true, serverStatus: nil, errorCode: nil,
            expectedChip: "Sync failed", expectedAffordance: .localRetry
        ),
        Row(
            name: "synced + server queued",
            localState: .synced, isOnline: true, serverStatus: .queued, errorCode: nil,
            expectedChip: "Queued", expectedAffordance: .none
        ),
        Row(
            name: "synced + server creating",
            localState: .synced, isOnline: true, serverStatus: .creating, errorCode: nil,
            expectedChip: "Creating workspace", expectedAffordance: .none
        ),
        Row(
            name: "synced + server sending",
            localState: .synced, isOnline: true, serverStatus: .sending, errorCode: nil,
            expectedChip: "Creating workspace", expectedAffordance: .none
        ),
        Row(
            name: "synced + server agentWorking",
            localState: .synced, isOnline: true, serverStatus: .agentWorking, errorCode: nil,
            expectedChip: "Agent working", expectedAffordance: .openDeepLink
        ),
        Row(
            name: "synced + server ready",
            localState: .synced, isOnline: true, serverStatus: .ready, errorCode: nil,
            expectedChip: "Ready", expectedAffordance: .openDeepLink
        ),
        Row(
            name: "synced + server readyUnverified",
            localState: .synced, isOnline: true, serverStatus: .readyUnverified, errorCode: nil,
            expectedChip: "Sent — agent status unknown", expectedAffordance: .openDeepLink
        ),
        Row(
            name: "synced + server failed auth",
            localState: .synced, isOnline: true, serverStatus: .failed, errorCode: .auth,
            expectedChip: "Auth error", expectedAffordance: .openSettingsApiKey
        ),
        Row(
            name: "synced + server failed other",
            localState: .synced, isOnline: true, serverStatus: .failed, errorCode: .network,
            expectedChip: "Failed: something broke", expectedAffordance: .serverRetry
        ),
    ]

    func testEveryStatusMappingTableRow() {
        for row in Self.rows {
            let serverRecord: ServerCaptureRecord? = row.serverStatus.map {
                TestSupport.makeServerRecord(
                    status: $0,
                    errorCode: row.errorCode,
                    error: row.errorCode == .network ? "something broke" : nil
                )
            }

            let result = StatusPresentation.present(
                localState: row.localState,
                serverRecord: serverRecord,
                isOnline: row.isOnline
            )

            XCTAssertEqual(result.chip, row.expectedChip, "chip mismatch for row: \(row.name)")
            XCTAssertEqual(result.affordance, row.expectedAffordance, "affordance mismatch for row: \(row.name)")
        }
    }

    // MARK: - Ready with question count

    func testReadyChipIncludesQuestionCount() {
        let record = TestSupport.makeServerRecord(status: .ready, clarifyingQuestions: ["Q1?", "Q2?", "Q3?"])
        let result = StatusPresentation.present(localState: .synced, serverRecord: record)
        XCTAssertEqual(result.chip, "Ready (+3 questions)")
        XCTAssertEqual(result.affordance, .openDeepLink)
    }

    func testReadyChipWithNoQuestionsOmitsCount() {
        let record = TestSupport.makeServerRecord(status: .ready, clarifyingQuestions: [])
        let result = StatusPresentation.present(localState: .synced, serverRecord: record)
        XCTAssertEqual(result.chip, "Ready")
    }

    // MARK: - openedAt de-emphasis flag

    func testOpenedAtSetsDeemphasizedFlag() {
        let opened = TestSupport.makeServerRecord(status: .ready, openedAt: Date())
        let notOpened = TestSupport.makeServerRecord(status: .ready, openedAt: nil)

        XCTAssertTrue(StatusPresentation.present(localState: .synced, serverRecord: opened).isDeemphasized)
        XCTAssertFalse(StatusPresentation.present(localState: .synced, serverRecord: notOpened).isDeemphasized)
    }

    func testPreSyncRowsAreNeverDeemphasized() {
        let result = StatusPresentation.present(localState: .queued, serverRecord: nil, isOnline: true)
        XCTAssertFalse(result.isDeemphasized)
    }

    // MARK: - Once a server record exists, it is the source of truth

    func testServerRecordOverridesLocalStateOnceItExists() {
        // Even if local state still says `.queued` (subscription raced
        // ahead of the local queue's own bookkeeping), the server record
        // wins per the §4.4 preamble.
        let record = TestSupport.makeServerRecord(status: .agentWorking)
        let result = StatusPresentation.present(localState: .queued, serverRecord: record)
        XCTAssertEqual(result.chip, "Agent working")
    }
}
