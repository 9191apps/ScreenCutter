import CoreGraphics
import XCTest

@testable import ScreenCutter

final class SnapEngineTests: XCTestCase {
    private let metrics = DisplayMetrics(
        screenID: 7,
        pointFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        pixelSize: CGSize(width: 2000, height: 2000)
    )

    private var window: ListedWindow {
        ListedWindow(
            windowID: 1,
            appKitFrame: CGRect(x: 100, y: 100, width: 300, height: 200),
            title: "Window"
        )
    }

    func testThresholdUsesFourPoints() {
        XCTAssertEqual(SnapEngine.threshold(for: metrics), 8)
    }

    func testCandidatesIncludeScreenEdgesCenterAndWindowEdges() {
        let candidates = SnapEngine.candidates(metrics: metrics, windows: [window])
        XCTAssertTrue(candidates.contains(SnapCandidate(axis: .vertical, coordinate: 0, priority: 2)))
        XCTAssertTrue(candidates.contains(SnapCandidate(axis: .vertical, coordinate: 1000, priority: 1)))
        XCTAssertTrue(candidates.contains(SnapCandidate(axis: .vertical, coordinate: 2000, priority: 2)))
        XCTAssertTrue(candidates.contains(SnapCandidate(axis: .vertical, coordinate: 200, priority: 0)))
        XCTAssertTrue(candidates.contains(SnapCandidate(axis: .vertical, coordinate: 800, priority: 0)))
        XCTAssertTrue(candidates.contains(SnapCandidate(axis: .horizontal, coordinate: 1400, priority: 0)))
        XCTAssertTrue(candidates.contains(SnapCandidate(axis: .horizontal, coordinate: 1800, priority: 0)))
    }

    func testNearestPrefersWindowEdgeOnATie() {
        let candidates = [
            SnapCandidate(axis: .vertical, coordinate: 50, priority: 2),
            SnapCandidate(axis: .vertical, coordinate: 54, priority: 0),
        ]
        XCTAssertEqual(
            SnapEngine.nearest(to: 52, axis: .vertical, candidates: candidates, threshold: 4),
            SnapCandidate(axis: .vertical, coordinate: 54, priority: 0)
        )
    }

    func testNearestIgnoresFarCandidates() {
        let candidates = [SnapCandidate(axis: .vertical, coordinate: 100, priority: 0)]
        XCTAssertNil(SnapEngine.nearest(to: 90, axis: .vertical, candidates: candidates, threshold: 8))
        XCTAssertEqual(
            SnapEngine.nearest(to: 92, axis: .vertical, candidates: candidates, threshold: 8),
            candidates[0]
        )
    }

    func testSnapPointMovesBothAxesToCandidates() {
        let candidates = SnapEngine.candidates(metrics: metrics, windows: [window])
        let snapped = SnapEngine.snap(
            point: PixelPoint(x: 197, y: 1397),
            metrics: metrics,
            candidates: candidates,
            threshold: 8
        )
        XCTAssertEqual(snapped, PixelPoint(x: 200, y: 1400))
    }

    func testSnapMovedShiftsWithoutResizing() {
        let rect = PixelRect(x: 190, y: 1390, width: 100, height: 50)
        let candidates = SnapEngine.candidates(metrics: metrics, windows: [window])
        let moved = SnapEngine.snapMoved(rect, metrics: metrics, candidates: candidates, threshold: 12)
        XCTAssertEqual(moved, PixelRect(x: 200, y: 1400, width: 100, height: 50))
    }

    func testSnapMovedDoesNotEscapeTheDisplay() {
        let rect = PixelRect(x: 2, y: 2, width: 100, height: 50)
        let candidates = [SnapCandidate(axis: .vertical, coordinate: 0, priority: 2)]
        let moved = SnapEngine.snapMoved(rect, metrics: metrics, candidates: candidates, threshold: 8)
        XCTAssertEqual(moved, PixelRect(x: 0, y: 2, width: 100, height: 50))
    }
}
