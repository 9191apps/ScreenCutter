import Combine
import CoreGraphics
import XCTest

@testable import ScreenCutter

/// Pins the two observation channels apart: the overlay needs every interactive
/// phase (many per second while dragging), while SwiftUI must only hear about the
/// coarse state it renders. Before this split, each drag event invalidated the
/// menu and the Settings window, and their layout ran inside the overlay's
/// display cycle on every frame.
@MainActor
final class PhaseObservationTests: XCTestCase {
    private let metrics = DisplayMetrics(
        screenID: 1,
        pointFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        pixelSize: CGSize(width: 1000, height: 1000)
    )

    private func selection(_ rect: PixelRect) -> ScreenSelection {
        ScreenSelection(metrics: metrics, pixelRect: rect)
    }

    func testResizingPublishesPhaseChangesWithoutInvalidatingSwiftUI() {
        let session = CaptureSession()
        session.setPhaseForTesting(.actionBar(selection(PixelRect(x: 100, y: 100, width: 200, height: 100))))

        var swiftUIInvalidations = 0
        var phases: [CapturePhase] = []
        let swiftUI = session.objectWillChange.sink { _ in swiftUIInvalidations += 1 }
        let overlay = session.phaseChanges.sink { phases.append($0) }

        session.beginAdjustment(handle: .maxX, at: CGPoint(x: 300, y: 150))
        for step in 1...20 {
            session.updateAdjustment(to: CGPoint(x: 300 + CGFloat(step), y: 150), snapEnabled: false)
        }

        withExtendedLifetime((swiftUI, overlay)) {
            XCTAssertEqual(phases.count, 20, "the overlay must see every adjustment step")
            XCTAssertEqual(swiftUIInvalidations, 0, "SwiftUI must not re-render while a handle is dragged")
        }
    }

    func testEditingTogglesThePublishedMenuFlag() {
        let session = CaptureSession()
        XCTAssertFalse(session.isEditingSelection)

        session.setPhaseForTesting(.editing(selection(PixelRect(x: 0, y: 0, width: 10, height: 10))))
        XCTAssertTrue(session.isEditingSelection)

        session.setPhaseForTesting(.actionBar(selection(PixelRect(x: 0, y: 0, width: 10, height: 10))))
        XCTAssertFalse(session.isEditingSelection)
    }

    func testUnchangedGeometryIsNotRepublished() {
        let session = CaptureSession()
        let rect = PixelRect(x: 10, y: 10, width: 10, height: 10)
        session.setPhaseForTesting(.actionBar(selection(rect)))

        var phases: [CapturePhase] = []
        let subscriber = session.phaseChanges.sink { phases.append($0) }

        session.beginAdjustment(handle: .maxX, at: CGPoint(x: 20, y: 15))
        // The pointer stays on the same pixel, so the selection cannot move.
        session.updateAdjustment(to: CGPoint(x: 20.2, y: 15.2), snapEnabled: false)
        session.updateAdjustment(to: CGPoint(x: 20.4, y: 15.4), snapEnabled: false)

        withExtendedLifetime(subscriber) {
            XCTAssertTrue(phases.isEmpty, "an unchanged pixel rect must not republish the phase")
        }
    }

    func testSameInteractionClassification() {
        let rect = PixelRect(x: 10, y: 10, width: 10, height: 10)
        let bar = CapturePhase.actionBar(selection(rect))
        let editing = CapturePhase.editing(selection(rect))

        XCTAssertTrue(CapturePhase.selecting(nil).isSameInteraction(as: .selecting(nil)))
        XCTAssertTrue(bar.isSameInteraction(as: .actionBar(selection(PixelRect(x: 0, y: 0, width: 1, height: 1)))))
        XCTAssertFalse(bar.isSameInteraction(as: editing))
        XCTAssertFalse(editing.isSameInteraction(as: editing), "annotation editing is not a per-frame drag state")
    }
}
