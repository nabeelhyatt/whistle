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

import AppKit
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
    var settingsGetError: Error?
    static let defaultTemplateBody =
        "Default body.\n## How to end\n3. **\"Clarifying questions:\"** followed by a numbered list."
    var templateBody = FakeOnboardingConvexService.defaultTemplateBody
    private let defaultTemplateBody = FakeOnboardingConvexService.defaultTemplateBody

    /// Scripted result for `conductorSetAndValidateKey` (staging-keys plan
    /// U5) — the single atomic call both key-entry flows now make. `nil`
    /// (the default) derives a result from `validateKeyResult` above so
    /// existing scenarios that only script the plain bool keep working
    /// unchanged; set this explicitly to also control `environment` /
    /// `projectsChanged` / `error`.
    var setAndValidateKeyResult: Result<ConductorSetAndValidateResult, Error>?

    // Call tracking
    private(set) var setAndValidateKeyCalls: [String] = []
    private(set) var settingsUpdateCalls: [SettingsPatch] = []
    private(set) var templatesUpdateCalls: [String] = []
    private(set) var templatesResetCallCount = 0

    // MARK: users

    func usersEnsure() async throws -> String { "user-1" }

    var usersMeResult = UserSelfSnapshot(email: "nabeel@sparkcapital.com", authSubject: "auth0|july9")
    private(set) var usersMeCallCount = 0
    func usersMe() async throws -> UserSelfSnapshot {
        lock.lock(); usersMeCallCount += 1; lock.unlock()
        return usersMeResult
    }

    // MARK: settings

    func settingsGet() async throws -> SettingsSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let settingsGetError { throw settingsGetError }
        return settingsSnapshot
    }

    func settingsUpdate(_ patch: SettingsPatch) async throws {
        lock.lock(); settingsUpdateCalls.append(patch); lock.unlock()
    }

    // MARK: conductor

    func conductorValidateKey() async throws -> Bool {
        return try validateKeyResult.get()
    }

    var validateKeyDetailedResult: Result<ConductorValidateResult, Error>?
    func conductorValidateKeyDetailed() async throws -> ConductorValidateResult {
        lock.lock(); let detailed = validateKeyDetailedResult; lock.unlock()
        if let detailed {
            return try detailed.get()
        }
        return ConductorValidateResult(ok: try validateKeyResult.get(), projectsChanged: false)
    }

    /// The atomic action both Onboarding and Settings now call. Server-side
    /// atomicity (KTD3) means a rejected key never reaches a separate
    /// "save" call — there is none — so this fake stores the key/environment
    /// into `settingsSnapshot` itself, only on `ok == true`.
    func conductorSetAndValidateKey(key: String) async throws -> ConductorSetAndValidateResult {
        lock.lock()
        setAndValidateKeyCalls.append(key)
        let scripted = setAndValidateKeyResult
        lock.unlock()

        let result: ConductorSetAndValidateResult
        if let scripted {
            result = try scripted.get()
        } else {
            let ok = try validateKeyResult.get()
            result = ok
                ? ConductorSetAndValidateResult(ok: true, environment: .prod, projectsChanged: false, error: nil)
                : ConductorSetAndValidateResult(
                    ok: false, environment: nil, projectsChanged: false,
                    error: "Conductor didn't accept that key. Check that you copied the whole key."
                )
        }

        if result.ok {
            lock.lock()
            settingsSnapshot.hasKey = true
            settingsSnapshot.lastFour = String(key.suffix(4))
            settingsSnapshot.environment = result.environment ?? .prod
            lock.unlock()
        }
        return result
    }

    func conductorRefreshProjects() async throws {}

    // MARK: orgs (multi-org plan)

    /// Backing store for `orgsList()` -- mutated by `orgAddKey`/`orgRemove`/
    /// `orgRename` below so a scenario can add a key, then reload the list
    /// and see it reflected, same as the real `orgs:*` actions/mutations.
    var orgKeysStore: [OrgKeyInfo] = []
    var orgsListError: Error?
    /// Scripted result for `orgAddKey`. `nil` (the default) derives a
    /// result from `validateKeyResult` the same way
    /// `conductorSetAndValidateKey` above does, so scenarios that only
    /// script the plain bool keep working unchanged.
    var orgAddKeyResult: Result<OrgAddKeyResult, Error>?
    var orgRemoveError: Error?
    var orgRenameError: Error?

    private(set) var orgAddKeyCalls: [(label: String, key: String)] = []
    private(set) var orgRemoveCalls: [String] = []
    private(set) var orgRenameCalls: [(orgId: String, label: String)] = []
    private var orgIdCounter = 0

    func orgsList() async throws -> [OrgKeyInfo] {
        lock.lock(); defer { lock.unlock() }
        if let orgsListError { throw orgsListError }
        return orgKeysStore
    }

    func orgAddKey(label: String, key: String) async throws -> OrgAddKeyResult {
        lock.lock()
        orgAddKeyCalls.append((label, key))
        let scripted = orgAddKeyResult
        orgIdCounter += 1
        let candidateOrgId = "org-\(orgIdCounter)"
        lock.unlock()

        let result: OrgAddKeyResult
        if let scripted {
            result = try scripted.get()
        } else {
            let ok = try validateKeyResult.get()
            result = ok
                ? OrgAddKeyResult(ok: true, orgId: candidateOrgId, environment: .prod, projectsChanged: false, error: nil)
                : OrgAddKeyResult(
                    ok: false,
                    error: "Conductor didn't accept that key. Check that you copied the whole key."
                )
        }

        if result.ok {
            lock.lock()
            let orgId = result.orgId ?? candidateOrgId
            orgKeysStore.append(OrgKeyInfo(
                orgId: orgId,
                label: label,
                displayName: label,
                lastFour: String(key.suffix(4)),
                environment: result.environment ?? .prod,
                createdAt: Date()
            ))
            settingsSnapshot.hasKey = true
            settingsSnapshot.lastFour = String(key.suffix(4))
            settingsSnapshot.environment = result.environment ?? .prod
            lock.unlock()
        }
        return result
    }

    func orgRemove(orgId: String) async throws {
        lock.lock()
        orgRemoveCalls.append(orgId)
        let error = orgRemoveError
        lock.unlock()
        if let error { throw error }
        lock.lock(); orgKeysStore.removeAll { $0.orgId == orgId }; lock.unlock()
    }

    func orgRename(orgId: String, label: String) async throws {
        lock.lock()
        orgRenameCalls.append((orgId, label))
        let error = orgRenameError
        lock.unlock()
        if let error { throw error }
        lock.lock()
        if let index = orgKeysStore.firstIndex(where: { $0.orgId == orgId }) {
            let old = orgKeysStore[index]
            orgKeysStore[index] = OrgKeyInfo(
                orgId: old.orgId,
                label: label,
                organizationName: old.organizationName,
                displayName: label,
                lastFour: old.lastFour,
                environment: old.environment,
                createdAt: old.createdAt
            )
        }
        lock.unlock()
    }

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

        // (3) API key — one atomic probe-and-store call (multi-org plan:
        // `orgs:addKey`, replacing the old single-key
        // `conductorSetAndValidateKey` shim)
        viewModel.apiKeyInput = "ck_valid_key_1234"
        await viewModel.submitApiKey()
        XCTAssertEqual(convex.orgAddKeyCalls.map(\.key), ["ck_valid_key_1234"])

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

    // MARK: Fix #5: the permissions row must reflect true live status, even
    // if the user grants access in System Settings while this
    // already-created window is merely backgrounded (the one-shot `.task`
    // that normally refreshes on first appearance never reruns in that
    // case) -- `OnboardingWindowController.windowDidBecomeKey` must
    // re-trigger the refresh whenever the wizard regains focus on the
    // permissions step, and must NOT do so on other steps.

    func testWindowRegainingKeyStatusRefreshesStalePermissionRowOnPermissionsStep() async throws {
        final class MutableFlag: @unchecked Sendable {
            var granted = false
        }
        let speechFlag = MutableFlag()

        let convex = FakeOnboardingConvexService()
        let auth = AuthController(
            authProvider: MockAuthProvider(),
            convexService: convex,
            breadcrumbStore: InMemoryAuthBreadcrumbStore()
        )
        let permissions = OnboardingPermissions(
            micStatus: { .granted },
            requestMic: { true },
            speechStatus: { speechFlag.granted ? .granted : .denied },
            requestSpeech: { speechFlag.granted },
            speechModelAvailability: { .available }
        )
        let screenRecording = ScreenRecordingAccess(
            isGranted: { false }, request: { false }, openSystemSettings: {}, relaunchApp: {}
        )
        let viewModel = OnboardingViewModel(
            auth: auth,
            convex: convex,
            permissions: permissions,
            screenRecording: screenRecording,
            stateStore: InMemoryOnboardingStateStore()
        )
        let controller = OnboardingWindowController(viewModel: viewModel)

        await viewModel.signIn()
        viewModel.refreshPermissionStatuses()
        XCTAssertEqual(viewModel.step, .permissions)
        XCTAssertEqual(viewModel.speechState, .denied, "stale row: speech wasn't granted yet at last refresh")

        // The user grants speech recognition in System Settings (outside
        // this app) and switches back -- the window regains key status.
        speechFlag.granted = true
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertEqual(viewModel.speechState, .granted, "regaining key status on the permissions step must refresh")
    }

    func testWindowRegainingKeyStatusDoesNotRefreshOnOtherSteps() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(speechGranted: false)
        let controller = OnboardingWindowController(viewModel: viewModel)

        await viewModel.signIn()
        viewModel.refreshPermissionStatuses()
        XCTAssertEqual(viewModel.speechState, .denied)
        viewModel.continueFromPermissions()
        XCTAssertEqual(viewModel.step, .apiKey)

        // Regaining key status on a later step must not silently mutate
        // permission state that's no longer being shown.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(viewModel.speechState, .denied)
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
        convex.orgAddKeyResult = .success(
            OrgAddKeyResult(
                ok: false,
                error: "Conductor didn't accept that key. Check that you copied the whole key."
            )
        )
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(convex: convex)

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "ck_bad_key"
        await viewModel.submitApiKey()

        XCTAssertEqual(viewModel.step, .apiKey, "invalid key must not advance")
        XCTAssertEqual(viewModel.apiKeyError, "Conductor didn't accept that key. Check that you copied the whole key.")
        XCTAssertEqual(convex.orgAddKeyCalls.map(\.key), ["ck_bad_key"], "the atomic action is still called")
        XCTAssertFalse(convex.settingsSnapshot.hasKey, "a rejected key must never be stored — there is no separate client-side save call to make")
    }

    func testValidateKeyNetworkErrorShowsInlineErrorAndDoesNotAdvance() async throws {
        let convex = FakeOnboardingConvexService()
        convex.orgAddKeyResult = .failure(StubError())
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(convex: convex)

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "ck_whatever"
        await viewModel.submitApiKey()

        XCTAssertEqual(viewModel.step, .apiKey)
        XCTAssertEqual(viewModel.apiKeyError, "Couldn't reach Conductor. Check your connection and try again.")
        XCTAssertFalse(convex.settingsSnapshot.hasKey)
    }

    func testEmptyKeyShowsInlineErrorWithoutCallingValidate() async throws {
        let (viewModel, convex, _, _) = OnboardingTestSupport.makeViewModel()

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "   "
        await viewModel.submitApiKey()

        XCTAssertEqual(viewModel.step, .apiKey)
        XCTAssertNotNil(viewModel.apiKeyError)
        XCTAssertTrue(convex.orgAddKeyCalls.isEmpty)
    }

    // MARK: Happy: successful staging key entry surfaces the staging confirmation

    func testSuccessfulStagingKeyEntrySetsStagingConfirmationState() async throws {
        let convex = FakeOnboardingConvexService()
        convex.orgAddKeyResult = .success(
            OrgAddKeyResult(ok: true, orgId: "org-1", environment: .staging, projectsChanged: false, error: nil)
        )
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(convex: convex)

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "ck_staging_key"
        await viewModel.submitApiKey()

        XCTAssertEqual(viewModel.connectedEnvironment, .staging)
        XCTAssertNil(viewModel.apiKeyError)
        XCTAssertEqual(viewModel.step, .testCapture, "a successful key still advances the wizard")
    }

    func testSuccessfulProdKeyEntryDoesNotSetStagingConfirmationState() async throws {
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel()

        await viewModel.signIn()
        viewModel.continueFromPermissions()

        viewModel.apiKeyInput = "ck_prod_key"
        await viewModel.submitApiKey()

        XCTAssertNil(viewModel.connectedEnvironment)
    }

    func testResumedKeyStepUsesStoredStagingEnvironmentForDashboardLink() async throws {
        let convex = FakeOnboardingConvexService()
        convex.settingsSnapshot = SettingsSnapshot(
            defaultProjectId: nil, agent: "claude", model: nil,
            screenshotsEnabled: true, hasKey: true, lastFour: "ging", environment: .staging
        )
        let stateStore = InMemoryOnboardingStateStore(
            initial: OnboardingState(step: .apiKey)
        )
        let (viewModel, _, _, _) = OnboardingTestSupport.makeViewModel(
            convex: convex, stateStore: stateStore
        )

        await viewModel.loadStoredKeyEnvironment()

        XCTAssertEqual(viewModel.connectedEnvironment, .staging)
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
        XCTAssertEqual(convex.settingsUpdateCalls.first?.defaultProjectId, .set("proj-only"))
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
        XCTAssertEqual(convex.settingsUpdateCalls.last?.defaultProjectId, .set("proj-b"))
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
            micPermissionStatus: { .granted }
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
        XCTAssertEqual(convex.settingsUpdateCalls.last?.model, .set("gpt-5.3-codex"))

        await viewModel.saveScreenshotsEnabled(false)
        XCTAssertEqual(convex.settingsUpdateCalls.last?.screenshotsEnabled, false)

        await viewModel.saveDefaultProject("proj-9")
        XCTAssertEqual(convex.settingsUpdateCalls.last?.defaultProjectId, .set("proj-9"))

        XCTAssertEqual(convex.settingsUpdateCalls.count, 4)
    }

    // MARK: - API key management (multi-org plan: labeled org keys)

    func testLoadPopulatesOrgKeysFromOrgsList() async throws {
        let convex = FakeOnboardingConvexService()
        convex.orgKeysStore = [
            OrgKeyInfo(orgId: "org-1", label: "Personal", displayName: "Personal", lastFour: "9xyz", environment: .prod, createdAt: Date())
        ]
        let (viewModel, _, _) = makeViewModel(convex: convex)
        await viewModel.load()

        XCTAssertEqual(viewModel.orgKeys.map(\.orgId), ["org-1"])
        XCTAssertEqual(viewModel.orgKeys.first?.displayName, "Personal")
    }

    func testAddKeySuccessAppendsOrgKeyAndClearsFormAndSetsSuccessState() async throws {
        let (viewModel, convex, _) = makeViewModel()
        await viewModel.load()
        XCTAssertTrue(viewModel.orgKeys.isEmpty)

        viewModel.newKeyLabel = "Personal"
        viewModel.newKeyInput = "ck_new_key_7890"
        await viewModel.addKey()

        // Single atomic call (multi-org plan, mirroring the old single-key
        // `conductorSetAndValidateKey`'s KTD3 atomicity) -- probes then
        // stores, only on acceptance.
        XCTAssertEqual(convex.orgAddKeyCalls.map(\.key), ["ck_new_key_7890"])
        XCTAssertEqual(convex.orgAddKeyCalls.map(\.label), ["Personal"])
        XCTAssertEqual(viewModel.keyAddSucceeded, true)
        XCTAssertTrue(viewModel.newKeyInput.isEmpty, "key input clears after a successful add")
        XCTAssertTrue(viewModel.newKeyLabel.isEmpty, "label input clears after a successful add")
        XCTAssertEqual(viewModel.orgKeys.map(\.lastFour), ["7890"])
    }

    func testAddKeyFailureSetsStatusMessageAndDoesNotClearField() async throws {
        let convex = FakeOnboardingConvexService()
        convex.orgAddKeyResult = .success(
            OrgAddKeyResult(ok: false, error: "Conductor didn't accept that key. Check that you copied the whole key.")
        )
        let (viewModel, _, _) = makeViewModel(convex: convex)
        await viewModel.load()

        viewModel.newKeyInput = "ck_revoked"
        await viewModel.addKey()

        XCTAssertEqual(viewModel.keyAddSucceeded, false)
        XCTAssertEqual(viewModel.keyStatusMessage, "Conductor didn't accept that key. Check that you copied the whole key.")
        XCTAssertEqual(viewModel.newKeyInput, "ck_revoked", "a rejected key's input is left in place so the user can correct/retry")
        XCTAssertTrue(viewModel.orgKeys.isEmpty, "a rejected key must never be stored")
    }

    func testAddKeyCanWarnWhenProjectSetChanged() async throws {
        let convex = FakeOnboardingConvexService()
        convex.orgAddKeyResult = .success(
            OrgAddKeyResult(ok: true, orgId: "org-1", environment: .prod, projectsChanged: true, error: nil)
        )
        let (viewModel, _, _) = makeViewModel(convex: convex)
        await viewModel.load()

        viewModel.newKeyInput = "ck_new_key_7890"
        await viewModel.addKey()

        XCTAssertEqual(viewModel.keyAddSucceeded, true)
        XCTAssertTrue(viewModel.keyProjectsChanged)
    }

    func testRemoveKeyRemovesRowFromOrgKeys() async throws {
        let convex = FakeOnboardingConvexService()
        convex.orgKeysStore = [
            OrgKeyInfo(orgId: "org-1", label: "Personal", displayName: "Personal", lastFour: "aaaa", environment: .prod, createdAt: Date()),
            OrgKeyInfo(orgId: "org-2", label: "Work", displayName: "Work", lastFour: "bbbb", environment: .prod, createdAt: Date())
        ]
        let (viewModel, _, _) = makeViewModel(convex: convex)
        await viewModel.load()
        XCTAssertEqual(viewModel.orgKeys.count, 2)

        await viewModel.removeKey(orgId: "org-1")

        XCTAssertEqual(convex.orgRemoveCalls, ["org-1"])
        XCTAssertEqual(viewModel.orgKeys.map(\.orgId), ["org-2"])
    }

    func testRenameKeyUpdatesTheRowsLabel() async throws {
        let convex = FakeOnboardingConvexService()
        convex.orgKeysStore = [
            OrgKeyInfo(orgId: "org-1", label: "Personal", displayName: "Personal", lastFour: "aaaa", environment: .prod, createdAt: Date())
        ]
        let (viewModel, _, _) = makeViewModel(convex: convex)
        await viewModel.load()

        await viewModel.renameKey(orgId: "org-1", label: "Side Project")

        XCTAssertEqual(convex.orgRenameCalls.map(\.label), ["Side Project"])
        XCTAssertEqual(viewModel.orgKeys.first?.label, "Side Project")
    }

    func testSignOutTransitionsAuthToSignedOut() async throws {
        let (viewModel, _, auth) = makeViewModel()
        await auth.signIn()
        XCTAssertEqual(auth.state, .signedIn)

        await viewModel.signOut()
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testSignInDelegatesToAuthAndPublishesTheNewState() async throws {
        let (viewModel, _, _) = makeViewModel()
        XCTAssertEqual(viewModel.authState, .signedOut)

        await viewModel.signIn()

        try await Whistle_waitUntil { viewModel.authState == .signedIn }
        XCTAssertEqual(viewModel.authState, .signedIn)
    }

    // MARK: Account identity display (canonical-accounts plan §4)

    func testSignedInIdentityShowsEmailAndConnectionLabelFromUsersMe() async throws {
        let convex = FakeOnboardingConvexService()
        convex.usersMeResult = UserSelfSnapshot(email: "nabeel@sparkcapital.com", authSubject: "auth0|july9")
        let (viewModel, _, auth) = makeViewModel(convex: convex)
        await auth.signIn()
        await viewModel.load()

        XCTAssertEqual(viewModel.signedInDisplayName, "nabeel@sparkcapital.com")
        XCTAssertEqual(viewModel.signedInConnectionLabel, "Email & password")
        XCTAssertEqual(convex.usersMeCallCount, 1)
    }

    func testSignedInIdentityFallsBackToAuthSubjectWhenEmailAbsent() async throws {
        let convex = FakeOnboardingConvexService()
        convex.usersMeResult = UserSelfSnapshot(
            email: nil, authSubject: "github|12345678"
        )
        let (viewModel, _, auth) = makeViewModel(convex: convex)
        await auth.signIn()
        await viewModel.load()

        XCTAssertEqual(viewModel.signedInDisplayName, "github|12345678")
        XCTAssertEqual(viewModel.signedInConnectionLabel, "GitHub")
    }

    func testConnectionLabelMapsKnownPrefixesAndFallsBackToRawPrefix() async throws {
        let convex = FakeOnboardingConvexService()
        let (viewModel, _, auth) = makeViewModel(convex: convex)
        await auth.signIn()

        convex.usersMeResult = UserSelfSnapshot(email: "a@b.com", authSubject: "google-oauth2|999")
        await viewModel.load()
        XCTAssertEqual(viewModel.signedInConnectionLabel, "Google")

        convex.usersMeResult = UserSelfSnapshot(email: "a@b.com", authSubject: "some-other-idp|999")
        await viewModel.load()
        XCTAssertEqual(viewModel.signedInConnectionLabel, "some-other-idp")
    }

    func testDevSignInSkipsIdentityLookupAndLeavesFieldsEmpty() async throws {
        let convex = FakeOnboardingConvexService()
        let auth = AuthController(
            authProvider: MockAuthProvider(),
            convexService: convex,
            breadcrumbStore: InMemoryAuthBreadcrumbStore(),
            isDevSignIn: true
        )
        let viewModel = SettingsViewModel(convex: convex, auth: auth)
        await auth.signIn()
        await viewModel.load()

        XCTAssertEqual(convex.usersMeCallCount, 0, "dev sign-in never calls users:me")
        XCTAssertEqual(viewModel.signedInDisplayName, "")
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
