import XCTest
@testable import ScreenCutter

final class ScrollCaptureTests: XCTestCase {
    func testWheelDeltaUsesPixelHeight() {
        XCTAssertEqual(ScrollCapture.wheelDeltaPixels(for: 100), 55)
        XCTAssertEqual(ScrollCapture.wheelDeltaPixels(for: 10), 40)
    }
}
