// PanelTheme.swift
// Shared design tokens for the capture panel's "Manifest" (V2) redesign
// (docs/design/capture-panel-redesign-spec.md, "Design tokens" table).
// One place for the hex literals so `CaptureView`, `FlapStatusView`,
// `HalftoneImage`, and `ProjectPicker`'s rail presentation don't each
// scatter their own `Color(red:green:blue:)` guesses.

import SwiftUI

extension Color {
    /// Convenience initializer for the spec's hex tokens (`#rrggbb`, with
    /// or without a leading `#`). Only exercised with the literals below --
    /// not a general-purpose parser.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Design tokens from the capture-panel-redesign spec's "Design tokens"
/// table. Roles, not decoration: amber is reserved for instrumentation
/// (things that report state), Whistle Orange for action (Submit) --
/// nothing else gets either color.
enum PanelTheme {
    /// Panel background, warm dark.
    static let panelBackground = Color(hex: 0x1e1a18)
    /// Accent -- instrumentation (mic label + dot, halftone dots,
    /// destination, caret).
    static let accentAmber = Color(hex: 0xffb000)
    /// Action -- buttons (Submit), Whistle Orange, white ink.
    static let actionOrange = Color(hex: 0xe8630a)
    /// Flap letters.
    static let cream = Color(hex: 0xf0e7d8)
    /// Body text ink.
    static let ink = Color(hex: 0xe8e2d9)
    /// Placeholder text ink.
    static let placeholderInk = Color(hex: 0x8a8078)
    /// Status rail background.
    static let railBackground = Color(hex: 0x0d0d0f)
    /// Flap cell background.
    static let flapCellBackground = Color(hex: 0x141416)
    /// Muted warm-gray icon color for the header's plain icon buttons
    /// (playground `.icon-btn { color: #a3988c; }`) -- not itself
    /// instrumentation or action, so it sits outside the amber/orange
    /// dual-accent system.
    static let iconMuted = Color(hex: 0xa3988c)

    /// Border opacity band the spec calls out as "white at 7-10%".
    static let borderLow = Color.white.opacity(0.07)
    static let borderHigh = Color.white.opacity(0.10)

    // Radii
    static let panelRadius: CGFloat = 14
    static let inputCardRadius: CGFloat = 11
    static let ideaFieldRadius: CGFloat = 10
    static let thumbRadius: CGFloat = 8
    static let notesSubmitRadius: CGFloat = 7
    static let flapCellRadius: CGFloat = 3
}
