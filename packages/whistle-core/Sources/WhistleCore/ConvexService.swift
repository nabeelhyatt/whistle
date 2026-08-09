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

    /// Clears any cached/stored credentials so no later launch or call can
    /// obtain a token for this session. Called by `AuthController.signOut()`
    /// -- without it, sign-out only flipped in-memory UI state while the
    /// real credentials (Keychain-backed for Auth0, in-memory for the dev/
    /// mock providers) stayed put, so a relaunch (or a second sign-in as a
    /// different user) could still mint tokens for the previous session.
    func logout() async
}

// MARK: - Mock auth provider (used by tests, and by U6's one-shot smoke run)

/// A trivial `WhistleAuthProvider` that always returns a fixed fake token
/// (or `nil`, in the `alwaysFail` mode used to simulate refresh failure).
/// The real Auth0 implementation lives in the app target (U6) — this
/// package must not depend on Auth0 or convex-swift-auth0.
public actor MockAuthProvider: WhistleAuthProvider {
    private var fixedToken: String?

    public init(fixedToken: String? = "mock-id-token") {
        self.fixedToken = fixedToken
    }

    public func currentIdToken() async -> String? {
        fixedToken
    }

    public var isAuthenticated: Bool {
        get async { fixedToken != nil }
    }

    /// Clears the mock's token, mirroring the real providers' logout()
    /// contract -- tests can assert `currentIdToken()` returns `nil`
    /// afterward. `fixedToken` is `var` (not `let`) specifically so this
    /// has somewhere to write.
    public func logout() async {
        fixedToken = nil
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

    /// Backend-truth identity for Settings' "Signed in as" / "Via" display
    /// (canonical-accounts plan §4) — never derived from decoding the JWT
    /// client-side. Mirrors `users:me` (a query, so this goes through
    /// `authedQuery` in `LiveConvexService`, same as `settingsGet`).
    func usersMe() async throws -> UserSelfSnapshot

    // MARK: auth lifecycle

    /// Drops the current websocket auth attachment and resets the internal
    /// attach-once gate, so the next authenticated call must re-attach with
    /// a fresh token instead of continuing to run under a previous session's
    /// already-pinned JWT. Called by `AuthController.signOut()` (and must be
    /// called before a different user signs in) -- without it, a second
    /// sign-in short-circuited the attach gate (`if attached { return true }`)
    /// and ran mutations under the FIRST user's token. Defaults to a no-op
    /// via the extension below so existing fakes/tests stay source-
    /// compatible without implementing it; `LiveConvexService` MUST override
    /// this with a real implementation.
    func detachAuth() async

    // MARK: settings
    func settingsGet() async throws -> SettingsSnapshot
    func settingsUpdate(_ patch: SettingsPatch) async throws

    // MARK: conductor

    /// Re-checks the CURRENTLY STORED key against its stored environment
    /// (clean break, KTD6: the backend `projects:validateKey` action dropped
    /// its `apiKey` arg entirely — there is no client-supplied-key variant
    /// anymore; key entry now goes through `conductorSetAndValidateKey`
    /// below instead).
    func conductorValidateKey() async throws -> Bool
    /// Like `conductorValidateKey`, but also reports whether this key's project
    /// set differs from the previously-saved key (canonical-accounts). Has a
    /// default implementation so existing fakes/tests conform unchanged; only
    /// `LiveConvexService` decodes the extra signal.
    func conductorValidateKeyDetailed() async throws -> ConductorValidateResult
    func conductorRefreshProjects() async throws

    /// Atomically probes `key` against both Conductor hosts (prod, then
    /// staging), and — only on acceptance — stores the key plus whichever
    /// environment accepted it and seeds `projectsCache`, all server-side in
    /// one action (`projects:setAndValidateKey`, KTD3). Replaces the previous
    /// client-side validate-then-save two-step in both key-entry flows
    /// (Onboarding, Settings): a rejected key changes nothing server-side, so
    /// there is no separate client "save" call to make on failure.
    func conductorSetAndValidateKey(key: String) async throws -> ConductorSetAndValidateResult

    // MARK: orgs (multi-org plan)

    /// All of the user's labeled Conductor org keys, masked -- mirrors
    /// `orgs:list`. Has a default implementation (returns `[]`, see the
    /// extension below) so pre-existing fakes/tests don't need to be touched
    /// just to keep conforming.
    func orgsList() async throws -> [OrgKeyInfo]

    /// Probes `key` against both Conductor hosts and, only on acceptance,
    /// stores it as a NEW labeled org row -- mirrors `orgs:addKey`. Unlike
    /// `conductorSetAndValidateKey`, this never replaces an existing row.
    /// Default implementation throws (see below) rather than no-op-
    /// succeeding.
    func orgAddKey(label: String, key: String) async throws -> OrgAddKeyResult

    /// Removes an org key -- mirrors `orgs:remove`. Default implementation
    /// throws (see below).
    func orgRemove(orgId: String) async throws

    /// Renames an org key's user-typed label -- mirrors `orgs:rename`.
    /// Default implementation throws (see below).
    func orgRename(orgId: String, label: String) async throws

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

    // MARK: connection self-healing (wedged-websocket rebuild)

    /// Fires once, asynchronously, right after `rebuildClient()` swaps in a
    /// fresh Convex client following a detected wedge (a short streak of
    /// consecutive call timeouts with no proof-of-life). The app wires this
    /// to a drain of the local sync queue so a stuck capture retries seconds
    /// after the rebuild instead of waiting for the next periodic drain tick.
    /// Settable (not init-only) because the app constructs the drain closure
    /// only after the Convex service already exists. Default no-op get/set
    /// via the extension below keeps existing fakes/tests source-compatible.
    var onConnectionRebuilt: (@Sendable () async -> Void)? { get set }

    /// True once at least one consecutive-call-timeout has been recorded
    /// against the current client generation and no success has reset it
    /// yet. Drives the app-side degraded-mode fast probe: a second drain
    /// loop runs on a much shorter interval only while this is true, closing
    /// the gap between "wedge detected" and "rebuilt client actually
    /// exercised." Default `false` via the extension below.
    var isConnectionDegraded: Bool { get }
}

/// Default no-op so pre-existing `ConvexServiceProtocol` fakes (test doubles
/// that predate `detachAuth()`) don't need to be touched just to keep
/// conforming. Only `LiveConvexService` needs a real implementation; a fake
/// that wants to assert on the call can still override it.
public extension ConvexServiceProtocol {
    func detachAuth() async {}

    /// Default: fall back to the plain bool validate and report no project-set
    /// change. `LiveConvexService` overrides this to decode the real signal;
    /// fakes/onboarding that only care about validity inherit this unchanged.
    func conductorValidateKeyDetailed() async throws -> ConductorValidateResult {
        ConductorValidateResult(ok: try await conductorValidateKey(), projectsChanged: false)
    }

    /// Default: no orgs. `LiveConvexService` overrides this to decode the
    /// real `orgs:list` response; a fake/test double that doesn't care about
    /// multi-org state inherits an empty list unchanged.
    func orgsList() async throws -> [OrgKeyInfo] { [] }

    /// Default: throws rather than silently no-op-succeeding. A fake that
    /// doesn't override this must not look like it added a key when nothing
    /// happened -- callers/tests that need `orgAddKey` to actually work
    /// override it explicitly.
    func orgAddKey(label: String, key: String) async throws -> OrgAddKeyResult {
        throw ConvexServiceError.requestFailed("orgAddKey not implemented by this ConvexServiceProtocol conformance")
    }

    /// Default: throws, same rationale as `orgAddKey` above -- a silent
    /// no-op here would hide a missing-fake bug (the caller would believe
    /// the org was removed when nothing happened).
    func orgRemove(orgId: String) async throws {
        throw ConvexServiceError.requestFailed("orgRemove not implemented by this ConvexServiceProtocol conformance")
    }

    /// Default: throws, same rationale as `orgAddKey` above.
    func orgRename(orgId: String, label: String) async throws {
        throw ConvexServiceError.requestFailed("orgRename not implemented by this ConvexServiceProtocol conformance")
    }

    /// Default no-op storage-less accessor so pre-existing fakes/test doubles
    /// don't need to be touched just to keep conforming (mirrors
    /// `detachAuth()`'s default above). Only `LiveConvexService` needs a real
    /// implementation.
    var onConnectionRebuilt: (@Sendable () async -> Void)? {
        get { nil }
        set {}
    }

    /// Default: a fake/test double is never "degraded" unless it overrides
    /// this itself.
    var isConnectionDegraded: Bool { false }
}

// MARK: - Supporting request/response shapes

/// The `users:me` response (canonical-accounts plan §4): backend-truth
/// identity for display, not a decoded JWT. `email` is absent for
/// identities that never carried one (e.g. a GitHub identity with email
/// privacy enabled) — callers fall back to `authSubject`.
public struct UserSelfSnapshot: Codable, Equatable, Sendable {
    public var email: String?
    public var authSubject: String

    public init(email: String?, authSubject: String) {
        self.email = email
        self.authSubject = authSubject
    }
}

/// The richer result of validating a Conductor API key (canonical-accounts):
/// besides `ok`, `projectsChanged` reports whether this key sees a different
/// set of Conductor projects than the previously-saved key — a heads-up that
/// the key may belong to a different Conductor account than the one the user
/// runs the Conductor app under. There is no Conductor whoami endpoint, so the
/// project set is the closest available identity proxy.
public struct ConductorValidateResult: Equatable, Sendable {
    public let ok: Bool
    public let projectsChanged: Bool

    public init(ok: Bool, projectsChanged: Bool) {
        self.ok = ok
        self.projectsChanged = projectsChanged
    }
}

/// The two Conductor deployments a stored key can be validated against
/// (staging-keys plan KTD2). Wire value is the lowercase raw string
/// ("prod"/"staging"), matching the backend's `ConductorEnvironment` union.
public enum ConductorEnvironment: String, Codable, Equatable, Sendable {
    case prod
    case staging
}

/// The result of `projects:setAndValidateKey` (staging-keys plan KTD3): probes
/// `key` against both Conductor hosts and, only on acceptance, atomically
/// stores the key + detected environment and seeds the projects cache
/// server-side. `environment`/`projectsChanged` are only meaningful when `ok`
/// is `true`; `error` only when `ok` is `false` — mirrors the action's own
/// `{ ok, environment?, projectsChanged?, error? }` response shape, so callers
/// never need to guess which fields are populated for which outcome.
public struct ConductorSetAndValidateResult: Equatable, Sendable {
    public let ok: Bool
    public let environment: ConductorEnvironment?
    public let projectsChanged: Bool
    public let error: String?

    public init(ok: Bool, environment: ConductorEnvironment?, projectsChanged: Bool, error: String?) {
        self.ok = ok
        self.environment = environment
        self.projectsChanged = projectsChanged
        self.error = error
    }
}

/// One user's labeled Conductor org key, masked (the raw key never leaves the
/// server) -- mirrors `orgs:list`'s `{ orgId, label, organizationName?,
/// displayName, lastFour, environment, createdAt }` response (multi-org
/// plan). Decoded via a custom `init(from:)`/`encode(to:)` pair, not
/// synthesized `Codable`: `createdAt` arrives as a raw ms-since-epoch number
/// on the wire (matching `ServerCaptureRecordWire`'s convention for every
/// other server timestamp), not an ISO-8601 string. Deliberately a plain,
/// non-float-boxing-tolerant `Codable` -- like `ServerCaptureRecord` vs
/// `ServerCaptureRecordWire` -- so literal-JSON tests can decode this type
/// directly without `ConvexMobile`; `LiveConvexService` decodes the
/// $float-tolerant `OrgKeyInfoWire` twin and maps into this type for the real
/// `orgs:list` call.
public struct OrgKeyInfo: Equatable, Sendable {
    public var orgId: String
    public var label: String
    public var organizationName: String?
    public var displayName: String
    public var lastFour: String
    public var environment: ConductorEnvironment
    public var createdAt: Date

    public init(
        orgId: String,
        label: String,
        organizationName: String? = nil,
        displayName: String,
        lastFour: String,
        environment: ConductorEnvironment,
        createdAt: Date
    ) {
        self.orgId = orgId
        self.label = label
        self.organizationName = organizationName
        self.displayName = displayName
        self.lastFour = lastFour
        self.environment = environment
        self.createdAt = createdAt
    }
}

extension OrgKeyInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case orgId, label, organizationName, displayName, lastFour, environment, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orgId = try container.decode(String.self, forKey: .orgId)
        label = try container.decode(String.self, forKey: .label)
        organizationName = try container.decodeIfPresent(String.self, forKey: .organizationName)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastFour = try container.decode(String.self, forKey: .lastFour)
        environment = try container.decode(ConductorEnvironment.self, forKey: .environment)
        let createdAtMs = try container.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(orgId, forKey: .orgId)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(organizationName, forKey: .organizationName)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(lastFour, forKey: .lastFour)
        try container.encode(environment, forKey: .environment)
        try container.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
    }
}

