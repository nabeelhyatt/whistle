// ConvexTimeoutTests.swift
// Regression coverage for the hung-mutation bug: `authedMutation`/
// `authedAction` (LiveConvexService, ConvexService.swift) previously awaited
// `client.mutation(...)`/`client.action(...)` with NO timeout at all, while
// the one-shot query path (`firstValue`) already raced its call against a
// timeout. If a mutation call ever hung instead of failing (a dropped
// connection with no error, a network-transition edge case), the caller
// suspended forever with no way to recover — and this also permanently
// wedged `SyncEngine`'s `isDraining` reentrancy guard, silently disabling
// all future capture syncing for the rest of that process's life (observed
// live: captures sat unsynced for 20+ hours until an app relaunch).
//
// The fix extracts `LiveConvexService.withTimeout`, the same
// task-group race-two-tasks shape `firstValue` already used, and wraps the
// mutation/action calls with it. `LiveConvexService` itself can't be
// driven hermetically (convex-swift's ffi-client seam is internal to the
// package, same constraint noted in ConvexAuthAttachmentTests /
// ConvexOneShotQueryTests), but `withTimeout` takes a plain `@Sendable`
// async closure and has no instance state, so it's fully testable in
// isolation.
//
// Important scope note (see `withTimeout`'s doc comment): this bounds the
// common "slow but eventually answers" case. For a genuinely-stuck
// convex-swift FFI call that never checks Swift task cancellation, the
// timeout task still fires and this function still returns promptly to
// ITS caller -- but the underlying `withThrowingTaskGroup` scope in
// `authedMutation`/`authedAction` cannot fully exit until that FFI call
// eventually settles, per Swift's structured-concurrency guarantee that a
// task group awaits all children before returning. These tests use a
// synthetic `operation` (a `Task.sleep`), which IS cancellation-aware, so
// they verify `withTimeout`'s own race/return logic correctly, but they
// cannot exercise -- and therefore cannot regress-guard -- the
// non-cancellation-aware-FFI-call scenario that motivated this fix.

import XCTest

@testable import WhistleCore

#if canImport(ConvexMobile)
    final class ConvexTimeoutTests: XCTestCase {
        func testTimesOutWhenOperationNeverCompletes() async {
            do {
                _ = try await LiveConvexService.withTimeout(.milliseconds(30)) {
                    // Never resolves within the test's lifetime — simulates
                    // a hung `client.mutation(...)` call.
                    try await Task.sleep(for: .seconds(60))
                    return "unreachable"
                }
                XCTFail("must throw when the operation never completes before the timeout")
            } catch {
                XCTAssertEqual(error as? ConvexServiceError, .requestFailed("operation timed out"))
            }
        }

        func testReturnsRealValueWhenOperationResolvesQuickly() async throws {
            let value = try await LiveConvexService.withTimeout(.seconds(5)) {
                "real-result"
            }
            XCTAssertEqual(value, "real-result", "a fast operation must be unaffected by the timeout wrapper")
        }

        func testSurfacesTheOperationsOwnErrorRatherThanATimeout() async {
            struct SomeOtherError: Error, Equatable {}

            do {
                _ = try await LiveConvexService.withTimeout(.seconds(5)) {
                    throw SomeOtherError()
                }
                XCTFail("must surface the operation's own error")
            } catch {
                XCTAssertEqual(
                    error as? SomeOtherError, SomeOtherError(),
                    "a non-timeout failure must surface as itself, not as a timeout error"
                )
            }
        }
    }
#endif
