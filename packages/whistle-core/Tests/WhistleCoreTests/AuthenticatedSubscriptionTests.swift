import Foundation
import XCTest
@testable import WhistleCore

final class AuthenticatedSubscriptionTests: XCTestCase {
    func testTerminatedStreamRestartsWithoutAnotherEnableCall() async {
        let harness = SubscriptionStreamHarness<Int>()
        let secondSubscription = expectation(description: "replacement subscription")
        harness.onSubscription = { count in
            if count == 2 { secondSubscription.fulfill() }
        }

        let subscription = AuthenticatedSubscription(
            label: "test",
            stream: { harness.makeStream() },
            onValue: { _, _ in },
            retryDelay: { _ in .zero },
            sleep: { _ in }
        )

        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(1)
        harness.finishSubscription(at: 0)

        await fulfillment(of: [secondSubscription], timeout: 1)
        XCTAssertEqual(harness.subscriptionCount, 2)
        subscription.setEnabled(false)
    }

    func testRepeatedEnableKeepsSingleSubscription() async {
        let harness = SubscriptionStreamHarness<Int>()
        let subscription = AuthenticatedSubscription(
            label: "test",
            stream: { harness.makeStream() },
            onValue: { _, _ in }
        )

        subscription.setEnabled(true)
        subscription.setEnabled(true)
        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(1)

        XCTAssertEqual(harness.subscriptionCount, 1)
        subscription.setEnabled(false)
    }

    func testBackoffAdvancesAndResetsAfterAValue() async {
        let harness = SubscriptionStreamHarness<Int>()
        let delays = LockedValues<Duration>()
        let valueDelivered = expectation(description: "value delivered")
        let subscription = AuthenticatedSubscription(
            label: "test",
            stream: { harness.makeStream() },
            onValue: { _, _ in valueDelivered.fulfill() },
            retryDelay: { attempt in .milliseconds(10 * (attempt + 1)) },
            sleep: { delay in delays.append(delay) }
        )

        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(1)
        harness.finishSubscription(at: 0)
        await harness.waitForSubscriptionCount(2)
        harness.finishSubscription(at: 1)
        await harness.waitForSubscriptionCount(3)
        harness.yield(42, to: 2)
        await fulfillment(of: [valueDelivered], timeout: 1)
        harness.finishSubscription(at: 2)
        await harness.waitForSubscriptionCount(4)

        XCTAssertEqual(delays.values, [.milliseconds(10), .milliseconds(20), .milliseconds(10)])
        subscription.setEnabled(false)
    }

    func testDisableDuringBackoffCancelsWithoutRestart() async {
        let harness = SubscriptionStreamHarness<Int>()
        let sleepStarted = expectation(description: "backoff started")
        let unexpectedRestart = expectation(description: "no replacement")
        unexpectedRestart.isInverted = true
        harness.onSubscription = { count in
            if count == 2 { unexpectedRestart.fulfill() }
        }

        let subscription = AuthenticatedSubscription(
            label: "test",
            stream: { harness.makeStream() },
            onValue: { _, _ in },
            retryDelay: { _ in .seconds(60) },
            sleep: { delay in
                sleepStarted.fulfill()
                try await Task.sleep(for: delay)
            }
        )

        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(1)
        harness.finishSubscription(at: 0)
        await fulfillment(of: [sleepStarted], timeout: 1)
        subscription.setEnabled(false)

        await fulfillment(of: [unexpectedRestart], timeout: 0.1)
        XCTAssertEqual(harness.subscriptionCount, 1)
    }

    func testDisableAndReenableFencesLateOldValues() async {
        let harness = SubscriptionStreamHarness<Int>()
        let received = LockedValues<Int>()
        let currentValueDelivered = expectation(description: "current value delivered")
        let subscription = AuthenticatedSubscription(
            label: "test",
            stream: { harness.makeStream() },
            onValue: { value, _ in
                received.append(value)
                if value == 2 { currentValueDelivered.fulfill() }
            }
        )

        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(1)
        subscription.setEnabled(false)
        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(2)

        harness.yield(1, to: 0)
        harness.yield(2, to: 1)
        await fulfillment(of: [currentValueDelivered], timeout: 1)

        XCTAssertEqual(received.values, [2])
        subscription.setEnabled(false)
        await harness.waitForTerminationCount(2)
    }

    func testHandlerCanFenceAValueAfterCrossingAnActorBoundary() async {
        let harness = SubscriptionStreamHarness<Int>()
        let gate = AsyncTestGate()
        let received = LockedValues<Int>()
        let oldHandlerStarted = expectation(description: "old handler started")
        let currentValueDelivered = expectation(description: "current value delivered")
        let subscription = AuthenticatedSubscription(
            label: "test",
            stream: { harness.makeStream() },
            onValue: { value, context in
                if value == 1 { oldHandlerStarted.fulfill() }
                await gate.wait()
                guard context.isCurrent else { return }
                received.append(value)
                if value == 2 { currentValueDelivered.fulfill() }
            }
        )

        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(1)
        harness.yield(1, to: 0)
        await fulfillment(of: [oldHandlerStarted], timeout: 1)

        subscription.setEnabled(false)
        subscription.setEnabled(true)
        await harness.waitForSubscriptionCount(2)
        await gate.release()
        harness.yield(2, to: 1)
        await fulfillment(of: [currentValueDelivered], timeout: 1)

        XCTAssertEqual(received.values, [2])
        subscription.setEnabled(false)
    }

    func testDeinitCancelsActiveSubscription() async {
        let harness = SubscriptionStreamHarness<Int>()
        weak var weakSubscription: AuthenticatedSubscription<Int>?

        do {
            let subscription = AuthenticatedSubscription(
                label: "test",
                stream: { harness.makeStream() },
                onValue: { _, _ in }
            )
            weakSubscription = subscription
            subscription.setEnabled(true)
            await harness.waitForSubscriptionCount(1)
        }

        XCTAssertNil(weakSubscription)
        await harness.waitForTerminationCount(1)
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] { lock.withLock { storage } }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private final class SubscriptionStreamHarness<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Element>.Continuation] = []
    private var subscriptionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var terminationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var terminations = 0

    var onSubscription: (@Sendable (Int) -> Void)?

    var subscriptionCount: Int { lock.withLock { continuations.count } }

    func makeStream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let result: (Int, [CheckedContinuation<Void, Never>]) = lock.withLock {
                continuations.append(continuation)
                let count = continuations.count
                let ready = subscriptionWaiters.filter { count >= $0.0 }.map(\.1)
                subscriptionWaiters.removeAll { count >= $0.0 }
                return (count, ready)
            }
            continuation.onTermination = { [weak self] _ in self?.recordTermination() }
            result.1.forEach { $0.resume() }
            onSubscription?(result.0)
        }
    }

    func yield(_ value: Element, to index: Int) {
        let continuation = lock.withLock { continuations[index] }
        continuation.yield(value)
    }

    func finishSubscription(at index: Int) {
        lock.withLock { continuations[index] }.finish()
    }

    func waitForSubscriptionCount(_ expected: Int) async {
        if subscriptionCount >= expected { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if continuations.count >= expected { return true }
                subscriptionWaiters.append((expected, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitForTerminationCount(_ expected: Int) async {
        if lock.withLock({ terminations >= expected }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if terminations >= expected { return true }
                terminationWaiters.append((expected, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func recordTermination() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            terminations += 1
            let ready = terminationWaiters.filter { terminations >= $0.0 }.map(\.1)
            terminationWaiters.removeAll { terminations >= $0.0 }
            return ready
        }
        ready.forEach { $0.resume() }
    }
}
