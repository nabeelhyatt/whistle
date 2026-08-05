// SyncEngine.swift
// Drains the local pending_captures queue when online (TECH-SPEC §4.1
// `SyncEngine` / §13 U5). Upload-then-create is atomic from the queue's
// point of view: if the screenshot upload fails, the whole capture stays
// queued (never partially synced). `captures.create` failures move the
// draft to `syncFailed`, which surfaces a LOCAL retry affordance distinct
// from the server-side `captures.retry` — the same `clientId` is always
// reused so the server's dedupe-on-`(userId, clientId)` makes retries safe.
//
// No AppKit/UIKit. Network reachability is injected via `NetworkMonitoring`
// so tests never touch real `NWPathMonitor`.

import Foundation
#if canImport(Network)
    import Network
#endif

// MARK: - Network monitoring seam

/// Abstraction over connectivity so SyncEngine is testable without a real
/// network stack. `NWPathMonitorNetworkMonitor` is the production
/// implementation (macOS/iOS); tests inject a fake that flips online/offline
/// on demand.
public protocol NetworkMonitoring: Sendable {
    /// Current reachability, polled once at drain time.
    var isOnline: Bool { get async }
    /// Emits `true`/`false` whenever reachability changes. The first value
    /// is the current state at subscription time.
    func pathUpdates() -> AsyncStream<Bool>
}

#if canImport(Network)
    /// Production `NetworkMonitoring` backed by `NWPathMonitor` (TECH-SPEC
    /// §4.1: "NWPathMonitor-driven queue drain").
    public final class NWPathMonitorNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "com.whistle.core.network-monitor")
        private let lock = NSLock()
        private var lastStatus: Bool?
        private var continuations: [Int: AsyncStream<Bool>.Continuation] = [:]
        private var nextId = 0

        public init() {
            monitor.pathUpdateHandler = { [weak self] path in
                self?.handle(path: path)
            }
            monitor.start(queue: queue)
        }

        deinit {
            monitor.cancel()
        }

        public var isOnline: Bool {
            get async {
                lock.withLock { lastStatus ?? false }
            }
        }

        public func pathUpdates() -> AsyncStream<Bool> {
            AsyncStream { continuation in
                let (id, current): (Int, Bool?) = lock.withLock {
                    let id = nextId
                    nextId += 1
                    continuations[id] = continuation
                    return (id, lastStatus)
                }
                if let current {
                    continuation.yield(current)
                }
                continuation.onTermination = { [weak self] _ in
                    self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
                }
                _ = id
            }
        }

        private func handle(path: NWPath) {
            let online = path.status == .satisfied
            let continuations: [AsyncStream<Bool>.Continuation] = lock.withLock {
                lastStatus = online
                return Array(self.continuations.values)
            }
            for continuation in continuations {
                continuation.yield(online)
            }
        }
    }

    extension NSLock {
        fileprivate func withLock<T>(_ body: () -> T) -> T {
            lock()
            defer { unlock() }
            return body()
        }
    }
#endif

// MARK: - Screenshot upload transport seam

/// Abstraction over the raw HTTP POST used to upload screenshot bytes to
/// the Convex-issued upload URL (TECH-SPEC §4.1: "generateUploadUrl -> HTTP
/// POST -> storageId"). Kept separate from `URLSession` so tests can fake
/// network failures without a real server.
public protocol ScreenshotUploading: Sendable {
    /// POSTs `data` to `uploadUrl` and returns the resulting Convex
    /// `storageId` (parsed from the JSON response body `{"storageId": ...}`
    /// per Convex file-upload conventions).
    func upload(data: Data, to uploadUrl: URL) async throws -> String
}

public struct URLSessionScreenshotUploader: ScreenshotUploading {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private struct UploadResponse: Decodable {
        let storageId: String
    }

