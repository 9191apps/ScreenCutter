import AppKit
import CoreGraphics
import XCTest

@testable import ScreenCutter

/// The capture is a still: every display is frozen before the overlay appears, and
/// the selection, the magnifier, and the exported file all come from that frame.
/// These tests pin the pixel mapping from a display-local selection into the frame
/// and the wiring that hands the frame to the overlay.
@MainActor
final class FrozenCaptureTests: XCTestCase {
    private let metrics = DisplayMetrics(
        screenID: 1,
        pointFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
        pixelSize: CGSize(width: 200, height: 200)
    )

    private func selection(_ rect: PixelRect) -> ScreenSelection {
        ScreenSelection(metrics: metrics, pixelRect: rect)
    }

    /// A frame where red is the x coordinate and green is the y coordinate, written
    /// top-down so a crop's offset can be read back directly.
    private func makeCoordinateImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(clamping: x)
                bytes[index + 1] = UInt8(clamping: y)
                bytes[index + 2] = 0
                bytes[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeSolidImage(level: UInt8, width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = level
            bytes[index + 1] = level
            bytes[index + 2] = level
            bytes[index + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8) {
        let one = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (bytes[0], bytes[1])
    }

    func testCropTakesTheSelectionPixelsOutOfTheFrame() throws {
        let frame = try makeCoordinateImage(width: 200, height: 200)

        let cropped = try XCTUnwrap(
            ScreenCaptureService.crop(frame, to: selection(PixelRect(x: 40, y: 30, width: 20, height: 10)))
        )

        XCTAssertEqual(cropped.width, 20)
        XCTAssertEqual(cropped.height, 10)
        let topLeft = try pixel(cropped, x: 0, y: 0)
        XCTAssertEqual(topLeft.red, 40)
        XCTAssertEqual(topLeft.green, 30)
        let bottomRight = try pixel(cropped, x: 19, y: 9)
        XCTAssertEqual(bottomRight.red, 59)
        XCTAssertEqual(bottomRight.green, 39)
    }

    func testCropRescalesWhenTheFrameIsNotTheModeSize() throws {
        let frame = try makeCoordinateImage(width: 400, height: 400)
        let halfScale = DisplayMetrics(
            screenID: 1,
            pointFrame: metrics.pointFrame,
            pixelSize: CGSize(width: 200, height: 200)
        )
        let selection = ScreenSelection(
            metrics: halfScale,
            pixelRect: PixelRect(x: 10, y: 10, width: 10, height: 10)
        )

        let cropped = try XCTUnwrap(ScreenCaptureService.crop(frame, to: selection))

        XCTAssertEqual(cropped.width, 20)
        XCTAssertEqual(cropped.height, 20)
        let topLeft = try pixel(cropped, x: 0, y: 0)
        XCTAssertEqual(topLeft.red, 20)
        XCTAssertEqual(topLeft.green, 20)
    }

    func testCropRejectsAnEmptySelection() throws {
        let frame = try makeCoordinateImage(width: 200, height: 200)
        XCTAssertNil(ScreenCaptureService.crop(frame, to: selection(PixelRect(x: 10, y: 10, width: 0, height: 10))))
        XCTAssertNil(ScreenCaptureService.crop(frame, to: selection(PixelRect(x: 300, y: 300, width: 10, height: 10))))
    }

    /// The overlay must read as one still: the frame at full brightness inside the
    /// hole, the same frame dimmed outside it.
    func testBackdropSitsUnderTheDimAndTheHoleStaysBright() throws {
        let solid = try makeSolidImage(level: 200, width: 100, height: 100)
        let container = FrozenBackdropView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        container.setImage(solid)
        let dim = DimMaskView(frame: container.bounds)
        container.addSubview(dim)
        dim.setHole(CGRect(x: 0, y: 0, width: 50, height: 100))

        // A window that is never ordered in does not attach subview layers, so
        // compose the same two layers AppKit would build for the overlay.
        let dimLayer = try XCTUnwrap(dim.layer)
        dimLayer.frame = container.bounds
        container.layer?.addSublayer(dimLayer)
        dim.layout()

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100,
            pixelsHigh: 100,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        container.layer?.render(in: graphics.cgContext)

        let shape = try XCTUnwrap(dim.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        XCTAssertFalse(shape.path?.isEmpty ?? true, "the dim needs a path")

        let holeColor = try XCTUnwrap(rep.colorAt(x: 10, y: 50))
        let dimmedColor = try XCTUnwrap(rep.colorAt(x: 90, y: 50))
        let hole = try XCTUnwrap(holeColor.usingColorSpace(.deviceRGB))
        let dimmed = try XCTUnwrap(dimmedColor.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(hole.redComponent, 0.7, "the hole must show the frozen frame undimmed")
        XCTAssertLessThan(dimmed.redComponent, 0.6, "outside the hole the same frame must be dimmed")
    }

    func testSessionServesTheFrozenFrameToTheLoupeAndExport() throws {
        let session = CaptureSession()
        let frame = try makeCoordinateImage(width: 200, height: 200)
        session.setFrozenScreensForTesting([1: frame])

        XCTAssertTrue(session.frozenFrame(for: 1) === frame)
        XCTAssertNil(session.frozenFrame(for: 2))

        let cropped = try XCTUnwrap(
            session.frozenImage(for: selection(PixelRect(x: 5, y: 6, width: 7, height: 8)))
        )
        XCTAssertEqual(cropped.width, 7)
        XCTAssertEqual(cropped.height, 8)
        let topLeft = try pixel(cropped, x: 0, y: 0)
        XCTAssertEqual(topLeft.red, 5)
        XCTAssertEqual(topLeft.green, 6)
    }

    /// Exercises the real capture path. It is skipped where the test host has no
    /// screen recording permission, so CI without a logged-in session stays green.
    func testFreezeReturnsFramesAtTheDisplayPixelSizeWhenPermitted() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("screen recording permission is not granted in this environment")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let pixelSize = screen.displayMetrics.pixelSize

        let frames = try await ScreenCaptureService.freeze(displays: [
            ScreenCaptureService.DisplayRequest(
                displayID: screen.displayID,
                pixelSize: pixelSize
            ),
        ])

        let frame = try XCTUnwrap(frames[screen.displayID])
        XCTAssertEqual(frame.width, Int(pixelSize.width.rounded()))
        XCTAssertEqual(frame.height, Int(pixelSize.height.rounded()))
    }

    func testOverlayBackdropShowsTheFrozenFrame() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Overlay layout needs a screen.")
        let session = CaptureSession()
        let frame = try makeCoordinateImage(width: 40, height: 40)
        session.setFrozenScreensForTesting([screen.displayID: frame])

        let view = SelectionTrackingView(session: session, screen: screen)
        let backdrop = try XCTUnwrap(view.subviews.compactMap { $0 as? FrozenBackdropView }.first)

        XCTAssertTrue(backdrop.image === frame)
        XCTAssertEqual(view.subviews.first, backdrop, "the still must sit under the dim and the chrome")
    }
}
