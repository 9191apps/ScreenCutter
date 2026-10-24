import CoreGraphics
import XCTest

@testable import ScreenCutter

final class SelectionGeometryTests: XCTestCase {
    func testCaptureUsesDisplayPixelsWithoutScaling() {
        let selection = ScreenSelection(
            screenID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 2,
            globalRect: CGRect(x: 10, y: 20.3, width: 15.2, height: 9.1)
        )
        let output = ScreenCaptureService.output(for: selection, pixelWidth: 2880, pixelHeight: 1800)
        XCTAssertFalse(output.scalesToFit)
        XCTAssertEqual(output.width, 2880)
        XCTAssertEqual(output.height, 1800)
        XCTAssertEqual(output.crop, CGRect(x: 20, y: 1741, width: 30, height: 18))
    }

    func testPixelCropOnScreenLeftOfPrimary() {
        let crop = SelectionGeometry.pixelCrop(
            globalRect: CGRect(x: -1000, y: 100, width: 400, height: 200),
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            imageWidth: 1920,
            imageHeight: 1080
        )
        XCTAssertEqual(crop, CGRect(x: 920, y: 780, width: 400, height: 200))
    }

    func testPixelAlignsEdgesToRetinaPixels() {
        let rect = CGRect(x: 10, y: 20.3, width: 15.2, height: 9.1)
        let aligned = SelectionGeometry.pixelAligned(rect, scale: 2)
        XCTAssertEqual(aligned, CGRect(x: 10, y: 20.5, width: 15, height: 9))
    }

