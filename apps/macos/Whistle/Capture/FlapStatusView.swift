// FlapStatusView.swift
// Mini split-flap speech-activity indicator for the capture panel's status
// rail (docs/design/capture-panel-redesign-spec.md, file change #2, states
// revised 2026-07-09 after live review). The cells are STATIC unless
// speech is arriving: when the transcript grows, each cell flips through a
// couple of random glyphs and lands on the last 3 characters of the
// transcript -- the flaps visibly "type out" what you say, then rest on
// those letters. The `● LISTENING` label (not the flipping) is what says
// the mic is hot. When the mic is denied, `CaptureView` doesn't place this
// in the rail (the mic-denied banner already communicates state), but the
// view defends itself the same way in case that ever changes.

import SwiftUI

struct FlapStatusView: View {
    /// The live transcript (committed + in-flight). Cell flips are driven
    /// by changes to its alphanumeric tail -- speech (or typing) flips the
    /// flaps; silence leaves them at rest.
    let transcript: String
    /// Mirrors `CaptureViewModel.isListening` -- drives the label only.
    let isListening: Bool
    /// When true, the whole indicator renders nothing: the mic-denied
    /// banner already communicates state, and blank flap cells next to it
    /// would be redundant noise.
    let isMicDenied: Bool

    /// Last 3 letters/digits of the transcript, uppercased and left-padded
    /// with blanks so cell N always has a stable target character.
    private var targets: [Character] {
        let tail = Array(transcript.uppercased().filter { $0.isLetter || $0.isNumber }.suffix(3))
        return Array(repeating: " ", count: max(0, 3 - tail.count)) + tail
    }

    var body: some View {
        if isMicDenied {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                let targets = self.targets
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        FlapCellView(cellIndex: index, target: targets[index])
                    }
                }

                if isListening {
                    labelRow
                }
            }
        }
    }

    private var labelRow: some View {
        HStack(spacing: 5) {
            PulsingDot()
            Text("LISTENING")
                .font(.system(size: 8.5, weight: .bold).width(.condensed))
                .tracking(1.5)
                .foregroundColor(PanelTheme.accentAmber)
        }
    }
}

/// 5pt pulsing dot next to the "LISTENING" label -- purely decorative,
/// no audio-level input (out of scope per the spec).
private struct PulsingDot: View {
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(PanelTheme.accentAmber)
            .frame(width: 5, height: 5)
            .opacity(isDim ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
    }
}

/// One 16x24pt split-flap cell. Each target change runs a short burst via
/// `.task(id: target)` -- 1-2 random intermediate glyphs, then the target
/// character -- so it reads as a mechanical flap settling, not a ticker.
/// The task is automatically cancelled/restarted when the target changes
/// mid-burst (continuous speech) or the view disappears (panels open and
/// close constantly -- no leaked timers).
private struct FlapCellView: View {
    let cellIndex: Int
    let target: Character

    @State private var displayedChar: Character = " "
    @State private var flipDegrees: Double = 0

    private static let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    var body: some View {
        Text(String(displayedChar))
            .font(.system(size: 16, weight: .bold).width(.condensed))
            .foregroundColor(PanelTheme.cream)
            .frame(width: 16, height: 24)
            .background(PanelTheme.flapCellBackground)
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.flapCellRadius, style: .continuous))
            .rotation3DEffect(
                .degrees(flipDegrees),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.4
            )
            .task(id: target) {
                guard target != displayedChar else { return }
                // Stagger cells slightly so a 3-character landing cascades
                // left-to-right instead of flipping in lockstep.
                try? await Task.sleep(nanoseconds: UInt64(cellIndex) * 40_000_000)
                guard !Task.isCancelled else { return }
                // Blanking (transcript cleared) flips straight to blank; a
                // real character gets 1-2 random glyphs first.
                if target != " " {
                    for _ in 0..<Int.random(in: 1...2) {
                        await flip(to: Self.glyphs.randomElement() ?? " ")
                        guard !Task.isCancelled else { return }
                    }
                }
                await flip(to: target)
            }
    }

    /// Single-leaf fold on the x-axis: rotate away, swap the character
    /// edge-on at the midpoint (invisible), rotate back with the new
    /// glyph. ~150ms total, matching the spec's flip timing; the
    /// two-half Solari fidelity from the mockup is explicitly a
    /// nice-to-have, not required.
    @MainActor
    private func flip(to newChar: Character) async {
        guard newChar != displayedChar else { return }
        withAnimation(.easeIn(duration: 0.075)) { flipDegrees = -90 }
        try? await Task.sleep(nanoseconds: 75_000_000)
        guard !Task.isCancelled else {
            displayedChar = newChar
            flipDegrees = 0
            return
        }
        displayedChar = newChar
        flipDegrees = 90
        withAnimation(.easeOut(duration: 0.075)) { flipDegrees = 0 }
        try? await Task.sleep(nanoseconds: 75_000_000)
    }
}
