// CaptureView.swift
// The capture panel's SwiftUI content (TECH-SPEC §4.1 `CaptureView` row,
// plan U8): slim header with History + Settings icon buttons (placeholder
// actions here -- wired fully in U9/U10), live transcript (editable,
// bound to committed+live text), typed-notes field usable simultaneously,
// removable screenshot thumbnail, project picker, submit.

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if viewModel.isMicDenied {
                micDeniedBanner
            }

            transcriptEditor

            notesEditor

            screenshotThumbnail

            ProjectPicker(
                projects: viewModel.projects,
                selectedProjectId: Binding(
                    get: { viewModel.selectedProjectId },
                    set: { if let id = $0 { viewModel.selectProject(id) } }
                )
            )

            submitRow
        }
        .padding(12)
        .frame(minWidth: 420, idealWidth: 460)
        .onAppear {
            transcriptFieldFocused = true
            if viewModel.focusProjectPicker {
                projectPickerFocused = true
            }
        }
        .onExitCommand {
            onEscape()
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button(action: onHistory) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .help("History")

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var micDeniedBanner: some View {
        HStack {
            Image(systemName: "mic.slash")
            Text("Microphone access denied — type your capture, or")
            Button("enable mic") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var transcriptEditor: some View {
        TextEditor(text: $viewModel.transcriptText)
            .font(.body)
            .frame(minHeight: 80)
            .focused($transcriptFieldFocused)
            .overlay(alignment: .topLeading) {
                if viewModel.transcriptText.isEmpty {
                    Text("Listening…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }

    private var notesEditor: some View {
        TextField("Notes…", text: $viewModel.notesText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
    }

    @ViewBuilder
    private var screenshotThumbnail: some View {
        if let data = viewModel.screenshotData, let image = NSImage(data: data) {
            HStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 90)
                    .cornerRadius(6)
                Spacer()
                Button(action: { viewModel.removeScreenshot() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Remove screenshot")
            }
        }
    }

    private var submitRow: some View {
        HStack {
            Spacer()
            Button("Submit") {
                onSubmit()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!viewModel.canSubmit)
        }
    }
}
