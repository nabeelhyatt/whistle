// OnboardingGatingTests.swift
// Plan U10 scenarios (all against fakes — no network, no TCC, no real
// Keychain), plus the SettingsWindow / TemplateEditor scenarios:
//   - Happy: all-granted path reaches test capture in the new order;
//     completion flag persists.
//   - Edge: each permission denied on the combined screen -> wizard
//     proceeds with degraded messaging (never hard-blocks except sign-in
//     and API key).
//   - Error: invalid key -> inline error, step doesn't advance.
//   - Happy: exactly one project -> project step skipped/auto-selected.
//   - Happy: multiple projects -> picker step shown.
//   - Happy: template edit -> save calls templates.update; reset restores
//     the default.
//   - Happy: lint warns on a missing "How to end" contract block (the
//     "Clarifying questions:" marker heuristic), clears when present, and
//     never blocks saving.
//   - Edge: wizard killed/relaunched mid-flow -> resumes at the correct
//     step with earlier grants intact.
//   - Happy: screenshot upsell only after the first successful test
//     capture; declining doesn't block completion.

import XCTest
@testable import Whistle
@testable import WhistleCore

// MARK: - Fake ConvexService (scriptable settings/templates/validate/projects)

private final class FakeOnboardingConvexService: ConvexServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()

    // Scripted behavior
    var validateKeyResult: Result<Bool, Error> = .success(true)
    var projectsToYield: [Project] = []
    var settingsSnapshot = SettingsSnapshot(
        defaultProjectId: nil, agent: "claude", model: nil,
        screenshotsEnabled: true, hasKey: false, lastFour: nil
    )
    static let defaultTemplateBody =
        "Default body.\n## How to end\n3. **\"Clarifying questions:\"** followed by a numbered list."
    var templateBody = FakeOnboardingConvexService.defaultTemplateBody
    private let defaultTemplateBody = FakeOnboardingConvexService.defaultTemplateBody

    // Call tracking
    private(set) var validateKeyCalls: [String?] = []
    private(set) var setConductorKeyCalls: [String] = []
    private(set) var settingsUpdateCalls: [SettingsPatch] = []
    private(set) var templatesUpdateCalls: [String] = []
    private(set) var templatesResetCallCount = 0

    // MARK: users

    func usersEnsure() async throws -> String { "user-1" }

    // MARK: settings

    func settingsGet() async throws -> SettingsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return settingsSnapshot
    }

    func settingsUpdate(_ patch: SettingsPatch) async throws {
        lock.lock(); settingsUpdateCalls.append(patch); lock.unlock()
    }

    func settingsSetConductorKey(_ key: String) async throws {
        lock.lock()
        setConductorKeyCalls.append(key)
        settingsSnapshot.hasKey = true
        settingsSnapshot.lastFour = String(key.suffix(4))
        lock.unlock()
    }

    // MARK: conductor

    func conductorValidateKey(key: String?) async throws -> Bool {
        lock.lock(); validateKeyCalls.append(key); lock.unlock()
        return try validateKeyResult.get()
    }

    func conductorRefreshProjects() async throws {}

    // MARK: projects

    func projectsList() -> AsyncStream<[Project]> {
        let projects = lock.withGuard { projectsToYield }
        return AsyncStream { continuation in
            continuation.yield(projects)
            continuation.finish()
        }
    }

    // MARK: templates

    func templatesGet() async throws -> TemplateSnapshot {
        lock.lock(); defer { lock.unlock() }
        return TemplateSnapshot(body: templateBody, isCustomized: templateBody != defaultTemplateBody, updatedAt: Date())
    }

    func templatesUpdate(body: String) async throws {
        lock.lock(); templatesUpdateCalls.append(body); templateBody = body; lock.unlock()
    }

    func templatesReset() async throws {
        lock.lock(); templatesResetCallCount += 1; templateBody = defaultTemplateBody; lock.unlock()
    }

    // MARK: files / captures (unused stubs)

    func filesGenerateUploadUrl() async throws -> String { "https://example.convex.cloud/upload/fake" }
    func capturesCreate(_ input: CaptureCreateInput) async throws -> String { "server-\(input.clientId)" }
    func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]> { AsyncStream { _ in } }
    func capturesList() async throws -> [ServerCaptureRecord] { [] }
    func capturesGet(id: String) async throws -> ServerCaptureRecord? { nil }
    func capturesRetry(id: String) async throws {}
    func capturesDeleteScreenshot(id: String) async throws {}
    func capturesMarkOpened(id: String) async throws {}
    func capturesArchive(id: String) async throws {}
}

