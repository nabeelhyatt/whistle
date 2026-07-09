// ConvexService.swift
// Wraps the official convex-swift client (product name `ConvexMobile`,
// package `convex-swift`, pinned exact 0.8.1 — see Package.swift and the
// resolved source read at packages/whistle-core/.build/checkouts/convex-swift
// before writing this file) behind WhistleCore's OWN protocol
// (`ConvexServiceProtocol`), per TECH-SPEC §4.1 `ConvexService` /
// §13 U5's pinning note: all convex-swift usage stays behind this one file
// so any API drift from its pre-1.0 status is absorbed here, not scattered
// across call sites.
//
// convex-swift's REAL API (as resolved, not as assumed from training data):
//   - `ConvexClient(deploymentUrl:)` — base client, unauthenticated.
//   - `ConvexClientWithAuth<T>(deploymentUrl:authProvider:)` — authenticated
//     client; `T` is whatever the AuthProvider's login returns.
//   - `subscribe<T: Decodable>(to: String, with: [String: ConvexEncodable?]?, yielding:) -> AnyPublisher<T, ClientError>`
//     — Combine-based, NOT AsyncSequence-based. `name` is "module:function".
//     This is ALSO the only way to run a one-shot Convex *query*: 0.8.1
//     exposes no `query(_:with:)` method at all (confirmed by reading
//     ConvexMobile.swift — only `subscribe`, `mutation`, `action` exist on
//     `ConvexClient`). Queries must therefore be driven through `subscribe`
//     and reduced to a single value (see `LiveConvexService.firstValue`).
//   - `mutation<T: Decodable>(_:with:) async throws -> T` and a
//     void-returning overload.
//   - `action<T: Decodable>(_:with:) async throws -> T` and a void-returning
//     overload.
//   - `AuthProvider<T>` protocol: `login(onIdToken:) async throws -> T`,
//     `logout() async throws`, `loginFromCache(onIdToken:) async throws -> T`,
//     `extractIdToken(from:) -> String`.
//   - Args are `[String: ConvexEncodable?]`; String/Int/Bool/Double etc.
//     conform out of the box.
//
// This file bridges that Combine-based `subscribe` surface to AsyncStream
// (WhistleCore's chosen concurrency idiom, matching CaptureStore) so callers
// never touch Combine directly.

import Combine
import Foundation
#if canImport(ConvexMobile)
    import ConvexMobile
#endif

// MARK: - AuthProvider seam (WhistleCore's own protocol)

/// Token-supplier seam so this package never depends on a concrete auth
/// implementation. `Auth0AuthProvider` (U6, app target) and
/// `MockAuthProvider` (this package, used by tests and the one-shot smoke
/// run) both implement this. Deliberately NOT the convex-swift
/// `AuthProvider<T>` protocol directly — that ties `T` to convex-swift's
/// generic client; this protocol is the stable seam WhistleCore owns.
public protocol WhistleAuthProvider: Sendable {
    /// Returns a valid JWT ID token, performing a login/refresh flow if
    /// needed. Returns `nil` if the user is unauthenticated or the session
    /// could not be refreshed (caller should present a re-auth prompt).
    func currentIdToken() async -> String?

    /// True once a token has successfully been obtained at least once this
    /// session (used by callers to decide whether to show a signed-in UI
    /// optimistically before the first token fetch completes).
    var isAuthenticated: Bool { get async }
}

// MARK: - Mock auth provider (used by tests, and by U6's one-shot smoke run)

/// A trivial `WhistleAuthProvider` that always returns a fixed fake token
/// (or `nil`, in the `alwaysFail` mode used to simulate refresh failure).
/// The real Auth0 implementation lives in the app target (U6) — this
/// package must not depend on Auth0 or convex-swift-auth0.
public actor MockAuthProvider: WhistleAuthProvider {
    private let fixedToken: String?

    public init(fixedToken: String? = "mock-id-token") {
        self.fixedToken = fixedToken
    }

    public func currentIdToken() async -> String? {
        fixedToken
    }

    public var isAuthenticated: Bool {
        get async { fixedToken != nil }
    }
}

// MARK: - ConvexServiceProtocol (WhistleCore's own client contract)

