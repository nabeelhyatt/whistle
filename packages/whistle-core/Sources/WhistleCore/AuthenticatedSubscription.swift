import Foundation

/// Supervises one long-lived authenticated stream while its owner declares
/// server updates enabled. Convex owns WebSocket reconnection; this type only
/// recreates an `AsyncStream` after that stream has actually terminated.
public final class AuthenticatedSubscription<Element: Sendable>: @unchecked Sendable {
    public typealias StreamFactory = @Sendable () -> AsyncStream<Element>
    public typealias ValueHandler = @Sendable (Element) async -> Void
    public typealias RetryDelay = @Sendable (_ attempt: Int) -> Duration
    public typealias Sleeper = @Sendable (_ delay: Duration) async throws -> Void

    private let label: String
    private let streamFactory: StreamFactory
    private let onValue: ValueHandler
    private let retryDelay: RetryDelay
    private let sleep: Sleeper
    private let gate = AuthenticatedSubscriptionGate()
    private let taskLock = NSLock()
    private var workerTask: Task<Void, Never>?

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
        _ = gate.disable()
        takeWorkerTask()?.cancel()
    }

    /// Idempotently enables or disables the supervised stream.
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    public func enable() {
        guard let generation = gate.enable() else { return }

        let task = Task { [weak self, gate, label, streamFactory, onValue, retryDelay, sleep] in
            await Self.run(
                generation: generation,
                gate: gate,
                label: label,
                streamFactory: streamFactory,
                onValue: onValue,
                retryDelay: retryDelay,
                sleep: sleep
            )
            self?.clearWorkerTask(generation: generation)
        }

        taskLock.withLock {
            if gate.isCurrent(generation) {
                workerTask = task
            } else {
                task.cancel()
            }
        }
    }

    public func disable() {
        let wasEnabled = gate.disable()
        takeWorkerTask()?.cancel()
        if wasEnabled {
            NSLog("Whistle: authenticated subscription %@ disabled", label)
        }
    }

    private static func run(
        generation: Int,
        gate: AuthenticatedSubscriptionGate,
        label: String,
        streamFactory: StreamFactory,
        onValue: ValueHandler,
        retryDelay: RetryDelay,
        sleep: Sleeper
    ) async {
        var retryAttempt = 0
        var reconnecting = false

        while gate.isCurrent(generation), !Task.isCancelled {
            let stream = streamFactory()

            for await value in stream {
                guard gate.isCurrent(generation), !Task.isCancelled else { return }
                await onValue(value)
                guard gate.isCurrent(generation), !Task.isCancelled else { return }

                if reconnecting {
                    NSLog("Whistle: authenticated subscription %@ reconnected", label)
                    reconnecting = false
                }
                retryAttempt = 0
            }

            guard gate.isCurrent(generation), !Task.isCancelled else { return }

            let delay = retryDelay(retryAttempt)
            NSLog(
                "Whistle: authenticated subscription %@ ended; retrying attempt %d after %@",
                label,
                retryAttempt + 1,
                String(describing: delay)
            )
            reconnecting = true

            do {
                try await sleep(delay)
            } catch {
                if gate.isCurrent(generation), !Task.isCancelled {
                    NSLog(
                        "Whistle: authenticated subscription %@ retry sleep failed: %@",
                        label,
                        String(describing: error)
                    )
                }
                return
            }
            retryAttempt += 1
        }
    }

    private func takeWorkerTask() -> Task<Void, Never>? {
        taskLock.withLock {
            defer { workerTask = nil }
            return workerTask
        }
    }

    private func clearWorkerTask(generation: Int) {
        guard gate.isCurrent(generation) else { return }
        taskLock.withLock { workerTask = nil }
    }
}

private final class AuthenticatedSubscriptionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0

    func enable() -> Int? {
        lock.withLock {
            guard !enabled else { return nil }
            enabled = true
            generation += 1
            return generation
        }
    }

    @discardableResult
    func disable() -> Bool {
        lock.withLock {
            let wasEnabled = enabled
            enabled = false
            generation += 1
            return wasEnabled
        }
    }

    func isCurrent(_ candidate: Int) -> Bool {
        lock.withLock { enabled && generation == candidate }
    }
}
