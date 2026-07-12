// HistoryWindow.swift
// TECH-SPEC §4.1 `HistoryWindow` row, plan U9: full history (recent first),
// searchable (transcript/notes/project), merges the server subscription
// (`captures.listRecent`) with local pending rows (`CaptureStore`) through
// `StatusPresentation` — the single source for chips (TECH-SPEC §4.4).
//
// Split into:
//   - `HistoryRowViewModel` / `HistoryViewModel`: pure(ish) merge + search
//     logic, no AppKit — directly unit-testable.
//   - `HistoryWindow` (SwiftUI view) + `HistoryWindowController` (NSWindow
//     wrapper): the actual window, opened from the panel's History icon or
//     the right-click menu (U6/U8 placeholders wired here).
//
// @MainActor per TECH-SPEC §4.1's concurrency map.

import AppKit
import SwiftUI
import WhistleCore

// MARK: - Merged row model

/// A single History row after merging the local pending queue with the
/// server subscription via `StatusPresentation` (TECH-SPEC §4.4). Local-only
/// rows (not yet synced) have `serverRecord == nil`; once a server record
/// exists for a `clientId`, it becomes the source of truth for display,
/// though the row is still keyed by `clientId` so a local placeholder isn't
/// duplicated once its server counterpart appears.
public struct HistoryRowViewModel: Identifiable, Equatable {
    public var id: String { clientId }
    public let clientId: String
    public let transcript: String
    public let notes: String
    public let projectName: String
    public let capturedAt: Date
    public let serverRecord: ServerCaptureRecord?
    public let presentation: StatusPresentationResult

    public var isArchived: Bool { serverRecord?.archivedAt != nil }
    public var isOpened: Bool { serverRecord?.openedAt != nil }
    public var deepLink: String? { serverRecord?.deepLink }
    public var clarifyingQuestions: [String] { serverRecord?.clarifyingQuestions ?? [] }
    public var screenshotId: String? { serverRecord?.screenshotId }

    public init(
        clientId: String,
        transcript: String,
        notes: String,
        projectName: String,
        capturedAt: Date,
        serverRecord: ServerCaptureRecord?,
        presentation: StatusPresentationResult
    ) {
        self.clientId = clientId
        self.transcript = transcript
        self.notes = notes
        self.projectName = projectName
        self.capturedAt = capturedAt
        self.serverRecord = serverRecord
        self.presentation = presentation
    }
}

/// Persists "last-seen server status per clientId" so `NotificationService`
/// only fires on OBSERVED transitions and a relaunch with existing `ready`
/// rows does not re-fire (plan U9 edge scenario). Deliberately app-target-
/// local (not `WhistleCore`/`CaptureStore`, per this unit's ownership of
/// `apps/macos/` only) — a tiny JSON file under the same Application Support
/// directory as the real `CaptureStore` database, so it persists exactly as
/// long as the local queue does. Tests inject an in-memory implementation.
public protocol LastSeenStatusStore: AnyObject {
    func status(for clientId: String) -> CaptureServerStatus?
    func setStatus(_ status: CaptureServerStatus, for clientId: String)
}

/// In-memory implementation — used by tests and as a safe fallback if the
/// on-disk store can't be created.
public final class InMemoryLastSeenStatusStore: LastSeenStatusStore {
    private var storage: [String: CaptureServerStatus] = [:]
    public init(initial: [String: CaptureServerStatus] = [:]) { storage = initial }
    public func status(for clientId: String) -> CaptureServerStatus? { storage[clientId] }
    public func setStatus(_ status: CaptureServerStatus, for clientId: String) { storage[clientId] = status }
}