/// Errors surfaced by `ConvexServiceProtocol` implementations. Deliberately
/// small and I/O-shaped (not convex-swift's `ClientError`) so callers and
/// tests don't need to know convex-swift exists.
public enum ConvexServiceError: Error, Equatable {
    case notAuthenticated
    case requestFailed(String)
    case decodingFailed(String)
}

/// Typed wrapper for every §7 function, plus the two subscriptions
/// (`captures.listRecent`, `projects.list`). Defined as a protocol so
/// SyncEngine/CaptureStore consumers (and all U5 tests) depend on this
/// contract, not on convex-swift directly; `LiveConvexService` is the real
/// implementation, and tests supply a fake.
public protocol ConvexServiceProtocol: Sendable {
    // MARK: users
    func usersEnsure() async throws -> String

    // MARK: settings
    func settingsGet() async throws -> SettingsSnapshot
    func settingsUpdate(_ patch: SettingsPatch) async throws
    func settingsSetConductorKey(_ key: String) async throws

    // MARK: conductor
    func conductorValidateKey(key: String?) async throws -> Bool
    func conductorRefreshProjects() async throws

    // MARK: projects
    func projectsList() -> AsyncStream<[Project]>

    // MARK: templates
    func templatesGet() async throws -> TemplateSnapshot
    func templatesUpdate(body: String) async throws
    func templatesReset() async throws

    // MARK: files
    func filesGenerateUploadUrl() async throws -> String

    // MARK: captures
    func capturesCreate(_ input: CaptureCreateInput) async throws -> String
    func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]>
    func capturesList() async throws -> [ServerCaptureRecord]
    func capturesGet(id: String) async throws -> ServerCaptureRecord?
    func capturesRetry(id: String) async throws
    func capturesDeleteScreenshot(id: String) async throws
    func capturesMarkOpened(id: String) async throws
    func capturesArchive(id: String) async throws
}

// MARK: - Supporting request/response shapes

public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public var defaultProjectId: String?
    public var agent: String
    public var model: String?
    public var screenshotsEnabled: Bool
    public var hasKey: Bool
    public var lastFour: String?

    public init(
        defaultProjectId: String?,
        agent: String,
        model: String?,
        screenshotsEnabled: Bool,
        hasKey: Bool,
        lastFour: String?
    ) {
        self.defaultProjectId = defaultProjectId
        self.agent = agent
        self.model = model
        self.screenshotsEnabled = screenshotsEnabled
        self.hasKey = hasKey
        self.lastFour = lastFour
    }
}

public struct SettingsPatch: Equatable, Sendable {
    public var defaultProjectId: String?
    public var agent: String?
    public var model: String?
    public var screenshotsEnabled: Bool?

    public init(
        defaultProjectId: String? = nil,
        agent: String? = nil,
        model: String? = nil,
        screenshotsEnabled: Bool? = nil
    ) {
        self.defaultProjectId = defaultProjectId
        self.agent = agent
        self.model = model
        self.screenshotsEnabled = screenshotsEnabled
    }
}

public struct TemplateSnapshot: Codable, Equatable, Sendable {
    public var body: String
    public var isCustomized: Bool
    public var updatedAt: Date

    public init(body: String, isCustomized: Bool, updatedAt: Date) {
        self.body = body
        self.isCustomized = isCustomized
        self.updatedAt = updatedAt
    }
}

/// Input to `captures.create` — the client (SyncEngine) → server contract,
/// TECH-SPEC §6/§7. `screenshotStorageId` is the id returned after the
/// upload-then-create sequence (generateUploadUrl → HTTP POST → storageId).
public struct CaptureCreateInput: Equatable, Sendable {
    public var clientId: String
    public var transcript: String
    public var notes: String
    public var screenshotStorageId: String?
    public var projectId: String
    public var projectName: String
    public var agent: String
    public var model: String?
    public var capturedAt: Date