extension NSLock {
    fileprivate func withGuard<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

private struct StubError: Error {}

// MARK: - Test support

@MainActor
private enum OnboardingTestSupport {
    /// Builds a fully-faked wizard. Every seam is scriptable; defaults are
    /// the all-granted happy path with a single project.
    static func makeViewModel(
        convex: FakeOnboardingConvexService = FakeOnboardingConvexService(),
        stateStore: OnboardingStateStoring = InMemoryOnboardingStateStore(),
        micGranted: Bool = true,
        speechGranted: Bool = true,
        speechAvailability: SpeechModelAvailability = .available,
        screenRecordingGranted: Bool = false,
        screenRecordingRequestResult: Bool = false,
        projects: [Project] = [Project(id: "proj-1", name: "Only Project", gitRemote: "git@example.com:one.git")]
    ) -> (viewModel: OnboardingViewModel, convex: FakeOnboardingConvexService, auth: AuthController, relaunches: () -> Int) {
        convex.projectsToYield = projects

        let auth = AuthController(
            authProvider: MockAuthProvider(),
            convexService: convex,
            breadcrumbStore: InMemoryAuthBreadcrumbStore()
        )

        let permissions = OnboardingPermissions(
            micStatus: { micGranted ? .granted : .denied },
            requestMic: { micGranted },
            speechStatus: { speechGranted ? .granted : .denied },
            requestSpeech: { speechGranted },
            speechModelAvailability: { speechAvailability }
        )

        let relaunchCounter = Counter()
        let screenRecording = ScreenRecordingAccess(
            isGranted: { screenRecordingGranted },
            request: { screenRecordingRequestResult },
            openSystemSettings: {},
            relaunchApp: { relaunchCounter.increment() }
        )

        let viewModel = OnboardingViewModel(
            auth: auth,
            convex: convex,
            permissions: permissions,
            screenRecording: screenRecording,
            stateStore: stateStore
        )
        return (viewModel, convex, auth, { relaunchCounter.value })
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withGuard { count } }
        func increment() { lock.withGuard { count += 1 } }
    }

    /// Drives the wizard through sign-in + permissions + API key with the
    /// given fakes — the common prefix of most scenarios.
    static func advanceThroughApiKey(_ viewModel: OnboardingViewModel, key: String = "ck_valid_key_1234") async {
        await viewModel.signIn()
        viewModel.continueFromPermissions()
        viewModel.apiKeyInput = key
        await viewModel.submitApiKey()
    }
}

// MARK: - Onboarding gating tests

@MainActor
final class OnboardingGatingTests: XCTestCase {
    // MARK: Happy: all-granted path reaches test capture in the reordered flow; completion persists