/// On-disk JSON-file-backed implementation, so "last-seen status per
/// clientId" survives an app relaunch (plan U9: "track last-seen status per
/// clientId ... so relaunch does NOT re-fire for existing ready rows").
public final class FileLastSeenStatusStore: LastSeenStatusStore {
    private let fileURL: URL
    private var cache: [String: CaptureServerStatus]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: CaptureServerStatus].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    public func status(for clientId: String) -> CaptureServerStatus? { cache[clientId] }

    public func setStatus(_ status: CaptureServerStatus, for clientId: String) {
        cache[clientId] = status
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - HistoryViewModel

/// Drives the History window: merges `CaptureStore`'s local pending queue
/// with the `captures.listRecent` subscription, computes `StatusPresentation`
/// per row, supports search, archive filter, and fires notifications on
/// observed status transitions (delegated to `NotificationService`). Also
/// computes the ready-and-unopened count that `StatusItemController` renders
/// as its ready-indicator.
@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public private(set) var rows: [HistoryRowViewModel] = []
    @Published public var searchText: String = ""
    @Published public var showArchived: Bool = false

    /// >=1 capture `ready` and unopened (TECH-SPEC §4.1 ready-indicator).
    @Published public private(set) var hasUnreadReadyCaptures: Bool = false

    /// Local `syncFailed` rows' "Retry" affordance (`.localRetry`) — wired by
    /// `AppDelegate` to `syncEngine.drainOnce()`; defaults to no-op so
    /// previews/tests that don't care can omit it.
    public var onLocalRetryRequested: () -> Void = {}

    private let store: CaptureStore
    private let convex: any ConvexServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let lastSeenStore: LastSeenStatusStore
    private let listRecentLimit: Int

    private var latestServerRecords: [ServerCaptureRecord] = []
    private var latestDrafts: [CaptureDraft] = []
    private var serverTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?

    public init(
        store: CaptureStore,
        convex: any ConvexServiceProtocol,
        notificationService: NotificationServiceProtocol,
        lastSeenStore: LastSeenStatusStore,
        listRecentLimit: Int = 100
    ) {
        self.store = store
        self.convex = convex
        self.notificationService = notificationService
        self.lastSeenStore = lastSeenStore
        self.listRecentLimit = listRecentLimit
    }

    deinit {
        serverTask?.cancel()
        pendingTask?.cancel()
    }

    /// Starts the two subscriptions (server + local pending queue). Safe to
    /// call once; re-entrant calls are ignored (idempotent start).
    public func start() {
        guard serverTask == nil else { return }

        serverTask = Task { [weak self] in
            guard let self else { return }
            for await records in self.convex.capturesListRecent(limit: self.listRecentLimit) {
                await MainActor.run {
                    self.handleServerRecords(records)
                }
            }
        }

        pendingTask = Task { [weak self] in
            guard let self else { return }
            for await drafts in self.store.pendingCapturesUpdates() {
                await MainActor.run {
                    self.latestDrafts = drafts
                    self.rebuildRows()
                }
            }
        }
    }

    // MARK: - Merge + notification-transition detection

    private func handleServerRecords(_ records: [ServerCaptureRecord]) {
        latestServerRecords = records
        try? store.cacheHistory(records)
        detectTransitions(records)
        rebuildRows()
    }

    /// Fires notifications only for OBSERVED transitions — i.e. the
    /// persisted last-seen status for this `clientId` differs from the
    /// newly-yielded status. `lastSeenStore` is seeded from disk at launch
    /// (`FileLastSeenStatusStore`) with whatever status each capture was
    /// last known to be in, so a relaunch that re-subscribes and immediately
    /// re-observes an already-`ready` row sees `previous == .ready ==
    /// record.status` and correctly stays silent (plan U9: "relaunch with
    /// existing ready rows -> no duplicate notifications"). A genuinely new
    /// capture reaching `ready` for the first time in this store's lifetime
    /// has `previous == nil`, which is always treated as a real transition
    /// (there is nothing to have silently pre-seen) — the happy-path
    /// notification fires exactly once, the moment it's first observed.
    private func detectTransitions(_ records: [ServerCaptureRecord]) {
        for record in records {
            let previous = lastSeenStore.status(for: record.clientId)
            lastSeenStore.setStatus(record.status, for: record.clientId)

            guard previous != record.status else { continue }
            notify(for: record)
        }
    }

    private func notify(for record: ServerCaptureRecord) {
        switch record.status {
        case .ready:
            notificationService.notifyReady(record)
        case .readyUnverified:
            notificationService.notifyReadyUnverified(record)
        case .failed:
            notificationService.notifyFailed(record)
        case .queued, .creating, .sending, .agentWorking:
            break
        }
    }

    private func rebuildRows() {
        var byClientId: [String: HistoryRowViewModel] = [:]

        // Server records first (source of truth once present).
        for record in latestServerRecords {
            let presentation = StatusPresentation.present(localState: .synced, serverRecord: record)
            byClientId[record.clientId] = HistoryRowViewModel(
                clientId: record.clientId,
                transcript: record.transcript,
                notes: record.notes,
                projectName: record.projectName,
                capturedAt: record.capturedAt,
                serverRecord: record,
                presentation: presentation
            )
        }

        // Local drafts fill in any clientId not yet represented server-side
        // (still queued/syncing/syncFailed — no server record exists yet).
        for draft in latestDrafts where byClientId[draft.clientId] == nil {
            let presentation = StatusPresentation.present(localState: draft.localState, serverRecord: nil)
            byClientId[draft.clientId] = HistoryRowViewModel(
                clientId: draft.clientId,
                transcript: draft.transcript,
                notes: draft.notes,
                projectName: draft.projectName,
                capturedAt: draft.capturedAt,
                serverRecord: nil,
                presentation: presentation
            )
        }

        let merged = byClientId.values.sorted { $0.capturedAt > $1.capturedAt }
        rows = merged
        hasUnreadReadyCaptures = merged.contains {
            $0.serverRecord?.status == .ready && $0.serverRecord?.openedAt == nil
        }
    }

    // MARK: - Filtering (search + archived)

    /// Rows presented to the UI: excludes archived unless `showArchived` is
    /// set (TECH-SPEC §7 `captures.archive`: "archived rows leave the
    /// default view ... reachable via a filter, not deleted"), and filtered
    /// by `searchText` against transcript/notes/project (plan U9: "searchable
    /// (transcript/notes/project)").
    public var visibleRows: [HistoryRowViewModel] {
        rows
            .filter { showArchived || !$0.isArchived }
            .filter { row in
                guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
                let needle = searchText.lowercased()
                return row.transcript.lowercased().contains(needle)
                    || row.notes.lowercased().contains(needle)
                    || row.projectName.lowercased().contains(needle)
            }
    }

    // MARK: - Row actions

    /// Opens a row's deep link (History row or notification click use the
    /// same path): marks opened server-side, then opens the URL. Idempotent
    /// — opening an already-opened row does not re-patch or re-decrement the
    /// ready-indicator count (TECH-SPEC §7 `captures.markOpened`: "first open
    /// wins").
    public func openDeepLink(for row: HistoryRowViewModel, urlOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        guard let record = row.serverRecord, let deepLink = record.deepLink, let url = URL(string: deepLink) else { return }

        if record.openedAt == nil {
            Task { [convex] in
                try? await convex.capturesMarkOpened(id: record.id)
            }
        }
        urlOpener(url)
    }

    public func archive(_ row: HistoryRowViewModel) {
        guard let record = row.serverRecord else { return }
        Task { [convex] in
            try? await convex.capturesArchive(id: record.id)
        }
    }

    public func retry(_ row: HistoryRowViewModel) {
        guard let record = row.serverRecord else { return }
        Task { [convex] in
            try? await convex.capturesRetry(id: record.id)
        }
    }

    /// Local `syncFailed` rows (`.localRetry`): no server record exists yet,
    /// so there's nothing to `captures.retry` -- instead this re-drains
    /// `SyncEngine` to retry the local-to-server sync. Wired by
    /// `AppDelegate` (`onLocalRetryRequested`) to `syncEngine.drainOnce()`.
    public func localRetry(_ row: HistoryRowViewModel) {
        onLocalRetryRequested()
    }

    /// "Duplicate as new capture" (TECH-SPEC §4.1 HistoryWindow/
    /// CaptureViewModel rows, PRD F3.6): builds the `CapturePreFill` from
    /// this row's content. Screenshot bytes are resolved by the caller
    /// (`AppDelegate`/`HistoryWindowController`), since fetching them may
    /// require a network round-trip (server `screenshotId`) or a local file
    /// read (`CaptureStore`) depending on whether the row is local-only or
    /// server-synced -- this view model just describes what to pre-fill.
    public func duplicatePreFill(for row: HistoryRowViewModel, screenshotData: Data?) -> CapturePreFill {
        CapturePreFill(
            transcript: row.transcript,
            notes: row.notes,
            screenshotData: screenshotData,
            focusProjectPicker: true
        )
    }
}