    public init(
        clientId: String,
        transcript: String,
        notes: String,
        screenshotStorageId: String?,
        projectId: String,
        projectName: String,
        agent: String,
        model: String?,
        capturedAt: Date
    ) {
        self.clientId = clientId
        self.transcript = transcript
        self.notes = notes
        self.screenshotStorageId = screenshotStorageId
        self.projectId = projectId
        self.projectName = projectName
        self.agent = agent
        self.model = model
        self.capturedAt = capturedAt
    }
}

// MARK: - LiveConvexService

/// The real `ConvexServiceProtocol` implementation, backed by convex-swift's
/// `ConvexClientWithAuth<String>` (the generic payload is the JWT itself —
/// we bridge our simpler `currentIdToken()` seam into convex-swift's
/// callback-based `AuthProvider` internally, and drive the client's
/// `loginFromCache()` before authenticated calls so the token actually
/// attaches to the websocket — see the "Auth attachment" section below).
///
/// NOTE for U6: convex-swift's `subscribe` returns a Combine
/// `AnyPublisher<T, ClientError>`, not an AsyncSequence. This wrapper
/// bridges each subscription into an `AsyncStream` via `.values` /
/// `sink`, so app-target code (History window, status item) only ever
/// deals in AsyncStream, matching `CaptureStore`'s idiom.
#if canImport(ConvexMobile)
    public final class LiveConvexService: ConvexServiceProtocol, @unchecked Sendable {
        private let client: ConvexClientWithAuth<String>
        private let authGate = ConvexAuthAttachmentGate()
        private var cancellables: Set<AnyCancellable> = []
        private let lock = NSLock()

        /// - Parameters:
        ///   - deploymentUrl: Convex deployment URL (dashboard → Settings).
        ///   - authProvider: WhistleCore's own auth seam. Bridged internally
        ///     into convex-swift's `AuthProvider<String>` shape.
        public init(deploymentUrl: String, authProvider: any WhistleAuthProvider) {
            let bridge = WhistleToConvexAuthProviderBridge(authProvider: authProvider)
            self.client = ConvexClientWithAuth(deploymentUrl: deploymentUrl, authProvider: bridge)
        }

        // MARK: - Auth attachment
        //
        // convex-swift's `ConvexClientWithAuth` only attaches the JWT to the
        // underlying websocket client inside its own `login()`/
        // `loginFromCache()` — that is where `ffiClient.setAuthCallback` is
        // invoked (see .build/checkouts/convex-swift ConvexMobile.swift).
        // Constructing the client with an `AuthProvider` alone attaches
        // NOTHING: every function call runs unauthenticated and the backend
        // throws `NotAuthenticatedError` (this was the post-Auth0-sign-in
        // "Sign-in didn't complete" bug). Every authenticated entry point
        // below therefore drives `loginFromCache()` at least once before
        // talking to the backend — covering both the fresh interactive-login
        // path (AuthController calls `usersEnsure` right after Auth0 stores
        // credentials) and the app-launch cached-session path — and
        // re-attempts on the next call after a failed attach (e.g. token
        // briefly unavailable).

        private func ensureAuthAttached() async throws {
            let attached = await authGate.runIfNeeded { [client] in
                switch await client.loginFromCache() {
                case .success:
                    return true
                case let .failure(error):
                    NSLog("Whistle: attaching auth to Convex client failed: %@", String(describing: error))
                    return false
                }
            }
            guard attached else { throw ConvexServiceError.notAuthenticated }
        }

        /// Maps convex-swift's stringly server error for backend auth
        /// rejections (`requireIdentity` throwing `NotAuthenticatedError`)
        /// onto `ConvexServiceError.notAuthenticated`, so callers
        /// (AuthController) can distinguish "backend rejected the session"
        /// from network/transport failures.
        private static func mapAuthError(_ error: Error) -> Error {
            let description = String(describing: error)
            if description.contains("NotAuthenticatedError") || description.contains("Not authenticated") {
                return ConvexServiceError.notAuthenticated
            }
            return error
        }

        // MARK: users

        public func usersEnsure() async throws -> String {
            try await ensureAuthAttached()
            do {
                return try await client.mutation("users:ensure")
            } catch {
                NSLog("Whistle: users:ensure failed: %@", String(describing: error))
                throw Self.mapAuthError(error)
            }
        }

        // MARK: - Authenticated call helpers (attach auth, then call)

        private func authedMutation<T: Decodable>(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws -> T {
            try await ensureAuthAttached()
            do {
                return try await client.mutation(name, with: args)
            } catch {
                NSLog("Whistle: Convex mutation %@ failed: %@", name, String(describing: error))
                throw Self.mapAuthError(error)
            }
        }

        private func authedMutation(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws {
            let _: String? = try await authedMutation(name, with: args)
        }

        private func authedAction<T: Decodable>(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws -> T {
            try await ensureAuthAttached()
            do {
                return try await client.action(name, with: args)
            } catch {
                NSLog("Whistle: Convex action %@ failed: %@", name, String(describing: error))
                throw Self.mapAuthError(error)
            }
        }

        private func authedAction(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws {
            let _: String? = try await authedAction(name, with: args)
        }

        /// Runs a one-shot Convex *query* (`settings:get`, `templates:get`,
        /// `captures:list`, `captures:get`). convex-swift 0.8.1 has no
        /// one-shot query method, so this subscribes via `client.subscribe`,
        /// takes the first yielded value, and cancels — see
        /// `LiveConvexService.firstValue` for the mechanics and
        /// `ConvexOneShotQueryTests` for coverage of that helper against a
        /// synthetic publisher (this method itself can't be driven
        /// hermetically without a live `ConvexClient`, same constraint noted
        /// in `ConvexAuthAttachmentTests`).
        private func authedQuery<T: Decodable & Sendable>(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws -> T {
            try await ensureAuthAttached()
            do {
                return try await Self.firstValue(
                    from: client.subscribe(to: name, with: args, yielding: T.self)
                )
            } catch {
                NSLog("Whistle: Convex query %@ failed: %@", name, String(describing: error))
                throw Self.mapAuthError(error)
            }
        }

        // MARK: settings

        public func settingsGet() async throws -> SettingsSnapshot {
            try await authedQuery("settings:get")
        }

        public func settingsUpdate(_ patch: SettingsPatch) async throws {
            try await authedMutation(
                "settings:update",
                with: [
                    "defaultProjectId": patch.defaultProjectId,
                    "agent": patch.agent,
                    "model": patch.model,
                    "screenshotsEnabled": patch.screenshotsEnabled,
                ]
            )
        }

        public func settingsSetConductorKey(_ key: String) async throws {
            try await authedMutation("settings:setConductorKey", with: ["conductorApiKey": key])
        }

        // MARK: conductor

        public func conductorValidateKey(key: String?) async throws -> Bool {
            // NOTE: this action lives in `projects.ts` on the backend (there
            // is no `conductor` Convex module — `conductorClient.ts` is a
            // plain helper, not a functions file), so the wire name is
            // "projects:validateKey", not "conductor:validateKey" (the
            // latter throws "Could not find function" on every call). The
            // handler also returns `{ ok, error? }`, not a bare bool, and
            // takes `apiKey`, not `key` — all three had to be fixed together
            // for this call to actually reach and decode correctly.
            let result: ConductorActionResult = try await authedAction(
                "projects:validateKey", with: ["apiKey": key]
            )
            return result.ok
        }

        public func conductorRefreshProjects() async throws {
            // Same module-name correction as `conductorValidateKey` above;
            // also decodes the actual `{ ok, error? }` response shape
            // instead of the previous `String?` guess (which would have
            // thrown a decoding error on every successful call).
            let _: ConductorActionResult = try await authedAction("projects:refreshProjects")
        }

        // MARK: projects

        public func projectsList() -> AsyncStream<[Project]> {
            asyncStream(subscribingTo: "projects:list")
        }

        // MARK: templates

        public func templatesGet() async throws -> TemplateSnapshot {
            try await authedQuery("templates:get")
        }

        public func templatesUpdate(body: String) async throws {
            try await authedMutation("templates:update", with: ["body": body])
        }

        public func templatesReset() async throws {
            try await authedMutation("templates:reset")
        }

        // MARK: files

        public func filesGenerateUploadUrl() async throws -> String {
            try await authedMutation("files:generateUploadUrl")
        }

        // MARK: captures

        public func capturesCreate(_ input: CaptureCreateInput) async throws -> String {
            try await authedMutation(
                "captures:create",
                with: [
                    "clientId": input.clientId,
                    "transcript": input.transcript,
                    "notes": input.notes,
                    "screenshotId": input.screenshotStorageId,
                    "projectId": input.projectId,
                    "projectName": input.projectName,
                    "agent": input.agent,
                    "model": input.model,
                    "capturedAt": input.capturedAt.timeIntervalSince1970 * 1000,
                ]
            )
        }

        public func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]> {
            // `limit` MUST encode as a float64: the backend validator is
            // `v.float64()` and convex-swift encodes Swift `Int` as an
            // `$integer` (bigint), which Convex rejects with an
            // ArgumentValidationError (observed repeatedly in deployment
            // logs before this was fixed).
            asyncStream(subscribingTo: "captures:listRecent", args: ["limit": Double(limit)])
        }

        public func capturesList() async throws -> [ServerCaptureRecord] {
            try await authedQuery("captures:list")
        }

        public func capturesGet(id: String) async throws -> ServerCaptureRecord? {
            // Arg key fixed to match the backend validator (`captures.get`
            // takes `captureId`, not `id`) — this had to be corrected
            // alongside the call-type fix, since routing this to the right
            // endpoint but with the wrong arg name would still fail with an
            // ArgumentValidationError.
            try await authedQuery("captures:get", with: ["captureId": id])
        }

        public func capturesRetry(id: String) async throws {
            try await authedMutation("captures:retry", with: ["id": id])
        }

        public func capturesDeleteScreenshot(id: String) async throws {
            try await authedMutation("captures:deleteScreenshot", with: ["id": id])
        }

        public func capturesMarkOpened(id: String) async throws {
            try await authedMutation("captures:markOpened", with: ["id": id])
        }

        public func capturesArchive(id: String) async throws {
            try await authedMutation("captures:archive", with: ["id": id])
        }

        // MARK: - Combine -> AsyncStream bridge

        private func asyncStream<T: Decodable & Sendable>(
            subscribingTo name: String,
            args: [String: ConvexEncodable?]? = nil
        ) -> AsyncStream<T> {
            AsyncStream { continuation in
                let subscriptionTask = Task { [weak self] in
                    guard let self else {
                        continuation.finish()
                        return
                    }
                    // Best-effort auth attach BEFORE subscribing, so
                    // authenticated queries don't land on the websocket
                    // without a JWT. An unauthenticated subscribe still goes
                    // through (matching prior behavior for the signed-out
                    // state); the server then rejects it and the stream
                    // finishes.
                    try? await self.ensureAuthAttached()
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    let cancellable = self.client.subscribe(to: name, with: args, yielding: T.self)
                        .sink(
                            receiveCompletion: { completion in
                                if case let .failure(error) = completion {
                                    NSLog(
                                        "Whistle: Convex subscription %@ failed: %@",
                                        name, String(describing: error)
                                    )
                                }
                                continuation.finish()
                            },
                            receiveValue: { value in continuation.yield(value) }
                        )
                    self.lock.withLock { _ = self.cancellables.insert(cancellable) }
                    // Replaces the task-cancelling handler installed below;
                    // by this point the task is finishing, so cancelling the
                    // subscription itself is all termination needs to do.
                    // (AsyncStream invokes a newly set onTermination
                    // immediately if the stream already terminated, so the
                    // subscription can't leak in that race.)
                    continuation.onTermination = { [weak self] _ in
                        self?.lock.withLock { _ = self?.cancellables.remove(cancellable) }
                        cancellable.cancel()
                    }
                }
                continuation.onTermination = { _ in
                    subscriptionTask.cancel()
                }
            }
        }

        // MARK: - One-shot query support (subscribe -> first value -> cancel)

        /// convex-swift 0.8.1 has no one-shot query method — `subscribe` is
        /// the only way to reach a Convex *query* function, and it's an
        /// indefinite Combine publisher. This reduces that publisher to a
        /// single value: take the first thing it yields, then cancel the
        /// underlying subscription (via `AsyncThrowingPublisher`'s
        /// cancel-on-task-cancel behavior, triggered by returning out of the
        /// `for try await` loop). Races against `timeout` so a query that
        /// never yields (dropped connection before the first snapshot, wrong
        /// function name, etc.) fails fast instead of hanging the caller.
        ///
        /// Internal (not private) — and free of any `LiveConvexService`
        /// instance state — so it's unit-testable against a synthetic
        /// `AnyPublisher` without a live `ConvexClient`; see
        /// `ConvexOneShotQueryTests`.
        static func firstValue<T: Sendable>(
            from publisher: AnyPublisher<T, ClientError>,
            timeout: Duration = .seconds(10)
        ) async throws -> T {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    for try await value in publisher.values {
                        return value
                    }
                    throw ConvexServiceError.requestFailed(
                        "query completed without yielding a value"
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ConvexServiceError.requestFailed(
                        "query timed out waiting for a value"
                    )
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw ConvexServiceError.requestFailed("query produced no result")
                }
                return result
            }
        }
    }

    /// Decodes the `{ ok: boolean, error?: string }` shape returned by the
    /// `projects:validateKey` / `projects:refreshProjects` Convex actions
    /// (see packages/backend/convex/projects.ts). `error` is currently
    /// unused (kept for future surfacing) — decoded so the field doesn't
    /// need to be absent for `Decodable` to succeed.
    struct ConductorActionResult: Decodable, Sendable {
        let ok: Bool
        let error: String?
    }

    /// Serializes "attach auth once; re-attempt after failure" semantics for
    /// `LiveConvexService`. Internal (not private) so the sequencing
    /// regression can be unit-tested without a live Convex client.
    final class ConvexAuthAttachmentGate: @unchecked Sendable {
        private let lock = NSLock()
        private var attached = false

        /// Runs `attach` unless a prior attempt already succeeded. Returns
        /// the overall attached state. A failed attempt leaves the gate
        /// open so the next call re-attempts.
        func runIfNeeded(_ attach: () async -> Bool) async -> Bool {
            if lock.withLock({ attached }) { return true }
            let success = await attach()
            if success {
                lock.withLock { attached = true }
            }
            return success
        }
    }

    /// Bridges WhistleCore's pull-based `WhistleAuthProvider.currentIdToken()`
    /// into convex-swift's `AuthProvider<String>` (login/logout/
    /// loginFromCache with an `onIdToken` callback). WhistleCore never calls
    /// convex-swift's interactive `login()` UI flow itself — the app target
    /// owns presenting login UI (Auth0 or mock); this bridge only exists so
    /// `ConvexClientWithAuth.loginFromCache()` can pull a current token via
    /// the same path every time, which is all WhistleCore needs.
    ///
    /// `T` is `String` — the JWT itself — because convex-swift's
    /// `ConvexClientWithAuth.login(strategy:)` seeds its internal
    /// `AuthTokenProviderBridge` with `extractIdToken(from: authData)`. The
    /// previous `T == Void` version of this bridge returned `""` from
    /// `extractIdToken`, which would have seeded the websocket auth
    /// callback with an empty token; returning the real JWT makes the
    /// token flow deterministic. Internal (not private) so the token
    /// passthrough is unit-testable.
    final class WhistleToConvexAuthProviderBridge: AuthProvider, @unchecked Sendable {
        typealias T = String

        let authProvider: any WhistleAuthProvider

        init(authProvider: any WhistleAuthProvider) {
            self.authProvider = authProvider
        }

        func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
            try await currentToken(onIdToken: onIdToken)
        }

        func logout() async throws {}

        func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
            try await currentToken(onIdToken: onIdToken)
        }

        func extractIdToken(from authResult: String) -> String {
            authResult
        }

        private func currentToken(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
            guard let token = await authProvider.currentIdToken() else {
                // No token available (signed out / refresh failed). Throwing
                // makes `ConvexClientWithAuth.loginFromCache()` resolve to
                // `.failure` + `.unauthenticated`, which
                // `LiveConvexService.ensureAuthAttached()` surfaces as
                // `ConvexServiceError.notAuthenticated`.
                throw ConvexServiceError.notAuthenticated
            }
            onIdToken(token)
            return token
        }
    }
#endif

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
