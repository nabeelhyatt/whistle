// FirstLaunchUpdateGateTests.swift
// Covers `FirstLaunchUpdateGate` — the one-time first-launch update check that
// keeps a new user who downloaded a stale DMG from running it for a day (see
// UpdateCoordinator.swift's header). Sparkle is not involved here: the gate
// takes its two effects (probe / show-UI) as closures and its callbacks as
// plain method calls, so every branch is exercised in-process.
//
// The branch that matters most is the offline one: an early version of this
// recorded "already checked" BEFORE the feed answered, which meant a first
// launch with no network permanently suppressed the exact check we wanted.

import XCTest
@testable import Whistle

@MainActor
final class FirstLaunchUpdateGateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A per-test scratch domain — never the app's real defaults.
        suiteName = "FirstLaunchUpdateGateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private final class Effects {
        var probeCount = 0
        var showUICount = 0
    }

    private func makeGate(
        bundlePath: String = "/Applications/Whistle.app",
        timeout: Duration = .seconds(60),
        isEnabled: Bool = true,
        effects: Effects
    ) -> FirstLaunchUpdateGate {
        FirstLaunchUpdateGate(
            store: FirstLaunchUpdateCheckStore(defaults: defaults),
            bundlePath: bundlePath,
            timeout: timeout,
            isEnabled: isEnabled,
            probe: { effects.probeCount += 1 },
            showInteractiveUpdateUI: { effects.showUICount += 1 }
        )
    }

    private var isRetired: Bool {
        FirstLaunchUpdateCheckStore(defaults: defaults).isRetired
    }

    private var attempts: Int {
        FirstLaunchUpdateCheckStore(defaults: defaults).attempts
    }

    /// Fails rather than hangs if the gate never releases the wizard.
    private func assertSettles(
        _ gate: FirstLaunchUpdateGate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let settled = expectation(description: "gate settled")
        Task {
            await gate.waitUntilSettled()
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 2)
    }

    // MARK: - Skip paths (all of which must still release onboarding)

    func testRunningFromReadOnlyVolumeSkipsWithoutConsumingAnAttempt() async {
        let effects = Effects()
        let gate = makeGate(bundlePath: "/Volumes/Whistle 1.0.9/Whistle.app", effects: effects)

        gate.start()

        XCTAssertEqual(effects.probeCount, 0, "Sparkle cannot install onto a read-only volume")
        XCTAssertEqual(attempts, 0, "a skipped launch must not burn one of the three attempts")
        XCTAssertFalse(isRetired, "the check has to still run on the first launch from /Applications")
        await assertSettles(gate)
    }

    func testDisabledBuildSkipsAndStillReleasesOnboarding() async {
        let effects = Effects()
        let gate = makeGate(isEnabled: false, effects: effects)

        gate.start()

        XCTAssertEqual(effects.probeCount, 0)
        await assertSettles(gate)
    }

    func testAlreadyRetiredCheckDoesNotProbeAgain() async {
        FirstLaunchUpdateCheckStore(defaults: defaults).retire()
        let effects = Effects()
        let gate = makeGate(effects: effects)

        gate.start()

        XCTAssertEqual(effects.probeCount, 0)
        await assertSettles(gate)
    }

    func testAttemptsAreExhaustedAfterThreeInconclusiveLaunches() async {
        let store = FirstLaunchUpdateCheckStore(defaults: defaults)
        for _ in 0..<3 {
            let gate = makeGate(effects: Effects())
            gate.start()
            gate.noteFailure()
            gate.noteCycleFinished(error: URLError(.notConnectedToInternet))
        }
        XCTAssertFalse(
            defaults.bool(forKey: FirstLaunchUpdateCheckStore.completedKey),
            "no conclusive answer was ever received, so the check was never completed"
        )
        XCTAssertTrue(store.isRetired, "but the attempt backstop stops it retrying forever")

        let effects = Effects()
        let fourth = makeGate(effects: effects)
        fourth.start()
        XCTAssertEqual(effects.probeCount, 0)
        await assertSettles(fourth)
    }

    // MARK: - Conclusive outcomes

    func testUpToDateRetiresTheCheckAndShowsNoUI() async {
        let effects = Effects()
        let gate = makeGate(effects: effects)

        gate.start()
        XCTAssertEqual(effects.probeCount, 1)
        XCTAssertEqual(attempts, 1)

        gate.noteNoUpdate()
        gate.noteCycleFinished(error: nil)

        XCTAssertEqual(effects.showUICount, 0, "no update means no UI at all on first launch")
        XCTAssertTrue(isRetired)
        await assertSettles(gate)
    }

    func testUpdateFoundEscalatesToUIAndHoldsOnboardingUntilTheUserDecides() async {
        let effects = Effects()
        let gate = makeGate(effects: effects)

        gate.start()
        gate.noteFoundUpdate()
        XCTAssertFalse(isRetired, "not done until the prompt is actually on screen")
        gate.noteCycleFinished(error: nil)

        XCTAssertEqual(effects.showUICount, 1)
        gate.noteEscalationShown()
        XCTAssertTrue(isRetired, "the user has now been told; scheduled checks take it from here")

        // The wizard must not appear behind the update window...
        let settledEarly = expectation(description: "must not settle yet")
        settledEarly.isInverted = true
        let waiter = Task {
            await gate.waitUntilSettled()
            settledEarly.fulfill()
        }
        await fulfillment(of: [settledEarly], timeout: 0.5)

        // ...but must appear once the interactive session ends (installed,
        // skipped, or errored).
        gate.noteCycleFinished(error: nil)
        _ = await waiter.value
        await assertSettles(gate)
    }

    /// Regression: Sparkle refuses a check while a session is in progress and
    /// only logs about it, so a swallowed escalation used to leave the wizard
    /// waiting forever behind a prompt that never appeared — and record the
    /// check as done even though the user was told nothing.
    func testEscalationFailureReleasesOnboardingAndKeepsTheCheckArmed() async {
        let gate = makeGate(effects: Effects())

        gate.start()
        gate.noteFoundUpdate()
        gate.noteCycleFinished(error: nil)
        gate.noteEscalationFailed()

        XCTAssertFalse(isRetired, "the user never saw a prompt, so this must be retried")
        await assertSettles(gate)
    }

    /// Regression: Sparkle reports an up-to-date check twice — once via
    /// `updaterDidNotFindUpdate`, then again as an abort carrying its own
    /// "You're up to date!" error. The second report must not downgrade the
    /// first, or a current install re-probes on every launch and the log claims
    /// a failure that never happened.
    func testLateFailureDoesNotDowngradeAConclusiveUpToDateResult() async {
        let gate = makeGate(effects: Effects())

        gate.start()
        gate.noteNoUpdate()
        gate.noteFailure()          // Sparkle's follow-up abort
        gate.noteCycleFinished(error: nil)

        XCTAssertTrue(isRetired, "the feed answered; that answer stands")
        await assertSettles(gate)
    }

    // MARK: - Inconclusive outcomes must stay retryable

    func testFeedFailureReleasesOnboardingWithoutRetiringTheCheck() async {
        let effects = Effects()
        let gate = makeGate(effects: effects)

        gate.start()
        gate.noteFailure()
        gate.noteCycleFinished(error: URLError(.cannotFindHost))

        XCTAssertEqual(effects.showUICount, 0, "an unreachable feed must not surface an error sheet")
        XCTAssertFalse(isRetired, "offline first launch is exactly when the check must run again")
        await assertSettles(gate)
    }

    func testCycleErrorWithNoPrecedingCallbackIsTreatedAsInconclusive() async {
        let gate = makeGate(effects: Effects())

        gate.start()
        gate.noteCycleFinished(error: URLError(.timedOut))

        XCTAssertFalse(isRetired)
        await assertSettles(gate)
    }

    func testTimeoutReleasesOnboardingAndAbandonsEscalationForThisLaunch() async {
        let effects = Effects()
        let gate = makeGate(timeout: .milliseconds(10), effects: effects)

        gate.start()
        await assertSettles(gate)

        XCTAssertFalse(isRetired, "a slow feed must be retried, not written off")

        // A late answer must not pop a modal over a wizard the user has already
        // started reading.
        gate.noteFoundUpdate()
        gate.noteCycleFinished(error: nil)
        XCTAssertEqual(effects.showUICount, 0)

        // And a second waiter still returns promptly (the release happened
        // while the probe was nominally still running).
        await assertSettles(gate)
    }

    func testStartIsIdempotent() async {
        let effects = Effects()
        let gate = makeGate(effects: effects)

        gate.start()
        gate.start()

        XCTAssertEqual(effects.probeCount, 1)
        XCTAssertEqual(attempts, 1)
    }
}
