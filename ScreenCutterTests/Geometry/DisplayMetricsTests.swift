import CoreGraphics
import XCTest

@testable import ScreenCutter

final class DisplayMetricsTests: XCTestCase {
    private let retina = DisplayMetrics(
        screenID: 1,
        pointFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800)
    )

    func testPixelRectRoundsEdgesAndFlipsTheVerticalAxis() {
        let rect = retina.pixelRect(for: CGRect(x: 10, y: 20.3, width: 15.2, height: 9.1))
        XCTAssertEqual(rect, PixelRect(x: 20, y: 1741, width: 30, height: 18))
    }

    func testPixelRectRoundTripsThroughGlobalPoints() {
        let rect = retina.pixelRect(for: CGRect(x: 10, y: 20.3, width: 15.2, height: 9.1))
        let global = retina.globalRect(for: rect)
        XCTAssertEqual(global, CGRect(x: 10, y: 20.5, width: 15, height: 9))
        XCTAssertEqual(retina.pixelRect(for: global), rect)
    }

    func testFullScreenMapsToTheWholeFramebuffer() {
        let rect = retina.pixelRect(for: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(rect, PixelRect(x: 0, y: 0, width: 2880, height: 1800))
        XCTAssertEqual(retina.globalRect(for: rect), CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testScreenLeftOfPrimary() {
        let metrics = DisplayMetrics(
            screenID: 2,
            pointFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080)
        )
        let rect = metrics.pixelRect(for: CGRect(x: -1000, y: 100, width: 400, height: 200))
        XCTAssertEqual(rect, PixelRect(x: 920, y: 780, width: 400, height: 200))
    }

    func testNonUniformPixelScale() {
        let metrics = DisplayMetrics(
            screenID: 3,
            pointFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            pixelSize: CGSize(width: 1500, height: 2000)
        )
        XCTAssertEqual(metrics.scaleX, 1.5)
        XCTAssertEqual(metrics.scaleY, 2)
        XCTAssertEqual(
            metrics.pixelRect(for: CGRect(x: 100, y: 200, width: 300, height: 400)),
            PixelRect(x: 150, y: 800, width: 450, height: 800)
        )
    }

    func testPixelPointCanFloorOrRound() {
        let point = CGPoint(x: 10.2, y: 20.7)
        XCTAssertEqual(retina.pixelPoint(for: point), PixelPoint(x: 20, y: 1758))
        XCTAssertEqual(retina.pixelPoint(for: point, rounded: true), PixelPoint(x: 20, y: 1759))
    }

    func testClampedEdges() {
        let rect = PixelRect(x: -10, y: -20, width: 50, height: 60).clampedEdges(in: retina)
        XCTAssertEqual(rect, PixelRect(x: 0, y: 0, width: 40, height: 40))
    }

    func testClampedForSelectionKeepsOnePixelAndStaysInside() {
        let rect = PixelRect(x: 5000, y: -3, width: 0, height: 9999).clampedForSelection(in: retina)
        XCTAssertEqual(rect, PixelRect(x: 2879, y: 0, width: 1, height: 1800))

        let tooLarge = PixelRect(x: 10, y: 10, width: 9999, height: 9999).clampedForSelection(in: retina)
        XCTAssertEqual(tooLarge, PixelRect(x: 0, y: 0, width: 2880, height: 1800))
    }

    func testScaledCropFallsBackToActualImageSize() {
        let rect = PixelRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(
            rect.scaled(from: CGSize(width: 2880, height: 1800), to: CGSize(width: 1440, height: 900)),
            PixelRect(x: 5, y: 10, width: 15, height: 20)
        )
    }

    func testPrecisionInputClampsEveryField() {
        let rect = PrecisionInput.rect(x: 5000, y: -3, width: 0, height: 9999, in: retina)
        XCTAssertEqual(rect, PixelRect(x: 2879, y: 0, width: 1, height: 1800))
    }
}
