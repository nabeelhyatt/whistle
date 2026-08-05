// ScreenshotService.swift
// TECH-SPEC §4.1 module table + §4.2 latency budget:
//   SCShareableContent -> display under mouse cursor -> SCScreenshotManager.captureImage
//   -> downscale to <=2000px long edge, JPEG q0.8 (<1MB) -> nil on TCC denial.
//
// Never crashes, never prompts for screen-recording permission itself
// (that's an onboarding/upsell concern, §4.1 OnboardingWindow) — this
// service only *checks* via `CGPreflightScreenCaptureAccess()` and backs
// off to `nil` when it's not granted.
//
// Screenshot-before-panel ordering: `capture(onCaptureStarted:)` fires a
// one-shot acknowledgement the instant the ScreenCaptureKit request is
// submitted (or, on any no-image path, immediately) so the caller can
// present its capture panel AFTER the frame request is in flight but
// WITHOUT waiting for image bytes or JPEG encoding. Submission-before-show
// narrows the WindowServer race but isn't a hard guarantee, so the real
// capturer also excludes Whistle's own app from the content filter — a
// frame sampled even after the panel appears can never contain it.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Seam over `CGPreflightScreenCaptureAccess()` so tests can simulate a
/// TCC-denied host without needing an actual denied permission (plan U7:
/// "TCC denied -> nil, no throw (inject the preflight check)").
public protocol ScreenCapturePreflightChecking: Sendable {
    func isScreenCaptureAccessGranted() -> Bool
}

public struct SystemScreenCapturePreflight: ScreenCapturePreflightChecking {
    public init() {}
    public func isScreenCaptureAccessGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}

/// Seam over "find the display under the mouse cursor and capture it,"
/// so `ScreenshotEncodeTests` can exercise the encode/downscale pipeline
/// with a synthetic `CGImage` without touching `SCShareableContent` /
/// `SCScreenshotManager` (which require the real TCC grant + a real
/// display to do anything meaningful in a unit test).
public protocol DisplayImageCapturing: Sendable {
    /// Returns the raw captured image for the display under the cursor, or
    /// `nil` if capture failed for any reason (no displays, SCK error,
    /// etc.) — never throws.
    ///
    /// `onCaptureStarted` fires EXACTLY ONCE on every path, on an arbitrary
    /// thread: immediately after the `SCScreenshotManager` request is
    /// submitted, or immediately before returning `nil` on any failure path
    /// (content fetch failed, no display). Semantics: "presenting UI can no
    /// longer contaminate this capture." A conformance that fires it more
    /// than once is tolerated (the sole caller's completion is idempotent);
    /// a conformance that never fires it is covered by the caller's timeout.
    func captureDisplayUnderCursor(onCaptureStarted: @escaping @Sendable () -> Void) async -> CGImage?
}

public extension DisplayImageCapturing {
    /// Source-compat convenience for callers that don't need the ack.
    func captureDisplayUnderCursor() async -> CGImage? {
        await captureDisplayUnderCursor(onCaptureStarted: {})
    }
}

/// Real `ScreenCaptureKit`-backed capturer.
public struct SCKitDisplayImageCapturer: DisplayImageCapturing {
    public init() {}

    public func captureDisplayUnderCursor(onCaptureStarted: @escaping @Sendable () -> Void) async -> CGImage? {
        guard let content = try? await SCShareableContent.current else {
            onCaptureStarted()
            return nil
        }
        guard let display = Self.displayUnderCursor(in: content.displays) ?? content.displays.first else {
            onCaptureStarted()
            return nil
        }

        // Exclude Whistle's own app from the capture so the panel (and any
        // other Whistle window, e.g. History/Settings) can never appear in
        // the frame — the invariant that submit-before-show alone can't
        // guarantee across the WindowServer's independent request channels.
        let selfApp = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: selfApp.map { [$0] } ?? [],
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.width = max(1, Int(display.width))
        config.height = max(1, Int(display.height))
        config.showsCursor = false

        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                continuation.resume(returning: image)
            }
            // Request submitted — safe to present UI now, ahead of the image.
            onCaptureStarted()
        }
    }

    /// NSEvent.mouseLocation is in the global Cocoa coordinate space
    /// (origin bottom-left of the primary display); `SCDisplay.frame` is
    /// in the same CoreGraphics global display space used by
    /// `NSScreen.frame`, so a direct `contains` check is correct across
    /// multi-display setups.
    private static func displayUnderCursor(in displays: [SCDisplay]) -> SCDisplay? {
        let mouseLocation = NSEvent.mouseLocation
        return displays.first { display in
            display.frame.contains(mouseLocation)
        }
    }
}

/// Screenshot capture + encode pipeline (TECH-SPEC §4.1/§4.2).
public struct ScreenshotService: Sendable {
    /// Long-edge cap in pixels — keeps uploads well under Convex/model
    /// image-size limits (TECH-SPEC §4.1).
    public static let maxLongEdge: CGFloat = 2000
    /// JPEG quality target — chosen (with the long-edge cap) to keep
    /// typical captures under 1 MB (TECH-SPEC §4.1).
    public static let jpegQuality: CGFloat = 0.8
    /// Hard upper bound the encode pipeline is expected to respect for the
    /// plan's "<1 MB" scenario.
    public static let maxEncodedBytes = 1 * 1024 * 1024

    private let preflight: any ScreenCapturePreflightChecking
    private let capturer: any DisplayImageCapturing

    public init(
        preflight: any ScreenCapturePreflightChecking = SystemScreenCapturePreflight(),
        capturer: any DisplayImageCapturing = SCKitDisplayImageCapturer()
    ) {
        self.preflight = preflight
        self.capturer = capturer
    }

    /// Captures the display under the mouse cursor, downscales, and
    /// encodes as JPEG. Returns `nil` gracefully whenever screen-recording
    /// access isn't granted, or if capture/encode fails for any reason —
    /// this service never throws and never itself prompts for TCC (per
    /// TECH-SPEC §4.1/§4.3, prompting is an onboarding-only concern).
    ///
    /// `onCaptureStarted` fires exactly once as soon as it is safe to present
    /// UI (request submitted, or no capture will occur), so the caller can
    /// show its panel ahead of image delivery — see the file header.
    public func capture(onCaptureStarted: @escaping @Sendable () -> Void = {}) async -> Data? {
        guard preflight.isScreenCaptureAccessGranted() else {
            onCaptureStarted()
            return nil
        }
        guard let image = await capturer.captureDisplayUnderCursor(onCaptureStarted: onCaptureStarted) else {
            return nil
        }
        return Self.encode(image)
    }

    /// Downscale-to-`maxLongEdge` + JPEG-encode pipeline, split out as a
    /// pure function of a `CGImage` so `ScreenshotEncodeTests` can feed it
    /// synthetic images of arbitrary size without any TCC/display
    /// involvement at all.
    public static func encode(_ image: CGImage) -> Data? {
        let scaled = downscale(image, maxLongEdge: maxLongEdge)
        let bitmap = NSBitmapImageRep(cgImage: scaled)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    /// Scales `image` down (never up) so its longer edge is at most
    /// `maxLongEdge` pixels, preserving aspect ratio.
    static func downscale(_ image: CGImage, maxLongEdge: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge else { return image }

        let scale = maxLongEdge / longEdge
        let newWidth = max(1, Int((width * scale).rounded()))
        let newHeight = max(1, Int((height * scale).rounded()))

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }
}
