// ConvexReconnectTests.swift
// Regression/behavior coverage for self-healing a wedged Convex websocket
// (see the "self-heal a wedged Convex connection" plan). convex-swift 0.8.1's
// `ConvexClient` has no reconnect API and its FFI calls don't check Swift
// cancellation, so a dropped websocket previously wedged `LiveConvexService`
// forever — every call kept timing out against the same dead client with no
// recovery short of an app relaunch.
//
// The fix: `ConvexConnectionHealthTracker` detects a generation-stamped
// consecutive-timeout streak and `LiveConvexService.rebuildClient()` swaps in
// a fresh client via the `makeClient` factory seam, bumping the generation
// and resetting the auth-attach gate. These tests cover:
//   1. `ConvexConnectionHealthTracker` in isolation (fast, no live client) —
//      threshold, cooldown, and the generation-stale-outcome guard that kills
//      the stale-completion race (KTD2/R2).
//   2. `LiveConvexService` driven end-to-end against a `FakeConvexClientAdapter`
//      (the `init(makeClient:)` test seam) — rebuild-after-2, the new client
//      actually gets used, `onConnectionRebuilt` fires once per rebuild, and
//      the `asyncStream` bridge resubscribes on the new client without
//      finishing the stream.
//
// Fake mutation/action calls report a timeout OUTCOME by throwing the same
// `ConvexServiceError.requestFailed("...timed out...")` `withTimeout` itself
// would produce, rather than actually hanging for the real 15s
// `authedCallTimeout` — that duration isn't test-injectable (by design, it's
// a fixed production constant), and `ConvexTimeoutTests` already covers
// `withTimeout`'s real hang-and-race behavior in isolation. This keeps these
// tests fast while still exercising the exact classify -> record -> rebuild
// wiring `authedMutation`/`authedAction`/`authedQuery`/`ensureAuthAttached`
// actually run.

import Combine
import XCTest

@testable import WhistleCore

// MARK: - ConvexConnectionHealthTracker (pure, no live client needed)

