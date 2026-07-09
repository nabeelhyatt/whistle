// ScreenshotEncodeTests.swift
// Plan U7 scenarios:
//   - encode a large (5K-equivalent synthetic) image -> <=2000px long
//     edge, <1MB
//   - TCC denied -> nil, no throw (inject the preflight check)

import CoreGraphics
import ImageIO
import XCTest
@testable import Whistle

// MARK: - Fakes

private struct FakePreflight: ScreenCapturePreflightChecking {
    let granted: Bool
    func isScreenCaptureAccessGranted() -> Bool { granted }
}

/// Fake `DisplayImageCapturing` that either returns a scripted `CGImage`
/// or `nil` (simulating any capture failure), without touching
/// `SCShareableContent`/`SCScreenshotManager` at all.
private struct FakeDisplayCapturer: DisplayImageCapturing {
    let image: CGImage?
    func captureDisplayUnderCursor() async -> CGImage? { image }
}

/// Builds a synthetic `CGImage` of the given pixel dimensions with a
/// non-trivial, but screenshot-realistic, pattern: a coarse grid of
/// blocks (each a solid color, like UI chrome/panels) plus a smooth
/// gradient (like a background or window content) rather than
/// per-pixel noise. Real screenshots — the actual input to this
/// pipeline — are full of large flat/smooth regions that JPEG's DCT
/// compresses very well; a per-pixel-random pattern is adversarial
/// high-frequency noise no real screenshot resembles, and would
/// legitimately fail the "<1MB" bound. This still isn't
/// trivially-flattenable (so the encoder can't collapse it to a
/// near-zero-byte solid color), but it stays representative.
private func makeSyntheticImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

    let blockSize = 64
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let blockX = x / blockSize
            let blockY = y / blockSize
            // Smooth gradient across the image plus a coarse per-block
            // color offset — large flat/smoothly-varying regions, the
            // way real screenshot content (panels, text blocks,
            // backgrounds) actually compresses.
            let gradientR = Int((Double(x) / Double(width)) * 255)
            let gradientG = Int((Double(y) / Double(height)) * 255)
            pixelData[offset] = UInt8((gradientR + blockX * 17) % 256)
            pixelData[offset + 1] = UInt8((gradientG + blockY * 23) % 256)
            pixelData[offset + 2] = UInt8((blockX * 29 + blockY * 31) % 256)
            pixelData[offset + 3] = 255
        }
    }

    let context = CGContext(
        data: &pixelData,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

final class ScreenshotEncodeTests: XCTestCase {
    // MARK: Happy: encode a large (5K-equivalent) synthetic image

    func testEncodingLargeImageDownscalesAndStaysUnderSizeCap() {
        // "5K-equivalent" synthetic image: 5120x2880 (5K display
        // resolution), well above the 2000px long-edge cap.
        let image = makeSyntheticImage(width: 5120, height: 2880)

        let data = ScreenshotService.encode(image)

        XCTAssertNotNil(data)
        guard let data else { return }

        XCTAssertLessThan(data.count, ScreenshotService.maxEncodedBytes)

        // Verify the encoded JPEG's actual pixel dimensions respect the
        // long-edge cap and preserve aspect ratio.
        guard let decoded = CGImage.decodeJPEGDimensions(data) else {
            XCTFail("failed to decode encoded JPEG back to an image")
            return
        }
        let longEdge = max(decoded.width, decoded.height)
        XCTAssertLessThanOrEqual(longEdge, Int(ScreenshotService.maxLongEdge))

        let originalAspect = 5120.0 / 2880.0
        let encodedAspect = Double(decoded.width) / Double(decoded.height)
        XCTAssertEqual(originalAspect, encodedAspect, accuracy: 0.01)
    }

    func testDownscalePreservesAspectRatioAndCapsLongEdge() {
        let image = makeSyntheticImage(width: 4000, height: 2000)
        let scaled = ScreenshotService.downscale(image, maxLongEdge: 2000)

        XCTAssertEqual(scaled.width, 2000)
        XCTAssertEqual(scaled.height, 1000)
    }

    func testDownscaleNeverUpscalesSmallImages() {
        let image = makeSyntheticImage(width: 800, height: 600)
        let scaled = ScreenshotService.downscale(image, maxLongEdge: 2000)

        XCTAssertEqual(scaled.width, 800)
        XCTAssertEqual(scaled.height, 600)
    }

    // MARK: Error: TCC denied -> nil, no throw

    func testCaptureReturnsNilWhenScreenCaptureAccessDenied() async {
        let service = ScreenshotService(
            preflight: FakePreflight(granted: false),
            capturer: FakeDisplayCapturer(image: makeSyntheticImage(width: 100, height: 100))
        )

        let result = await service.capture()

        XCTAssertNil(result, "capture() must return nil (not throw) when TCC access is denied")
    }

    func testCaptureReturnsDataWhenAccessGrantedAndCapturerSucceeds() async {
        let service = ScreenshotService(
            preflight: FakePreflight(granted: true),
            capturer: FakeDisplayCapturer(image: makeSyntheticImage(width: 1200, height: 800))
        )

        let result = await service.capture()

        XCTAssertNotNil(result)
    }

    func testCaptureReturnsNilWhenAccessGrantedButCapturerFails() async {
        // Simulates any underlying SCK capture failure (no displays, SCK
        // error, etc.) — still nil, never throws.
        let service = ScreenshotService(
            preflight: FakePreflight(granted: true),
            capturer: FakeDisplayCapturer(image: nil)
        )

        let result = await service.capture()

        XCTAssertNil(result)
    }
}

// MARK: - Test-only JPEG decode helper

private extension CGImage {
    static func decodeJPEGDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return (image.width, image.height)
    }
}
