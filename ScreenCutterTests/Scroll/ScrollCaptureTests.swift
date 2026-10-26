import XCTest
@testable import ScreenCutter

final class ScrollCaptureTests: XCTestCase {
    func testWheelDeltaUsesPixelHeight() {
        XCTAssertEqual(ScrollCapture.wheelDeltaPixels(for: 100), 35)
        XCTAssertEqual(ScrollCapture.wheelDeltaPixels(for: 10), 40)
    }

    func testPreferredOverlapTracksScrollStep() {
        XCTAssertEqual(ScrollCapture.preferredOverlapRows(forFrameHeight: 100), 65)
        let range = ScrollCapture.overlapSearchRange(forFrameHeight: 100)
        XCTAssertTrue(range.contains(65))
        XCTAssertGreaterThanOrEqual(range.lowerBound, ScrollStitch.minimumOverlap)
    }
}
