// ProjectsSyncCoordinator.swift
// Keeps `CaptureStore`'s `projects_snapshot` (TECH-SPEC §4.1 `CaptureStore`
// row, §7: "projects.list ... client persists the latest yield into GRDB
// for offline picker use") fresh, app-wide -- not just while Settings
// happens to be open.
//
// The bug this fixes: the capture panel's `ProjectPicker` (via
// `CaptureViewModel.loadProjects()`) reads `CaptureStore.projectsSnapshot()`
// -- the GRDB `projects_snapshot` table. Nothing in the app ever called
// `CaptureStore.saveProjectsSnapshot(_:)` to populate that table.
// `SettingsWindow.swift`'s `SettingsViewModel.subscribeToProjects()`
// subscribes to `convex.projectsList()` directly into its own `@Published`
// property and displays projects fine -- but it never round-trips through
// `CaptureStore` at all, so Settings showing projects gave no indication
// the snapshot the capture panel depends on was empty. Hence: Settings
// shows projects, the capture panel's picker says "No projects".
//
// `ProjectsSyncCoordinator` is the missing piece: a single, app-wide
// `projects.list` subscription (started once at launch, independent of any
// window being open) whose every yield is persisted into
// `CaptureStore.projects_snapshot`, plus the stale-refresh trigger
// (`conductor.refreshProjects`, TECH-SPEC §7: "called when stale (>1h) or
// on picker open").

import Foundation

/// Actor-isolated so the subscription task and stale-check both serialize
/// through a single owner, matching `SyncEngine`'s concurrency shape.
public actor ProjectsSyncCoordinator {
    private let store: CaptureStore
    private let convex: any ConvexServiceProtocol
    private let staleAfter: TimeInterval

    private var subscriptionTask: Task<Void, Never>?

    public init(
        store: CaptureStore,
        convex: any ConvexServiceProtocol,
        staleAfter: TimeInterval = 3600
    ) {
        self.store = store
        self.convex = convex
        self.staleAfter = staleAfter
    }

    deinit {
        subscriptionTask?.cancel()
    }

    /// Subscribes to `projects.list` and persists every yield into
    /// `CaptureStore.projects_snapshot`. Idempotent (safe to call once at
    /// app launch and never worry about it again) -- a re-entrant call is a
    /// no-op while the subscription is already running.
    public func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [store, convex] in
            for await projects in convex.projectsList() {
                try? store.saveProjectsSnapshot(projects)
            }
        }
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
