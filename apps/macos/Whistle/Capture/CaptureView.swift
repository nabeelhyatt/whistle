// CaptureView.swift
// The capture panel's SwiftUI content (TECH-SPEC §4.1 `CaptureView` row,
// plan U8): slim header with History + Settings icon buttons (placeholder
// actions here -- wired fully in U9/U10), live transcript (editable,
// bound to committed+live text), typed-notes field usable simultaneously,
// removable screenshot thumbnail, project picker, submit.
//
// Body restructured per docs/design/capture-panel-redesign-spec.md's
// "Manifest" (V2) layout: things that go IN (idea text, notes, screenshot)
// are grouped in one bounded input card; things about STATE (mic status,
// destination project, submit) live together on a departure-board rail
// at the panel's foot. All prior behavior is preserved -- focus states,
// `.onExitCommand`, `canSubmit` gating, remove-screenshot, and
// `ProjectPicker`'s selection/persistence flow are unchanged, only their
// presentation moved.

import AppKit
import SwiftUI
import WhistleCore

struct CaptureView: View {
    @ObservedObject var viewModel: CaptureViewModel

    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onHistory: () -> Void
    var onSettings: () -> Void

    @FocusState private var transcriptFieldFocused: Bool
    @FocusState private var projectPickerFocused: Bool

    private static let halftoneStripSize = CGSize(width: 412, height: 74)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header

                if viewModel.isMicDenied {
                    micDeniedBanner
                } else if viewModel.isSpeechRecognitionDenied {
                    speechRecognitionDeniedBanner
                }