/// Result of `orgs:addKey` (multi-org plan): probes a key and, only on
/// acceptance, stores it as a NEW labeled org row. Mirrors
/// `ConductorSetAndValidateResult`'s split -- `orgId`/`environment`/
/// `projectsChanged` are only meaningful when `ok` is `true`; `error` only
/// when `ok` is `false`. Not itself `Codable` -- like
/// `ConductorSetAndValidateResult`, decoding goes through a private wire
/// twin (`OrgAddKeyActionResult`) that `LiveConvexService` maps into this
/// type.
public struct OrgAddKeyResult: Equatable, Sendable {
    public var ok: Bool
    public var orgId: String?
    public var environment: ConductorEnvironment?
    public var projectsChanged: Bool?
    public var error: String?

    public init(
        ok: Bool,
        orgId: String? = nil,
        environment: ConductorEnvironment? = nil,
        projectsChanged: Bool? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.orgId = orgId
        self.environment = environment
        self.projectsChanged = projectsChanged
        self.error = error
    }
}

/// Where a user manages their Conductor API keys — `app.conductor.build` for
/// a prod-environment key, `stage-app.conductor.build` for staging
/// (Roundhouse's own `api.` -> `app.` / `stage-api.` -> `stage-app.` host
/// mapping, R6). Shared by every dashboard-link call site (Onboarding's link,
/// Settings' link, Settings' rejected-key error text) so the environment-aware
/// URL choice lives in one place, not three inline ternaries. `nil`
/// environment (unknown yet, e.g. before a key has ever been accepted) falls
/// back to the prod URL.
public enum ConductorDashboardLink {
    public static func apiKeysURL(environment: ConductorEnvironment?) -> URL {
        switch environment {
        case .staging:
            URL(string: "https://stage-app.conductor.build/users/api-keys")!
        case .prod, nil:
            URL(string: "https://app.conductor.build/users/api-keys")!
        }
    }

    /// Display text matching `apiKeysURL`'s host, so a staging user never
    /// sees a link labeled "app.conductor.build" that actually opens
    /// `stage-app.conductor.build` underneath.
    public static func apiKeysLabel(environment: ConductorEnvironment?) -> String {
        switch environment {
        case .staging:
            "stage-app.conductor.build/users/api-keys"
        case .prod, nil:
            "app.conductor.build/users/api-keys"
        }
    }
}