    func testAllGrantedPathReachesTestCaptureInOrderAndCompletionFlagPersists() async throws {
        let store = InMemoryOnboardingStateStore()
        let (viewModel, convex, _, _) = OnboardingTestSupport.makeViewModel(stateStore: store)

        XCTAssertEqual(viewModel.step, .signIn)

        // (1) sign in — hard gate
        await viewModel.signIn()
        XCTAssertEqual(viewModel.step, .permissions)

        // (2) combined permission screen, both granted
        viewModel.refreshPermissionStatuses()
        XCTAssertEqual(viewModel.micState, .granted)
        XCTAssertEqual(viewModel.speechState, .granted)
        viewModel.continueFromPermissions()
        XCTAssertEqual(viewModel.step, .apiKey)

        // (3) API key — validated inline, stored only when valid
        viewModel.apiKeyInput = "ck_valid_key_1234"
        await viewModel.submitApiKey()
        XCTAssertEqual(convex.validateKeyCalls, ["ck_valid_key_1234"])
        XCTAssertEqual(convex.setConductorKeyCalls, ["ck_valid_key_1234"])

        // (4) exactly one project -> auto-selected, NO picker step: we land
        // directly on the test capture.
        XCTAssertEqual(viewModel.step, .testCapture)

        // (5) guided test capture -> (6) upsell
        var captureTriggered = false
        viewModel.onTriggerTestCapture = { captureTriggered = true }
        viewModel.startTestCapture()
        XCTAssertTrue(captureTriggered)
        viewModel.noteTestCaptureSubmitted()
        XCTAssertEqual(viewModel.step, .screenRecordingUpsell)

        // (6) declining the upsell completes the wizard
        viewModel.declineScreenshots()
        XCTAssertEqual(viewModel.step, .done)
        XCTAssertTrue(viewModel.isCompleted)

        // Completion flag persists: a fresh view model over the SAME store
        // (simulated relaunch) starts done — first-run-only wizard.
        XCTAssertTrue(store.load().completed)
        let (relaunched, _, _, _) = OnboardingTestSupport.makeViewModel(convex: convex, stateStore: store)
        XCTAssertEqual(relaunched.step, .done)
        XCTAssertTrue(relaunched.isCompleted)
    }

    // MARK: Gate: sign-in hard-blocks

    func testSignInFailureKeepsWizardOnSignInStepWithInlineError() async throws {
        let convex = FakeOnboardingConvexService()
        let store = InMemoryOnboardingStateStore()
        // MockAuthProvider(fixedToken: nil) simulates a login that never
        // yields a token — sign-in cannot complete.
        let auth = AuthController(
            authProvider: MockAuthProvider(fixedToken: nil),
            convexService: convex,
            breadcrumbStore: InMemoryAuthBreadcrumbStore()
        )
        let viewModel = OnboardingViewModel(
            auth: auth,
            convex: convex,
            permissions: OnboardingPermissions(
                micStatus: { .granted },
                requestMic: { true },
                speechStatus: { .granted },
                requestSpeech: { true },
                speechModelAvailability: { .available }
            ),
            screenRecording: ScreenRecordingAccess(
                isGranted: { false }, request: { false },
                openSystemSettings: {}, relaunchApp: {}
            ),
            stateStore: store
        )

        await viewModel.signIn()
        XCTAssertEqual(viewModel.step, .signIn, "sign-in is a hard gate — no advance without a session")
        XCTAssertNotNil(viewModel.signInError)
    }

    // MARK: Edge: each permission denied -> proceeds with degraded messaging

    func testMicDeniedStillAdvancesPastCombinedPermissionScreen() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(micGranted: false)

        await viewModel.signIn()
        viewModel.refreshPermissionStatuses()
        XCTAssertEqual(viewModel.micState, .denied)
        XCTAssertEqual(viewModel.speechState, .granted)

