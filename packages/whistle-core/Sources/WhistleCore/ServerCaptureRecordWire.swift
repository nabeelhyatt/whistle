// ServerCaptureRecordWire.swift
// Wire-shape twin of `ServerCaptureRecord` (Models.swift).
//
// Root cause of the long-standing "stuck Queued" History bug: every
// `captures:listRecent`/`captures:list`/`captures:get` payload is a RAW
// Convex document, decoded by convex-swift's vanilla `JSONDecoder`. Convex
// documents key their id as `_id`; `ServerCaptureRecord` (relying on its
// synthesized `Codable`) expects `id`, so decoding threw `keyNotFound` on
// every single real server payload — the subscription stream died
// immediately, `history_cache` never populated, and synced drafts rendered
// "Queued" forever. Separately, date fields (`capturedAt`, `messageSentAt`,
// `openedAt`, `archivedAt`) arrive as ms-since-epoch float64 (optionally
// boxed as `{"$float": "<base64>"}` when Convex's wire format needs to
// disambiguate a float from a bigint); vanilla `JSONDecoder` decodes `Date`
// from a bare number as seconds-since-2001 (`Date(timeIntervalSinceReferenceDate:)`),
// which would have silently produced wrong dates even once the `_id` bug
// was fixed.
//
// This type is deliberately a SEPARATE struct from `ServerCaptureRecord`,
// not a change to its Codable: `ServerCaptureRecord`'s synthesized
// Codable (`_id`-less, ISO-8601-dated) is load-bearing for
// `CaptureStore.history_cache`, which round-trips it through its own
// iso8601 `JSONEncoder`/`JSONDecoder` (see CaptureStore.swift). Decoding
// the raw wire shape here and mapping into the public model keeps both
// contracts intact.
import Foundation
#if canImport(ConvexMobile)
    import ConvexMobile
#endif

#if canImport(ConvexMobile)
/// Wire-shape twin of `ServerCaptureRecord`: decodes the RAW Convex
/// `captures` document exactly as convex-swift yields it (`_id` key,
/// ms-since-epoch float64 timestamps, `$float`-tolerant numbers) and maps
/// into the public model. Deliberately separate from `ServerCaptureRecord`
/// so its synthesized Codable — which `CaptureStore`'s `history_cache`
/// round-trips with iso8601 dates and an `id` key — is never touched.
struct ServerCaptureRecordWire: Decodable, @unchecked Sendable {
    var id: String
    var userId: String
    var clientId: String
    var transcript: String
    var notes: String
    var screenshotId: String?
    var projectId: String
    var projectName: String
    var agent: String
    var model: String?
    @ConvexFloat var capturedAt: Double

    /// Decoded as a raw `String`, not `CaptureServerStatus` directly -- see
    /// `asRecord`'s mapping for why (schema-drift tolerance).
    var status: String
    /// Decoded as a raw `String?`, not `CaptureErrorCode?` directly -- see
    /// `asRecord`'s mapping for why (schema-drift tolerance).
    var errorCode: String?
    var error: String?
    @ConvexFloat var attempt: Double
    var workspaceId: String?
    var workspaceName: String?
    var sessionId: String?
    var deepLink: String?
    @OptionalConvexFloat var messageSentAt: Double?
    var clarifyingQuestions: [String]?
    var agentSummary: String?

    @OptionalConvexFloat var openedAt: Double?
    @OptionalConvexFloat var archivedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case userId, clientId, transcript, notes, screenshotId, projectId,
             projectName, agent, model, capturedAt, status, errorCode, error,
             attempt, workspaceId, workspaceName, sessionId, deepLink,
             messageSentAt, clarifyingQuestions, agentSummary, openedAt, archivedAt
        // `_creationTime` (and any other server-only fields Convex adds to
        // the raw document) is intentionally unmapped — `JSONDecoder`
        // ignores keys with no matching `CodingKey`.
    }

    /// Maps the raw wire shape onto the public model. Ms-since-epoch floats
    /// become `Date`s via `Date(timeIntervalSince1970:)` (NOT
    /// `timeIntervalSinceReferenceDate`, which is seconds-since-2001 and was
    /// the silent-wrong-date half of this bug); `attempt`'s float64 becomes
    /// the model's `Int`.
    ///
    /// `status`/`errorCode` are decoded as raw strings (not the closed
    /// enums directly) and mapped here with a fallback rather than left to
    /// `Decodable`'s enum-from-rawValue behavior, which throws and kills the
    /// WHOLE `captures.listRecent` publisher on a single unrecognized value.
    /// A future backend deploy adding a new status/errorCode before the
    /// client ships its matching case must degrade one row's chip, not
    /// re-freeze all of History -- so an unknown string falls back to
    /// `.queued`/`.unknown` (display-neutral) instead of throwing.
    var asRecord: ServerCaptureRecord {
        ServerCaptureRecord(
            id: id,
            userId: userId,
            clientId: clientId,
            transcript: transcript,
            notes: notes,
            screenshotId: screenshotId,
            projectId: projectId,
            projectName: projectName,
            agent: agent,
            model: model,
            capturedAt: Date(timeIntervalSince1970: capturedAt / 1000),
            status: CaptureServerStatus(rawValue: status) ?? .queued,
            errorCode: errorCode.map { CaptureErrorCode(rawValue: $0) ?? .unknown },
            error: error,
            // `attempt` arrives as a Convex float64; a non-finite value
            // (NaN/inf -- shouldn't happen, but the wire format doesn't rule
            // it out) would trap `Int(attempt)`. `Int(exactly:)` on the
            // rounded value returns `nil` for anything that can't losslessly
            // become an `Int` (non-finite, out-of-range), falling back to 0
            // rather than crashing the whole decode.
            attempt: Int(exactly: attempt.rounded()) ?? 0,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            sessionId: sessionId,
            deepLink: deepLink,
            messageSentAt: messageSentAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            clarifyingQuestions: clarifyingQuestions,
            agentSummary: agentSummary,
            openedAt: openedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            archivedAt: archivedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
#endif