public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public var defaultProjectId: String?
    public var agent: String
    public var model: String?
    public var screenshotsEnabled: Bool
    public var hasKey: Bool
    public var lastFour: String?
    /// The environment the stored key was last validated against (R4:
    /// absent/legacy rows default to prod). Non-optional here because the
    /// backend's `settings:get` always includes it — but decoded leniently
    /// (see `init(from:)`) so a client running slightly ahead of a backend
    /// rollout still decodes instead of throwing.
    public var environment: ConductorEnvironment

    public init(
        defaultProjectId: String?,
        agent: String,
        model: String?,
        screenshotsEnabled: Bool,
        hasKey: Bool,
        lastFour: String?,
        environment: ConductorEnvironment = .prod
    ) {
        self.defaultProjectId = defaultProjectId
        self.agent = agent
        self.model = model
        self.screenshotsEnabled = screenshotsEnabled
        self.hasKey = hasKey
        self.lastFour = lastFour
        self.environment = environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultProjectId = try container.decodeIfPresent(String.self, forKey: .defaultProjectId)
        agent = try container.decode(String.self, forKey: .agent)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        screenshotsEnabled = try container.decode(Bool.self, forKey: .screenshotsEnabled)
        hasKey = try container.decode(Bool.self, forKey: .hasKey)
        lastFour = try container.decodeIfPresent(String.self, forKey: .lastFour)
        environment = try container.decodeIfPresent(ConductorEnvironment.self, forKey: .environment) ?? .prod
    }
}

/// Tri-state patch value for a settings field that has a real "clear"
/// affordance in the UI (unlike `agent`/`screenshotsEnabled`, which have no
/// way to be cleared through the UI, so a plain `Optional` is enough for
/// them): `nil` means "leave untouched," `.set` writes a new value, `.clear`
/// explicitly unsets the field server-side. See `settingsUpdateArgs` for how
/// each case is encoded on the wire.
public enum SettingsFieldPatch<Value: Equatable & Sendable>: Equatable, Sendable {
    case set(Value)
    case clear
}

public struct SettingsPatch: Equatable, Sendable {
    public var defaultProjectId: SettingsFieldPatch<String>?
    public var agent: String?
    public var model: SettingsFieldPatch<String>?
    public var screenshotsEnabled: Bool?

    public init(
        defaultProjectId: SettingsFieldPatch<String>? = nil,
        agent: String? = nil,
        model: SettingsFieldPatch<String>? = nil,
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
    /// Which Conductor org key to attribute this capture to (multi-org
    /// plan) -- omitted from the wire entirely when `nil` (see
    /// `capturesCreateArgs`'s omit-vs-null note), letting the server fall
    /// back to its own single-org shim.
    public var orgId: String?

    public init(
        clientId: String,
        transcript: String,
        notes: String,
        screenshotStorageId: String?,
        projectId: String,
        projectName: String,
        agent: String,
        model: String?,
        capturedAt: Date,
        orgId: String? = nil
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
        self.orgId = orgId
    }
}

// MARK: - Connection self-healing: health tracker + auth-gate epoch
//
// Both types below are free of any ConvexMobile/convex-swift dependency
// (plain NSLock + closures), so they live outside the `canImport(ConvexMobile)`
// guard around `LiveConvexService` and are unit-testable without a live
// Convex client — see `ConvexReconnectTests`.

/// Detects a wedged Convex websocket via a generation-stamped consecutive-
/// timeout streak (see the "self-heal a wedged Convex connection" plan,
/// KTD1/KTD2/R2). Mirrors `ConvexAuthAttachmentGate`'s single-NSLock design.
///
/// Generation stamping is the load-bearing race fix: every authed call in
/// `LiveConvexService` captures `(client, generation)` together at entry
/// (`currentClient()`) and reports that SAME generation here at completion
/// via `recordOutcome(_:clientGeneration:)`. An outcome whose
/// `clientGeneration` no longer matches the tracker's current `generation`
/// is ignored entirely — neither increments nor resets — so a slow success
/// from an already-rebuilt-away client can't paper over a real wedge, and a
/// late timeout from an old client can't inflate the new generation's
/// counter or force a second, spurious rebuild.
final class ConvexConnectionHealthTracker: @unchecked Sendable {
    /// Outcome classification for one authed call, as judged by its caller:
    /// `.timedOut` for `requestFailed("operation timed out" | "query timed
    /// out waiting for a value" | "auth attach timed out")`; `.success` for
    /// any call that provably round-tripped (a real result, a server error,
    /// a decoding failure — the connection is alive); `.neutral` for a
    /// missing-token `notAuthenticated` (no network round-trip happened, so
    /// it says nothing about the connection's health).
    enum Outcome {
        case timedOut
        case success
        case neutral
    }

    private let lock = NSLock()
    private var consecutiveTimeouts = 0
    private var generation = 0
    private var lastRebuildAt: Date?
    private let threshold: Int
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - threshold: consecutive matching-generation timeouts required to
    ///     trip a rebuild. 2 (not 3) — safe because of the generation guard
    ///     above; saves a full periodic-drain cycle of recovery latency.
    ///   - cooldown: minimum wall-clock time between rebuilds. Belt-and-
    ///     suspenders behind the generation guard, not the primary storm
    ///     defense (the guard already makes concurrent double-trips
    ///     impossible under the lock).
    ///   - now: injectable clock so cooldown behavior is deterministic in
    ///     tests.
    init(
        threshold: Int = 2,
        cooldown: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.threshold = threshold
        self.cooldown = cooldown
        self.now = now
    }

    /// Snapshot together with `LiveConvexService.client` under its own lock
    /// (see `currentClient()`) so every authed call's `(client, generation)`
    /// pair is internally consistent even as `rebuildClient()` swaps both.
    var currentGeneration: Int {
        lock.withLock { generation }
    }

    /// True once at least one timeout has been recorded against the current
    /// generation and no success has reset it yet. Drives the app-side
    /// degraded-mode fast probe (U5) — cheap to poll from any thread.
    var isDegraded: Bool {
        lock.withLock { consecutiveTimeouts >= 1 }
    }

    /// Records one call's outcome, stamped with the generation it ran
    /// against. Returns `true` exactly when the caller should rebuild the
    /// client now (threshold crossed AND cooldown elapsed since the last
    /// rebuild) — the caller is responsible for actually rebuilding.
    @discardableResult
    func recordOutcome(_ outcome: Outcome, clientGeneration: Int) -> Bool {
        lock.withLock {
            guard clientGeneration == generation else {
                // Stale generation: this outcome ran against a client that
                // has already been rebuilt away. Neither increments nor
                // resets — see the type doc above for why.
                return false
            }
            switch outcome {
            case .neutral:
                return false
            case .success:
                consecutiveTimeouts = 0
                return false
            case .timedOut:
                consecutiveTimeouts += 1
                guard consecutiveTimeouts >= threshold else { return false }
                if let lastRebuildAt, now().timeIntervalSince(lastRebuildAt) < cooldown {
                    return false
                }
                return true
            }
        }
    }

    /// Called by `rebuildClient()` in the SAME lock acquisition that swaps
    /// `LiveConvexService.client`, so `currentClient()`'s (client,
    /// generation) snapshot can never observe half of an old pair and half
    /// of a new one. Bumps the generation, zeroes the counter, stamps the
    /// cooldown clock, and returns the new generation for logging.
    func noteRebuilt() -> Int {
        lock.withLock {
            generation += 1
            consecutiveTimeouts = 0
            lastRebuildAt = now()
            return generation
        }
    }
}

/// Serializes "attach auth once; re-attempt after failure" semantics for
/// `LiveConvexService`. Internal (not private) so the sequencing regression
/// can be unit-tested without a live Convex client.
///
/// Epoch compare-and-set (KTD4/R3): a rebuild's `reset()` bumps `epoch` so an
/// `ensureAuthAttached` call that started its `attach()` against the OLD
/// client (before the rebuild) cannot latch `attached = true` after the
/// rebuild completes — that would silently re-wedge every future call into
/// `NotAuthenticatedError` forever, because the NEW client would never get a
/// chance to attach. `runIfNeeded` captures `epoch` before running `attach`
/// and only latches if `epoch` is unchanged when `attach()` returns;
/// otherwise it discards the result (even a `true` one) and the next call
/// re-attempts against the current epoch/client.
final class ConvexAuthAttachmentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var attached = false
    private var epoch = 0

