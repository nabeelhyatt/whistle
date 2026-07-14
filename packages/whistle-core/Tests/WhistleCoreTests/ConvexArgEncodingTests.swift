// ConvexArgEncodingTests.swift
// Regression coverage for the nil-key encoding fix (the real production bug
// this PR closes): the backend validators for `captures:create` and
// `settings:update` are `v.optional(...)`, which tolerates a key being ABSENT
// but rejects an explicit JSON `null`. convex-swift's dictionary encoder emits
// a nil-valued entry as literal `null`, so before the fix every capture with
// no model/screenshot -- and every partial settings patch -- failed to sync
// with an `ArgumentValidationError`.
//
// The fix builds the arg dicts by including only non-nil optional fields.
// `LiveConvexService` itself can't be driven hermetically (convex-swift's
// ffi-client seam is internal to the package, same constraint noted in
// ConvexTimeoutTests / ConvexOneShotQueryTests), so the encoding was extracted
// into the pure, instance-state-free `capturesCreateArgs`/`settingsUpdateArgs`
// statics, which these tests exercise directly. A future refactor that
// reintroduces the null-vs-omit bug now has a test to catch it.

import XCTest

@testable import WhistleCore

#if canImport(ConvexMobile)
    final class ConvexArgEncodingTests: XCTestCase {
        // MARK: captures:create

        func testCapturesCreateOmitsNilOptionalFields() {
            let input = CaptureCreateInput(
                clientId: "c1",
                transcript: "t",
                notes: "n",
                screenshotStorageId: nil,
                projectId: "p",
                projectName: "pn",
                agent: "claude",
                model: nil,
                capturedAt: Date(timeIntervalSince1970: 0)
            )

            let args = LiveConvexService.capturesCreateArgs(input)

            XCTAssertFalse(
                args.keys.contains("screenshotId"),
                "a nil screenshotId must be omitted, not sent as JSON null"
            )
            XCTAssertFalse(
                args.keys.contains("model"),
                "a nil model must be omitted, not sent as JSON null"
            )
            // Required fields are always present.
            for key in ["clientId", "transcript", "notes", "projectId", "projectName", "agent", "capturedAt"] {
                XCTAssertTrue(args.keys.contains(key), "expected required field '\(key)' to be present")
            }
        }

        func testCapturesCreateIncludesOptionalFieldsWhenSet() {
            let input = CaptureCreateInput(
                clientId: "c2",
                transcript: "t",
                notes: "n",
                screenshotStorageId: "storage-123",
                projectId: "p",
                projectName: "pn",
                agent: "claude",
                model: "opus-4.8",
                capturedAt: Date(timeIntervalSince1970: 0)
            )

            let args = LiveConvexService.capturesCreateArgs(input)

            XCTAssertTrue(args.keys.contains("screenshotId"), "a set screenshotId must be included")
            XCTAssertTrue(args.keys.contains("model"), "a set model must be included")
        }

        // MARK: settings:update

        func testSettingsUpdateAllNilPatchSendsNoKeys() {
            let args = LiveConvexService.settingsUpdateArgs(SettingsPatch())
            XCTAssertTrue(
                args.isEmpty,
                "an all-nil patch must send zero keys (every field is v.optional and rejects null), got: \(args.keys)"
            )
        }

        func testSettingsUpdatePartialPatchSendsOnlySetFields() {
            let args = LiveConvexService.settingsUpdateArgs(SettingsPatch(agent: "codex"))
            XCTAssertEqual(
                Set(args.keys), ["agent"],
                "a single-field patch must send exactly that field, got: \(args.keys)"
            )
        }

        func testSettingsUpdateBoolFieldOmittedWhenNilIncludedWhenSet() {
            XCTAssertFalse(
                LiveConvexService.settingsUpdateArgs(SettingsPatch()).keys.contains("screenshotsEnabled"),
                "a nil screenshotsEnabled must be omitted"
            )
            XCTAssertTrue(
                LiveConvexService.settingsUpdateArgs(SettingsPatch(screenshotsEnabled: false)).keys.contains("screenshotsEnabled"),
                "screenshotsEnabled: false is a real value and must be included, not confused with unset"
            )
        }
    }
#endif
