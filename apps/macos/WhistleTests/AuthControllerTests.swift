// AuthControllerTests.swift
// Plan U6 scenarios:
//   - Happy: signed-out -> mock sign-in flow -> users.ensure called once ->
//     signed-in menu state.
//   - Edge: token refresh failure (simulated via the mock) -> signed-out
//     (re-auth prompt) state, no crash.
//
// All tests run against WhistleCore's `MockAuthProvider` — never
// `Auth0AuthProvider` — per TECH-SPEC §2a/§9: "All automated tests, and the
// one-shot smoke run, use MockAuthProvider."

import XCTest
@testable import Whistle
@testable import WhistleCore

// MARK: - Local fake ConvexServiceProtocol (this module can't see
// WhistleCoreTests' internal FakeConvexService, so a small scriptable
// double is defined here, scoped to what AuthController needs).

private final class FakeConvexService: ConvexServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var usersEnsureCallCount = 0
    private(set) var detachAuthCallCount = 0
    private(set) var authCalls: [String] = []
    var usersEnsureError: Error?

    func usersEnsure() async throws -> String {
        lock.withLock {
            usersEnsureCallCount += 1
            authCalls.append("ensure")
        }
        if let usersEnsureError { throw usersEnsureError }
        return "user-1"
    }

    // MARK: auth lifecycle (overrides the protocol's no-op default so
    // signOut()'s wiring is assertable -- see testSignOutDetachesConvexAndLogsOutProvider)

    func detachAuth() async {
        lock.withLock {
            detachAuthCallCount += 1
            authCalls.append("detach")
        }
    }

    // MARK: settings (unused by AuthController; trivial stubs)

    func settingsGet() async throws -> SettingsSnapshot {
        SettingsSnapshot(defaultProjectId: nil, agent: "claude", model: nil, screenshotsEnabled: true, hasKey: false, lastFour: nil)
    }
    func settingsUpdate(_ patch: SettingsPatch) async throws {}
    func settingsSetConductorKey(_ key: String) async throws {}

    // MARK: conductor

    func conductorValidateKey(key: String?) async throws -> Bool { true }
    func conductorRefreshProjects() async throws {}

    // MARK: projects

    func projectsList() -> AsyncStream<[Project]> {
        AsyncStream { _ in }
    }

    // MARK: templates

    func templatesGet() async throws -> TemplateSnapshot {
        TemplateSnapshot(body: "", isCustomized: false, updatedAt: Date(timeIntervalSince1970: 0))
    }
    func templatesUpdate(body: String) async throws {}
    func templatesReset() async throws {}

    // MARK: files

    func filesGenerateUploadUrl() async throws -> String { "https://example.convex.cloud/upload/fake" }

    // MARK: captures

    func capturesCreate(_ input: CaptureCreateInput) async throws -> String { "server-\(input.clientId)" }
    func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]> {
        AsyncStream { _ in }
    }
    func capturesList() async throws -> [ServerCaptureRecord] { [] }
    func capturesGet(id: String) async throws -> ServerCaptureRecord? { nil }
    func capturesRetry(id: String) async throws {}
    func capturesDeleteScreenshot(id: String) async throws {}
    func capturesMarkOpened(id: String) async throws {}
    func capturesArchive(id: String) async throws {}
}

// MARK: - Local fake WhistleAuthProvider that records logout() calls
// (MockAuthProvider itself now clears its token on logout(), but doesn't
// expose a call count -- this wraps the same fixed-token behavior with one).

private actor RecordingAuthProvider: WhistleAuthProvider {
    private var token: String?
    private(set) var logoutCallCount = 0

    init(fixedToken: String? = "mock-id-token") {
        token = fixedToken
    }

    func currentIdToken() async -> String? { token }

    var isAuthenticated: Bool {
        get async { token != nil }
    }

    func logout() async {
        logoutCallCount += 1
        token = nil
    }
}

// MARK: - Tests