        // Denied mic never blocks (degraded: type-only capture).
        viewModel.continueFromPermissions()
        XCTAssertEqual(viewModel.step, .apiKey)
    }

    func testSpeechDeniedStillAdvancesPastCombinedPermissionScreen() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(speechGranted: false)

        await viewModel.signIn()
        viewModel.refreshPermissionStatuses()
        XCTAssertEqual(viewModel.speechState, .denied)

        viewModel.continueFromPermissions()
        XCTAssertEqual(viewModel.step, .apiKey)
    }

    func testBothPermissionsDeniedStillAdvances() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(micGranted: false, speechGranted: false)

        await viewModel.signIn()
        viewModel.refreshPermissionStatuses()
        viewModel.continueFromPermissions()
        XCTAssertEqual(viewModel.step, .apiKey, "wizard never hard-blocks except sign-in and API key")
    }

    func testSpeechModelUnavailableSurfacesSystemSettingsGuidanceButDoesNotBlock() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(
            speechAvailability: .unavailableRequiresSystemSettings
        )

        await viewModel.signIn()
        await viewModel.checkSpeechModelAvailability()
        XCTAssertEqual(viewModel.speechModelAvailability, .unavailableRequiresSystemSettings)

        viewModel.continueFromPermissions()
        XCTAssertEqual(viewModel.step, .apiKey, "missing dictation model degrades (type-only), never blocks")
    }

    // MARK: Error: invalid key -> inline error, step doesn't advance

    func testInvalidKeyShowsInlineErrorAndDoesNotAdvanceOrStoreKey() async throws {
        let convex = FakeOnboardingConvexService()
        convex.validateKeyResult = .success(false)
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(convex: convex)

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "ck_bad_key"
        await viewModel.submitApiKey()

        XCTAssertEqual(viewModel.step, .apiKey, "invalid key must not advance")
        XCTAssertNotNil(viewModel.apiKeyError)
        XCTAssertTrue(convex.setConductorKeyCalls.isEmpty, "an invalid key must never be stored")
    }

    func testValidateKeyNetworkErrorShowsInlineErrorAndDoesNotAdvance() async throws {
        let convex = FakeOnboardingConvexService()
        convex.validateKeyResult = .failure(StubError())
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(convex: convex)

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "ck_whatever"
        await viewModel.submitApiKey()

        XCTAssertEqual(viewModel.step, .apiKey)
        XCTAssertNotNil(viewModel.apiKeyError)
        XCTAssertTrue(convex.setConductorKeyCalls.isEmpty)
    }

    func testEmptyKeyShowsInlineErrorWithoutCallingValidate() async throws {
        let (viewModel, convex, _, _) = OnboardingTestSupport.makeViewModel()

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "   "
        await viewModel.submitApiKey()

        XCTAssertEqual(viewModel.step, .apiKey)
        XCTAssertNotNil(viewModel.apiKeyError)
        XCTAssertTrue(convex.validateKeyCalls.isEmpty)
    }

    // MARK: Happy: exactly one project -> step skipped, auto-selected

    func testSingleProjectAutoSelectsWithNoPickerStepAndPatchesDefaultProject() async throws {
        let (viewModel, convex, _, _) = OnboardingTestSupport.makeViewModel(
            projects: [Project(id: "proj-only", name: "Solo", gitRemote: "git@example.com:solo.git")]
        )

        await OnboardingTestSupport.advanceThroughApiKey(viewModel)

        XCTAssertEqual(viewModel.step, .testCapture, "single-project accounts skip the picker entirely")
        XCTAssertEqual(viewModel.selectedProjectId, "proj-only")
        XCTAssertEqual(convex.settingsUpdateCalls.count, 1)
        XCTAssertEqual(convex.settingsUpdateCalls.first?.defaultProjectId, "proj-only")
    }

    // MARK: Happy: multiple projects -> picker step shown

    func testMultipleProjectsShowsPickerStepAndSelectionAdvances() async throws {
        let (viewModel, convex, _, _) = OnboardingTestSupport.makeViewModel(projects: [
            Project(id: "proj-a", name: "Alpha", gitRemote: "git@example.com:a.git"),
            Project(id: "proj-b", name: "Beta", gitRemote: "git@example.com:b.git"),
        ])

        await OnboardingTestSupport.advanceThroughApiKey(viewModel)

        XCTAssertEqual(viewModel.step, .projectSelection, "multi-project accounts get the picker")
        XCTAssertEqual(viewModel.projects.count, 2)
        // First project pre-selected so Continue is never a dead end.
        XCTAssertEqual(viewModel.selectedProjectId, "proj-a")

        viewModel.selectedProjectId = "proj-b"
        await viewModel.confirmProjectSelection()

        XCTAssertEqual(viewModel.step, .testCapture)
        XCTAssertEqual(convex.settingsUpdateCalls.last?.defaultProjectId, "proj-b")
    }

    // MARK: Happy: upsell only after first successful test capture; declining never blocks

    func testScreenRecordingUpsellShownOnlyAfterFirstSuccessfulTestCapture() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel()

        await OnboardingTestSupport.advanceThroughApiKey(viewModel)
        XCTAssertEqual(viewModel.step, .testCapture)
        XCTAssertFalse(viewModel.testCaptureCompleted)

        // The upsell never appears before the capture panel reports a
        // submit — there is no path from .testCapture to the upsell except
        // noteTestCaptureSubmitted().
        viewModel.noteTestCaptureSubmitted()
        XCTAssertEqual(viewModel.step, .screenRecordingUpsell)
        XCTAssertTrue(viewModel.testCaptureCompleted)
    }

    func testUpsellGrantRequiringRelaunchOffersRelaunchAndPersistsProgress() async throws {
        let store = InMemoryOnboardingStateStore()
        let (viewModel, _, _, relaunches) = OnboardingTestSupport.makeViewModel(
            stateStore: store,
            screenRecordingGranted: false,
            screenRecordingRequestResult: false
        )

        await OnboardingTestSupport.advanceThroughApiKey(viewModel)
        viewModel.noteTestCaptureSubmitted()
        XCTAssertEqual(viewModel.step, .screenRecordingUpsell)

        // CGRequestScreenCaptureAccess "granted but needs relaunch" shape:
        // request returns false, preflight still false.
        viewModel.enableScreenshots()
        XCTAssertTrue(viewModel.needsRelaunchForScreenRecording)
        XCTAssertEqual(viewModel.step, .screenRecordingUpsell, "upsell is non-blocking, not auto-completed")

        viewModel.relaunchForScreenRecording()
        XCTAssertEqual(relaunches(), 1)

        // The relaunched wizard resumes at the upsell with the test capture
        // already recorded — no progress lost (F5.1 persistence).
        let persisted = store.load()
        XCTAssertEqual(persisted.step, .screenRecordingUpsell)
        XCTAssertTrue(persisted.testCaptureCompleted)
        XCTAssertFalse(persisted.completed)
    }

    func testUpsellImmediateGrantCompletesWizard() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(screenRecordingRequestResult: true)

        await OnboardingTestSupport.advanceThroughApiKey(viewModel)
        viewModel.noteTestCaptureSubmitted()

        viewModel.enableScreenshots()
        XCTAssertTrue(viewModel.screenRecordingGranted)
        XCTAssertEqual(viewModel.step, .done)
        XCTAssertTrue(viewModel.isCompleted)
    }

    // MARK: Edge: relaunch mid-flow resumes at the right step with grants intact

    func testWizardStateRoundTripsThroughPersistenceAcrossSimulatedRelaunch() async throws {
        let store = InMemoryOnboardingStateStore()
        let (first, convex, _, _) = OnboardingTestSupport.makeViewModel(
            stateStore: store,
            micGranted: true,
            speechGranted: false
        )

        // Advance past step 2 (permissions recorded: mic granted, speech
        // denied) into step 3 — then "kill" the app.
        await first.signIn()
        first.refreshPermissionStatuses()
        first.continueFromPermissions()
        XCTAssertEqual(first.step, .apiKey)

        // Relaunch: a NEW view model over the same store must resume at
        // .apiKey with the mic grant intact (PRD F5.1 persistence).
        let (second, _, _, _) = OnboardingTestSupport.makeViewModel(convex: convex, stateStore: store)
        XCTAssertEqual(second.step, .apiKey, "relaunch mid-flow resumes at the persisted step")
        XCTAssertEqual(second.micState, .granted, "earlier grants survive the relaunch")
        XCTAssertFalse(second.isCompleted)
    }

    func testUserDefaultsStoreRoundTripsState() throws {
        let suiteName = "whistle-onboarding-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsOnboardingStateStore(defaults: defaults)
        XCTAssertEqual(store.load(), OnboardingState(), "missing data decodes to the initial state")

        let state = OnboardingState(
            step: .testCapture, micGranted: true, speechGranted: true,
            testCaptureCompleted: false, completed: false
        )
        store.save(state)
        XCTAssertEqual(UserDefaultsOnboardingStateStore(defaults: defaults).load(), state)
    }

    // MARK: Integration: capture panel submit callback drives the wizard's test-capture gate

    func testCapturePanelSubmitCallbackFiresWithClientIdOnRealSubmit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-onboarding-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let captureStore = try CaptureStore(
            path: tempDir.appendingPathComponent("test.sqlite").path,
            screenshotsDirectory: tempDir.appendingPathComponent("screenshots")
        )

        let viewModel = CaptureViewModel(
            store: captureStore,
            transcriptionServiceFactory: { FakeTranscriptionService() },
            micPermissionChecker: { true }
        )
        viewModel.beginCapture()
        viewModel.notesText = "guided test capture"

        // Same shape as CapturePanelController.handleSubmit: submit, then
        // report the clientId (the onboarding wizard's advance signal).
        var reported: String?
        let result = viewModel.submit()
        if case .submitted(let clientId) = result {
            reported = clientId
        }
        XCTAssertEqual(reported, viewModel.clientId)

        let (wizard, _, _, _) = OnboardingTestSupport.makeViewModel()
        await OnboardingTestSupport.advanceThroughApiKey(wizard)
        wizard.noteTestCaptureSubmitted()
        XCTAssertEqual(wizard.step, .screenRecordingUpsell)
    }
}