// MARK: - SwiftUI window content

struct HistoryWindow: View {
    @ObservedObject var viewModel: HistoryViewModel
    var onDuplicate: (HistoryRowViewModel) -> Void
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if viewModel.visibleRows.isEmpty {
                emptyState
            } else {
                List(viewModel.visibleRows) { row in
                    HistoryRow(
                        row: row,
                        onOpenDeepLink: { viewModel.openDeepLink(for: row) },
                        onArchive: { viewModel.archive(row) },
                        onRetry: { viewModel.retry(row) },
                        onDuplicate: { onDuplicate(row) },
                        onOpenSettings: onOpenSettings,
                        onLocalRetry: { viewModel.localRetry(row) }
                    )
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { viewModel.start() }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search captures…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
            Toggle("Show archived", isOn: $viewModel.showArchived)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No captures yet")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - NSWindow wrapper

/// Owns the actual `NSWindow` hosting `HistoryWindow`. Opened from the
/// panel-header History icon (U8) or the status item's right-click menu
/// (U6) — both wired in `AppDelegate`.
@MainActor
public final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel: HistoryViewModel

    /// Invoked when the user chooses "Duplicate as new capture" on a row.
    /// `AppDelegate` wires this to `CapturePanelController.trigger(preFill:)`
    /// (the U8 hook), resolving screenshot bytes first as needed.
    public var onDuplicate: (HistoryRowViewModel) -> Void = { _ in }

    /// Auth-error rows' "Open Settings" affordance — wired by AppDelegate
    /// to the real SettingsWindow's API-key section (U10).
    public var onOpenSettings: () -> Void = {}

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = HistoryWindow(
            viewModel: viewModel,
            onDuplicate: { [weak self] row in
                self?.onDuplicate(row)
            },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
            }
        )
        let hosting = NSHostingView(rootView: content)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "History"
        newWindow.contentView = hosting
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