@MainActor
final class AuthControllerTests: XCTestCase {
    // MARK: Happy path

    func testSignInFlowCallsUsersEnsureOnceAndReachesSignedIn() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        let breadcrumb = InMemoryAuthBreadcrumbStore()
        let controller = AuthController(
            authProvider: mockAuth,
            convexService: convex,
            breadcrumbStore: breadcrumb
        )

        XCTAssertEqual(controller.state, .signedOut)

        await controller.signIn()

        XCTAssertEqual(controller.state, .signedIn)
        XCTAssertEqual(controller.usersEnsureCallCount, 1)
        XCTAssertEqual(convex.usersEnsureCallCount, 1)
        XCTAssertEqual(convex.detachAuthCallCount, 0, "an initial sign-in has no stale attachment to reset")
        XCTAssertTrue(breadcrumb.hasSignedInBefore())
    }

    func testResolveInitialStateSignsInAutomaticallyWithCachedToken() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.resolveInitialState()

        XCTAssertEqual(controller.state, .signedIn)
        XCTAssertEqual(convex.usersEnsureCallCount, 1)
    }

    func testSignInIsIdempotentWhileAlreadySignedIn() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.signIn()
        await controller.signIn() // second call should be a no-op

        XCTAssertEqual(controller.state, .signedIn)
        XCTAssertEqual(convex.usersEnsureCallCount, 1)
    }

    // MARK: Edge: token refresh failure

    func testTokenRefreshFailureTransitionsToReauthRequiredWithoutCrashing() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.signIn()
        XCTAssertEqual(controller.state, .signedIn)

        controller.handleTokenRefreshFailure()

        XCTAssertEqual(controller.state, .reauthRequired)
    }

    func testReauthenticationDetachesStaleConvexAuthBeforeEnsuringUser() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.signIn()
        controller.handleTokenRefreshFailure()
        await controller.signIn()

        XCTAssertEqual(controller.state, .signedIn)
        XCTAssertEqual(convex.detachAuthCallCount, 1)
        XCTAssertEqual(convex.authCalls, ["ensure", "detach", "ensure"])
    }

    func testResolveInitialStateWithNoTokenAndNoPriorSignInIsSignedOut() async {
        let mockAuth = MockAuthProvider(fixedToken: nil) // simulates a failed/absent session
        let convex = FakeConvexService()
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.resolveInitialState()

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertEqual(convex.usersEnsureCallCount, 0)
    }

    func testResolveInitialStateWithNoTokenButPriorSignInShowsReauthRequired() async {
        let mockAuth = MockAuthProvider(fixedToken: nil) // simulates refresh failure on relaunch
        let convex = FakeConvexService()
        let breadcrumb = InMemoryAuthBreadcrumbStore()
        breadcrumb.setHasSignedInBefore(true)
        let controller = AuthController(authProvider: mockAuth, convexService: convex, breadcrumbStore: breadcrumb)

        await controller.resolveInitialState()

        XCTAssertEqual(controller.state, .reauthRequired)
        XCTAssertEqual(convex.usersEnsureCallCount, 0)
    }

    func testUsersEnsureFailureDoesNotCrashAndRequestsReauth() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        convex.usersEnsureError = ConvexServiceError.requestFailed("simulated failure")
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.signIn()

        XCTAssertEqual(controller.state, .reauthRequired)
        XCTAssertEqual(convex.usersEnsureCallCount, 1)
    }

    // MARK: Sign-in failure surfacing (regression: the Convex handshake
    // failing after a SUCCESSFUL Auth0 login used to be silent — no log, no
    // cause-specific message, just a generic "didn't complete").

    func testBackendAuthRejectionSurfacesBackendSpecificErrorMessage() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        convex.usersEnsureError = ConvexServiceError.notAuthenticated
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.signIn()

        XCTAssertEqual(controller.state, .reauthRequired)
        let message = controller.lastSignInErrorMessage
        XCTAssertNotNil(message, "a backend auth rejection must publish a user-facing reason")
        XCTAssertTrue(
            message?.contains("backend couldn't verify") ?? false,
            "backend-auth failure must be distinguishable from a network failure; got: \(message ?? "nil")"
        )
    }

    func testNetworkishUsersEnsureFailureSurfacesConnectionErrorMessage() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        convex.usersEnsureError = ConvexServiceError.requestFailed("socket closed")
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.signIn()

        XCTAssertEqual(controller.state, .reauthRequired)
        XCTAssertTrue(
            controller.lastSignInErrorMessage?.contains("couldn't be reached") ?? false,
            "non-auth failures should read as connection problems; got: \(controller.lastSignInErrorMessage ?? "nil")"
        )
    }

    func testSuccessfulSignInClearsLastSignInErrorMessage() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        convex.usersEnsureError = ConvexServiceError.notAuthenticated
        let controller = AuthController(authProvider: mockAuth, convexService: convex)

        await controller.signIn()
        XCTAssertNotNil(controller.lastSignInErrorMessage)

        // Retry with the backend healthy again (state is .reauthRequired,
        // from which signIn() is a legal retry).
        convex.usersEnsureError = nil
        await controller.signIn()

        XCTAssertEqual(controller.state, .signedIn)
        XCTAssertNil(controller.lastSignInErrorMessage)
    }

    func testInteractiveLoginFailurePublishesRetryMessage() async {
        let mockAuth = MockAuthProvider(fixedToken: nil)
        let convex = FakeConvexService()
        struct LoginCancelled: Error {}
        let controller = AuthController(
            authProvider: mockAuth,
            convexService: convex,
            performInteractiveLogin: { throw LoginCancelled() }
        )

        await controller.signIn()

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNotNil(controller.lastSignInErrorMessage)
    }

    func testSignOutClearsBreadcrumbAndReturnsToSignedOut() async {
        let mockAuth = MockAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        let breadcrumb = InMemoryAuthBreadcrumbStore()
        let controller = AuthController(authProvider: mockAuth, convexService: convex, breadcrumbStore: breadcrumb)

        await controller.signIn()
        XCTAssertEqual(controller.state, .signedIn)

        await controller.signOut()

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertFalse(breadcrumb.hasSignedInBefore())
    }

    // MARK: Sign-out actually ends the session (fix: signOut() previously
    // only flipped local state -- neither the provider's cached credentials
    // nor Convex's websocket auth attachment were ever cleared, so a
    // relaunch or a second sign-in as a different user could still ride on
    // the previous session).

    func testSignOutDetachesConvexAndLogsOutProvider() async {
        let recordingAuth = RecordingAuthProvider(fixedToken: "mock-id-token")
        let convex = FakeConvexService()
        let controller = AuthController(authProvider: recordingAuth, convexService: convex)

        await controller.signIn()
        XCTAssertEqual(controller.state, .signedIn)

        await controller.signOut()

        XCTAssertEqual(controller.state, .signedOut)
        let logoutCallCount = await recordingAuth.logoutCallCount
        XCTAssertEqual(logoutCallCount, 1, "signOut() must clear the provider's cached credentials")
        XCTAssertEqual(convex.detachAuthCallCount, 1, "signOut() must detach the Convex websocket auth attachment")
        let tokenAfterSignOut = await recordingAuth.currentIdToken()
        XCTAssertNil(tokenAfterSignOut, "the provider's token must be gone after signOut()")
    }

    // MARK: Interactive login hook failure (e.g. user cancels Auth0 flow)

    func testInteractiveLoginFailureFallsBackToSignedOut() async {
        let mockAuth = MockAuthProvider(fixedToken: nil)
        let convex = FakeConvexService()
        struct LoginCancelled: Error {}
        let controller = AuthController(
            authProvider: mockAuth,
            convexService: convex,
            performInteractiveLogin: { throw LoginCancelled() }
        )

        await controller.signIn()

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertEqual(convex.usersEnsureCallCount, 0)
    }
}