// MARK: - Settings tests (PRD F5.2)

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private func makeViewModel(
        convex: FakeOnboardingConvexService = FakeOnboardingConvexService()
    ) -> (SettingsViewModel, FakeOnboardingConvexService, AuthController) {
        let auth = AuthController(
            authProvider: MockAuthProvider(),
            convexService: convex,
            breadcrumbStore: InMemoryAuthBreadcrumbStore()
        )
        return (SettingsViewModel(convex: convex, auth: auth), convex, auth)
    }

    func testAgentModelScreenshotAndDefaultProjectSavesCallSettingsUpdate() async throws {
        let (viewModel, convex, _) = makeViewModel()
        await viewModel.load()

        await viewModel.saveAgent("codex")
        XCTAssertEqual(convex.settingsUpdateCalls.last?.agent, "codex")

        viewModel.model = "  gpt-5.3-codex  "
        await viewModel.saveModel()
        XCTAssertEqual(convex.settingsUpdateCalls.last?.model, "gpt-5.3-codex")

        await viewModel.saveScreenshotsEnabled(false)
        XCTAssertEqual(convex.settingsUpdateCalls.last?.screenshotsEnabled, false)

        await viewModel.saveDefaultProject("proj-9")
        XCTAssertEqual(convex.settingsUpdateCalls.last?.defaultProjectId, "proj-9")

        XCTAssertEqual(convex.settingsUpdateCalls.count, 4)
    }

    func testMaskedKeyDisplayShowsLastFourAndNeverTheKey() async throws {
        let convex = FakeOnboardingConvexService()
        convex.settingsSnapshot = SettingsSnapshot(
            defaultProjectId: nil, agent: "claude", model: nil,
            screenshotsEnabled: true, hasKey: true, lastFour: "9xyz"
        )
        let (viewModel, _, _) = makeViewModel(convex: convex)
        await viewModel.load()

        XCTAssertTrue(viewModel.hasKey)
        XCTAssertEqual(viewModel.maskedKeyDisplay, "••••••••••••9xyz")
    }

    func testReplaceKeyFlowCallsSetConductorKeyThenValidateAndRefreshesMask() async throws {
        let (viewModel, convex, _) = makeViewModel()
        await viewModel.load()
        XCTAssertEqual(viewModel.maskedKeyDisplay, "No key on file")

        viewModel.newKeyInput = "ck_new_key_7890"
        await viewModel.replaceKey()

        // Replace flow order per plan U10: setConductorKey THEN validateKey
        // (validate with key: nil = validate the stored key).
        XCTAssertEqual(convex.setConductorKeyCalls, ["ck_new_key_7890"])
        XCTAssertEqual(convex.validateKeyCalls, [nil])
        XCTAssertEqual(viewModel.keyReplaceSucceeded, true)
        XCTAssertTrue(viewModel.newKeyInput.isEmpty, "input clears after a successful replace")
        XCTAssertEqual(viewModel.maskedKeyDisplay, "••••••••••••7890")
    }

    func testReplaceKeyRejectedByConductorSurfacesInlineWarning() async throws {
        let convex = FakeOnboardingConvexService()
        convex.validateKeyResult = .success(false)
        let (viewModel, _, _) = makeViewModel(convex: convex)
        await viewModel.load()

        viewModel.newKeyInput = "ck_revoked"
        await viewModel.replaceKey()

        XCTAssertEqual(viewModel.keyReplaceSucceeded, false)
        XCTAssertNotNil(viewModel.keyStatusMessage)
    }

    func testSignOutTransitionsAuthToSignedOut() async throws {
        let (viewModel, _, auth) = makeViewModel()
        await auth.signIn()
        XCTAssertEqual(auth.state, .signedIn)

        await viewModel.signOut()
        XCTAssertEqual(auth.state, .signedOut)
    }
}

