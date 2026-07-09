// PermissionStep.swift
// The ONE combined mic + speech permission step of the onboarding wizard
// (PRD F5.1 step 2, reordered flow; TECH-SPEC §4.1 OnboardingWindow row):
// per-permission live status rows, not two separate explainer screens.
// Screen recording is deliberately NOT here — it's the post-first-capture
// upsell (PRD F5.1 step 6), see OnboardingWindow.swift.
//
// This file also owns the permission seams (mic, speech, speech-model
// availability, screen recording) so OnboardingGatingTests can simulate any
// grant/deny combination without touching real TCC state — mirroring the
// `ScreenCapturePreflightChecking` / `micPermissionChecker` seams from U7/U8.

import AVFoundation
import CoreGraphics
import Speech
import SwiftUI

// MARK: - Permission state

/// Tri-state per permission, driving the live status rows.
public enum PermissionState: String, Equatable, Sendable, Codable {
    case notDetermined
    case granted
    case denied
}

// MARK: - Permission seams (injected into OnboardingViewModel)

/// Closure bundle over the real mic/speech TCC surfaces
/// (`AVCaptureDevice` / `SFSpeechRecognizer`) plus the per-OS speech-model
/// availability check (TECH-SPEC §4.1b, via `TranscriptionServiceFactory`).
/// Tests construct this with scripted closures; the app uses `.system()`.
public struct OnboardingPermissions {
    public var micStatus: @MainActor () -> PermissionState
    public var requestMic: @MainActor () async -> Bool
    public var speechStatus: @MainActor () -> PermissionState
    public var requestSpeech: @MainActor () async -> Bool
    /// Per-OS on-device speech model availability (§4.1b): macOS 14–15 has
    /// no programmatic download (System Settings guidance); macOS 26+ can
    /// download in-app.
    public var speechModelAvailability: () async -> SpeechModelAvailability

    public init(
        micStatus: @escaping @MainActor () -> PermissionState,
        requestMic: @escaping @MainActor () async -> Bool,
        speechStatus: @escaping @MainActor () -> PermissionState,
        requestSpeech: @escaping @MainActor () async -> Bool,
        speechModelAvailability: @escaping () async -> SpeechModelAvailability
    ) {
        self.micStatus = micStatus
        self.requestMic = requestMic
        self.speechStatus = speechStatus
        self.requestSpeech = requestSpeech
        self.speechModelAvailability = speechModelAvailability
    }

    /// The real system-backed implementation used by the app target.
    public static func system() -> OnboardingPermissions {
        OnboardingPermissions(
            micStatus: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .granted
                case .denied, .restricted: return .denied
                case .notDetermined: return .notDetermined
                @unknown default: return .denied
                }
            },
            requestMic: {
                await AVCaptureDevice.requestAccess(for: .audio)
            },
            speechStatus: {
                switch SFSpeechRecognizer.authorizationStatus() {
                case .authorized: return .granted
                case .denied, .restricted: return .denied
                case .notDetermined: return .notDetermined
                @unknown default: return .denied
                }
            },
            requestSpeech: {
                await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status == .authorized)
                    }
                }
            },
            speechModelAvailability: {
                await TranscriptionServiceFactory.checkAvailability()
            }
        )
    }
}

/// Closure bundle over the screen-recording TCC surface (TECH-SPEC §4.3):
/// preflight check, the one-shot `CGRequestScreenCaptureAccess()` prompt,
/// the System Settings deep link, and app relaunch (the grant can require
/// one). Introduced here — no earlier unit calls
/// `CGRequestScreenCaptureAccess` (U7's `ScreenshotService` only preflights).
public struct ScreenRecordingAccess {
    public var isGranted: @MainActor () -> Bool
    public var request: @MainActor () -> Bool
    public var openSystemSettings: @MainActor () -> Void
    public var relaunchApp: @MainActor () -> Void

