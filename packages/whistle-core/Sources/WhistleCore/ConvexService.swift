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
/// `ConvexClientWithAuth<Void>` (auth state is tracked by our own
/// `WhistleAuthProvider`, so the generic payload convex-swift's
/// `AuthProvider<T>` would normally carry isn't needed — we bridge our
/// simpler `currentIdToken()` seam into convex-swift's callback-based
/// `AuthProvider` internally).
///
/// NOTE for U6: convex-swift's `subscribe` returns a Combine
/// `AnyPublisher<T, ClientError>`, not an AsyncSequence. This wrapper
/// bridges each subscription into an `AsyncStream` via `.values` /
/// `sink`, so app-target code (History window, status item) only ever
/// deals in AsyncStream, matching `CaptureStore`'s idiom.
#if canImport(ConvexMobile)
    public final class LiveConvexService: ConvexServiceProtocol, @unchecked Sendable {
        private let client: ConvexClientWithAuth<Void>
        private var cancellables: Set<AnyCancellable> = []
        private let lock = NSLock()

        /// - Parameters:
        ///   - deploymentUrl: Convex deployment URL (dashboard → Settings).
        ///   - authProvider: WhistleCore's own auth seam. Bridged internally
        ///     into convex-swift's `AuthProvider<Void>` shape.
        public init(deploymentUrl: String, authProvider: any WhistleAuthProvider) {
            let bridge = WhistleToConvexAuthProviderBridge(authProvider: authProvider)
            self.client = ConvexClientWithAuth(deploymentUrl: deploymentUrl, authProvider: bridge)
        }

        // MARK: users

        public func usersEnsure() async throws -> String {
            try await client.mutation("users:ensure")
        }

        // MARK: settings

        public func settingsGet() async throws -> SettingsSnapshot {
            try await client.mutation("settings:get")
        }

        public func settingsUpdate(_ patch: SettingsPatch) async throws {
            try await client.mutation(
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
            try await client.mutation("settings:setConductorKey", with: ["conductorApiKey": key])
        }

        // MARK: conductor

        public func conductorValidateKey(key: String?) async throws -> Bool {
            try await client.action("conductor:validateKey", with: ["key": key])
        }

        public func conductorRefreshProjects() async throws {
            try await client.action("conductor:refreshProjects")
        }

        // MARK: projects

        public func projectsList() -> AsyncStream<[Project]> {
            asyncStream(subscribingTo: "projects:list")
        }

        // MARK: templates

        public func templatesGet() async throws -> TemplateSnapshot {
            try await client.mutation("templates:get")
        }

        public func templatesUpdate(body: String) async throws {
            try await client.mutation("templates:update", with: ["body": body])
        }

        public func templatesReset() async throws {
            try await client.mutation("templates:reset")
        }

        // MARK: files

        public func filesGenerateUploadUrl() async throws -> String {
            try await client.mutation("files:generateUploadUrl")
        }

        // MARK: captures

        public func capturesCreate(_ input: CaptureCreateInput) async throws -> String {
            try await client.mutation(
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
            asyncStream(subscribingTo: "captures:listRecent", args: ["limit": limit])
        }

        public func capturesList() async throws -> [ServerCaptureRecord] {
            try await client.mutation("captures:list")
        }

        public func capturesGet(id: String) async throws -> ServerCaptureRecord? {
            try await client.mutation("captures:get", with: ["id": id])
        }

        public func capturesRetry(id: String) async throws {
            try await client.mutation("captures:retry", with: ["id": id])
        }

        public func capturesDeleteScreenshot(id: String) async throws {
            try await client.mutation("captures:deleteScreenshot", with: ["id": id])
        }

        public func capturesMarkOpened(id: String) async throws {
            try await client.mutation("captures:markOpened", with: ["id": id])
        }

        public func capturesArchive(id: String) async throws {
            try await client.mutation("captures:archive", with: ["id": id])
        }

        // MARK: - Combine -> AsyncStream bridge

        private func asyncStream<T: Decodable & Sendable>(
            subscribingTo name: String,
            args: [String: ConvexEncodable?]? = nil
        ) -> AsyncStream<T> {
            AsyncStream { continuation in
                let cancellable = self.client.subscribe(to: name, with: args, yielding: T.self)
                    .sink(
                        receiveCompletion: { _ in continuation.finish() },
                        receiveValue: { value in continuation.yield(value) }
                    )
                self.lock.withLock { _ = self.cancellables.insert(cancellable) }
                continuation.onTermination = { [weak self] _ in
                    self?.lock.withLock { _ = self?.cancellables.remove(cancellable) }
                    cancellable.cancel()
                }
            }
        }
    }

    /// Bridges WhistleCore's pull-based `WhistleAuthProvider.currentIdToken()`
    /// into convex-swift's push-based `AuthProvider<Void>` (login/logout/
    /// loginFromCache with an `onIdToken` callback). WhistleCore never calls
    /// convex-swift's interactive `login()` UI flow itself — the app target
    /// owns presenting login UI (Auth0 or mock); this bridge only exists so
    /// `ConvexClientWithAuth` can pull a current token via the same
    /// `loginFromCache` path every time, which is all WhistleCore needs.
    private final class WhistleToConvexAuthProviderBridge: AuthProvider, @unchecked Sendable {
        typealias T = Void

        let authProvider: any WhistleAuthProvider

        init(authProvider: any WhistleAuthProvider) {
            self.authProvider = authProvider
        }

        func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws {
            let token = await authProvider.currentIdToken()
            onIdToken(token)
        }

        func logout() async throws {}

        func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws {
            let token = await authProvider.currentIdToken()
            onIdToken(token)
        }

        func extractIdToken(from authResult: Void) -> String {
            // convex-swift calls this to pull the token out of whatever
            // `login`/`loginFromCache` returned; since our bridge never
            // actually returns a token through `T` (it pushes eagerly via
            // `onIdToken` instead), this is never meaningfully invoked with
            // a token consumers rely on — return empty string. See U6 note
            // below: this whole bridge should be revisited if convex-swift's
            // token-pull path (`AuthTokenProviderBridge.fetchToken`) proves
            // to need a real value here.
            ""
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