final class ConvexConnectionHealthTrackerTests: XCTestCase {
    func testTripsAfterExactlyThresholdConsecutiveTimeouts() {
        let tracker = ConvexConnectionHealthTracker(threshold: 2, cooldown: 60)

        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 0), "must not trip on the first timeout")
        XCTAssertTrue(tracker.recordOutcome(.timedOut, clientGeneration: 0), "must trip on the second consecutive timeout")
    }

    func testSuccessResetsTheCounterSoATripNeedsAFreshStreak() {
        let tracker = ConvexConnectionHealthTracker(threshold: 2, cooldown: 60)

        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 0))
        XCTAssertFalse(tracker.recordOutcome(.success, clientGeneration: 0), "success is never itself a trip signal")
        XCTAssertFalse(
            tracker.recordOutcome(.timedOut, clientGeneration: 0),
            "one timeout after a reset must not immediately re-trip"
        )
        XCTAssertTrue(tracker.recordOutcome(.timedOut, clientGeneration: 0), "a fresh 2-streak must still trip")
    }

    func testNeutralOutcomeNeitherIncrementsNorResets() {
        let tracker = ConvexConnectionHealthTracker(threshold: 2, cooldown: 60)

        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 0))
        XCTAssertFalse(tracker.recordOutcome(.neutral, clientGeneration: 0), "neutral (missing-token) must not count")
        XCTAssertTrue(
            tracker.recordOutcome(.timedOut, clientGeneration: 0),
            "the streak from before the neutral outcome must still be intact"
        )
    }

    func testStaleGenerationTimeoutIsIgnoredEntirely() {
        let tracker = ConvexConnectionHealthTracker(threshold: 2, cooldown: 60)

        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 0))
        // Simulate a rebuild having happened (generation now 1) by recording
        // against generation 1 directly is awkward without noteRebuilt(), so
        // drive it via the real API: a matching-gen timeout trips at 2, which
        // bumps the generation via `noteRebuilt()` -- but `recordOutcome`
        // itself never calls that. Exercise the guard directly instead: an
        // outcome stamped with a generation that ISN'T current (1, while the
        // tracker is still at 0) must be a pure no-op.
        XCTAssertFalse(
            tracker.recordOutcome(.timedOut, clientGeneration: 1),
            "an outcome from a not-yet-current generation must be ignored, not trip early"
        )
        // The real (generation 0) streak must be completely unaffected by
        // the stale-generation call above.
        XCTAssertTrue(tracker.recordOutcome(.timedOut, clientGeneration: 0), "the gen-0 streak must still trip at its own 2nd timeout")
    }

    func testStaleGenerationSuccessDoesNotResetTheCurrentStreak() {
        let tracker = ConvexConnectionHealthTracker(threshold: 2, cooldown: 60)

        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 0))
        XCTAssertFalse(
            tracker.recordOutcome(.success, clientGeneration: 1),
            "a success stamped with a not-yet-current generation must be ignored"
        )
        XCTAssertTrue(
            tracker.recordOutcome(.timedOut, clientGeneration: 0),
            "the stale-generation success above must NOT have reset the real (generation 0) streak"
        )
    }

    func testCooldownSuppressesARebuildWithinTheWindow() {
        let clockBox = ClockBox(start: Date(timeIntervalSince1970: 0))
        let tracker = ConvexConnectionHealthTracker(threshold: 2, cooldown: 60, now: { clockBox.now })

        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 0))
        XCTAssertTrue(tracker.recordOutcome(.timedOut, clientGeneration: 0), "first trip must fire")
        _ = tracker.noteRebuilt()

        clockBox.advance(by: 10) // well within the 60s cooldown
        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 1))
        XCTAssertFalse(
            tracker.recordOutcome(.timedOut, clientGeneration: 1),
            "a second threshold-crossing within the cooldown window must NOT trip again"
        )

        // The streak never reset (only the cooldown blocked it), so once
        // the cooldown elapses the very next timeout re-crosses the
        // still-exceeded threshold and trips immediately -- no fresh 2-streak
        // is required.
        clockBox.advance(by: 60) // now well past the cooldown
        XCTAssertTrue(
            tracker.recordOutcome(.timedOut, clientGeneration: 1),
            "once the cooldown elapses, the still-exceeded streak must trip on the next timeout"
        )
    }

    func testNoteRebuiltBumpsGenerationAndZeroesTheCounter() {
        let tracker = ConvexConnectionHealthTracker(threshold: 2, cooldown: 0)

        XCTAssertEqual(tracker.currentGeneration, 0)
        XCTAssertFalse(tracker.recordOutcome(.timedOut, clientGeneration: 0))
        XCTAssertTrue(tracker.recordOutcome(.timedOut, clientGeneration: 0))

        let newGeneration = tracker.noteRebuilt()

        XCTAssertEqual(newGeneration, 1)
        XCTAssertEqual(tracker.currentGeneration, 1)
        XCTAssertFalse(tracker.isDegraded, "the counter must be zeroed immediately after a rebuild")
    }

    func testIsDegradedTracksAtLeastOneUnresolvedTimeout() {
        let tracker = ConvexConnectionHealthTracker(threshold: 5, cooldown: 60)

        XCTAssertFalse(tracker.isDegraded)
        _ = tracker.recordOutcome(.timedOut, clientGeneration: 0)
        XCTAssertTrue(tracker.isDegraded, "a single timeout must already mark the connection degraded")
        _ = tracker.recordOutcome(.success, clientGeneration: 0)
        XCTAssertFalse(tracker.isDegraded, "a success must clear degraded state")
    }
}

// MARK: - LiveConvexService end-to-end against a fake client

