import XCTest

@testable import ScreenCutter

@MainActor
final class LoupeViewTests: XCTestCase {
    func testSamplingAreaFillsTheMagnifiedContent() {
        XCTAssertEqual(
            LoupeView.zoom * CGFloat(LoupeView.sampleCount),
            LoupeView.contentSide,
            "改变倍数时也要调整取样格数，否则放大区会被裁切或留白"
        )
    }
}