// MARK: - Template editor tests (PRD F5.2/F5.3)

@MainActor
final class TemplateEditorTests: XCTestCase {
    func testTemplateEditSaveCallsTemplatesUpdate() async throws {
        let convex = FakeOnboardingConvexService()
        let viewModel = TemplateEditorViewModel(convex: convex)
        await viewModel.load()

        viewModel.body += "\n\nCustom instructions."
        await viewModel.save()

        XCTAssertEqual(convex.templatesUpdateCalls.count, 1)
        XCTAssertTrue(convex.templatesUpdateCalls[0].hasSuffix("Custom instructions."))
        XCTAssertTrue(viewModel.isCustomized)
    }

    func testResetRestoresDefaultBody() async throws {
        let convex = FakeOnboardingConvexService()
        let viewModel = TemplateEditorViewModel(convex: convex)
        await viewModel.load()
        let defaultBody = viewModel.body

        viewModel.body = "totally rewritten"
        await viewModel.save()
        XCTAssertEqual(viewModel.body, "totally rewritten")

        await viewModel.reset()
        XCTAssertEqual(convex.templatesResetCallCount, 1)
        XCTAssertEqual(viewModel.body, defaultBody, "reset restores the default template body")
    }

    func testLintWarnsOnMissingContractBlockAndClearsWhenRestored() async throws {
        let convex = FakeOnboardingConvexService()
        let viewModel = TemplateEditorViewModel(convex: convex)
        await viewModel.load()

        // Default template carries the "How to end" contract block.
        XCTAssertNil(viewModel.lintWarning)

        // Removing the "Clarifying questions:" marker (the heuristic per
        // PRD F5.2) triggers the inline warning...
        viewModel.body = "Plan this idea thoroughly. End however you like."
        XCTAssertNotNil(viewModel.lintWarning)

        // ...and saving is STILL allowed (warn, don't block); the warning
        // persists after the save.
        await viewModel.save()
        XCTAssertEqual(convex.templatesUpdateCalls.count, 1)
        XCTAssertNotNil(viewModel.lintWarning, "warning persists until the block is restored")

        // Restoring the marker clears the warning live.
        viewModel.body += "\n\nEnd with \"Clarifying questions:\" followed by a numbered list."
        XCTAssertNil(viewModel.lintWarning)
    }

    func testLintHeuristicDirectly() {
        XCTAssertNil(TemplateLint.warning(for: "…\nClarifying questions:\n1. …"))
        XCTAssertNotNil(TemplateLint.warning(for: "no contract block here"))
        XCTAssertNotNil(TemplateLint.warning(for: "clarifying questions:"), "marker match is case-sensitive — the pipeline greps the exact form")
    }

    func testPreviewRendersThroughWhistleCoreTemplatePreview() async throws {
        let convex = FakeOnboardingConvexService()
        convex.templateBody = "Project: {{project_name}}\n{{#if screenshot_url}}Shot: {{screenshot_url}}{{/if}}\n> {{transcript}}\n\nClarifying questions:"
        let viewModel = TemplateEditorViewModel(convex: convex)
        await viewModel.load()

        let preview = viewModel.preview()
        XCTAssertTrue(preview.contains("Project: whistle"))
        XCTAssertTrue(preview.contains("Shot: https://"), "sample vars include a screenshot URL, so the {{#if}} block renders")
        XCTAssertFalse(preview.contains("{{transcript}}"), "variables are substituted, not left literal")
    }
}