    func testDisplayLocalRectOnRetinaPrimaryScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 200, width: 300, height: 150)

        XCTAssertEqual(
            SelectionGeometry.displayLocalRect(selection: selection, screenFrame: screen),
            CGRect(x: 100, y: 550, width: 300, height: 150)
        )
        XCTAssertEqual(
            SelectionGeometry.outputPixelSize(of: selection, scale: 2),
            PixelSize(width: 600, height: 300)
        )
    }

    func testDisplayLocalRectOn1xScreenLeftOfPrimary() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: -1000, y: 100, width: 400, height: 200)

        XCTAssertEqual(
            SelectionGeometry.displayLocalRect(selection: selection, screenFrame: screen),
            CGRect(x: 920, y: 780, width: 400, height: 200)
        )
        XCTAssertEqual(
            SelectionGeometry.outputPixelSize(of: selection, scale: 1),
            PixelSize(width: 400, height: 200)
        )
    }

    func testDisplayLocalRectOnScreenAbovePrimary() {
        let screen = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let selection = CGRect(x: 10, y: 1000, width: 50, height: 40)

        XCTAssertEqual(
            SelectionGeometry.displayLocalRect(selection: selection, screenFrame: screen),
            CGRect(x: 10, y: 760, width: 50, height: 40)
        )
    }

    func testActionBarPrefersBelowTrailingEdge() {
        let frame = SelectionGeometry.actionBarFrame(
            selection: CGRect(x: 100, y: 100, width: 200, height: 150),
            screenSize: CGSize(width: 1000, height: 800),
            barSize: CGSize(width: 180, height: 36),
            margin: 8
        )
        XCTAssertEqual(frame, CGRect(x: 120, y: 258, width: 180, height: 36))
    }

    func testActionBarFlipsAboveBottomEdge() {
        let frame = SelectionGeometry.actionBarFrame(
            selection: CGRect(x: 100, y: 740, width: 200, height: 50),
            screenSize: CGSize(width: 1000, height: 800),
            barSize: CGSize(width: 180, height: 36),
            margin: 8
        )
        XCTAssertEqual(frame, CGRect(x: 120, y: 696, width: 180, height: 36))
    }

    func testActionBarShiftsInwardFromLeftEdge() {
        let frame = SelectionGeometry.actionBarFrame(
            selection: CGRect(x: 4, y: 100, width: 40, height: 40),
            screenSize: CGSize(width: 1000, height: 800),
            barSize: CGSize(width: 180, height: 36),
            margin: 8
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: 148, width: 180, height: 36))
    }

    func testActionBarShiftsInwardFromRightEdge() {
        let frame = SelectionGeometry.actionBarFrame(
            selection: CGRect(x: 900, y: 100, width: 80, height: 40),
            screenSize: CGSize(width: 1000, height: 800),
            barSize: CGSize(width: 180, height: 36),
            margin: 8
        )
        XCTAssertEqual(frame, CGRect(x: 800, y: 148, width: 180, height: 36))
    }

    func testSquareConstraintUsesTheLongerSide() {
        let rect = SelectionGeometry.rect(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 30, y: 50),
            constrainSquare: true
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 40, height: 40))
    }

    func testCornerHitWinsOverTheEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 80)
        XCTAssertEqual(
            SelectionGeometry.hitHandle(point: CGPoint(x: 300, y: 180), in: rect),
            .maxXmaxY
        )
        XCTAssertEqual(
            SelectionGeometry.hitHandle(point: CGPoint(x: 200, y: 180), in: rect),
            .maxY
        )
        XCTAssertEqual(
            SelectionGeometry.hitHandle(point: CGPoint(x: 160, y: 140), in: rect),
            .move
        )
        XCTAssertNil(SelectionGeometry.hitHandle(point: CGPoint(x: 20, y: 20), in: rect))
    }

    func testResizeKeepsTheOppositeEdgeAndMinimumSize() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 80)
        XCTAssertEqual(
            SelectionGeometry.resized(rect, handle: .maxX, to: CGPoint(x: 250, y: 100)),
            CGRect(x: 100, y: 100, width: 150, height: 80)
        )
        XCTAssertEqual(
            SelectionGeometry.resized(rect, handle: .minX, to: CGPoint(x: 310, y: 100)),
            CGRect(x: 296, y: 100, width: 4, height: 80)
        )
    }

    func testNudgeMovesUpInGlobalCoordinatesAndStopsAtTheScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 100, y: 100, width: 40, height: 40)
        XCTAssertEqual(
            SelectionGeometry.nudged(rect, direction: .up, step: 10, within: screen),
            CGRect(x: 100, y: 110, width: 40, height: 40)
        )
        let againstTop = CGRect(x: 100, y: 760, width: 40, height: 40)
        XCTAssertEqual(
            SelectionGeometry.nudged(againstTop, direction: .up, step: 10, within: screen),
            againstTop
        )
    }

    func testSpaceMoveTranslatesBothCornersAndStopsAtTheScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let moved = SelectionGeometry.movedSelection(
            anchor: CGPoint(x: 100, y: 100),
            current: CGPoint(x: 300, y: 250),
            by: CGPoint(x: 50, y: 20),
            within: screen
        )
        XCTAssertEqual(moved.anchor, CGPoint(x: 150, y: 120))
        XCTAssertEqual(moved.current, CGPoint(x: 350, y: 270))

        let pinned = SelectionGeometry.movedSelection(
            anchor: CGPoint(x: 10, y: 10),
            current: CGPoint(x: 40, y: 40),
            by: CGPoint(x: -100, y: -100),
            within: screen
        )
        XCTAssertEqual(pinned.anchor, .zero)
        XCTAssertEqual(pinned.current, CGPoint(x: 30, y: 30))
    }

    func testSelectionMustBeAtLeastFourPointsOnEachSide() {
        XCTAssertFalse(SelectionGeometry.isSubstantial(CGRect(x: 0, y: 0, width: 3.9, height: 100)))
        XCTAssertTrue(SelectionGeometry.isSubstantial(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    func testSuggestedFilenameUsesLocalCalendarComponents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 10,
            day: 23,
            hour: 22,
            minute: 45,
            second: 1
        ))!

        XCTAssertEqual(
            ImageExport.suggestedFilename(date: date, calendar: calendar),
            "ScreenCutter 2026-10-23 22.45.01.png"
        )
    }
}
