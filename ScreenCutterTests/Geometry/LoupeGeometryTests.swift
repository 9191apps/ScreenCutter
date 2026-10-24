import CoreGraphics
import XCTest

@testable import ScreenCutter

final class LoupeGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 160, height: 190)

    func testLoupeSitsBelowRightOfTheCursorWhenThereIsRoom() {
        let frame = LoupeGeometry.frame(cursor: CGPoint(x: 100, y: 700), size: size, bounds: bounds)
        XCTAssertEqual(frame, CGRect(x: 118, y: 492, width: 160, height: 190))
    }

    func testLoupeFlipsWhenTheCursorIsNearTheRightAndBottomEdges() {
        let frame = LoupeGeometry.frame(cursor: CGPoint(x: 950, y: 100), size: size, bounds: bounds)
        XCTAssertEqual(frame, CGRect(x: 772, y: 118, width: 160, height: 190))
    }

    func testLoupeClampsInsideTheOverlay() {
        let frame = LoupeGeometry.frame(cursor: CGPoint(x: 2, y: 2), size: size, bounds: bounds)
        XCTAssertEqual(frame, CGRect(x: 20, y: 20, width: 160, height: 190))
    }

    func testLoupeFrameSnapsToTheBackingStore() {
        let frame = CGRect(x: 110.3, y: 492.7, width: 160, height: 190)
        XCTAssertEqual(
            LoupeGeometry.alignedToBackingStore(frame, scale: 1),
            CGRect(x: 110, y: 493, width: 160, height: 190)
        )
        XCTAssertEqual(
            LoupeGeometry.alignedToBackingStore(frame, scale: 2),
            CGRect(x: 110.5, y: 492.5, width: 160, height: 190)
        )
        XCTAssertEqual(
            LoupeGeometry.alignedToBackingStore(frame, scale: 0),
            frame
        )
    }

    func testSourceFocusScalesWithTheSnapshot() {        let focus = PixelPoint(x: 100, y: 50)
        XCTAssertEqual(
            LoupeGeometry.sourceFocus(
                displayFocus: focus,
                sourceSize: CGSize(width: 3840, height: 2160),
                displayPixelSize: CGSize(width: 1920, height: 1080)
            ),
            CGPoint(x: 200, y: 100)
        )
        XCTAssertEqual(
            LoupeGeometry.sourceFocus(
                displayFocus: focus,
                sourceSize: CGSize(width: 3840, height: 2160),
                displayPixelSize: CGSize(width: 3840, height: 2160)
            ),
            CGPoint(x: 100, y: 50)
        )
    }
}