    public func upload(data: Data, to uploadUrl: URL) async throws -> String {
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.upload(for: request, from: data)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SyncEngineError.uploadFailed(statusCode: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(UploadResponse.self, from: body)
        return decoded.storageId
    }
}

// MARK: - Errors

public enum SyncEngineError: Error, Equatable {
    case uploadFailed(statusCode: Int)
    case offline
}

// MARK: - Backoff policy

/// Backoff schedule for local retries, mirroring the spirit of the
/// server-side pipeline's backoff (TECH-SPEC §6) but local-only. Not used to
/// block `drainOnce()` — SyncEngine leaves scheduling/timing to the caller
/// (e.g. a periodic timer or connectivity callback in the app target); this
/// just computes the delay a caller *should* wait before the next attempt.
public enum SyncBackoff {
    private static let delaysSeconds: [TimeInterval] = [1, 4, 10, 20]

    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let index = min(attempt - 1, delaysSeconds.count - 1)
        return delaysSeconds[index]
    }
}

// MARK: - SyncEngine

/// Drains `CaptureStore`'s pending queue against a `ConvexServiceProtocol`.
/// Every method is safe to call repeatedly and safe to call while offline
/// (it simply does nothing / reports nothing drained).
public actor SyncEngine {
    private let store: CaptureStore
    private let convex: any ConvexServiceProtocol
    private let uploader: any ScreenshotUploading
    private let networkMonitor: (any NetworkMonitoring)?
    private let logger: @Sendable (String) -> Void
    /// Invoked once per drain pass that hits `ConvexServiceError
    /// .notAuthenticated` (see `drainPass`'s catch arm). Auth deferral is
    /// deliberately NOT surfaced as `.syncFailed` (there's no local-retry
    /// affordance that helps while genuinely signed out) -- but that also
    /// means a server-revoked session with locally-persisted `.signedIn`
    /// state defers silently forever, tick after tick, with no user-visible
    /// surface at all. The app target uses repeated calls to this hook as a
    /// signal to force re-auth (`AuthController.handleTokenRefreshFailure()`)
    /// after tolerating a few deferred passes. `nil` by default so existing
    /// callers/tests are unaffected.
    private let onAuthDeferred: (@Sendable () async -> Void)?

    /// Reentrancy guard for `drainOnce()`: true while a drain pass is
    /// in-flight. Without this, two concurrently-invoked `drainOnce()` calls
    /// (e.g. the launch-time `runForever()` drain still mid-loop when a
    /// capture submit triggers its own `drainOnce()`) can each snapshot the
    /// same `.queued`/`.syncFailed` draft before either has marked it
    /// `.syncing`, causing a duplicate upload + `captures.create` for it.
    private var isDraining = false
    /// Set when `drainOnce()` is called while a pass is already in-flight, so
    /// the in-flight pass loops back for another pass instead of the caller's
    /// request being silently dropped.
    private var rerunRequested = false

    public init(
        store: CaptureStore,
        convex: any ConvexServiceProtocol,
        uploader: any ScreenshotUploading = URLSessionScreenshotUploader(),
        networkMonitor: (any NetworkMonitoring)? = nil,
        logger: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) },
        onAuthDeferred: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.convex = convex
        self.uploader = uploader
        self.networkMonitor = networkMonitor
        self.logger = logger
        self.onAuthDeferred = onAuthDeferred
    }

    /// Attempts to drain every `queued`/`syncFailed` draft once, in
    /// capture-order (oldest first). Does nothing (returns immediately) if
    /// the network monitor reports offline. Each draft is fully independent:
    /// one failing does not stop the others from being attempted.
    ///
    /// - Returns: clientIds that were successfully synced this pass.
    @discardableResult
    public func drainOnce() async -> [String] {
        if let networkMonitor, await networkMonitor.isOnline == false {
            logger("Whistle: SyncEngine skipping drain — network monitor reports offline")
            return []
        }

        // Coalesce overlapping calls: if a pass is already running, ask it to
        // run again once it's done instead of racing it with our own
        // snapshot of the same queued/syncFailed drafts.
        if isDraining {
            rerunRequested = true
            logger("Whistle: SyncEngine drain already in flight, requesting rerun")
            return []
        }

        isDraining = true
        defer { isDraining = false }

        var allSynced: [String] = []
        repeat {
            rerunRequested = false
            allSynced += await drainPass()
        } while rerunRequested
        return allSynced
    }

    /// A single fetch-and-process pass over the current
    /// `queued`/`syncFailed` drafts. Only ever called from within
    /// `drainOnce()`'s `isDraining` guard.
    private func drainPass() async -> [String] {
        let drafts: [CaptureDraft]
        do {
            drafts = try store.drafts(in: [.queued, .syncFailed])
        } catch {
            logger("Whistle: SyncEngine failed to read pending drafts: \(error)")
            return []
        }

        if drafts.isEmpty {
            return []
        }
        logger("Whistle: SyncEngine draining \(drafts.count) draft(s)")

        var synced: [String] = []
        for (index, draft) in drafts.enumerated() {
            do {
                try store.updateLocalState(clientId: draft.clientId, to: .syncing)
                let serverId = try await syncOne(draft)
                try store.updateLocalState(clientId: draft.clientId, to: .synced, serverId: serverId, localError: nil)
                synced.append(draft.clientId)
                logger("Whistle: SyncEngine synced \(draft.clientId) -> \(serverId)")
            } catch ConvexServiceError.notAuthenticated {
                // Not a local sync failure -- there's nothing a manual
                // ".localRetry" click could fix while genuinely signed out,
                // and marking `.syncFailed` here would surface a misleading
                // "Retry" affordance for a condition that isn't the local
                // queue's fault. Revert to `.queued` (never leave it stuck
                // in `.syncing`) so the next drain -- once auth actually
                // resolves -- picks it back up, with no wasted attempt
                // increment. `runPeriodicDrain()`'s `gate` parameter keeps
                // this from firing on every periodic tick for a persistently
                // signed-out user, but the revert stays defensive here too
                // (a gate can only check the app's local signed-in state --
                // it can't detect e.g. a token the server has independently
                // rejected).
                do {
                    try store.updateLocalState(clientId: draft.clientId, to: .queued, localError: nil)
                    logger("Whistle: SyncEngine sync deferred for \(draft.clientId): not authenticated")
                } catch {
                    logger("Whistle: SyncEngine failed to revert \(draft.clientId) to .queued: \(error)")
                }
                let remaining = drafts.count - index - 1
                if remaining > 0 {
                    logger("Whistle: SyncEngine skipping remaining \(remaining) draft(s) this pass after not-authenticated")
                }
                // Fire once per deferred pass (not once per deferred draft --
                // the `break` below means only the first draft in the pass
                // ever reaches this arm). Without this, a server-revoked
                // session combined with locally-persisted `.signedIn` state
                // defers every single tick forever with nothing surfaced to
                // the user; the app target counts these calls and escalates
                // to a re-auth prompt after a threshold.
                await onAuthDeferred?()
                break
            } catch {
                _ = try? store.incrementLocalAttempt(clientId: draft.clientId)
                _ = try? store.updateLocalState(
                    clientId: draft.clientId,
                    to: .syncFailed,
                    localError: String(describing: error)
                )
                logger("Whistle: SyncEngine sync failed for \(draft.clientId): \(error)")
            }
        }
        return synced
    }

    /// Uploads the screenshot (if any) then calls `captures.create`. Atomic
    /// from the queue's point of view: if the upload throws, this whole
    /// function throws before any mutation is attempted, so the draft is
    /// left `queued`/`syncFailed` rather than partially synced (TECH-SPEC
    /// §13 U5: "screenshot upload fails but mutation would succeed -> whole
    /// capture stays queued").
    private func syncOne(_ draft: CaptureDraft) async throws -> String {
        var screenshotStorageId: String?

        if let path = draft.screenshotPath, let data = store.screenshotData(atPath: path) {
            let uploadUrl = try await convex.filesGenerateUploadUrl()
            guard let url = URL(string: uploadUrl) else {
                throw SyncEngineError.uploadFailed(statusCode: -1)
            }
            // If this throws, we return before calling capturesCreate —
            // nothing has been mutated server-side, and the draft stays in
            // the queue for the next drain attempt (same clientId reused).
            screenshotStorageId = try await uploader.upload(data: data, to: url)
        }

        let input = CaptureCreateInput(
            clientId: draft.clientId,
            transcript: draft.transcript,
            notes: draft.notes,
            screenshotStorageId: screenshotStorageId,
            projectId: draft.projectId,
            projectName: draft.projectName,
            agent: draft.agent,
            model: draft.model,
            capturedAt: draft.capturedAt,
            orgId: draft.orgId
        )
        // The server dedupes on (userId, clientId) — TECH-SPEC §6 — so
        // calling this again on a local retry with the same clientId is
        // always safe and never creates a duplicate capture.
        return try await convex.capturesCreate(input)
    }

    /// Convenience for a caller (e.g. app target) that wants to keep
    /// draining forever as connectivity changes. Not required for tests;
    /// tests call `drainOnce()` directly to keep assertions deterministic.
    public func runForever() async {
        guard let networkMonitor else {
            _ = await drainOnce()
            return
        }
        for await online in networkMonitor.pathUpdates() {
            if online {
                _ = await drainOnce()
            }
        }
    }

    /// Safety net, not the primary sync path: every trigger-based drain
    /// (launch, network-path change, capture submit, manual retry) can in
    /// principle miss firing or fail to recover, leaving a capture stuck
    /// `queued`/`syncFailed` until the app is relaunched. This independent
    /// loop guarantees a capture is retried within `interval` regardless of
    /// whether any other trigger ever fires. It is intentionally a separate
    /// loop from `runForever()` rather than folded into its
    /// `networkMonitor.pathUpdates()` loop, so a hung/absent network monitor
    /// can never suppress the periodic retry too. Safe to run concurrently
    /// with any other caller of `drainOnce()` -- the `isDraining`/
    /// `rerunRequested` guard above coalesces overlapping passes.
    ///
    /// - Parameter gate: Checked before every tick's `drainOnce()`; a tick
    ///   whose gate returns `false` is skipped (the loop keeps running, it
    ///   just doesn't drain that time). Defaults to always-true so existing
    ///   callers/tests are unaffected. The app target passes a gate that
    ///   mirrors `drainSyncIfSignedIn()`'s signed-in check, so a periodic
    ///   tick firing after sign-out never even attempts an upload -- defense
    ///   in depth alongside sign-out's credential-clear/auth-detach, and
    ///   consistency with every other drain trigger (all of which route
    ///   through the same signed-in check) instead of being the one ungated
    ///   exception.
    public func runPeriodicDrain(
        interval: Duration = .seconds(180),
        gate: @escaping @Sendable () async -> Bool = { true }
    ) async {
        guard interval > .zero else {
            logger("Whistle: SyncEngine periodic drain requires a positive interval, got \(interval)")
            return
        }
        // `Task.sleep(for:)` throws `CancellationError` once the driving
        // Task is cancelled, but Swift's cooperative cancellation is
        // opt-in -- a bare `try?` around the sleep would silently swallow
        // that error and `Task.sleep` returns immediately once cancelled,
        // so without the explicit `Task.isCancelled` checks below this loop
        // would busy-spin calling `drainOnce()` forever instead of actually
        // stopping when a caller (e.g. a test) cancels it.
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            guard await gate() else { continue }
            _ = await drainOnce()
        }
    }

    /// Recovers drafts a previous process left stranded in `.syncing`.
    ///
    /// `drainPass` marks a draft `.syncing` *before* the awaited network
    /// call, and only ever re-fetches `.queued`/`.syncFailed`. So if that
    /// call never returns (a hang, or the process being killed mid-sync),
    /// the draft is frozen `.syncing` forever: the next drain skips it, and
    /// even a relaunch -- the documented fallback -- never picks it back up,
    /// because a fresh process's `drainPass` still only looks at
    /// `.queued`/`.syncFailed`. Reverting these to `.queued` at launch closes
    /// that hole.
    ///
    /// Call this ONCE at launch, before any drain starts. It is unsafe to
    /// call concurrently with an in-flight drain within the same process,
    /// where `.syncing` legitimately means "being processed right now" -- but
    /// at launch no drain has run yet, so every `.syncing` draft is
    /// necessarily a stale strand from a prior process.
    public func recoverStrandedSyncing() async {
        let stranded: [CaptureDraft]
        do {
            stranded = try store.drafts(in: [.syncing])
        } catch {
            logger("Whistle: SyncEngine failed to read stranded .syncing drafts: \(error)")
            return
        }
        for draft in stranded {
            do {
                try store.updateLocalState(clientId: draft.clientId, to: .queued, localError: nil)
                logger("Whistle: SyncEngine recovered stranded .syncing draft \(draft.clientId) -> .queued")
            } catch {
                logger("Whistle: SyncEngine failed to recover stranded .syncing draft \(draft.clientId): \(error)")
            }
        }
    }
}
