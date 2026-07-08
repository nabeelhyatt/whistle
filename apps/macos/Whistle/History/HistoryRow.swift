// HistoryRow.swift
// TECH-SPEC §4.1 `HistoryWindow` row (plan U9): per-row rendering — status
// chip, transcript/notes preview, screenshot thumbnail, timestamps,
// clarifying questions (when ready), deep-link button, delete-screenshot,
// archive/dismiss affordance, "Duplicate as new capture." Rows with
// `openedAt` set are visually de-emphasized (per `StatusPresentationResult
// .isDeemphasized`).

import SwiftUI
import WhistleCore

struct HistoryRow: View {
    let row: HistoryRowViewModel
    var onOpenDeepLink: () -> Void
    var onArchive: () -> Void
    var onRetry: () -> Void
    var onDuplicate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusChip
                Spacer()
                Text(row.capturedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !row.transcript.isEmpty {
                Text(row.transcript)
                    .font(.body)
                    .lineLimit(2)
            }

            if !row.notes.isEmpty {
                Text(row.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !row.projectName.isEmpty {
                Text(row.projectName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !row.clarifyingQuestions.isEmpty {
                clarifyingQuestionsView
            }

            actionRow
        }
        .padding(.vertical, 6)
        .opacity(row.presentation.isDeemphasized ? 0.55 : 1.0)
    }

    private var statusChip: some View {
        Text(row.presentation.chip)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(chipBackground, in: Capsule())
    }

    private var chipBackground: Color {
        switch row.presentation.affordance {
        case .serverRetry, .localRetry:
            return .red.opacity(0.15)
        case .openSettingsApiKey:
            return .orange.opacity(0.2)
        case .openDeepLink:
            return .green.opacity(0.15)
        case .automatic, .none:
            return .gray.opacity(0.15)
        }
    }

    @ViewBuilder
    private var clarifyingQuestionsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(row.clarifyingQuestions.enumerated()), id: \.offset) { _, question in
                Text("• \(question)")
                    .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            switch row.presentation.affordance {
            case .openDeepLink:
                Button("Open", action: onOpenDeepLink)
                    .buttonStyle(.link)
            case .serverRetry:
                Button("Retry", action: onRetry)
                    .buttonStyle(.link)
            case .openSettingsApiKey:
                Button("Open Settings", action: onOpenDeepLink)
                    .buttonStyle(.link)
            case .localRetry, .automatic, .none:
                EmptyView()
            }

            Button("Duplicate as new capture", action: onDuplicate)
                .buttonStyle(.link)
                .font(.caption)

            if !row.isArchived, row.serverRecord != nil {
                Button("Archive", action: onArchive)
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Spacer()
        }
        .font(.caption)
    }
}
