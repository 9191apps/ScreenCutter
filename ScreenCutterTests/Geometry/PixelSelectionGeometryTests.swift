import CoreGraphics
import XCTest

@testable import ScreenCutter

final class PixelSelectionGeometryTests: XCTestCase {
    private let metrics = DisplayMetrics(
        screenID: 1,
        pointFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        pixelSize: CGSize(width: 1000, height: 1000)
    )

    func testRectFromTwoPointsHandlesEveryDirection() {
        XCTAssertEqual(
            PixelSelectionGeometry.rect(from: PixelPoint(x: 10, y: 20), to: PixelPoint(x: 4, y: 30)),
            PixelRect(x: 4, y: 20, width: 6, height: 10)
        )
        XCTAssertEqual(
            PixelSelectionGeometry.rect(from: PixelPoint(x: 40, y: 50), to: PixelPoint(x: 10, y: 20)),
            PixelRect(x: 10, y: 20, width: 30, height: 30)
        )
    }

    func testMoveClampsToTheDisplayAndKeepsSize() {
        let rect = PixelRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(
            PixelSelectionGeometry.moved(rect, by: PixelPoint(x: -50, y: 30), in: metrics),
            PixelRect(x: 0, y: 50, width: 100, height: 50)
        )
        XCTAssertEqual(
            PixelSelectionGeometry.moved(rect, by: PixelPoint(x: 1000, y: 1000), in: metrics),
            PixelRect(x: 900, y: 950, width: 100, height: 50)
        )
    }

    func testNudgeUsesPixelDirections() {
        let rect = PixelRect(x: 100, y: 100, width: 40, height: 40)
        XCTAssertEqual(
            PixelSelectionGeometry.nudged(rect, direction: .up, step: 1, in: metrics),
            PixelRect(x: 100, y: 99, width: 40, height: 40)
        )
        XCTAssertEqual(
            PixelSelectionGeometry.nudged(rect, direction: .down, step: 10, in: metrics),
            PixelRect(x: 100, y: 110, width: 40, height: 40)
        )
    }

    func testResizingRightEdgeChangesWidth() {
        let rect = PixelRect(x: 100, y: 100, width: 200, height: 80)
        XCTAssertEqual(
            PixelSelectionGeometry.resized(
                rect,
                handle: .maxX,
                to: PixelPoint(x: 250, y: 0),
                in: metrics
            ),
            PixelRect(x: 100, y: 100, width: 150, height: 80)
        )
    }

    func testResizingLeftEdgeKeepsOnePixelMinimum() {
        let rect = PixelRect(x: 100, y: 100, width: 200, height: 80)
        XCTAssertEqual(
            PixelSelectionGeometry.resized(
                rect,
                handle: .minX,
                to: PixelPoint(x: 310, y: 0),
                in: metrics
            ),
            PixelRect(x: 299, y: 100, width: 1, height: 80)
        )
    }

    func testAppKitBottomHandleMovesThePixelBottomEdge() {
        let rect = PixelRect(x: 100, y: 100, width: 200, height: 80)
        XCTAssertEqual(
            PixelSelectionGeometry.resized(
                rect,
                handle: .minY,
                to: PixelPoint(x: 0, y: 250),
                in: metrics
            ),
            PixelRect(x: 100, y: 100, width: 200, height: 150)
        )
    }

    func testAppKitTopHandleMovesThePixelTopEdge() {
        let rect = PixelRect(x: 100, y: 100, width: 200, height: 80)
        XCTAssertEqual(
            PixelSelectionGeometry.resized(
                rect,
                handle: .maxY,
                to: PixelPoint(x: 0, y: 90),
                in: metrics
            ),
            PixelRect(x: 100, y: 90, width: 200, height: 90)
        )
    }

    func testOptionArrowAdjustsOnlyTheTrailingAndTopEdges() {
        let rect = PixelRect(x: 100, y: 100, width: 200, height: 80)
        XCTAssertEqual(
            PixelSelectionGeometry.adjustedTrailingEdge(rect, direction: .right, step: 10, in: metrics),
            PixelRect(x: 100, y: 100, width: 210, height: 80)
        )
        XCTAssertEqual(
            PixelSelectionGeometry.adjustedTrailingEdge(rect, direction: .left, step: 10, in: metrics),
            PixelRect(x: 100, y: 100, width: 190, height: 80)
        )
        XCTAssertEqual(
            PixelSelectionGeometry.adjustedTrailingEdge(rect, direction: .up, step: 10, in: metrics),
            PixelRect(x: 100, y: 90, width: 200, height: 90)
        )
        XCTAssertEqual(
            PixelSelectionGeometry.adjustedTrailingEdge(rect, direction: .down, step: 10, in: metrics),
            PixelRect(x: 100, y: 110, width: 200, height: 70)
        )
    }

    func testOnePixelSelectionIsStillSelectableAndExportable() {
        let rect = PixelRect(x: 10, y: 10, width: 1, height: 1)
        XCTAssertTrue(SelectionGeometry.isSubstantial(rect))
        XCTAssertEqual(rect.clampedForSelection(in: metrics), rect)
    }
}
