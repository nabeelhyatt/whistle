// StatusPresentation.swift
// Pure function implementing the TECH-SPEC §4.4 status-presentation mapping
// table: (localState, serverRecord?) -> (chip, affordance). No I/O, no
// AppKit — safe to unit test exhaustively and to share with a future iOS app.

import Foundation

/// What affordance (if any) a History row / notification should offer for a
/// given capture's current status.
public enum CaptureAffordance: Equatable, Sendable {
    /// No action available right now.
    case none
    /// Automatic — e.g. "waiting for network," nothing for the user to do.
    case automatic
    /// Re-run the local SyncEngine drain for this capture (local retry,
    /// distinct from the server-side `captures.retry`).
    case localRetry
    /// Open the capture's Conductor deep link.
    case openDeepLink
    /// Route to Settings → API key.
    case openSettingsApiKey
    /// Call the server-side `captures.retry` mutation.
    case serverRetry
}

/// The rendered chip text plus whether this row should be visually
/// de-emphasized (TECH-SPEC §4.1 HistoryRow: rows with `openedAt` set
/// recede).
public struct StatusPresentationResult: Equatable, Sendable {
    public let chip: String
    public let affordance: CaptureAffordance
    /// True when the capture has been opened (`openedAt` set) and the row
    /// should render de-emphasized. Always false pre-sync (no server record
    /// yet — there is nothing to have "opened").
    public let isDeemphasized: Bool

    public init(chip: String, affordance: CaptureAffordance, isDeemphasized: Bool = false) {
        self.chip = chip
        self.affordance = affordance
        self.isDeemphasized = isDeemphasized
    }
}

public enum StatusPresentation {
    /// Whether the given local/server state pair should currently be
    /// considered "online" for the pre-sync rows in the §4.4 table. Local
    /// `queued`/`syncing` differ in chip only by connectivity — CaptureStore
    /// doesn't persist connectivity, so callers pass it in explicitly.
    public static func present(
        localState: LocalCaptureState,
        serverRecord: ServerCaptureRecord?,
        isOnline: Bool = true
    ) -> StatusPresentationResult {
        // Once a server record exists, it is the source of truth (TECH-SPEC
        // §4.4 preamble) — local state no longer drives the chip.
        if let server = serverRecord {
            return presentServer(server)
        }

        switch localState {
        case .draft:
            // Not yet queued; no row exists in the History view for a bare
            // draft. Present a neutral "not queued" state for completeness/
            // defensiveness rather than crashing.
            return StatusPresentationResult(chip: "Draft", affordance: .none)

        case .queued, .syncing:
            if isOnline {
                return StatusPresentationResult(chip: "Queued", affordance: .none)
            } else {
                return StatusPresentationResult(chip: "Waiting for network", affordance: .automatic)
            }

        case .synced:
            // `synced` with no server record yet is a transient window
            // (mutation succeeded, subscription hasn't yielded yet) — treat
            // like the just-synced "queued" row from the table.
            return StatusPresentationResult(chip: "Queued", affordance: .none)

        case .syncFailed:
            return StatusPresentationResult(chip: "Sync failed", affordance: .localRetry)
        }
    }

    private static func presentServer(_ server: ServerCaptureRecord) -> StatusPresentationResult {
        let isDeemphasized = server.openedAt != nil

        switch server.status {
        case .queued:
            return StatusPresentationResult(chip: "Queued", affordance: .none, isDeemphasized: isDeemphasized)

        case .creating, .sending:
            return StatusPresentationResult(chip: "Creating workspace", affordance: .none, isDeemphasized: isDeemphasized)

        case .agentWorking:
            return StatusPresentationResult(chip: "Agent working", affordance: .openDeepLink, isDeemphasized: isDeemphasized)

        case .ready:
            let count = server.clarifyingQuestions?.count ?? 0
            let chip = count > 0 ? "Ready (+\(count) questions)" : "Ready"
            return StatusPresentationResult(chip: chip, affordance: .openDeepLink, isDeemphasized: isDeemphasized)

        case .readyUnverified:
            return StatusPresentationResult(
                chip: "Sent — agent status unknown",
                affordance: .openDeepLink,
                isDeemphasized: isDeemphasized
            )

        case .failed:
            if server.errorCode == .auth {
                return StatusPresentationResult(chip: "Auth error", affordance: .openSettingsApiKey, isDeemphasized: isDeemphasized)
            } else {
                let message = server.error ?? "Unknown error"
                return StatusPresentationResult(chip: "Failed: \(message)", affordance: .serverRetry, isDeemphasized: isDeemphasized)
            }
        }
    }
}