    /// Runs `attach` unless a prior attempt already succeeded (and no
    /// `reset()` has run since). Returns the overall attached state. A
    /// failed attempt, or one whose epoch moved mid-flight, leaves the gate
    /// open so the next call re-attempts.
    func runIfNeeded(_ attach: () async -> Bool) async -> Bool {
        let startEpoch: Int? = lock.withLock { attached ? nil : epoch }
        guard let startEpoch else { return true }
        let success = await attach()
        return lock.withLock {
            guard epoch == startEpoch else {
                // `reset()` ran during `attach()` (a rebuild happened
                // mid-flight) — discard this result even if it was `true`;
                // the next call re-attaches against the new epoch/client.
                return false
            }
            if success {
                attached = true
            }
            return success
        }
    }

    /// Forces the next `runIfNeeded` call to re-attempt `attach`, even if a
    /// prior attempt already succeeded, and bumps `epoch` so any attach
    /// already in flight against the pre-reset state cannot latch. Called on
    /// sign-out (via `detachAuth()`) and on every client rebuild
    /// (`rebuildClient()`) so a later sign-in or a post-rebuild call can't
    /// short-circuit on stale `attached == true` state.
    func reset() {
        lock.withLock {
            attached = false
            epoch &+= 1
        }
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
    /// Testable seam abstracting exactly the convex-swift surface
    /// `LiveConvexService` uses (mutation/action/subscribe/loginFromCache/
    /// logout/watchWebSocketState), so `ConvexReconnectTests` can inject a
    /// fake/hanging client and drive `rebuildClient()` deterministically
    /// without a live server — the "thorough" seam from the reconnect design
    /// doc, R5/§5. `ConvexClientWithAuth<String>` conforms via the extension
    /// below with no extra glue: every requirement is already present on the
    /// real type (`mutation`/`action`/`subscribe`/`watchWebSocketState` from
    /// `ConvexClient`, `loginFromCache`/`logout` from `ConvexClientWithAuth`
    /// itself).
    protocol ConvexClientAdapter: Sendable {
        func mutation<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]?) async throws -> T
        func mutation(_ name: String, with args: [String: ConvexEncodable?]?) async throws
        func action<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]?) async throws -> T
        func action(_ name: String, with args: [String: ConvexEncodable?]?) async throws
        func subscribe<T: Decodable>(
            to name: String, with args: [String: ConvexEncodable?]?, yielding output: T.Type?
        ) -> AnyPublisher<T, ClientError>
        func loginFromCache() async -> Result<String, Error>
        func logout() async
        func watchWebSocketState() -> AnyPublisher<WebSocketState, Never>
    }

    extension ConvexClientWithAuth: ConvexClientAdapter, @retroactive @unchecked Sendable where T == String {}

    public final class LiveConvexService: ConvexServiceProtocol, @unchecked Sendable {
        /// Mutable (not `let`): `rebuildClient()` swaps this in under `lock`
        /// when the health tracker detects a wedge. Every call site must
        /// snapshot `(client, generation)` together ONCE at entry via
        /// `currentClient()` and capture that snapshot in its escaping
        /// closure — never read `self.client` inside a `withTimeout`/
        /// subscribe closure (R5's load-bearing snapshot rule): a leaked
        /// hung task from before a rebuild must never touch the new client.
        private var client: any ConvexClientAdapter
        /// Builds a fresh client on demand (captures `deploymentUrl` +
        /// the auth bridge internally). Also the test seam: `init(makeClient:)`
        /// lets `ConvexReconnectTests` inject a fake/hanging client and
        /// drive `rebuildClient()` deterministically without a live server.
        private let makeClient: @Sendable () -> any ConvexClientAdapter
        private let authGate = ConvexAuthAttachmentGate()
        private let healthTracker: ConvexConnectionHealthTracker
        /// Publishes the client generation on every `rebuildClient()`, so the
        /// `asyncStream` resubscribe loop (U4) can wait for "either the
        /// server naturally ends this subscription, or the client got
        /// rebuilt out from under it" without polling.
        private let generationSubject = CurrentValueSubject<Int, Never>(0)
        private var cancellables: Set<AnyCancellable> = []
        private let lock = NSLock()

        /// Set by the app after construction (`WhistleApp` wires this to
        /// `drainSyncIfSignedIn()`) and fired once, asynchronously, at the
        /// end of every `rebuildClient()` — see the protocol doc.
        public var onConnectionRebuilt: (@Sendable () async -> Void)?

        public var isConnectionDegraded: Bool { healthTracker.isDegraded }

        /// - Parameters:
        ///   - deploymentUrl: Convex deployment URL (dashboard → Settings).
        ///   - authProvider: WhistleCore's own auth seam. Bridged internally
        ///     into convex-swift's `AuthProvider<String>` shape.
        public convenience init(deploymentUrl: String, authProvider: any WhistleAuthProvider) {
            let bridge = WhistleToConvexAuthProviderBridge(authProvider: authProvider)
            self.init(makeClient: {
                ConvexClientWithAuth(deploymentUrl: deploymentUrl, authProvider: bridge)
            })
        }

        /// Internal factory seam (not `private`) so tests can construct a
        /// `LiveConvexService` around a fake `ConvexClientAdapter` and drive
        /// rebuild deterministically. `healthTracker` is also injectable so
        /// tests can use a short threshold/cooldown/fake clock, and
        /// `authedCallTimeout` so tests can exercise a REAL (short) hang
        /// through `ensureAuthAttached`/`authedMutation`/etc. instead of only
        /// simulating a timeout's error shape; production uses the
        /// documented defaults (threshold 2, cooldown 60s, timeout 15s).
        init(
            makeClient: @escaping @Sendable () -> any ConvexClientAdapter,
            healthTracker: ConvexConnectionHealthTracker = ConvexConnectionHealthTracker(),
            authedCallTimeout: Duration = .seconds(15)
        ) {
            self.makeClient = makeClient
            self.client = makeClient()
            self.healthTracker = healthTracker
            self.authedCallTimeout = authedCallTimeout
            watchWebSocketState(generation: healthTracker.currentGeneration)
        }

        /// Snapshots `(client, generation)` together under `lock`, so the
        /// pair is always internally consistent with whatever
        /// `rebuildClient()` last swapped in — see `ConvexConnectionHealthTracker.noteRebuilt()`.
        private func currentClient() -> (client: any ConvexClientAdapter, generation: Int) {
            lock.withLock { (client, healthTracker.currentGeneration) }
        }

        /// Discards the current (wedged) client and builds a fresh one via
        /// `makeClient`, re-attaching auth on the next call (KTD3). Does
        /// **not** call `client.logout()` on the old client — that's another
        /// FFI call into a dead socket; the old reference is simply dropped
        /// and any of its leaked in-flight tasks settle (or don't) on their
        /// own, per `withTimeout`'s single-resume race arbiter.
        private func rebuildClient() {
            let newGeneration = lock.withLock { () -> Int in
                client = makeClient()
                return healthTracker.noteRebuilt()
            }
            // The new client has no auth attached; reset the gate (and bump
            // its own epoch, KTD4) so the very next authed call re-runs
            // `loginFromCache()` against the new client rather than
            // short-circuiting on the old client's stale `attached == true`.
            authGate.reset()
            NSLog(
                "Whistle: Convex client wedged (%d consecutive timeouts) — rebuilt client (generation %d)",
                Self.rebuildThreshold, newGeneration
            )
            watchWebSocketState(generation: newGeneration)
            // Wakes any `asyncStream` resubscribe loops (U4) waiting on the
            // old generation, so long-lived subscriptions heal without a
            // History/Settings/Projects flash.
            generationSubject.send(newGeneration)
            if let onConnectionRebuilt {
                Task { await onConnectionRebuilt() }
            }
        }

        /// Consecutive-timeout threshold used only for the log line above —
        /// the real threshold lives inside `healthTracker` (KTD1: 2).
        private static let rebuildThreshold = 2

        /// Subscribes to `client.watchWebSocketState()` for diagnostics only
        /// (KTD7/R7): logs every transition tagged with the client
        /// generation it belongs to. NOT a rebuild trigger — `WebSocketState`
        /// has no `.disconnected` case and is a no-replay `PassthroughSubject`,
        /// so a "stuck in `.connecting`" accelerant would rest on an
        /// unverified assumption. The next wedge's `log show` output decides
        /// empirically whether that's worth adding later.
        private func watchWebSocketState(generation: Int) {
            let (client, _) = currentClient()
            let cancellable = client.watchWebSocketState()
                .sink { state in
                    NSLog("Whistle: Convex websocket state (generation %d): %@", generation, String(describing: state))
                }
            lock.withLock { _ = cancellables.insert(cancellable) }
        }

        /// Records one authed call's outcome against the generation it ran
        /// on, and rebuilds the client if the tracker says a wedge has been
        /// detected. Shared by `ensureAuthAttached`, `authedMutation`,
        /// `authedAction`, and `authedQuery`'s catch/success paths.
        private func noteOutcome(_ outcome: ConvexConnectionHealthTracker.Outcome, generation: Int) {
            if healthTracker.recordOutcome(outcome, clientGeneration: generation) {
                rebuildClient()
            }
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
            // Snapshot ONCE at entry (R5) — the closure below must never
            // read `self.client`, only this snapshot, so a leaked attach
            // from a since-rebuilt-away client can't touch the current one.
            let (client, generation) = currentClient()
            // `ConvexAuthAttachmentGate.runIfNeeded`'s closure is
            // non-throwing, so a timeout is recorded here via this flag
            // rather than thrown from inside the closure — checked after
            // `runIfNeeded` returns, below, to implement KTD6's error split
            // (timeout -> `.requestFailed`, token failure -> `.notAuthenticated`).
            var timedOut = false
            let attached = await authGate.runIfNeeded {
                // `loginFromCache()` is itself a network-touching call with
                // no internal timeout; a hang here (before `withTimeout` ever
                // wraps the mutation/action below) would wedge syncing just
                // like a hung mutation once did. Bound it too, so a stuck
                // login defers (revert-to-`.queued` via `.notAuthenticated`)
                // instead of blocking the drain forever.
                do {
                    let result = try await Self.withTimeout(authedCallTimeout) {
                        await client.loginFromCache()
                    }
                    switch result {
                    case .success:
                        self.noteOutcome(.success, generation: generation)
                        return true
                    case let .failure(error):
                        NSLog("Whistle: attaching auth to Convex client failed: %@", String(describing: error))
                        // Genuine token/login rejection — no network round-
                        // trip failure to count, and definitely not a
                        // transport timeout (KTD6).
                        self.noteOutcome(.neutral, generation: generation)
                        return false
                    }
                } catch {
                    NSLog("Whistle: attaching auth to Convex client timed out: %@", String(describing: error))
                    self.noteOutcome(.timedOut, generation: generation)
                    timedOut = true
                    return false
                }
            }
            guard attached else {
                // KTD6: stop conflating transport-timeout with token-failure.
                // A genuine outage would otherwise repeatedly reset the gate
                // (every rebuild) and re-surface as `.notAuthenticated`,
                // driving `onAuthDeferred` -> a spurious "sign in again"
                // prompt. Only a real token/login rejection (or an
                // epoch-discarded attach, KTD4) throws `.notAuthenticated`;
                // the timeout branch throws `.requestFailed` instead, which
                // `SyncEngine` treats as an ordinary retryable `.syncFailed`.
                if timedOut {
                    throw ConvexServiceError.requestFailed("auth attach timed out")
                }
                throw ConvexServiceError.notAuthenticated
            }
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
            // Was calling `client.mutation` directly, bypassing
            // `authedMutation`'s `Self.withTimeout` wrap -- interactive
            // sign-in (which calls this right after Auth0 stores
            // credentials) could hang indefinitely on a stuck network call
            // instead of timing out into a retry like every other mutation.
            try await authedMutation("users:ensure")
        }

        /// `users:me` is a query (backend-truth identity for Settings'
        /// account tab, canonical-accounts plan §4) — routed through
        /// `authedQuery` like `settingsGet`, not `authedMutation` like
        /// `usersEnsure` above.
        public func usersMe() async throws -> UserSelfSnapshot {
            try await authedQuery("users:me")
        }

        // MARK: auth lifecycle

        /// `client.logout()` (convex-swift's own, not `WhistleAuthProvider`'s)
        /// calls the bridge's `logout()` (a no-op -- WhistleCore never owns
        /// credential storage), clears convex-swift's internal auth bridge,
        /// and tears down the websocket's auth callback; it never throws
        /// (internal errors are swallowed there, not surfaced to us). The
        /// gate reset is what actually matters for correctness: without it,
        /// `ensureAuthAttached()`'s `runIfNeeded` would see `attached == true`
        /// left over from the previous session and skip re-attaching
        /// entirely, so the very next authenticated call after a fresh
        /// sign-in would ride on convex-swift's already-torn-down (or,
        /// worse, still-live) previous-session attachment instead of pulling
        /// a fresh token via `loginFromCache()`.
        public func detachAuth() async {
            // `client.logout()` is the one Convex call this file previously
            // left unwrapped -- a wedged/non-cancellation-aware FFI logout
            // (the same class of hang `withTimeout` exists to bound; see
            // below) would await here forever. The reauth path
            // (`AuthController.signIn()`) calls `detachAuth()` while
            // `state == .signingIn`, guarded against re-entry, so a hang here
            // would permanently strand sign-in until an app relaunch. Bound
            // it like every other Convex call, and ALWAYS reset the gate
            // afterward regardless of whether logout completed or timed out
            // -- a stuck logout must not also leave the attach gate latched
            // to the old session.
            let (client, _) = currentClient()
            _ = try? await Self.withTimeout(authedCallTimeout) {
                await client.logout()
            }
            authGate.reset()
        }

        // MARK: - Authenticated call helpers (attach auth, then call)

        /// Upper bound on how long an authenticated mutation/action (and the
        /// `loginFromCache()` attach) may block the caller. `Self.withTimeout`
        /// enforces this as a real bound — it returns the instant this
        /// elapses even if the underlying convex-swift FFI call never checks
        /// cancellation (see `withTimeout`). This is what prevents a hung call
        /// from permanently wedging `SyncEngine`'s `isDraining` reentrancy
        /// guard, the failure that once left captures unsynced for 20+ hours
        /// until an app relaunch. 15s (the production default) is generous
        /// for a real slow network yet short enough that a genuine hang
        /// self-resolves into a retry quickly. Instance property (not
        /// `static let`) so `init(makeClient:healthTracker:authedCallTimeout:)`
        /// can inject a short duration for tests.
        private let authedCallTimeout: Duration

        /// Classifies a call's thrown error for the health tracker (shared by
        /// `authedMutation`/`authedAction`/`authedQuery`'s catch arms):
        /// `requestFailed` whose message mentions a timeout counts as
        /// `.timedOut`; anything else (a real result path never reaches
        /// here, decoding failures, backend/`ConvexError` rejections
        /// including a server-side `NotAuthenticatedError`) proves the
        /// connection round-tripped, so it counts as `.success` — see KTD1's
        /// COUNT/RESET rules.
        private static func classifyOutcome(_ error: Error) -> ConvexConnectionHealthTracker.Outcome {
            if case let .requestFailed(message)? = error as? ConvexServiceError,
               message.contains("timed out")
            {
                return .timedOut
            }
            return .success
        }

        private func authedMutation<T: Decodable>(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws -> T {
            try await ensureAuthAttached()
            let (client, generation) = currentClient()
            do {
                let result: T = try await Self.withTimeout(authedCallTimeout) {
                    try await client.mutation(name, with: args)
                }
                noteOutcome(.success, generation: generation)
                return result
            } catch {
                NSLog("Whistle: Convex mutation %@ failed: %@", name, String(describing: error))
                noteOutcome(Self.classifyOutcome(error), generation: generation)
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
            let (client, generation) = currentClient()
            do {
                let result: T = try await Self.withTimeout(authedCallTimeout) {
                    try await client.action(name, with: args)
                }
                noteOutcome(.success, generation: generation)
                return result
            } catch {
                NSLog("Whistle: Convex action %@ failed: %@", name, String(describing: error))
                noteOutcome(Self.classifyOutcome(error), generation: generation)
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
            let (client, generation) = currentClient()
            do {
                let result: T = try await Self.firstValue(
                    from: client.subscribe(to: name, with: args, yielding: T.self)
                )
                noteOutcome(.success, generation: generation)
                return result
            } catch {
                NSLog("Whistle: Convex query %@ failed: %@", name, String(describing: error))
                noteOutcome(Self.classifyOutcome(error), generation: generation)
                throw Self.mapAuthError(error)
            }
        }

        // MARK: settings

        public func settingsGet() async throws -> SettingsSnapshot {
            try await authedQuery("settings:get")
        }

        public func settingsUpdate(_ patch: SettingsPatch) async throws {
            try await authedMutation("settings:update", with: Self.settingsUpdateArgs(patch))
        }

        /// Builds the `settings:update` argument dict, omitting unset fields
        /// entirely rather than sending them as `null`. Every field is
        /// `v.optional(...)` on the backend specifically so a partial patch
        /// can update just one field and leave the rest untouched — but a
        /// nil-valued dict entry serializes as literal JSON `null`, which
        /// `v.optional(...)` rejects. Extracted as a pure, `internal` static
        /// function so the omit-vs-null encoding (a real production fix) is
        /// unit-testable without a live `ConvexClient`; see
        /// `ConvexArgEncodingTests`.
        ///
        /// `defaultProjectId`/`model` are tri-state (`SettingsFieldPatch`):
        /// `nil` omits the key (leave untouched), `.set(v)` sends the value,
        /// and `.clear` sends an explicit key-present-with-`nil` entry, which
        /// serializes to JSON `null` — the backend's `v.optional(v.union(...,
        /// v.null()))` args treat that `null` as "unset this field" (see
        /// `settings.ts`'s `update` mutation), distinct from the key being
        /// absent entirely.
        static func settingsUpdateArgs(_ patch: SettingsPatch) -> [String: ConvexEncodable?] {
            var args: [String: ConvexEncodable?] = [:]
            encodeTriState(patch.defaultProjectId, forKey: "defaultProjectId", into: &args)
            if let agent = patch.agent {
                args["agent"] = agent
            }
            encodeTriState(patch.model, forKey: "model", into: &args)
            if let screenshotsEnabled = patch.screenshotsEnabled {
                args["screenshotsEnabled"] = screenshotsEnabled
            }
            return args
        }

        /// Encodes one tri-state field: absent (`nil`) omits the key,
        /// `.set` stores the value, `.clear` stores the key mapped to a nil
        /// value. For `.clear`, NOT `args[key] = nil` -- Dictionary's
        /// subscript setter treats assigning `nil` as *removing* the key,
        /// even though `Value` here (`ConvexEncodable?`) is itself optional.
        /// `updateValue(_:forKey:)` doesn't have that special-case, so it
        /// actually stores the key mapped to a nil value, which is what we
        /// need to encode explicit JSON `null` (the backend's clear
        /// sentinel).
        private static func encodeTriState(
            _ field: SettingsFieldPatch<String>?,
            forKey key: String,
            into args: inout [String: ConvexEncodable?]
        ) {
            switch field {
            case .set(let value):
                args[key] = value
            case .clear:
                args.updateValue(nil, forKey: key)
            case nil:
                break
            }
        }

        // MARK: conductor

        public func conductorValidateKey() async throws -> Bool {
            // NOTE: this action lives in `projects.ts` on the backend (there
            // is no `conductor` Convex module — `conductorClient.ts` is a
            // plain helper, not a functions file), so the wire name is
            // "projects:validateKey", not "conductor:validateKey" (the
            // latter throws "Could not find function" on every call). The
            // handler also returns `{ ok, error? }`, not a bare bool. Clean
            // break (KTD6): `validateKey` no longer takes an `apiKey` arg at
            // all — it re-checks whichever key is already stored, against
            // its stored environment — so no args dict is sent.
            let result: ConductorActionResult = try await authedAction("projects:validateKey")
            return result.ok
        }

        public func conductorValidateKeyDetailed() async throws -> ConductorValidateResult {
            // Same wire call as `conductorValidateKey` (see the note there), but
            // surfaces the `changedFromPrevious` field the Settings key flow
            // uses to warn about a possible different-account key.
            let result: ConductorActionResult = try await authedAction("projects:validateKey")
            return ConductorValidateResult(
                ok: result.ok,
                projectsChanged: result.changedFromPrevious ?? false
            )
        }

        /// Atomic probe-store-seed action (KTD3): probes `key` against prod
        /// then staging and, only on acceptance, stores the key + detected
        /// environment and seeds `projectsCache` server-side in one action —
        /// replacing the old client-side validate-then-`settingsSetConductorKey`
        /// two-step in both key-entry flows.
        public func conductorSetAndValidateKey(key: String) async throws -> ConductorSetAndValidateResult {
            let result: ConductorSetAndValidateActionResult = try await authedAction(
                "projects:setAndValidateKey", with: ["apiKey": key]
            )
            return ConductorSetAndValidateResult(
                ok: result.ok,
                environment: result.environment,
                projectsChanged: result.projectsChanged ?? false,
                error: result.error
            )
        }

        public func conductorRefreshProjects() async throws {
            // Same module-name correction as `conductorValidateKey` above;
            // also decodes the actual `{ ok, error? }` response shape
            // instead of the previous `String?` guess (which would have
            // thrown a decoding error on every successful call).
            let _: ConductorActionResult = try await authedAction("projects:refreshProjects")
        }

        // MARK: orgs (multi-org plan)

        public func orgsList() async throws -> [OrgKeyInfo] {
            // See `capturesListRecent` above for the same wire/public split:
            // decodes the raw, $float-tolerant wire shape, then maps to the
            // public model.
            let wireInfos: [OrgKeyInfoWire] = try await authedQuery("orgs:list")
            return wireInfos.map(\.asInfo)
        }

        public func orgAddKey(label: String, key: String) async throws -> OrgAddKeyResult {
            let result: OrgAddKeyActionResult = try await authedAction(
                "orgs:addKey", with: ["label": label, "apiKey": key]
            )
            return OrgAddKeyResult(
                ok: result.ok,
                orgId: result.orgId,
                environment: result.environment,
                projectsChanged: result.projectsChanged,
                error: result.error
            )
        }

        public func orgRemove(orgId: String) async throws {
            try await authedMutation("orgs:remove", with: ["orgId": orgId])
        }

        public func orgRename(orgId: String, label: String) async throws {
            try await authedMutation("orgs:rename", with: ["orgId": orgId, "label": label])
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
            try await authedMutation("captures:create", with: Self.capturesCreateArgs(input))
        }

        /// Builds the `captures:create` argument dict, omitting the optional
        /// fields (`screenshotId`/`model`/`orgId`) entirely when nil rather
        /// than including them with a `nil` value. The backend validator is
        /// `v.optional(...)`, which only tolerates the key being ABSENT --
        /// convex-swift's dictionary encoder has no way to express "omit this
        /// key," so a nil-valued entry always serializes as the literal JSON
        /// `null`, which `v.optional(...)` rejects (`ArgumentValidationError`,
        /// observed in production: every capture with no model/screenshot was
        /// failing to sync). Extracted as a pure, `internal` static function
        /// so this encoding is unit-testable without a live `ConvexClient`;
        /// see `ConvexArgEncodingTests`.
        static func capturesCreateArgs(_ input: CaptureCreateInput) -> [String: ConvexEncodable?] {
            var args: [String: ConvexEncodable?] = [
                "clientId": input.clientId,
                "transcript": input.transcript,
                "notes": input.notes,
                "projectId": input.projectId,
                "projectName": input.projectName,
                "agent": input.agent,
                "capturedAt": input.capturedAt.timeIntervalSince1970 * 1000,
            ]
            if let screenshotId = input.screenshotStorageId {
                args["screenshotId"] = screenshotId
            }
            if let model = input.model {
                args["model"] = model
            }
            if let orgId = input.orgId {
                args["orgId"] = orgId
            }
            return args
        }

        public func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]> {
            // `limit` MUST encode as a float64: the backend validator is
            // `v.float64()` and convex-swift encodes Swift `Int` as an
            // `$integer` (bigint), which Convex rejects with an
            // ArgumentValidationError (observed repeatedly in deployment
            // logs before this was fixed).
            //
            // Subscribes yielding the RAW wire shape (`ServerCaptureRecordWire`
            // — `_id`, ms-epoch float64 dates) rather than `ServerCaptureRecord`
            // directly: `ServerCaptureRecord`'s synthesized `Codable` expects
            // `id` and iso8601 dates (a contract `CaptureStore.history_cache`
            // depends on), so decoding a live Convex document straight into it
            // threw `keyNotFound` on every payload — the root cause of History
            // rows getting stuck on "Queued" forever. This wraps the wire
            // stream in a small mapping `AsyncStream` so callers keep seeing
            // `[ServerCaptureRecord]`.
            let wireStream: AsyncStream<[ServerCaptureRecordWire]> = asyncStream(
                subscribingTo: "captures:listRecent", args: ["limit": Double(limit)]
            )
            return AsyncStream { continuation in
                let mappingTask = Task {
                    for await wireRecords in wireStream {
                        continuation.yield(wireRecords.map(\.asRecord))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in mappingTask.cancel() }
            }
        }

        public func capturesList() async throws -> [ServerCaptureRecord] {
            // See `capturesListRecent` above: decodes the raw wire shape,
            // then maps to the public model.
            let wireRecords: [ServerCaptureRecordWire] = try await authedQuery("captures:list")
            return wireRecords.map(\.asRecord)
        }

        public func capturesGet(id: String) async throws -> ServerCaptureRecord? {
            // Arg key fixed to match the backend validator (`captures.get`
            // takes `captureId`, not `id`) — this had to be corrected
            // alongside the call-type fix, since routing this to the right
            // endpoint but with the wrong arg name would still fail with an
            // ArgumentValidationError. Also decodes the raw wire shape (see
            // `capturesListRecent` above) rather than `ServerCaptureRecord`
            // directly.
            let wireRecord: ServerCaptureRecordWire? = try await authedQuery(
                "captures:get", with: ["captureId": id]
            )
            return wireRecord?.asRecord
        }

        public func capturesRetry(id: String) async throws {
            // Arg key fixed to match the backend validator (`captures.retry`
            // takes `captureId`, not `id`) -- same class of bug as
            // `capturesGet` above: the call would otherwise fail with an
            // ArgumentValidationError regardless of routing to the right
            // endpoint.
            try await authedMutation("captures:retry", with: ["captureId": id])
        }

        public func capturesDeleteScreenshot(id: String) async throws {
            try await authedMutation("captures:deleteScreenshot", with: ["captureId": id])
        }

        public func capturesMarkOpened(id: String) async throws {
            try await authedMutation("captures:markOpened", with: ["captureId": id])
        }

        public func capturesArchive(id: String) async throws {
            try await authedMutation("captures:archive", with: ["captureId": id])
        }

        // MARK: - Combine -> AsyncStream bridge

        /// Single-resume arbiter for one subscribe-iteration of the
        /// resubscribing bridge below: whichever happens first — the
        /// server naturally ending this subscription (`.completed`), or a
        /// rebuild bumping the generation out from under it (`.rebuilt`) —
        /// wins and delivers its outcome. Mirrors `TimeoutState`'s
        /// single-resume design but for a non-throwing two-way race.
        private final class SubscriptionRaceState: @unchecked Sendable {
            enum Outcome { case completed, rebuilt }
            private let lock = NSLock()
            private var result: Outcome?
            private var continuation: CheckedContinuation<Outcome, Never>?

            func finish(_ outcome: Outcome) {
                let waiting: CheckedContinuation<Outcome, Never>? = lock.withLock {
                    guard result == nil else { return nil }
                    result = outcome
                    defer { continuation = nil }
                    return continuation
                }
                waiting?.resume(returning: outcome)
            }

            func value() async -> Outcome {
                await withCheckedContinuation { cont in
                    let ready: Outcome? = lock.withLock {
                        if let result { return result }
                        continuation = cont
                        return nil
                    }
                    if let ready { cont.resume(returning: ready) }
                }
            }
        }

        /// Bridges convex-swift's Combine `subscribe` into an `AsyncStream`,
        /// and — implementing U4's generation-aware resubscribe — heals a
        /// long-lived subscription across a `rebuildClient()` without ever
        /// finishing the continuation. A wedge would otherwise leave
        /// `projectsList()`/`capturesListRecent()` subscribers silently
        /// stale forever (they're bound to the dead pre-rebuild client and
        /// never go through `withTimeout`, so they never time out either —
        /// see the plan's R1 latency walk-through). Convex redelivers the
        /// full current query result on every (re)subscribe, and consumers
        /// (`HistoryViewModel.handleServerRecords` etc.) replace their
        /// snapshot wholesale, so resubscribing on the new client restores
        /// correct state within one round trip with no duplicate/cleared
        /// emission (R6) — zero changes needed in any consumer.
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
                    while !Task.isCancelled {
                        // Snapshot ONCE per resubscribe iteration (R5) — the
                        // sink closure below must never read `self.client`.
                        let (client, generation) = self.currentClient()
                        // Best-effort auth attach BEFORE subscribing, so
                        // authenticated queries don't land on the websocket
                        // without a JWT. An unauthenticated subscribe still
                        // goes through (matching prior behavior for the
                        // signed-out state); the server then rejects it and
                        // the subscription completes below.
                        try? await self.ensureAuthAttached()
                        if Task.isCancelled { break }

                        let raceState = SubscriptionRaceState()
                        let cancellable = client.subscribe(to: name, with: args, yielding: T.self)
                            .sink(
                                receiveCompletion: { completion in
                                    if case let .failure(error) = completion {
                                        NSLog(
                                            "Whistle: Convex subscription %@ failed: %@",
                                            name, String(describing: error)
                                        )
                                    }
                                    raceState.finish(.completed)
                                },
                                receiveValue: { value in continuation.yield(value) }
                            )
                        self.lock.withLock { _ = self.cancellables.insert(cancellable) }

                        // Race the subscription's own natural completion
                        // against a generation change (a rebuild). Cancelling
                        // this task (stream consumer went away) must also
                        // stop the wait promptly, so a completed-looking
                        // outcome is forced on cancellation.
                        let outcome = await withTaskCancellationHandler(
                            operation: { () async -> SubscriptionRaceState.Outcome in
                                let watchTask = Task {
                                    for await latestGeneration in self.generationSubject.values {
                                        if latestGeneration != generation {
                                            raceState.finish(.rebuilt)
                                            return
                                        }
                                    }
                                }
                                defer { watchTask.cancel() }
                                return await raceState.value()
                            },
                            onCancel: { raceState.finish(.completed) }
                        )

                        self.lock.withLock { _ = self.cancellables.remove(cancellable) }
                        cancellable.cancel()

                        switch outcome {
                        case .completed:
                            continuation.finish()
                            return
                        case .rebuilt:
                            // Loop and resubscribe on the new client — the
                            // continuation stays open, so consumers never
                            // see this as a finished stream.
                            continue
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    subscriptionTask.cancel()
                }
            }
        }

        // MARK: - Bounded-wait helper (shared by mutations/actions/queries)

        /// Single-resume race arbiter for `withTimeout`: whichever of the
        /// two racing tasks (the real work, or the timeout timer) finishes
        /// first delivers its result to the awaiting caller; the loser's
        /// later result is dropped. Thread-safe because the two tasks run
        /// concurrently on the global executor.
        private final class TimeoutState<T: Sendable>: @unchecked Sendable {
            private let lock = NSLock()
            private var result: Result<T, Error>?
            private var continuation: CheckedContinuation<T, Error>?

            /// Called by both racers; only the first call wins.
            func finish(_ outcome: Result<T, Error>) {
                let waiting: CheckedContinuation<T, Error>? = lock.withLock {
                    guard result == nil else { return nil }
                    result = outcome
                    defer { continuation = nil }
                    return continuation
                }
                waiting?.resume(with: outcome)
            }

            /// Awaited exactly once by `withTimeout`. Returns as soon as the
            /// first racer finishes — it does NOT await the loser, which is
            /// the whole point (see `withTimeout`).
            func value() async throws -> T {
                try await withCheckedThrowingContinuation { cont in
                    let ready: Result<T, Error>? = lock.withLock {
                        if let result { return result }
                        continuation = cont
                        return nil
                    }
                    if let ready { cont.resume(with: ready) }
                }
            }
        }

        /// Races `operation` against `timeout`, throwing
        /// `ConvexServiceError.requestFailed(timeoutMessage)` if the timeout
        /// elapses first. Extracted so `authedMutation`/`authedAction` and
        /// `firstValue` share one bounded-wait implementation instead of
        /// duplicating the plumbing.
        ///
        /// Why this uses an unstructured `Task` + a single-resume
        /// continuation rather than `withThrowingTaskGroup`: a task group
        /// cannot return until *every* child task has finished (SE-0304),
        /// and `cancelAll()` is cooperative-only. `convex-swift` 0.8.1's
        /// `client.mutation`/`client.action` bottom out in a UniFFI polling
        /// loop (`uniffiRustCallAsync`) that never checks `Task.isCancelled`,
        /// so a genuinely-hung/dropped-connection call would keep a group
        /// child running forever and a group-based race would never return —
        /// which is exactly what previously left `SyncEngine`'s `isDraining`
        /// reentrancy guard wedged `true` for the rest of the process's life
        /// (observed live: captures sat unsynced for 20+ hours until a
        /// relaunch). Running `operation` in an unstructured task means this
        /// function returns the instant the timer fires: the timed-out call
        /// is thrown to the caller, `isDraining` resets, and retries proceed.
        /// The hung operation task is cancelled (a no-op for the
        /// non-cancellation-aware FFI call) and leaks in the background until
        /// the FFI future eventually settles on its own — a cheap suspended
        /// task, and a strictly better trade than a permanent wedge. This
        /// therefore delivers a real upper bound of `timeout` on the caller's
        /// wait, unlike the previous group-based version.
        ///
        /// Internal (not private) and free of any `LiveConvexService`
        /// instance state, so it's unit-testable in isolation against a
        /// synthetic `operation`; see `ConvexTimeoutTests`.
        static func withTimeout<T: Sendable>(
            _ timeout: Duration,
            timeoutMessage: String = "operation timed out",
            operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            let state = TimeoutState<T>()
            let work = Task {
                do { state.finish(.success(try await operation())) }
                catch { state.finish(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                state.finish(.failure(ConvexServiceError.requestFailed(timeoutMessage)))
            }
            defer {
                timer.cancel()
                work.cancel()
            }
            return try await state.value()
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
        ///
        /// Shares the one bounded-wait primitive (`withTimeout`) rather than
        /// duplicating the race plumbing. Unlike the mutation/action path,
        /// the underlying `AsyncThrowingPublisher` IS cancellation-aware, so
        /// when `withTimeout` cancels the losing work task the subscription
        /// is actually torn down (returning out of the `for try await` loop
        /// triggers `AnyPublisher.values`' cancel-on-task-cancel behavior).
        static func firstValue<T: Sendable>(
            from publisher: AnyPublisher<T, ClientError>,
            timeout: Duration = .seconds(10)
        ) async throws -> T {
            try await withTimeout(timeout, timeoutMessage: "query timed out waiting for a value") {
                for try await value in publisher.values {
                    return value
                }
                throw ConvexServiceError.requestFailed(
                    "query completed without yielding a value"
                )
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
        /// True when this key lists a different set of Conductor projects than
        /// the previously-cached key (see `projects.ts` `validateKey`). Absent
        /// on the `refreshProjects` response and on older backends — decode as
        /// optional and treat absence as "no change."
        let changedFromPrevious: Bool?
    }

    /// Decodes the `{ ok, environment?, projectsChanged?, error? }` shape
    /// returned by the `projects:setAndValidateKey` action (see
    /// `packages/backend/convex/projects.ts`). `environment`/`projectsChanged`
    /// are only present when `ok` is `true`; `error` only when `ok` is
    /// `false` — all three decode as optional so either shape succeeds.
    struct ConductorSetAndValidateActionResult: Decodable, Sendable {
        let ok: Bool
        let environment: ConductorEnvironment?
        let projectsChanged: Bool?
        let error: String?
    }

    /// Wire-shape twin of `OrgKeyInfo`: decodes `orgs:list`'s raw Convex
    /// response, tolerating `createdAt` arriving float-boxed
    /// (`{"$float": "<base64>"}`) the same way `ServerCaptureRecordWire`
    /// does for every other server timestamp -- `OrgKeyInfo` itself stays a
    /// plain, bare-number `Codable` so literal-JSON tests don't need
    /// `ConvexMobile` at all.
    struct OrgKeyInfoWire: Decodable, @unchecked Sendable {
        var orgId: String
        var label: String
        var organizationName: String?
        var displayName: String
        var lastFour: String
        var environment: ConductorEnvironment
        @ConvexFloat var createdAt: Double

        var asInfo: OrgKeyInfo {
            OrgKeyInfo(
                orgId: orgId,
                label: label,
                organizationName: organizationName,
                displayName: displayName,
                lastFour: lastFour,
                environment: environment,
                createdAt: Date(timeIntervalSince1970: createdAt / 1000)
            )
        }
    }

    /// Decodes the `{ ok, orgId?, environment?, projectsChanged?, error? }`
    /// shape returned by the `orgs:addKey` action (see
    /// `packages/backend/convex/orgs.ts`). Mirrors
    /// `ConductorSetAndValidateActionResult`'s all-optional-except-`ok`
    /// shape; `orgId` is a plain Convex document id (already a bare string
    /// over the wire, unlike `createdAt` -- no float-boxing concern here).
    struct OrgAddKeyActionResult: Decodable, Sendable {
        let ok: Bool
        let orgId: String?
        let environment: ConductorEnvironment?
        let projectsChanged: Bool?
        let error: String?
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
