import Combine
import WhistleCore

/// Applies each distinct authentication state to every app-wide
/// authenticated subscription in one ordered MainActor hop.
@MainActor
final class AuthenticatedServerUpdatesCoordinator {
    private let stateSubscription: AnyCancellable

    init(
        auth: AuthController,
        history: HistoryViewModel,
        projects: ProjectsSyncCoordinator
    ) {
        stateSubscription = auth.$state
            .map { $0 == .signedIn }
            .removeDuplicates()
            .sink { enabled in
                history.setServerUpdatesEnabled(enabled)
                projects.setServerUpdatesEnabled(enabled)
            }
    }
}
