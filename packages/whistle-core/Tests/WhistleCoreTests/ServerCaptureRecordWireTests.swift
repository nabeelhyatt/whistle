// ServerCaptureRecordWireTests.swift
// Regression coverage for the stuck-Queued root cause: every real Convex
// `captures` document keys its id as `_id` (not `id`) and carries
// ms-since-epoch float64 timestamps (optionally boxed as
// `{"$float": "<base64>"}`), while `ServerCaptureRecord`'s synthesized
// `Codable` expects `id` and iso8601-string dates. Decoding a raw document
// straight into `ServerCaptureRecord` threw `keyNotFound` on every payload,
// killing the `captures:listRecent` subscription and leaving `history_cache`
// permanently empty. `ServerCaptureRecordWire` decodes the raw shape and
// maps into the public model; these tests exercise that decode/map directly
// against inline JSON literals (no bundled fixtures — Package.swift has no
// `resources:` entry for this target).

import XCTest

@testable import WhistleCore

#if canImport(ConvexMobile)
    final class ServerCaptureRecordWireTests: XCTestCase {
        private func decodeWireArray(_ json: String) throws -> [ServerCaptureRecordWire] {
            try JSONDecoder().decode([ServerCaptureRecordWire].self, from: Data(json.utf8))
        }

        private func decodeWire(_ json: String) throws -> ServerCaptureRecordWire {
            try JSONDecoder().decode(ServerCaptureRecordWire.self, from: Data(json.utf8))
        }

        // MARK: 1. Full realistic document, as `captures:listRecent` yields it

        func testDecodesFullRealisticDocument() throws {
            let json = """
            [
              {
                "_id": "jd7abc123",
                "_creationTime": 1752868357123.4,
                "userId": "user_1",
                "clientId": "client-uuid-1",
                "transcript": "hello world",
                "notes": "some notes",
                "screenshotId": "storage_1",
                "projectId": "proj_1",
                "projectName": "Whistle",
                "agent": "claude",
                "model": "opus-4.8",
                "capturedAt": 1752868357000.0,
                "status": "ready",
                "error": null,
                "attempt": 1,
                "workspaceId": "ws_1",
                "workspaceName": "cambridge-v1",
                "sessionId": "sess_1",
                "deepLink": "conductor://open/1",
                "messageSentAt": 1752868358000.0,
                "clarifyingQuestions": ["Q1?"],
                "agentSummary": "Did the thing.",
                "openedAt": 1752868359000.0,
                "archivedAt": 1752868360000.0
              }
            ]
            """

            let wire = try decodeWireArray(json)
            XCTAssertEqual(wire.count, 1)
            let record = wire[0].asRecord

            XCTAssertEqual(record.id, "jd7abc123")
            XCTAssertEqual(record.userId, "user_1")
            XCTAssertEqual(record.clientId, "client-uuid-1")
            XCTAssertEqual(record.transcript, "hello world")
            XCTAssertEqual(record.notes, "some notes")
            XCTAssertEqual(record.screenshotId, "storage_1")
            XCTAssertEqual(record.projectId, "proj_1")
            XCTAssertEqual(record.projectName, "Whistle")
            XCTAssertEqual(record.agent, "claude")
            XCTAssertEqual(record.model, "opus-4.8")
            XCTAssertEqual(
                record.capturedAt.timeIntervalSince1970, 1_752_868_357.0, accuracy: 0.001
            )
            XCTAssertEqual(record.status, .ready)
            XCTAssertNil(record.errorCode)
            XCTAssertNil(record.error)
            XCTAssertEqual(record.attempt, 1)
            XCTAssertEqual(record.workspaceId, "ws_1")
            XCTAssertEqual(record.workspaceName, "cambridge-v1")
            XCTAssertEqual(record.sessionId, "sess_1")
            XCTAssertEqual(record.deepLink, "conductor://open/1")
            XCTAssertEqual(
                try XCTUnwrap(record.messageSentAt).timeIntervalSince1970, 1_752_868_358.0, accuracy: 0.001
            )
            XCTAssertEqual(record.clarifyingQuestions, ["Q1?"])
            XCTAssertEqual(record.agentSummary, "Did the thing.")
            XCTAssertEqual(
                try XCTUnwrap(record.openedAt).timeIntervalSince1970, 1_752_868_359.0, accuracy: 0.001
            )
            XCTAssertEqual(
                try XCTUnwrap(record.archivedAt).timeIntervalSince1970, 1_752_868_360.0, accuracy: 0.001
            )
        }

        // MARK: 2. Minimal queued document — required fields only

        func testDecodesMinimalQueuedDocumentWithAbsentOptionals() throws {
            let json = """
            {
              "_id": "jd7min",
              "_creationTime": 1752868357123.4,
              "userId": "user_1",
              "clientId": "client-uuid-2",
              "transcript": "t",
              "notes": "n",
              "projectId": "proj_1",
              "projectName": "Whistle",
              "agent": "claude",
              "capturedAt": 1752868357000.0,
              "status": "queued",
              "attempt": 0
            }
            """

            let record = try decodeWire(json).asRecord

            XCTAssertEqual(record.id, "jd7min")
            XCTAssertEqual(record.status, .queued)
            XCTAssertEqual(record.attempt, 0)
            XCTAssertNil(record.screenshotId)
            XCTAssertNil(record.model)
            XCTAssertNil(record.errorCode)
            XCTAssertNil(record.error)
            XCTAssertNil(record.workspaceId)
            XCTAssertNil(record.workspaceName)
            XCTAssertNil(record.sessionId)
            XCTAssertNil(record.deepLink)
            XCTAssertNil(record.messageSentAt)
            XCTAssertNil(record.clarifyingQuestions)
            XCTAssertNil(record.agentSummary)
            XCTAssertNil(record.openedAt)
            XCTAssertNil(record.archivedAt)
        }

        // MARK: 2b. `failed` status with a non-nil `errorCode` — regression
        // coverage for the exact stream-killing class this PR's decode fix
        // addresses: the full-document test above only ever asserts
        // `XCTAssertNil(record.errorCode)`, so a broken `errorCode` decode
        // (e.g. a raw-value mismatch) had no test that would catch it.

        func testDecodesFailedStatusWithNetworkErrorCode() throws {
            let json = """
            {
              "_id": "jd7failed",
              "_creationTime": 1752868357123.4,
              "userId": "user_1",
              "clientId": "client-uuid-failed",
              "transcript": "t",
              "notes": "n",
              "projectId": "proj_1",
              "projectName": "Whistle",
              "agent": "claude",
              "capturedAt": 1752868357000.0,
              "status": "failed",
              "errorCode": "network",
              "error": "connection reset",
              "attempt": 2
            }
            """

            let record = try decodeWire(json).asRecord

            XCTAssertEqual(record.status, .failed)
            XCTAssertEqual(record.errorCode, .network)
            XCTAssertEqual(record.error, "connection reset")
        }

        // MARK: 2c. Schema-drift tolerance — an unrecognized `status`/
        // `errorCode` string (e.g. a future backend deploy shipping a new
        // enum case before the client does) must degrade that ONE row's
        // chip, not throw and kill the whole `captures:listRecent`
        // publisher (the exact "one bad payload freezes History" shape of
        // the original stuck-Queued bug, now reachable again via a closed
        // enum rather than the `_id` mismatch).

        func testUnknownStatusStringFallsBackToQueuedInsteadOfThrowing() throws {
            let json = """
            {
              "_id": "jd7unknownstatus",
              "_creationTime": 1752868357123.4,
              "userId": "user_1",
              "clientId": "client-uuid-unknown-status",
              "transcript": "t",
              "notes": "n",
              "projectId": "proj_1",
              "projectName": "Whistle",
              "agent": "claude",
              "capturedAt": 1752868357000.0,
              "status": "some-future-status-value",
              "attempt": 0
            }
            """

            let record = try decodeWire(json).asRecord
            XCTAssertEqual(record.status, .queued, "an unrecognized status string must fall back to a display-neutral default, not throw")
        }

        func testUnknownErrorCodeStringFallsBackToUnknown() throws {
            let json = """
            {
              "_id": "jd7unknownerror",
              "_creationTime": 1752868357123.4,
              "userId": "user_1",
              "clientId": "client-uuid-unknown-error",
              "transcript": "t",
              "notes": "n",
              "projectId": "proj_1",
              "projectName": "Whistle",
              "agent": "claude",
              "capturedAt": 1752868357000.0,
              "status": "failed",
              "errorCode": "some-future-error-code",
              "attempt": 0
            }
            """

            let record = try decodeWire(json).asRecord
            XCTAssertEqual(record.errorCode, .unknown, "an unrecognized errorCode string must fall back to .unknown, not throw")
        }

        func testWholeBatchSurvivesOneRecordWithAnUnrecognizedStatus() throws {
            let json = """
            [
              {
                "_id": "jd7good",
                "_creationTime": 1752868357123.4,
                "userId": "user_1",
                "clientId": "client-uuid-good",
                "transcript": "t",
                "notes": "n",
                "projectId": "proj_1",
                "projectName": "Whistle",
                "agent": "claude",
                "capturedAt": 1752868357000.0,
                "status": "ready",
                "attempt": 0
              },
              {
                "_id": "jd7drift",
                "_creationTime": 1752868357123.4,
                "userId": "user_1",
                "clientId": "client-uuid-drift",
                "transcript": "t",
                "notes": "n",
                "projectId": "proj_1",
                "projectName": "Whistle",
                "agent": "claude",
                "capturedAt": 1752868357000.0,
                "status": "some-brand-new-status",
                "attempt": 0
              }
            ]
            """

            let wire = try decodeWireArray(json)
            XCTAssertEqual(wire.count, 2, "the whole batch must decode even though one record has an unrecognized status")
            XCTAssertEqual(wire[0].asRecord.status, .ready)
            XCTAssertEqual(wire[1].asRecord.status, .queued)
        }

        // MARK: 3. `$float`-boxed encoding (Convex's wire format for a float64
        // that needs disambiguating from a bigint)

        func testDecodesDollarFloatBoxedCapturedAt() throws {
            let millis = 1_752_868_357_000.0
            let base64 = withUnsafeBytes(of: millis) { Data($0) }.base64EncodedString()
            let json = """
            {
              "_id": "jd7float",
              "_creationTime": 1752868357123.4,
              "userId": "user_1",
              "clientId": "client-uuid-3",
              "transcript": "t",
              "notes": "n",
              "projectId": "proj_1",
              "projectName": "Whistle",
              "agent": "claude",
              "capturedAt": {"$float": "\(base64)"},
              "status": "queued",
              "attempt": 0
            }
            """

            let record = try decodeWire(json).asRecord
            XCTAssertEqual(record.capturedAt.timeIntervalSince1970, millis / 1000, accuracy: 0.001)
        }

        // MARK: 3b. `$float`-boxed encoding on an OPTIONAL date field.
        // `@ConvexFloat` (non-optional, `capturedAt`) and `@OptionalConvexFloat`
        // (optional, `messageSentAt`/`openedAt`/`archivedAt`) have separately
        // written `init(from:)` implementations — the boxed-`$float` branch
        // above only exercises the non-optional property wrapper, so
        // `@OptionalConvexFloat`'s own boxed-value branch has no direct
        // coverage without this test.

        func testDecodesDollarFloatBoxedMessageSentAt() throws {
            let millis = 1_752_868_358_000.0
            let base64 = withUnsafeBytes(of: millis) { Data($0) }.base64EncodedString()
            let json = """
            {
              "_id": "jd7floatoptional",
              "_creationTime": 1752868357123.4,
              "userId": "user_1",
              "clientId": "client-uuid-4",
              "transcript": "t",
              "notes": "n",
              "projectId": "proj_1",
              "projectName": "Whistle",
              "agent": "claude",
              "capturedAt": 1752868357000.0,
              "status": "queued",
              "attempt": 0,
              "messageSentAt": {"$float": "\(base64)"}
            }
            """

            let record = try decodeWire(json).asRecord
            XCTAssertEqual(
                try XCTUnwrap(record.messageSentAt).timeIntervalSince1970, millis / 1000, accuracy: 0.001,
                "@OptionalConvexFloat's boxed-$float branch must decode independently of @ConvexFloat's"
            )
        }

        // MARK: 4. Cache round-trip regression — guards CaptureStore's contract

        func testServerCaptureRecordCacheRoundTripStillWorks() throws {
            let original = ServerCaptureRecord(
                id: "jd7abc123",
                userId: "user_1",
                clientId: "client-uuid-1",
                transcript: "hello world",
                notes: "some notes",
                screenshotId: "storage_1",
                projectId: "proj_1",
                projectName: "Whistle",
                agent: "claude",
                model: "opus-4.8",
                capturedAt: Date(timeIntervalSince1970: 1_752_868_357),
                status: .ready,
                errorCode: nil,
                error: nil,
                attempt: 1,
                workspaceId: "ws_1",
                workspaceName: "cambridge-v1",
                sessionId: "sess_1",
                deepLink: "conductor://open/1",
                messageSentAt: Date(timeIntervalSince1970: 1_752_868_358),
                clarifyingQuestions: ["Q1?"],
                agentSummary: "Did the thing.",
                openedAt: Date(timeIntervalSince1970: 1_752_868_359),
                archivedAt: Date(timeIntervalSince1970: 1_752_868_360)
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ServerCaptureRecord.self, from: data)

            XCTAssertEqual(decoded, original)
        }
    }
#endif
