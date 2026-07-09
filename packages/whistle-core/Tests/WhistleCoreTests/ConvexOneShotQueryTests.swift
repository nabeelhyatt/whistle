// ConvexOneShotQueryTests.swift
// Regression coverage for the query/mutation call-routing bug: convex-swift
// 0.8.1 exposes no one-shot query method (only `subscribe`, `mutation`,
// `action` — confirmed by reading ConvexMobile.swift), yet
// `settings:get`/`templates:get`/`captures:list`/`captures:get` are Convex
// *queries*. `LiveConvexService` previously called them via
// `client.mutation(...)`, which fails at runtime against a query function.
//
// The fix routes those calls through `LiveConvexService.authedQuery`, which
// reduces `client.subscribe(...)`'s indefinite Combine publisher to a single
// value via `LiveConvexService.firstValue`. `LiveConvexService` itself can't
// be driven hermetically (convex-swift's ffi-client seam is internal to the
// package, same constraint noted in ConvexAuthAttachmentTests), but
// `firstValue` takes a plain `AnyPublisher<T, ClientError>` and has no
// instance state, so it's fully testable against a synthetic publisher.

import Combine
import XCTest

@testable import WhistleCore

#if canImport(ConvexMobile)
    import ConvexMobile

    final class ConvexOneShotQueryTests: XCTestCase {
        func testReturnsFirstYieldedValue() async throws {
            let subject = PassthroughSubject<Int, ClientError>()

            async let result = LiveConvexService.firstValue(
                from: subject.eraseToAnyPublisher(), timeout: .seconds(5)
            )

            // Give the task group's subscribing task a moment to attach
            // before sending, then confirm a second value doesn't change
            // the outcome (proving only the FIRST value is taken).
            try await Task.sleep(for: .milliseconds(20))
            subject.send(1)
            subject.send(2)

            let value = try await result
            XCTAssertEqual(value, 1, "must resolve to the first yielded value, not a later one")
        }

        func testCancelsUpstreamSubscriptionAfterFirstValue() async throws {
            let subject = PassthroughSubject<Int, ClientError>()
            let cancelled = Flag()
            let publisher = subject
                .handleEvents(receiveCancel: { cancelled.set() })
                .eraseToAnyPublisher()

            async let result = LiveConvexService.firstValue(from: publisher, timeout: .seconds(5))
            try await Task.sleep(for: .milliseconds(20))
            subject.send(42)

            _ = try await result
            // Allow the task group's implicit cancel-and-await of the
            // (already-finished) subscribing task to settle.
            try await Task.sleep(for: .milliseconds(50))

            XCTAssertTrue(
                cancelled.get(),
                "the subscription must be cancelled once the first value is taken, not left running"
            )
        }

        func testThrowsWhenPublisherCompletesWithoutAValue() async {
            let subject = PassthroughSubject<Int, ClientError>()

            async let result = LiveConvexService.firstValue(
                from: subject.eraseToAnyPublisher(), timeout: .seconds(5)
            )
            try? await Task.sleep(for: .milliseconds(20))
            subject.send(completion: .finished)

            do {
                _ = try await result
                XCTFail("must throw when the query stream ends before yielding anything")
            } catch {
                XCTAssertEqual(error as? ConvexServiceError, .requestFailed("query completed without yielding a value"))
            }
        }

        func testTimesOutWhenNoValueArrives() async {
            let subject = PassthroughSubject<Int, ClientError>()

            do {
                _ = try await LiveConvexService.firstValue(
                    from: subject.eraseToAnyPublisher(), timeout: .milliseconds(30)
                )
                XCTFail("must throw when no value arrives before the timeout")
            } catch {
                XCTAssertEqual(error as? ConvexServiceError, .requestFailed("query timed out waiting for a value"))
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
#endif
