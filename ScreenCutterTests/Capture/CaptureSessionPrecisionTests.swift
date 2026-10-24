import CoreGraphics
import XCTest

@testable import ScreenCutter

@MainActor
final class CaptureSessionPrecisionTests: XCTestCase {
    private let metrics = DisplayMetrics(
        screenID: 1,
        pointFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        pixelSize: CGSize(width: 1000, height: 1000)
    )

    private func selection(_ rect: PixelRect) -> ScreenSelection {
        ScreenSelection(metrics: metrics, pixelRect: rect)
    }

    private func actionBarRect(_ session: CaptureSession) -> PixelRect? {
        guard case .actionBar(let selection) = session.phase else { return nil }
        return selection.pixelRect
    }

    func testArrowNudgeMovesInPixels() {
        let session = CaptureSession()
        session.setPhaseForTesting(.actionBar(selection(PixelRect(x: 100, y: 100, width: 200, height: 100))))

        session.nudge(direction: .right, step: 1)
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 101, y: 100, width: 200, height: 100))

        session.nudge(direction: .right, step: 10)
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 111, y: 100, width: 200, height: 100))
    }

    func testOptionResizeChangesOnlyTheTrailingAndTopEdges() {
        let session = CaptureSession()
        session.setPhaseForTesting(.actionBar(selection(PixelRect(x: 100, y: 100, width: 200, height: 100))))

        session.resizeSelection(direction: .right, step: 10)
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 100, y: 100, width: 210, height: 100))

        session.resizeSelection(direction: .up, step: 10)
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 100, y: 90, width: 210, height: 110))
    }

    func testPrecisionInputIsClampedInsideTheDisplay() {
        let session = CaptureSession()
        session.setPhaseForTesting(.actionBar(selection(PixelRect(x: 100, y: 100, width: 200, height: 100))))

        session.setSelection(pixelRect: PixelRect(x: 990, y: 990, width: 50, height: 50))
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 950, y: 950, width: 50, height: 50))
    }

    func testDragShorterThanFourPointsIsDiscarded() {
        let session = CaptureSession()
        let drag = SelectionDrag(
            metrics: metrics,
            anchor: CGPoint(x: 100, y: 100),
            current: CGPoint(x: 102, y: 102),
            constrainSquare: false
        )
        session.setPhaseForTesting(.selecting(drag))

        session.endDrag(screenID: 1)

        guard case .selecting(nil) = session.phase else {
            return XCTFail("a short drag should return to the empty selecting state")
        }
    }

    func testSelectionSizeOnePixelSurvivesTheActionBar() {
        let session = CaptureSession()
        session.setPhaseForTesting(.actionBar(selection(PixelRect(x: 10, y: 10, width: 1, height: 1))))

        session.nudge(direction: .left, step: 1)
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 9, y: 10, width: 1, height: 1))

        session.resizeSelection(direction: .up, step: 1)
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 9, y: 9, width: 1, height: 2))
    }


    func testPreviewDoesNotMoveTheActionBar() {
        let session = CaptureSession()
        let original = PixelRect(x: 100, y: 100, width: 200, height: 100)
        session.setPhaseForTesting(.actionBar(selection(original)))

        session.previewSelection(PixelRect(x: 20, y: 30, width: 40, height: 50))

        XCTAssertEqual(session.previewRect, PixelRect(x: 20, y: 30, width: 40, height: 50))
        XCTAssertEqual(actionBarRect(session), original)

        session.previewSelection(nil)
        XCTAssertNil(session.previewRect)
        XCTAssertEqual(actionBarRect(session), original)
    }

    func testApplyingASelectionClearsThePreview() {
        let session = CaptureSession()
        session.setPhaseForTesting(.actionBar(selection(PixelRect(x: 100, y: 100, width: 200, height: 100))))
        session.previewSelection(PixelRect(x: 20, y: 30, width: 40, height: 50))

        session.setSelection(pixelRect: PixelRect(x: 20, y: 30, width: 40, height: 50))

        XCTAssertNil(session.previewRect)
        XCTAssertEqual(actionBarRect(session), PixelRect(x: 20, y: 30, width: 40, height: 50))
    }

    func testDragSnapsToTheScreenEdge() {
        let session = CaptureSession()
        session.setPhaseForTesting(.selecting(SelectionDrag(
            metrics: metrics,
            anchor: CGPoint(x: 800, y: 200),
            current: CGPoint(x: 800, y: 500),
            constrainSquare: false
        )))

        session.updateDrag(
            metrics: metrics,
            anchor: CGPoint(x: 800, y: 200),
            current: CGPoint(x: 996, y: 500),
            constrainSquare: false,
            snapEnabled: true
        )
        session.endDrag(screenID: 1)

        XCTAssertEqual(actionBarRect(session)?.width, 200)
    }
}
