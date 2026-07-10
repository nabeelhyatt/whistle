# Capture Panel Redesign — "Manifest" (V2) SwiftUI Port Spec

**Decision (2026-07-09):** Nabeel picked **V2 · Manifest** from `docs/design/panel-layout-playground.html` — inputs coupled in one card, status on a departure-board rail. Component styling was validated earlier in `docs/design/visualizer-playground.html`. This spec translates that mockup into the real macOS app.

**Design principle:** things that go *in* (idea text, notes, screenshot) are grouped in one bounded input card; things about *state* (mic status, destination project, submit) live together on a dark rail at the panel's foot. The split-flap is a **mic-on indicator**, not a transcript readout.

## Design tokens

| Token | Value |
|---|---|
| Panel background | `#1e1a18` (warm dark) |
| Accent — instrumentation (mic label + dot, halftone dots, destination, caret) | `#ffb000` amber |
| Action — buttons (Submit) | `#e8630a` Whistle Orange, white ink |
| Cream (flap letters) | `#f0e7d8` |
| Ink (body text) | `#e8e2d9`; placeholder `#8a8078` |
| Rail background | `#0d0d0f`; flap cell `#141416` |
| Borders | white at 7–10% opacity |
| Radii | panel 14, input card 11, idea field 10, thumb 8, notes/submit 7, flap cell 3 |
| Labels | bold condensed caps ~8.5pt, tracking ~0.18em (`.system(.bold).width(.condensed)` + `.tracking`) |
| Destination | monospaced bold ~10.5pt, tracking ~0.22em |

Reference markup with exact CSS: the "Copy Code" export in the playground (Nabeel pasted it back verbatim in chat — treat those values as approved).

## File changes

### 1. `apps/macos/Whistle/Capture/CaptureViewModel.swift`
Add mic-activity state the flap can bind to:
- `@Published public private(set) var isListening: Bool = false`
- Set `true` at the end of `startTranscriptionIfPermitted()` (line ~168, only when not mic-denied); set `false` in `stopTranscription()` (line ~196) and when the transcription stream ends.

### 2. New: `apps/macos/Whistle/Capture/FlapStatusView.swift`
3 split-flap cells (16×24pt each, 2pt gap) + caps label to their right/above per rail layout.
- States **(revised 2026-07-09 after live review)**: cells are STATIC unless speech is arriving. Idle/mic-hot-but-silent → cells hold their last glyphs (blank before any speech) + `● LISTENING` label while the mic is hot; when the transcript grows (user is speaking, or typing), each cell flips through 1–2 random glyphs and lands on the last 3 alphanumeric characters of the transcript — the flaps visibly "type out" what you say, then rest. Mic denied → hidden (rail shows the denied banner instead). Nabeel: "they should be static, not flipping, until i talk, then when i talk they flip through a few of those letters."
- Flip: per cell, swap character at animation midpoint under a `rotation3DEffect(x:)` fold ~150ms. A single-leaf fold is acceptable; the two-half Solari fidelity from the mockup is a nice-to-have.
- Drive with `TimelineView(.periodic)` or a per-view `Timer`; stagger by cell index. No audio-level input needed.

### 3. New: `apps/macos/Whistle/Capture/HalftoneImage.swift`
Screenshot → retro halftone once per `screenshotData` change (cache the result):
- Core Image chain: `CIDotScreen` (width ≈ 5–6, sharpness ≈ 0.7) on the downscaled screenshot → map to amber-on-dark via `CIFalseColor` (color0 `#0d0d0f`, color1 accent).
- Render through a shared `CIContext` off the main actor if cost shows; thumbnails are small (~412×74pt strip, cover-cropped).

### 4. `apps/macos/Whistle/Capture/CaptureView.swift` — restructure `body`
```
VStack(spacing 10)                      // .padding(14), bg #1e1a18
  header                                // whistle glyph left (small SVG/SFSymbol placeholder OK),
                                        // Spacer, existing History/Settings buttons (lines 60-75)
  micDeniedBanner (unchanged, lines 77-90)
  inputCard:                            // RoundedRect 11, bg white@3%, border white@10%, inner shadow
    transcriptEditor (lines 92-106)     // placeholder "Type or speak your idea…";
                                        // scrollContentBackground(.hidden), bg white@4.5%, radius 10
    notesEditor (lines 108-112)         // slim, placeholder-toned
    HalftoneImage strip                 // replaces screenshotThumbnail (lines 114-131);
                                        // keep the xmark remove button as an overlay, top-trailing
  statusRail:                           // HStack, bg #0d0d0f, negative-inset to panel edges,
                                        // top border white@10%, bottom corners follow panel radius
    FlapStatusView(isListening:)        // left
    destinationMenu                     // center, flex: "TO: TTL" styling wrapping the existing
                                        // ProjectPicker selection logic (keep Binding + selectProject)
    Submit button                       // right, accent bg, dark ink, keep .keyboardShortcut(.return)
                                        // and .disabled(!canSubmit) (lines 133-142)
```
Keep all behavior: focus states, `.onExitCommand`, `canSubmit` gating, remove-screenshot. `ProjectPicker.swift` gains a compact "rail" presentation (menu labeled `TO: <NAME>` in the destination style) — don't fork its selection logic.

### 5. `apps/macos/Whistle/Capture/CapturePanelController.swift`
Hosting frame is `460×360` (line ~183) — the rail adds ~44pt; bump height to ~400 or size-to-fit, and verify `positionBeneathStatusItem` still clears the screen edge.

## Verification
1. `apps/macos/generate.sh`, build, run; open panel via Option-Shift-W.
2. Mic authorized: `● LISTENING` shows, cells static; speak — cells flip and land on the tail of what you said; go silent — cells rest on those letters.
3. Mic denied (System Settings): banner shows, flap blank/standby, panel fully usable for typing.
4. Screenshot renders as amber halftone; remove button works; screenshot-only submit still allowed.
5. Submit: flap settles to `SAV`, draft queued, panel closes; Esc-with-content confirm unchanged.
6. Compare side-by-side against V2 in `panel-layout-playground.html` (double-click the file).

## Open questions
- ~~Accent: amber vs orange~~ **Resolved (2026-07-09, "i like both"): dual-accent system.** Amber `#ffb000` for instrumentation (things that report state: flap labels, halftone, destination, caret); Whistle Orange `#e8630a` for action (Submit). Roles, not decoration — nothing else gets either color.
- Develop-sweep animation on the halftone at panel open: charming but optional; skip in v1 of the port.

## Out of scope (unchanged from mockup phase)
- Audio-level reactivity (`AudioEngineTap` publishes no amplitude; not needed — flap churn is binary on mic state).
- History window / settings styling — this spec covers the capture panel only.