#if canImport(ConvexMobile)
    import ConvexMobile

    final class ConvexReconnectLiveServiceTests: XCTestCase {
        func testRebuildsAfterTwoConsecutiveMatchingGenerationTimeouts() async throws {
            let fakes = FakeClientFactory()
            let service = LiveConvexService(
                makeClient: { fakes.makeNext() },
                healthTracker: ConvexConnectionHealthTracker(threshold: 2, cooldown: 0)
            )

            fakes.current.mutationHandler = { _ in
                throw ConvexServiceError.requestFailed("operation timed out")
            }

            _ = try? await service.usersEnsure() // timeout #1 -- no rebuild yet
            XCTAssertEqual(fakes.madeCount, 1, "must not have rebuilt after only one timeout")

            _ = try? await service.usersEnsure() // timeout #2 -- trips the rebuild
            XCTAssertEqual(fakes.madeCount, 2, "must rebuild exactly once after the 2nd consecutive timeout")

            // The NEW fake must actually be the one serving the next call.
            fakes.current.mutationHandler = { _ in "fresh-token" }
            let result = try await service.usersEnsure()
            XCTAssertEqual(result, "fresh-token")
            XCTAssertEqual(fakes.all[1].mutationCallCount, 1, "the post-rebuild call must reach the NEW client")
        }

        func testNoRebuildOnOneTimeoutThenSuccess() async throws {
            let fakes = FakeClientFactory()
            let service = LiveConvexService(
                makeClient: { fakes.makeNext() },
                healthTracker: ConvexConnectionHealthTracker(threshold: 2, cooldown: 0)
            )

            fakes.current.mutationHandler = { _ in
                throw ConvexServiceError.requestFailed("operation timed out")
            }
            _ = try? await service.usersEnsure()

            fakes.current.mutationHandler = { _ in "ok" }
            _ = try await service.usersEnsure() // success resets the streak

            fakes.current.mutationHandler = { _ in
                throw ConvexServiceError.requestFailed("operation timed out")
            }
            _ = try? await service.usersEnsure() // only 1 fresh timeout -- must not trip

            XCTAssertEqual(fakes.madeCount, 1, "an intervening success must prevent a rebuild from a single fresh timeout")
        }

        func testOnConnectionRebuiltFiresExactlyOncePerRebuild() async throws {
            let fakes = FakeClientFactory()
            let service = LiveConvexService(
                makeClient: { fakes.makeNext() },
                healthTracker: ConvexConnectionHealthTracker(threshold: 2, cooldown: 0)
            )
            let rebuildCount = Counter()
            service.onConnectionRebuilt = { rebuildCount.increment() }

            fakes.current.mutationHandler = { _ in
                throw ConvexServiceError.requestFailed("operation timed out")
            }
            _ = try? await service.usersEnsure()
            _ = try? await service.usersEnsure()

            // Give the fire-and-forget `Task { await onConnectionRebuilt() }` a
            // moment to run.
            try await Task.sleep(for: .milliseconds(50))

            XCTAssertEqual(rebuildCount.value, 1)
        }

        func testIsConnectionDegradedReflectsTheHealthTracker() async throws {
            let fakes = FakeClientFactory()
            let service = LiveConvexService(
                makeClient: { fakes.makeNext() },
                healthTracker: ConvexConnectionHealthTracker(threshold: 5, cooldown: 0)
            )

            XCTAssertFalse(service.isConnectionDegraded)

            fakes.current.mutationHandler = { _ in
                throw ConvexServiceError.requestFailed("operation timed out")
            }
            _ = try? await service.usersEnsure()

            XCTAssertTrue(service.isConnectionDegraded)

            fakes.current.mutationHandler = { _ in "ok" }
            _ = try await service.usersEnsure()

            XCTAssertFalse(service.isConnectionDegraded)
        }

        func testAsyncStreamBridgeResubscribesOnTheNewClientAfterARebuild() async throws {
            let fakes = FakeClientFactory()
            let service = LiveConvexService(
                makeClient: { fakes.makeNext() },
                healthTracker: ConvexConnectionHealthTracker(threshold: 2, cooldown: 0)
            )

            let stream = service.projectsList()
            var iterator = stream.makeAsyncIterator()

            // First subscription lands on the first fake.
            try await Task.sleep(for: .milliseconds(20))
            let firstSubject = fakes.current.lastSubscribeSubject
            firstSubject?.send([Project(id: "p1", name: "one", gitRemote: "git@x")])
            let firstValue = await iterator.next()
            XCTAssertEqual(firstValue?.first?.id, "p1")

            // Trip a rebuild via two consecutive mutation timeouts (the
            // subscription itself never times out -- it's the mutation path
            // that trips the tracker per KTD1).
            fakes.current.mutationHandler = { _ in
                throw ConvexServiceError.requestFailed("operation timed out")
            }
            _ = try? await service.usersEnsure()
            _ = try? await service.usersEnsure()

            // Give the resubscribe loop a moment to notice the generation
            // change and resubscribe on the new (second) fake.
            try await Task.sleep(for: .milliseconds(50))
            let secondSubject = fakes.all[1].lastSubscribeSubject
            XCTAssertNotNil(secondSubject, "the bridge must resubscribe on the NEW client, not go silent")

            secondSubject?.send([Project(id: "p2", name: "two", gitRemote: "git@y")])
            let secondValue = await iterator.next()
            XCTAssertEqual(
                secondValue?.first?.id, "p2",
                "the SAME AsyncStream iterator must keep yielding after a rebuild, with no finished/duplicate emission"
            )
        }
    }

    // MARK: - Test doubles

    /// Hands out a fresh `FakeConvexClientAdapter` on every call — mirrors
    /// exactly what `rebuildClient()` calling `makeClient()` again looks
    /// like from the outside (once at `LiveConvexService.init`, then once
    /// per rebuild).
    private final class FakeClientFactory: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var all: [FakeConvexClientAdapter] = []

        func makeNext() -> any ConvexClientAdapter {
            lock.withLock {
                let fake = FakeConvexClientAdapter()
                all.append(fake)
                return fake
            }
        }

        var current: FakeConvexClientAdapter {
            lock.withLock { all[all.count - 1] }
        }

        var madeCount: Int {
            lock.withLock { all.count }
        }
    }

    /// Fake `ConvexClientAdapter`: mutation/action outcomes are scripted via
    /// throwing closures (see the file doc for why this models a timeout by
    /// throwing the same error `withTimeout` would, rather than actually
    /// hanging for the real 15s production timeout).
    private final class FakeConvexClientAdapter: ConvexClientAdapter, @unchecked Sendable {
        private let lock = NSLock()
        var mutationHandler: @Sendable (String) throws -> Any = { _ in "ok" }
        var actionHandler: @Sendable (String) throws -> Any = { _ in "ok" }
        var loginFromCacheHandler: @Sendable () -> Result<String, Error> = { .success("token") }
        private(set) var mutationCallCount = 0
        private(set) var lastSubscribeSubject: PassthroughSubject<Any, ClientError>?

        func mutation<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]?) async throws -> T {
            lock.withLock { mutationCallCount += 1 }
            let raw = try mutationHandler(name)
            guard let value = raw as? T else {
                throw ConvexServiceError.decodingFailed("FakeConvexClientAdapter: cannot cast fake payload to \(T.self)")
            }
            return value
        }

        func mutation(_ name: String, with args: [String: ConvexEncodable?]?) async throws {
            let _: String? = try await mutation(name, with: args)
        }

        func action<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]?) async throws -> T {
            let raw = try actionHandler(name)
            guard let value = raw as? T else {
                throw ConvexServiceError.decodingFailed("FakeConvexClientAdapter: cannot cast fake payload to \(T.self)")
            }
            return value
        }

        func action(_ name: String, with args: [String: ConvexEncodable?]?) async throws {
            let _: String? = try await action(name, with: args)
        }

        func subscribe<T: Decodable>(
            to name: String, with args: [String: ConvexEncodable?]?, yielding output: T.Type?
        ) -> AnyPublisher<T, ClientError> {
            let subject = PassthroughSubject<Any, ClientError>()
            lock.withLock { lastSubscribeSubject = subject }
            return subject.compactMap { $0 as? T }.eraseToAnyPublisher()
        }

        func loginFromCache() async -> Result<String, Error> {
            loginFromCacheHandler()
        }

        func logout() async {}

        func watchWebSocketState() -> AnyPublisher<WebSocketState, Never> {
            Empty<WebSocketState, Never>().eraseToAnyPublisher()
        }
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { current = start }
        var now: Date { lock.withLock { current } }
        func advance(by seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
#endif

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