                inputCard
            }
            .padding(14)

            statusRail
        }
        // Panel background token (#1e1a18). Corner rounding is left to the
        // hosting NSPanel's own window chrome (`CapturePanelController`)
        // rather than re-clipped here, to avoid a mismatched double-round
        // artifact between the window mask and a SwiftUI-side clip.
        .background(PanelTheme.panelBackground)
        .foregroundStyle(PanelTheme.ink)
        .frame(minWidth: 420, idealWidth: 460)
        // The panel is always dark regardless of system appearance --
        // force it so text fields, TextEditor selection color, etc. all
        // render for a dark host.
        .preferredColorScheme(.dark)
        .onAppear {
            applyInitialFocus()
        }
        .onChange(of: viewModel.focusRequestToken) { _, _ in
            // Fires on every subsequent show -- fresh open, a resumed
            // draft, or a plain refocus -- since `.onAppear` alone won't
            // refire when a hidden-but-preserved panel is simply reordered
            // front again (plan U8 fix #3).
            applyInitialFocus()
        }
        .onExitCommand {
            onEscape()
        }
    }

    // MARK: - Header

    private func applyInitialFocus() {
        transcriptFieldFocused = true
        if viewModel.focusProjectPicker {
            projectPickerFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tram.fill")
                .foregroundStyle(PanelTheme.iconMuted)

            Spacer()

            Button(action: onHistory) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanelTheme.iconMuted)
            .help("History")

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanelTheme.iconMuted)
            .help("Settings")
        }
    }

    /// Fix #1a: previously this whole `HStack` (including the button) had
    /// `.foregroundStyle(.secondary)` applied, which -- since a modifier
    /// applied to a container is inherited by children that don't override
    /// it -- painted the "enable mic" button the same flat gray as the
    /// surrounding sentence, so it read as plain text, not something
    /// tappable. The button below sets its own accent-colored, underlined
    /// label so it visibly stands out as a real affordance; only the
    /// explanatory sentence stays secondary/caption-styled.
    private var micDeniedBanner: some View {
        HStack(spacing: 4) {
            Image(systemName: "mic.slash")
                .foregroundStyle(.secondary)
            Text("Microphone access denied — type your capture, or")
                .foregroundStyle(.secondary)
            Button {
                openSystemSettingsPane("Privacy_Microphone")
            } label: {
                Text("enable mic in Settings").underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .font(.caption)
        .foregroundStyle(PanelTheme.placeholderInk)
    }

    /// Fix #1d: speech-recognition (SFSpeechRecognizer) can be denied even
    /// when mic access itself is granted -- its own banner + deep link to
    /// the Privacy_SpeechRecognition pane (not Privacy_Microphone). Only
    /// shown when mic is authorized (`micDeniedBanner` already covers the
    /// mic-denied case, and without mic access speech recognition can't
    /// run regardless).
    private var speechRecognitionDeniedBanner: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.slash")
                .foregroundStyle(.secondary)
            Text("Speech recognition access denied — type your capture, or")
                .foregroundStyle(.secondary)
            Button {
                openSystemSettingsPane("Privacy_SpeechRecognition")
            } label: {
                Text("enable speech recognition in Settings").underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .font(.caption)
        .foregroundStyle(PanelTheme.placeholderInk)
    }

    private func openSystemSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Input card (idea text, notes, screenshot -- everything IN)

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            transcriptEditor
            notesEditor
            halftoneStrip
        }
        .padding(9)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.inputCardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelTheme.inputCardRadius, style: .continuous)
                .strokeBorder(PanelTheme.borderHigh, lineWidth: 1)
        }
    }

    private var transcriptEditor: some View {
        TextEditor(text: $viewModel.transcriptText)
            .font(.system(size: 13.5))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 70)
            .focused($transcriptFieldFocused)
            .padding(6)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.ideaFieldRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if viewModel.transcriptText.isEmpty {
                    Text(transcriptPlaceholder)
                        .font(.system(size: 13.5))
                        .foregroundStyle(PanelTheme.placeholderInk)
                        .padding(.top, 14)
                        .padding(.leading, 11)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Fix #1c: "Listening…" implies live dictation is actually running --
    /// showing it in type-only mode (mic or speech-recognition denied) is
    /// misleading, since nothing is listening. Falls back to a neutral
    /// prompt in that case.
    private var transcriptPlaceholder: String {
        (viewModel.isMicDenied || viewModel.isSpeechRecognitionDenied) ? "Type your idea..." : "Type or speak your idea..."
    }

    private var notesEditor: some View {
        TextField("Notes…", text: $viewModel.notesText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .lineLimit(1...4)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.notesSubmitRadius, style: .continuous))
    }

    @ViewBuilder
    private var halftoneStrip: some View {
        if let data = viewModel.screenshotData {
            let size = Self.halftoneStripSize
            ZStack(alignment: .topTrailing) {
                if let halftone = HalftoneImage.render(data, displaySize: size) {
                    Image(nsImage: halftone)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                } else if let fallback = NSImage(data: data) {
                    // Defensive fallback if the Core Image chain ever fails
                    // to decode (e.g. malformed data) -- still removable,
                    // still submits, just not halftoned.
                    Image(nsImage: fallback)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }

                Button(action: { viewModel.removeScreenshot() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .padding(6)
                .help("Remove screenshot")
            }
            .frame(width: size.width, height: size.height)
            .background(PanelTheme.railBackground)
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.thumbRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PanelTheme.thumbRadius, style: .continuous)
                    .strokeBorder(PanelTheme.borderHigh, lineWidth: 1)
            }
        }
    }

    // MARK: - Status rail (mic status, destination project, submit -- everything about STATE)

    private var statusRail: some View {
        HStack(spacing: 12) {
            FlapStatusView(
                transcript: viewModel.transcriptText,
                isListening: viewModel.isListening,
                isMicDenied: viewModel.isMicDenied
            )

            Spacer(minLength: 8)

            ProjectPicker(
                projects: viewModel.projects,
                selectedProjectId: Binding(
                    get: { viewModel.selectedProjectId },
                    set: { if let id = $0 { viewModel.selectProject(id) } }
                ),
                isFocused: $projectPickerFocused,
                style: .rail
            )

            Spacer(minLength: 8)

            clearButton

            submitButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PanelTheme.railBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PanelTheme.borderHigh)
                .frame(height: 1)
        }
    }

    private var clearButton: some View {
        Button("Clear") {
            viewModel.clear()
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(PanelTheme.placeholderInk)
        .disabled(!viewModel.hasContent)
    }

    private var submitButton: some View {
        Button("Submit") {
            onSubmit()
        }
        .keyboardShortcut(.return, modifiers: [])
        .disabled(!viewModel.canSubmit)
        .buttonStyle(SubmitButtonStyle())
    }
}

/// Submit is the one Action element in the dual-accent system: fixed
/// Whistle Orange background, white ink -- never the amber used for
/// instrumentation elsewhere on the rail.
private struct SubmitButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(PanelTheme.actionOrange.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.notesSubmitRadius, style: .continuous))
    }
}
