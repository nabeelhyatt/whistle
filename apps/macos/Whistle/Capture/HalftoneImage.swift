// HalftoneImage.swift
// Screenshot -> retro amber halftone rendering for the capture panel's
// input card (docs/design/capture-panel-redesign-spec.md, file change
// #3). Core Image chain: downscale to ~2x display size (cover-cropped,
// matching the ~412x74pt strip) -> CIDotScreen -> CIFalseColor mapping
// black to the rail's near-black and white to the amber instrumentation
// accent. Computed once per `screenshotData` and cached -- CaptureView
// re-attaches the same `Data` on every body re-evaluation while the
// screenshot is unchanged, so this must not redo the CI chain per frame.

import AppKit
import CoreImage

enum HalftoneImage {
    /// Shared context per spec ("shared CIContext"); CI contexts are
    /// expensive to create and safe to reuse across renders.
    private static let context = CIContext()

    /// Small render cache keyed by the raw screenshot bytes so repeated
    /// SwiftUI body evaluations (typing in the transcript field, etc.)
    /// don't re-run the Core Image chain -- only a genuinely new
    /// screenshot pays the render cost.
    private static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        // One render is live per panel; a couple of spares cover rapid
        // reopen. Bounding it releases stale full-screen renders promptly
        // instead of waiting for memory pressure (PR #5 review).
        cache.countLimit = 4
        return cache
    }()

    /// Renders (or returns the cached render of) `data` as an amber-on-
    /// dark halftone `NSImage` sized for display at `displaySize` (points).
    /// Returns `nil` if `data` isn't decodable as an image.
    static func render(_ data: Data, displaySize: CGSize, displayScale: CGFloat = 2) -> NSImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = makeHalftone(data, displaySize: displaySize, displayScale: displayScale) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func makeHalftone(_ data: Data, displaySize: CGSize, displayScale: CGFloat) -> NSImage? {
        guard displaySize.width > 0, displaySize.height > 0,
              let source = CIImage(data: data), source.extent.width > 0, source.extent.height > 0
        else { return nil }

        // Downscale to ~2x display size (spec: "downscale to ~2x display
        // size") and cover-crop to the strip's aspect ratio.
        let targetPixelSize = CGSize(
            width: displaySize.width * displayScale,
            height: displaySize.height * displayScale
        )
        let scaleFactor = max(
            targetPixelSize.width / source.extent.width,
            targetPixelSize.height / source.extent.height
        )
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        let cropRect = CGRect(
            x: scaled.extent.minX + (scaled.extent.width - targetPixelSize.width) / 2,
            y: scaled.extent.minY + (scaled.extent.height - targetPixelSize.height) / 2,
            width: targetPixelSize.width,
            height: targetPixelSize.height
        ).integral
        let cropped = scaled.cropped(to: cropRect)

        guard let dotScreen = CIFilter(name: "CIDotScreen") else { return nil }
        dotScreen.setValue(cropped, forKey: kCIInputImageKey)
        dotScreen.setValue(CIVector(x: cropRect.midX, y: cropRect.midY), forKey: kCIInputCenterKey)
        dotScreen.setValue(5.5, forKey: kCIInputWidthKey)
        dotScreen.setValue(0.7, forKey: kCIInputSharpnessKey)
        guard let dotted = dotScreen.outputImage else { return nil }

        guard let falseColor = CIFilter(name: "CIFalseColor") else { return nil }
        falseColor.setValue(dotted, forKey: kCIInputImageKey)
        // color0 <- black (rail near-black #0d0d0f), color1 <- white
        // (amber instrumentation accent #ffb000).
        falseColor.setValue(CIColor(red: 0x0d / 255.0, green: 0x0d / 255.0, blue: 0x0f / 255.0), forKey: "inputColor0")
        falseColor.setValue(CIColor(red: 0xff / 255.0, green: 0xb0 / 255.0, blue: 0x00 / 255.0), forKey: "inputColor1")
        guard let colored = falseColor.outputImage else { return nil }

        guard let cgImage = context.createCGImage(colored, from: cropRect) else { return nil }
        return NSImage(cgImage: cgImage, size: displaySize)
    }
}
