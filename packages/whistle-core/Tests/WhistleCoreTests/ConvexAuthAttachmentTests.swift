// ConvexAuthAttachmentTests.swift
// Regression coverage for the post-sign-in Convex handshake bug: convex-swift's
// `ConvexClientWithAuth` only attaches the JWT to the websocket inside its own
// `login()`/`loginFromCache()`, which `LiveConvexService` previously never
// called — every backend call ran unauthenticated and `users:ensure` failed
// with NotAuthenticatedError ("Sign-in didn't complete" in the UI).
//
// `LiveConvexService` itself can't be driven hermetically (convex-swift's
// ffi-client seam is internal to the package), so these tests pin the two
// pieces that make the fix correct:
//   1. `ConvexAuthAttachmentGate` — attach exactly once on success,
//      re-attempt after failure, report unattached until a success.
//   2. `WhistleToConvexAuthProviderBridge` — carries the REAL token through
//      convex-swift's `AuthProvider<String>` shape (`extractIdToken` must
//      return the JWT, not the previous `""`), and fails loudly when no
//      token is available.

import XCTest

@testable import WhistleCore

#if canImport(ConvexMobile)
    import ConvexMobile
#endif

// MARK: - ConvexAuthAttachmentGate

final class ConvexAuthAttachmentGateTests: XCTestCase {
    func testAttachRunsExactlyOnceAcrossRepeatedCallsAfterSuccess() async {
        let gate = ConvexAuthAttachmentGate()
        let attempts = Counter()

        for _ in 0..<3 {
            let attached = await gate.runIfNeeded {
                attempts.increment()
                return true
            }
            XCTAssertTrue(attached)
        }

        XCTAssertEqual(attempts.value, 1, "a successful attach must not be repeated")
    }

    func testFailedAttachIsReattemptedOnNextCall() async {
        let gate = ConvexAuthAttachmentGate()
        let attempts = Counter()

        let first = await gate.runIfNeeded {
            attempts.increment()
            return false
        }
        XCTAssertFalse(first, "a failed attach must report unattached")

        let second = await gate.runIfNeeded {
            attempts.increment()
            return true
        }
        XCTAssertTrue(second, "the next call after a failure must re-attempt and succeed")
        XCTAssertEqual(attempts.value, 2)

        // And after the success, no further attempts.
        let third = await gate.runIfNeeded {
            attempts.increment()
            return true
        }
        XCTAssertTrue(third)
        XCTAssertEqual(attempts.value, 2)
    }

    // Regression coverage for the sign-out fix: a stale `attached == true`
    // left over from a previous session used to make `runIfNeeded` skip
    // re-attaching entirely, so a fresh sign-in (same user or a different
    // one) could run mutations under the OLD session's already-pinned JWT.
    func testResetForcesTheNextRunIfNeededToReattemptAttach() async {
        let gate = ConvexAuthAttachmentGate()
        let attempts = Counter()

        let first = await gate.runIfNeeded {
            attempts.increment()
            return true
        }
        XCTAssertTrue(first)
        XCTAssertEqual(attempts.value, 1)

        gate.reset()

        let second = await gate.runIfNeeded {
            attempts.increment()
            return true
        }
        XCTAssertTrue(second, "a re-attempt after reset() must actually re-run attach, not just report the old state")
        XCTAssertEqual(attempts.value, 2, "reset() must force the next call to re-attempt attach instead of short-circuiting on stale state")
    }

    // MARK: - Epoch compare-and-set (KTD4/R3, the reconnect plan)
    //
    // Regression coverage for the silent-re-wedge bug the epoch guards
    // against: without it, an `ensureAuthAttached()` call that started its
    // `attach()` against the OLD (pre-rebuild) client could complete AFTER
    // `rebuildClient()` swapped in a new one and latch `attached = true` —
    // the NEW client would then never get a chance to attach, and every
    // future call would fail `NotAuthenticatedError` forever. `reset()` now
    // bumps an internal epoch; `runIfNeeded` only latches a success if the
    // epoch is unchanged when `attach()` returns.

    func testResetDuringAnInFlightAttachDiscardsALateSuccessAndForcesReattach() async {
        let gate = ConvexAuthAttachmentGate()
        let attempts = Counter()
        let releaseGate = ReleaseGate()

        // Start an attach and hold it mid-flight (as if `loginFromCache()`
        // were still in progress against the OLD client) until the test
        // explicitly releases it.
        let attachTask = Task {
            await gate.runIfNeeded {
                attempts.increment()
                await releaseGate.wait()
                return true
            }
        }

        // Give the task a moment to pass the `attached` fast-path check and
        // actually enter `attach()`.
        try? await Task.sleep(for: .milliseconds(20))
        // Simulates `rebuildClient()` calling `authGate.reset()` mid-flight.
        gate.reset()
        releaseGate.release()

        let firstResult = await attachTask.value
        XCTAssertFalse(
            firstResult,
            "an attach whose epoch moved mid-flight must be discarded (report unattached), even though its own attach() returned true"
        )

        // The next call must actually re-run attach() against the fresh
        // epoch/client, not short-circuit on a stale `attached == true` the
        // discarded attempt might otherwise have left behind.
        let second = await gate.runIfNeeded {
            attempts.increment()
            return true
        }
        XCTAssertTrue(second, "the call after the epoch-discarded attach must re-attach and succeed")
        XCTAssertEqual(attempts.value, 2, "the discarded attach must not block or skip the next real attempt")
    }

