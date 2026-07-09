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
