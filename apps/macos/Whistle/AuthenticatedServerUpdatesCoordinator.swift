import Combine
import WhistleCore

/// Applies each distinct authentication state to every app-wide
/// authenticated subscription in one ordered MainActor hop.
@MainActor
final class AuthenticatedServerUpdatesCoordinator {
    private var stateSubscription: AnyCancellable?

    init(
        auth: AuthController,
        history: HistoryViewModel,
        projects: ProjectsSyncCoordinator
    ) {
        stateSubscription = auth.$state
            .removeDuplicates()
            .sink { state in
                let enabled = state == .signedIn
                history.setServerUpdatesEnabled(enabled)
                projects.setServerUpdatesEnabled(enabled)
            }
    }
}