    public init(
        isGranted: @escaping @MainActor () -> Bool,
        request: @escaping @MainActor () -> Bool,
        openSystemSettings: @escaping @MainActor () -> Void,
        relaunchApp: @escaping @MainActor () -> Void
    ) {
        self.isGranted = isGranted
        self.request = request
        self.openSystemSettings = openSystemSettings
        self.relaunchApp = relaunchApp
    }

    /// Deep link into System Settings → Privacy & Security → Screen &
    /// System Audio Recording (TECH-SPEC §4.3 — screen recording has no
    /// usage-string prompt flow like mic/speech; the user flips it there).
    public static let systemSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    public static func system() -> ScreenRecordingAccess {
        ScreenRecordingAccess(
            isGranted: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() },
            openSystemSettings: {
                if let url = URL(string: systemSettingsURL) {
                    NSWorkspace.shared.open(url)
                }
            },
            relaunchApp: {
                // Standard relaunch pattern: spawn a fresh instance of this
                // bundle, then terminate this one. Required because a
                // freshly-granted screen-recording TCC entry only takes
                // effect on the next launch (§4.3).
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(
                    at: Bundle.main.bundleURL,
                    configuration: configuration
                ) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        )
    }
}

// MARK: - Permission step view (SwiftUI)

/// One combined screen, one live status row per permission (PRD F5.1 step
/// 2). Never hard-blocks: Continue is always enabled; a denied permission
/// just shows its degraded-mode consequence inline (type-only capture for
/// mic, no live transcript for speech).
struct PermissionStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Microphone & Speech")
                .font(.title2.bold())
            Text("Whistle transcribes your voice on-device the instant you trigger a capture. Audio never leaves this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                title: "Microphone",
                state: viewModel.micState,
                deniedNote: "Captures will be type-only until enabled in System Settings.",
                action: { Task { await viewModel.requestMicAccess() } }
            )

            permissionRow(
                title: "Speech recognition",
                state: viewModel.speechState,
                deniedNote: "Live transcription stays off; you can still type notes.",
                action: { Task { await viewModel.requestSpeechAccess() } }
            )

            speechModelSection

            Spacer()

            HStack {
                Spacer()
                Button("Continue") {
                    viewModel.continueFromPermissions()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .task {
            viewModel.refreshPermissionStatuses()
            await viewModel.checkSpeechModelAvailability()
        }
    }

    /// Per-OS speech-model availability messaging nested inside this step
    /// (TECH-SPEC §4.1b): macOS 14–15 gets System Settings → Keyboard →
    /// Dictation guidance with a re-check button; macOS 26+ gets an in-app
    /// download affordance.
    @ViewBuilder
    private var speechModelSection: some View {
        switch viewModel.speechModelAvailability {
        case .none, .some(.available):
            EmptyView()
        case .some(.unavailableRequiresSystemSettings):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "On-device dictation model not installed",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Text("Enable Dictation in System Settings → Keyboard to download it. Until then, captures are type-only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Check again") {
                    Task { await viewModel.checkSpeechModelAvailability() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.1)))
        case .some(.downloadable):
            VStack(alignment: .leading, spacing: 6) {
                Label("Speech model available to download", systemImage: "arrow.down.circle")
                Text("Whistle can download the on-device speech model now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Check again") {
                    Task { await viewModel.checkSpeechModelAvailability() }
                }
            }
        case .some(.downloading):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading speech model…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(
        title: String,
        state: PermissionState,
        deniedNote: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(for: state)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                switch state {
                case .granted:
                    Text("Granted").font(.callout).foregroundStyle(.secondary)
                case .denied:
                    Text(deniedNote).font(.callout).foregroundStyle(.secondary)
                case .notDetermined:
                    Text("Not yet requested").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch state {
            case .notDetermined:
                Button("Allow", action: action)
            case .denied:
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .granted:
                EmptyView()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder
    private func statusIcon(for state: PermissionState) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
        case .notDetermined:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
