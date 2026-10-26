import XCTest
@testable import ScreenCutter

final class ScrollCaptureTests: XCTestCase {
    func testWheelDeltaUsesPixelHeight() {
        XCTAssertEqual(ScrollCapture.wheelDeltaPixels(for: 100), 35)
        XCTAssertEqual(ScrollCapture.wheelDeltaPixels(for: 10), 40)
    }

    func testShiftSearchRangeCentersOnScrollStep() {
        XCTAssertEqual(ScrollCapture.expectedNewRows(forFrameHeight: 100), 35)
        let range = ScrollShift.shiftSearchRange(
            frameHeight: 100,
            expectedNewRows: 35,
            slack: ScrollCapture.shiftSearchSlack(forExpectedNewRows: 35)
        )
        XCTAssertTrue(range.contains(35))
        XCTAssertGreaterThanOrEqual(range.lowerBound, ScrollShift.minimumNewRows)
    }
}