    func testAttachCompletingBeforeAnyResetLatchesNormally() async {
        // Sanity check that the epoch machinery doesn't interfere with the
        // ordinary (no-rebuild) path already covered above.
        let gate = ConvexAuthAttachmentGate()
        let attempts = Counter()

        let first = await gate.runIfNeeded {
            attempts.increment()
            return true
        }
        XCTAssertTrue(first)

        let second = await gate.runIfNeeded {
            attempts.increment()
            return true
        }
        XCTAssertTrue(second)
        XCTAssertEqual(attempts.value, 1, "no reset happened, so the second call must short-circuit on the latched attach")
    }

    // Regression coverage for the reauth-wedge bug: `LiveConvexService.detachAuth()`
    // previously awaited `client.logout()` with no timeout -- the only Convex
    // call in the file not wrapped in `withTimeout` -- while the reauth path
    // (`AuthController.signIn()`) awaits `detachAuth()` with `state ==
    // .signingIn` and re-entry guarded, so a wedged/non-cancellation-aware FFI
    // logout would permanently strand sign-in until an app relaunch.
    //
    // `LiveConvexService` itself can't be driven hermetically (its
    // `ConvexClientWithAuth` seam is internal to the package, same constraint
    // noted atop this file / in ConvexOneShotQueryTests / ConvexTimeoutTests),
    // so this reproduces `detachAuth()`'s exact fixed shape -- a hung logout
    // bounded by `withTimeout`, with the gate ALWAYS reset afterward
    // regardless of the timeout outcome -- against the same testable, instance-
    // state-free primitives (`LiveConvexService.withTimeout`,
    // `ConvexAuthAttachmentGate`) `detachAuth()` is built from.
    #if canImport(ConvexMobile)
        func testDetachAuthPatternReturnsPromptlyOnAHungLogoutAndAlwaysResetsTheGate() async {
            let gate = ConvexAuthAttachmentGate()
            let attempts = Counter()

            // Prime the gate as if a previous session had already attached.
            let primed = await gate.runIfNeeded {
                attempts.increment()
                return true
            }
            XCTAssertTrue(primed)
            XCTAssertEqual(attempts.value, 1)

            let start = Date()
            // Mirrors `detachAuth()`: bound a logout call that neither
            // completes nor honors cancellation (exactly convex-swift's
            // non-cancellation-aware FFI behavior) in `withTimeout`, then
            // ALWAYS reset the gate -- whether or not the call actually
            // finished.
            _ = try? await LiveConvexService.withTimeout(.milliseconds(50)) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            gate.reset()
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(
                elapsed, 2.0,
                "a hung logout must not prevent detachAuth's pattern from returning promptly (elapsed: \(elapsed)s)"
            )

            // The gate must actually be reset -- not just "returned promptly"
            // -- so the next sign-in re-attaches with a fresh token instead of
            // short-circuiting on stale `attached == true` state.
            let reattached = await gate.runIfNeeded {
                attempts.increment()
                return true
            }
            XCTAssertTrue(reattached)
            XCTAssertEqual(attempts.value, 2, "reset() after a timed-out logout must force the next call to re-attempt attach")
        }
    #endif
}

// MARK: - WhistleToConvexAuthProviderBridge

#if canImport(ConvexMobile)
    final class WhistleToConvexAuthProviderBridgeTests: XCTestCase {
        func testLoginFromCacheReturnsRealTokenAndExtractIdTokenRoundTrips() async throws {
            let bridge = WhistleToConvexAuthProviderBridge(
                authProvider: MockAuthProvider(fixedToken: "jwt-abc-123")
            )
            let pushed = TokenBox()

            let authData = try await bridge.loginFromCache(onIdToken: { pushed.set($0) })

            XCTAssertEqual(authData, "jwt-abc-123")
            XCTAssertEqual(
                bridge.extractIdToken(from: authData), "jwt-abc-123",
                "extractIdToken must return the real JWT — convex-swift seeds the websocket auth callback from it (the old Void bridge returned \"\")"
            )
            XCTAssertEqual(pushed.get(), "jwt-abc-123", "the token must also be pushed via onIdToken")
        }

        func testLoginThrowsNotAuthenticatedWhenNoTokenIsAvailable() async {
            let bridge = WhistleToConvexAuthProviderBridge(
                authProvider: MockAuthProvider(fixedToken: nil)
            )

            do {
                _ = try await bridge.login(onIdToken: { _ in })
                XCTFail("login with no available token must throw, not silently push nil")
            } catch {
                XCTAssertEqual(error as? ConvexServiceError, .notAuthenticated)
            }
        }
    }
#endif

// MARK: - Helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        token = value
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }
}

/// One-shot async gate: `wait()` suspends until `release()` is called (from
/// any thread, any number of times -- only the first has an effect). Used to
/// hold an in-flight `attach()` closure open long enough for the test to
/// call `gate.reset()` mid-flight, deterministically reproducing the epoch
/// race without relying on timing alone.
private final class ReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if released {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
