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
// The fix wraps the mutation/action calls in `LiveConvexService.withTimeout`,
// which runs the operation in an unstructured `Task` and races it against a
// timer via a single-resume continuation -- so it returns the instant the
// timeout fires even if the operation never finishes AND never checks
// cancellation. `LiveConvexService` itself can't be driven hermetically
// (convex-swift's ffi-client seam is internal to the package, same constraint
// noted in ConvexAuthAttachmentTests / ConvexOneShotQueryTests), but
// `withTimeout` takes a plain `@Sendable` async closure and has no instance
// state, so it's fully testable in isolation.
//
// Crucially, `testReturnsPromptlyWhenOperationIgnoresCancellation` below
// reproduces the exact motivating scenario -- an operation that neither
// completes nor honors cancellation (via a continuation that never resumes),
// modeling the non-cancellation-aware convex-swift FFI call. The previous
// `withThrowingTaskGroup` implementation would hang there forever (a task
// group cannot return until every child finishes, per SE-0304); the current
// implementation returns at the timeout. That regression is now guarded.

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

        func testReturnsPromptlyWhenOperationIgnoresCancellation() async {
            // The heart of the fix: an operation that never completes and
            // never checks `Task.isCancelled` -- exactly how convex-swift's
            // `uniffiRustCallAsync` polling loop behaves on a hung/dropped
            // connection. `withCheckedContinuation { _ in }` never resumes and
            // has no cancellation handler, so cancelling its task does nothing.
            // The old task-group version would block here forever (wedging
            // `SyncEngine.isDraining`); this must still return at the timeout.
            let start = Date()
            do {
                _ = try await LiveConvexService.withTimeout(.milliseconds(50)) {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return "unreachable"
                }
                XCTFail("must throw a timeout even when the operation ignores cancellation")
            } catch {
                XCTAssertEqual(error as? ConvexServiceError, .requestFailed("operation timed out"))
            }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(
                elapsed, 2.0,
                "withTimeout must return at the timeout, not wait for the hung operation (elapsed: \(elapsed)s)"
            )
        }

        func testUsesTheProvidedTimeoutMessage() async {
            do {
                _ = try await LiveConvexService.withTimeout(.milliseconds(20), timeoutMessage: "custom message") {
                    try await Task.sleep(for: .seconds(60))
                    return "unreachable"
                }
                XCTFail("must throw")
            } catch {
                XCTAssertEqual(error as? ConvexServiceError, .requestFailed("custom message"))
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
