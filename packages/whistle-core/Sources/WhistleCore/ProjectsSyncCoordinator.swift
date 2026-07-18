// ProjectsSyncCoordinator.swift
// Sole auth-gated owner of the app-wide `projects.list` subscription.
// Settings and the capture picker consume its persisted CaptureStore
// snapshot, which remains available offline.

import Foundation

/// Stale-refresh access is actor-isolated. Subscription lifecycle control is
/// explicitly nonisolated because its supervisor is internally synchronized.
public actor ProjectsSyncCoordinator {
    private let store: CaptureStore
    private let convex: any ConvexServiceProtocol
    private let staleAfter: TimeInterval

    nonisolated private let subscription: AuthenticatedSubscription<[Project]>

    public init(
        store: CaptureStore,
        convex: any ConvexServiceProtocol,
        staleAfter: TimeInterval = 3600
    ) {
        self.store = store
        self.convex = convex
        self.staleAfter = staleAfter
        self.subscription = AuthenticatedSubscription(
            label: "projects.list",
            stream: { convex.projectsList() },
            onValue: { projects, context in
                guard context.isCurrent else { return }
                do {
                    try store.saveProjectsSnapshot(projects)
                } catch {
                    NSLog("Whistle: failed to persist projects snapshot: %@", String(describing: error))
                }
            }
        )
    }

    deinit {
        subscription.setEnabled(false)
    }

    /// Owns the authenticated projects subscription across auth changes.
    /// The shared supervisor automatically replaces a terminated stream
    /// while enabled and cancels active iteration/backoff when disabled.
    public nonisolated func setServerUpdatesEnabled(_ enabled: Bool) {
        subscription.setEnabled(enabled)
    }

    /// Triggers a server-side `conductor.refreshProjects` if the local
    /// snapshot is missing or older than `staleAfter` (default 1h) --
    /// TECH-SPEC §7: "called when stale (>1h) or on picker open." Callers
    /// (`CaptureViewModel.beginCapture()`/`resumeDraft()`, via
    /// `CapturePanelController`) call this every time the capture panel
    /// opens; a fresh snapshot is a cheap no-op.
    public func refreshIfStale(now: Date = Date()) async {
        let fetchedAt = try? store.projectsSnapshotFetchedAt()
        let isStale = fetchedAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
        guard isStale else { return }
        try? await convex.conductorRefreshProjects()
    }
}
