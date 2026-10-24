import CoreGraphics
import XCTest
@testable import ScreenCutter

final class WindowGeometryTests: XCTestCase {
    func testQuartzFrameFlipsAroundThePrimaryDisplayTop() {
        let quartz = CGRect(x: 100, y: 50, width: 200, height: 100)
        XCTAssertEqual(
            WindowGeometry.appKitFrame(fromQuartz: quartz, primaryHeight: 900),
            CGRect(x: 100, y: 750, width: 200, height: 100)
        )
    }

    func testHitPrefersTheFrontWindowAndClipsToTheCurrentScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let front = ListedWindow(windowID: 1, appKitFrame: CGRect(x: 100, y: 100, width: 400, height: 300), title: "前")
        let behind = ListedWindow(windowID: 2, appKitFrame: CGRect(x: 120, y: 120, width: 500, height: 400), title: "后")
        let crossing = ListedWindow(
            windowID: 3,
            appKitFrame: CGRect(x: 900, y: 100, width: 300, height: 200),
            title: "跨屏"
        )

        let frontHit = WindowGeometry.hit(point: CGPoint(x: 200, y: 200), windows: [front, behind], screenFrame: screen)
        XCTAssertEqual(frontHit?.window.windowID, 1)

        let clipped = WindowGeometry.hit(point: CGPoint(x: 950, y: 150), windows: [crossing], screenFrame: screen)
        XCTAssertEqual(clipped?.visibleFrame, CGRect(x: 900, y: 100, width: 100, height: 200))
        XCTAssertNil(WindowGeometry.hit(point: CGPoint(x: 1100, y: 150), windows: [crossing], screenFrame: screen))
    }
}
