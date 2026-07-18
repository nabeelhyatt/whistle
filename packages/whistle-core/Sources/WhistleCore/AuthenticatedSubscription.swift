import Foundation

/// Supervises one long-lived authenticated stream while its owner declares
/// server updates enabled. Convex owns WebSocket reconnection; this type only
/// recreates an `AsyncStream` after that stream has actually terminated.
public final class AuthenticatedSubscription<Element: Sendable>: @unchecked Sendable {
    public typealias StreamFactory = @Sendable () -> AsyncStream<Element>
    public typealias ValueHandler = @Sendable (Element, AuthenticatedSubscriptionContext) async -> Void
    public typealias RetryDelay = @Sendable (_ attempt: Int) -> Duration
    public typealias Sleeper = @Sendable (_ delay: Duration) async throws -> Void

    private let label: String
    private let streamFactory: StreamFactory
    private let onValue: ValueHandler
    private let retryDelay: RetryDelay
    private let sleep: Sleeper
    private let state = AuthenticatedSubscriptionState()

    public init(
        label: String,
        stream: @escaping StreamFactory,
        onValue: @escaping ValueHandler,
        retryDelay: @escaping RetryDelay = { attempt in
            let cappedAttempt = min(max(attempt, 0), 7)
            return .milliseconds(min(30_000, 250 * (1 << cappedAttempt)))
        },
        sleep: @escaping Sleeper = { delay in try await Task.sleep(for: delay) }
    ) {
        self.label = label
        self.streamFactory = stream
        self.onValue = onValue
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    deinit {
        state.disable().task?.cancel()
    }

    /// Idempotently enables or disables the supervised stream.
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    private func enable() {
        guard let token = state.reserveEnable() else { return }

        let task = Task { [state, label, streamFactory, onValue, retryDelay, sleep] in
            await Self.run(
                token: token,
                state: state,
                label: label,
                streamFactory: streamFactory,
                onValue: onValue,
                retryDelay: retryDelay,
                sleep: sleep
            )
            state.finish(token: token)
        }
        state.install(task: task, token: token)
    }

    private func disable() {
        let result = state.disable()
        result.task?.cancel()
        if result.wasEnabled {
            NSLog("Whistle: authenticated subscription %@ disabled", label)
        }
    }

    private static func run(
        token: AuthenticatedSubscriptionToken,
        state: AuthenticatedSubscriptionState,
        label: String,
        streamFactory: StreamFactory,
        onValue: ValueHandler,
        retryDelay: RetryDelay,
        sleep: Sleeper
    ) async {
        var retryAttempt = 0

        while state.isCurrent(token), !Task.isCancelled {
            let stream = streamFactory()
            let context = AuthenticatedSubscriptionContext {
                state.isCurrent(token)
            }

            for await value in stream {
                guard state.isCurrent(token), !Task.isCancelled else { return }
                await onValue(value, context)
                guard state.isCurrent(token), !Task.isCancelled else { return }

                if retryAttempt > 0 {
                    NSLog("Whistle: authenticated subscription %@ reconnected", label)
                }
                retryAttempt = 0
            }

            guard state.isCurrent(token), !Task.isCancelled else { return }

            let delay = retryDelay(retryAttempt)
            NSLog(
                "Whistle: authenticated subscription %@ ended; retrying attempt %d after %@",
                label,
                retryAttempt + 1,
                String(describing: delay)
            )
            do {
                try await sleep(delay)
            } catch is CancellationError {
                return
            } catch {
                if state.isCurrent(token), !Task.isCancelled {
                    NSLog(
                        "Whistle: authenticated subscription %@ retry sleep failed: %@",
                        label,
                        String(describing: error)
                    )
                }
                guard state.isCurrent(token), !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            retryAttempt += 1
        }
    }
}

/// A generation fence for handlers that cross an actor boundary. Owners
/// should check this immediately before applying a value so a callback that
/// was queued before sign-out cannot mutate state after a later sign-in.
public struct AuthenticatedSubscriptionContext: @unchecked Sendable {
    private let checkIsCurrent: @Sendable () -> Bool

    fileprivate init(checkIsCurrent: @escaping @Sendable () -> Bool) {
        self.checkIsCurrent = checkIsCurrent
    }

    public var isCurrent: Bool { checkIsCurrent() }
}

private final class AuthenticatedSubscriptionToken: @unchecked Sendable {}

private final class AuthenticatedSubscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var currentToken: AuthenticatedSubscriptionToken?
    private var workerTask: Task<Void, Never>?

    func reserveEnable() -> AuthenticatedSubscriptionToken? {
        lock.withLock {
            guard !enabled else { return nil }
            enabled = true
            let token = AuthenticatedSubscriptionToken()
            currentToken = token
            return token
        }
    }

    func install(task: Task<Void, Never>, token: AuthenticatedSubscriptionToken) {
        let shouldCancel = lock.withLock {
            guard enabled, currentToken === token else { return true }
            workerTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func disable() -> (wasEnabled: Bool, task: Task<Void, Never>?) {
        lock.withLock {
            let wasEnabled = enabled
            enabled = false
            currentToken = nil
            defer { workerTask = nil }
            return (wasEnabled, workerTask)
        }
    }

    func finish(token: AuthenticatedSubscriptionToken) {
        lock.withLock {
            guard currentToken === token else { return }
            enabled = false
            currentToken = nil
            workerTask = nil
        }
    }

    func isCurrent(_ token: AuthenticatedSubscriptionToken) -> Bool {
        lock.withLock { enabled && currentToken === token }
    }
}
