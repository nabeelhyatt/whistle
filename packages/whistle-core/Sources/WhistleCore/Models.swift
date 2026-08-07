// Models.swift
// Cross-platform (no AppKit/UIKit) data model shared by the macOS app and a
// future iOS app. Mirrors TECH-SPEC §5 (Convex schema.ts) for the server
// shapes, and TECH-SPEC §4.1 (CaptureStore) for the local queue shapes.

import Foundation

// MARK: - Local capture lifecycle

/// Local (on-device, pre/peri-sync) lifecycle of a queued capture.
/// TECH-SPEC §4.1 `CaptureStore` row: `draft → queued → syncing → synced / syncFailed`.
public enum LocalCaptureState: String, Codable, Sendable, CaseIterable {
    case draft
    case queued
    case syncing
    case synced
    case syncFailed
}

/// A capture as it exists purely on-device, before (or independent of) any
/// server record. This is what `CaptureStore` persists in `pending_captures`.
public struct CaptureDraft: Codable, Equatable, Sendable {
    /// UUID minted on device. Reused verbatim across retries (server dedupes
    /// on `(userId, clientId)`, TECH-SPEC §6) — never regenerate this for an
    /// existing draft.
    public var clientId: String
    public var transcript: String
    public var notes: String
    /// Path to a local temp-file copy of the screenshot JPEG, if any. The
    /// SyncEngine uploads this file's bytes and clears it (or lets it be
    /// cleaned up) once `synced`.
    public var screenshotPath: String?
    public var projectId: String
    public var projectName: String
    public var agent: String
    public var model: String?
    public var capturedAt: Date
    public var localState: LocalCaptureState
    /// Number of local (pre-sync) retry attempts. Distinct from the server's
    /// `attempt` counter (TECH-SPEC §5), which tracks pipeline retries.
    public var localAttempt: Int
    /// Populated once `captures.create` succeeds; lets CaptureStore correlate
    /// this local row with server-side subscription updates by `clientId`
    /// even before a server id is known, and by server id once available.
    public var serverId: String?
    /// Local-only human-readable failure reason, set when `localState ==
    /// .syncFailed`. Distinct from the server's `error`/`errorCode`.
    public var localError: String?
    /// Which Conductor org key this capture was created under (multi-org
    /// plan) -- threaded through to `captures.create`'s optional `orgId` arg.
    /// `nil` when the project was picked before multi-org existed, or under
    /// a single-key account; the server falls back to its own single-org
    /// shim in that case.
    public var orgId: String?

    public init(
        clientId: String = UUID().uuidString,
        transcript: String,
        notes: String,
        screenshotPath: String? = nil,
        projectId: String,
        projectName: String,
        agent: String,
        model: String? = nil,
        capturedAt: Date = Date(),
        localState: LocalCaptureState = .draft,
        localAttempt: Int = 0,
        serverId: String? = nil,
        localError: String? = nil,
        orgId: String? = nil
    ) {
        self.clientId = clientId
        self.transcript = transcript
        self.notes = notes
        self.screenshotPath = screenshotPath
        self.projectId = projectId
        self.projectName = projectName
        self.agent = agent
        self.model = model
        self.capturedAt = capturedAt
        self.localState = localState
        self.localAttempt = localAttempt
        self.serverId = serverId
        self.localError = localError
        self.orgId = orgId
    }
}

// MARK: - Server capture record (mirrors TECH-SPEC §5 `captures` table)

/// Pipeline status on the server record. Exactly the `captures.status` union
/// in TECH-SPEC §5.
public enum CaptureServerStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case creating
    case sending
    case agentWorking
    case ready
    case readyUnverified
    case failed
}

/// `captures.errorCode` union, TECH-SPEC §5.
public enum CaptureErrorCode: String, Codable, Sendable, CaseIterable {
    case auth
    case workspaceSetup
    case network
    case stalled
    case unknown
}

/// A capture record as returned by the backend (`captures.get`/`list`/
/// `listRecent`), mirroring TECH-SPEC §5's `captures` table shape field for
/// field (including the ready-state lifecycle fields `openedAt`/`archivedAt`).
public struct ServerCaptureRecord: Codable, Equatable, Sendable, Identifiable {
    /// Convex document id (`_id`).
    public var id: String
    public var userId: String
    public var clientId: String
    public var transcript: String
    public var notes: String
    public var screenshotId: String?
    public var projectId: String
    public var projectName: String
    public var agent: String
    public var model: String?
    public var capturedAt: Date

    public var status: CaptureServerStatus
    public var errorCode: CaptureErrorCode?
    public var error: String?
    public var attempt: Int
    public var workspaceId: String?
    public var workspaceName: String?
    public var sessionId: String?
    public var deepLink: String?
    public var messageSentAt: Date?
    public var clarifyingQuestions: [String]?
    public var agentSummary: String?

    /// Patched when the user opens this capture's deep link from Whistle
    /// (History row or notification) — TECH-SPEC §7 `captures.markOpened`.
    public var openedAt: Date?
    /// Patched when the user dismisses/archives the row from History —
    /// TECH-SPEC §7 `captures.archive`.
    public var archivedAt: Date?

    public init(
        id: String,
        userId: String,
        clientId: String,
        transcript: String,
        notes: String,
        screenshotId: String? = nil,
        projectId: String,
        projectName: String,
        agent: String,
        model: String? = nil,
        capturedAt: Date,
        status: CaptureServerStatus,
        errorCode: CaptureErrorCode? = nil,
        error: String? = nil,
        attempt: Int = 0,
        workspaceId: String? = nil,
        workspaceName: String? = nil,
        sessionId: String? = nil,
        deepLink: String? = nil,
        messageSentAt: Date? = nil,
        clarifyingQuestions: [String]? = nil,
        agentSummary: String? = nil,
        openedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.clientId = clientId
        self.transcript = transcript
        self.notes = notes
        self.screenshotId = screenshotId
        self.projectId = projectId
        self.projectName = projectName
        self.agent = agent
        self.model = model
        self.capturedAt = capturedAt
        self.status = status
        self.errorCode = errorCode
        self.error = error
        self.attempt = attempt
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.sessionId = sessionId
        self.deepLink = deepLink
        self.messageSentAt = messageSentAt
        self.clarifyingQuestions = clarifyingQuestions
        self.agentSummary = agentSummary
        self.openedAt = openedAt
        self.archivedAt = archivedAt
    }
}

// MARK: - Project

/// A Conductor project as cached client-side (TECH-SPEC §5 `projectsCache`
/// entry / §7 `projects.list`).
public struct Project: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var gitRemote: String
    /// Which Conductor org key this project came from (multi-org plan) --
    /// absent for a legacy pre-migration cache row (both `orgId`/`orgLabel`
    /// arrive together or not at all, per `projects:list`). Decoded leniently
    /// (both fields are `Optional`, so the synthesized `Codable` conformance
    /// already decodes them with `decodeIfPresent`) so a client running
    /// ahead of a backend rollout still decodes instead of throwing.
    public var orgId: String?
    /// Display name for `orgId`'s org (server-resolved `orgDisplayName`, not
    /// user-typed `label` directly) -- for grouping the project picker by
    /// org.
    public var orgLabel: String?

    public init(id: String, name: String, gitRemote: String, orgId: String? = nil, orgLabel: String? = nil) {
        self.id = id
        self.name = name
        self.gitRemote = gitRemote
        self.orgId = orgId
        self.orgLabel = orgLabel
    }
}
