import AppKit
import XCTest

@testable import ScreenCutter

/// Covers the overlay's phase-to-layout wiring. `@Published` delivers its value
/// before the property is assigned, so these tests pin the overlay to the
/// publisher's phase rather than to `session.phase`.
@MainActor
final class SelectionTrackingViewTests: XCTestCase {
    func testActionBarPhaseShowsResizeHandles() throws {
        let overlay = try makeOverlay()

        overlay.session.setPhaseForTesting(.actionBar(overlay.selection))

        let chrome = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? SelectionChromeView }.first
        )
        XCTAssertEqual(chrome.resizeHandlePoints.count, 8)
        XCTAssertEqual(
            chrome.resizeHandlePoints.first,
            CGPoint(
                x: overlay.selection.globalRect.minX - overlay.screen.frame.minX,
                y: overlay.selection.globalRect.minY - overlay.screen.frame.minY
            )
        )
    }

    func testSelectingPhaseHasNoResizeHandles() throws {
        let overlay = try makeOverlay()

        overlay.session.setPhaseForTesting(.selecting(SelectionDrag(
            screenID: overlay.screen.displayID,
            screenFrame: overlay.screen.frame,
            scale: overlay.screen.backingScaleFactor,
            anchor: overlay.selection.globalRect.origin,
            current: CGPoint(
                x: overlay.selection.globalRect.maxX,
                y: overlay.selection.globalRect.maxY
            ),
            constrainSquare: false
        )))

        let chrome = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? SelectionChromeView }.first
        )
        XCTAssertTrue(chrome.resizeHandlePoints.isEmpty)
    }

    func testCursorIntentsForSelectionPhases() throws {
        let overlay = try makeOverlay()
        let selection = overlay.selection

        overlay.session.setPhaseForTesting(.selecting(nil))
        XCTAssertEqual(overlay.view.cursorIntent(at: CGPoint(x: 20, y: 20)), .crosshair)

        overlay.session.setPhaseForTesting(.windowPicking(nil))
        XCTAssertEqual(overlay.view.cursorIntent(at: CGPoint(x: 20, y: 20)), .arrow)

        overlay.session.setPhaseForTesting(.windowPicking(WindowHover(
            screenID: overlay.screen.displayID,
            screenFrame: overlay.screen.frame,
            scale: overlay.screen.backingScaleFactor,
            globalRect: selection.globalRect,
            title: "Window"
        )))
        XCTAssertEqual(overlay.view.cursorIntent(at: CGPoint(x: 20, y: 20)), .pointingHand)

        overlay.session.setPhaseForTesting(.working(selection))
        XCTAssertEqual(overlay.view.cursorIntent(at: CGPoint(x: 20, y: 20)), .arrow)
    }

    func testCursorIntentsForActionBarSelection() throws {
        let overlay = try makeOverlay()
        let local = selectionViewRect(overlay.selection, screen: overlay.screen)

        overlay.session.setPhaseForTesting(.actionBar(overlay.selection))

        XCTAssertEqual(
            overlay.view.cursorIntent(at: CGPoint(x: local.midX, y: local.midY)),
            .openHand
        )
        XCTAssertEqual(
            overlay.view.cursorIntent(at: CGPoint(x: local.minX, y: local.minY)),
            .resize(.minXminY)
        )
        XCTAssertEqual(
            overlay.view.cursorIntent(at: CGPoint(x: local.minX - 40, y: local.midY)),
            .arrow
        )
    }

    func testCursorIntentsForAnnotations() throws {
        let overlay = try makeOverlay()
        let image = try XCTUnwrap(makeImage(width: 800, height: 600))
        overlay.session.setEditingImageForTesting(image)
        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let window = NSWindow(
            contentRect: overlay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay.view
        overlay.view.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )
        let local = SelectionGeometry.displayLocalRect(
            selection: overlay.selection.globalRect,
            screenFrame: overlay.screen.frame
        )
        let imageFrame = CGRect(
            x: local.minX,
            y: overlay.view.bounds.height - local.maxY,
            width: local.width,
            height: local.height
        )
        let rectangle = CGRect(
            x: local.minX + 100,
            y: imageFrame.maxY - 150,
            width: 50,
            height: 50
        )
        let imageRect = AnnotationGeometry.imageRect(
            viewRect: rectangle,
            imageFrame: imageFrame,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        overlay.session.setAnnotationDraft(.rectangle(imageRect, overlay.session.annotation.style))
        overlay.session.commitAnnotationDraft()
        XCTAssertEqual(overlay.session.selectedAnnotation, 0)

        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: rectangle.midX, y: rectangle.midY)),
            .openHand
        )
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: rectangle.minX, y: rectangle.minY)),
            .resize(.minXminY)
        )

        // A selected rectangle shows the move cursor while dragging.
        canvas.mouseDown(
            with: mouseEvent(.leftMouseDown, at: CGPoint(x: rectangle.midX, y: rectangle.midY), in: window)
        )
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: rectangle.midX, y: rectangle.midY)),
            .closedHand
        )
        canvas.mouseUp(
            with: mouseEvent(.leftMouseUp, at: CGPoint(x: rectangle.midX, y: rectangle.midY), in: window)
        )
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: rectangle.midX, y: rectangle.midY)),
            .openHand
        )

        // A selected rectangle's handle shows the matching resize cursor.
        canvas.mouseDown(
            with: mouseEvent(.leftMouseDown, at: CGPoint(x: rectangle.minX, y: rectangle.minY), in: window)
        )
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: rectangle.minX, y: rectangle.minY)),
            .resize(.minXminY)
        )
        canvas.mouseUp(
            with: mouseEvent(.leftMouseUp, at: CGPoint(x: rectangle.minX, y: rectangle.minY), in: window)
        )

        // An unselected annotation is clickable, so hover shows a pointing
        // hand. Once the drag threshold starts a new stroke, it becomes a
        // crosshair so the cursor matches what the drag is doing.
        overlay.session.selectAnnotation(at: nil)
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: rectangle.midX, y: rectangle.midY)),
            .pointingHand
        )

        let drawStart = CGPoint(x: rectangle.midX, y: rectangle.midY)
        let drawEnd = CGPoint(x: drawStart.x + 12, y: drawStart.y + 12)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: drawStart, in: window))
        XCTAssertEqual(canvas.cursorIntent(at: drawStart), .pointingHand)
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: drawEnd, in: window))
        XCTAssertEqual(canvas.cursorIntent(at: drawEnd), .crosshair)
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: drawEnd, in: window))

        XCTAssertEqual(overlay.session.annotation.strokes.count, 2)
        XCTAssertEqual(overlay.session.selectedAnnotation, 1)
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: local.minX + 10, y: imageFrame.maxY - 10)),
            .crosshair
        )

        // The text tool places text rather than moving an annotation.
        overlay.session.setAnnotationTool(.text)
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(x: local.minX + 50, y: imageFrame.maxY - 50)),
            .iBeam
        )
        XCTAssertEqual(
            canvas.cursorIntent(at: CGPoint(
                x: canvas.toolbarView.frame.midX,
                y: canvas.toolbarView.frame.midY
            )),
            .arrow
        )
    }

    func testEditingPhaseShowsAnnotationToolbarAndHidesSelectionActionBar() throws {
        let overlay = try makeOverlay()

        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )
        XCTAssertFalse(canvas.isHidden)
        XCTAssertFalse(canvas.toolbarView.isHidden)
        XCTAssertGreaterThan(canvas.toolbarView.frame.width, 100)
        XCTAssertGreaterThan(canvas.toolbarView.frame.height, 20)
        XCTAssertTrue(overlay.view.bounds.contains(canvas.toolbarView.frame))

        let actionBar = overlay.view.subviews
            .compactMap { $0 as? NSVisualEffectView }
            .first { $0 !== canvas.toolbarView }
        XCTAssertEqual(actionBar?.isHidden, true)
    }

    func testAnnotationToolbarHasNoTrailingBlankStrip() throws {
        let overlay = try makeOverlay()

        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )
        let toolbar = canvas.toolbarView
        let stack = try XCTUnwrap(
            toolbar.subviews.compactMap { $0 as? NSStackView }.first
        )
        let lastButton = try XCTUnwrap(stack.arrangedSubviews.last)

        toolbar.layoutSubtreeIfNeeded()

        XCTAssertEqual(toolbar.frame.width, stack.fittingSize.width, accuracy: 0.5)
        let lastFrame = lastButton.convert(lastButton.bounds, to: toolbar)
        let trailingInset = toolbar.bounds.maxX - lastFrame.maxX
        XCTAssertGreaterThanOrEqual(trailingInset, 0, "最后一个按钮超出了工具条")
        XCTAssertLessThanOrEqual(trailingInset, 12, "工具条右侧留出了空白")
    }

    func testAnnotationToolbarMarksDefaultStyleAndFollowsChanges() throws {
        let overlay = try makeOverlay()

        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )
        let stack = try XCTUnwrap(
            canvas.toolbarView.subviews.compactMap { $0 as? NSStackView }.first
        )
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertGreaterThanOrEqual(buttons.count, 13)

        let tools = Array(buttons[0..<4])
        let colors = Array(buttons[4..<10])
        let widths = Array(buttons[10..<13])

        XCTAssertEqual(tools.map(\.state), [.on, .off, .off, .off])
        XCTAssertEqual(colors.map(\.state), [.on, .off, .off, .off, .off, .off])
        XCTAssertEqual(widths.map(\.state), [.off, .on, .off])

        tools[2].performClick(nil)
        XCTAssertEqual(overlay.session.annotation.tool, .pen)
        XCTAssertEqual(tools.map(\.state), [.off, .off, .on, .off])

        colors[2].performClick(nil)
        XCTAssertEqual(overlay.session.annotation.style.color, .green)
        XCTAssertEqual(colors.map(\.state), [.off, .off, .on, .off, .off, .off])

        widths[2].performClick(nil)
        XCTAssertEqual(overlay.session.annotation.style.lineWidth, 16)
        XCTAssertEqual(widths.map(\.state), [.off, .off, .on])
    }

    func testDrawingAndResizingARectangleUpdatesItsGeometry() throws {
        let overlay = try makeOverlay()
        let image = try XCTUnwrap(makeImage(width: 800, height: 600))
        overlay.session.setEditingImageForTesting(image)
        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let window = NSWindow(
            contentRect: overlay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay.view
        overlay.view.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )

        // Draw a rectangle from (200, 200) to (300, 300) in the view.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 300, y: 300), in: window))

        let drawn = try XCTUnwrap(lastRectangle(in: overlay.session))
        XCTAssertEqual(drawn, CGRect(x: 200, y: 200, width: 200, height: 200))

        // The new rectangle stays selected; its bottom-right handle resizes it.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 350, y: 350), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 350, y: 350), in: window))

        let resized = try XCTUnwrap(lastRectangle(in: overlay.session))
        XCTAssertEqual(resized, CGRect(x: 200, y: 100, width: 300, height: 300))
    }

    func testRectangleCanBeSelectedWhileAnotherToolIsActive() throws {
        let overlay = try makeOverlay()
        let image = try XCTUnwrap(makeImage(width: 800, height: 600))
        overlay.session.setEditingImageForTesting(image)
        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let window = NSWindow(
            contentRect: overlay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay.view
        overlay.view.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )

        // Draw a rectangle, then an arrow with the arrow tool.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 300, y: 300), in: window))

        overlay.session.setAnnotationTool(.arrow)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 350, y: 200), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 420, y: 250), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 420, y: 250), in: window))
        XCTAssertEqual(overlay.session.annotation.strokes.count, 2)

        // A click inside the rectangle selects it even though the arrow tool is active.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 250, y: 250), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 250, y: 250), in: window))

        // Its handle still resizes the rectangle and does not add an arrow.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 350, y: 350), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 350, y: 350), in: window))

        XCTAssertEqual(overlay.session.annotation.tool, .arrow)
        XCTAssertEqual(overlay.session.annotation.strokes.count, 2)
        guard case .rectangle(let rect, _) = overlay.session.annotation.strokes[0] else {
            return XCTFail("the first stroke should still be the rectangle")
        }
        XCTAssertEqual(rect, CGRect(x: 200, y: 100, width: 300, height: 300))
    }

    func testUndoRestoresTheRectangleSizeAfterResizing() throws {
        let overlay = try makeOverlay()
        let image = try XCTUnwrap(makeImage(width: 800, height: 600))
        overlay.session.setEditingImageForTesting(image)
        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let window = NSWindow(
            contentRect: overlay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay.view
        overlay.view.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 300, y: 300), in: window))
        let drawn = try XCTUnwrap(lastRectangle(in: overlay.session))

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 350, y: 350), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 350, y: 350), in: window))
        let resized = try XCTUnwrap(lastRectangle(in: overlay.session))
        XCTAssertNotEqual(resized, drawn)

        overlay.session.undoAnnotation()
        XCTAssertEqual(try XCTUnwrap(lastRectangle(in: overlay.session)), drawn)
        XCTAssertEqual(overlay.session.annotation.strokes.count, 1)

        overlay.session.undoAnnotation()
        XCTAssertTrue(overlay.session.annotation.strokes.isEmpty)
    }

    func testMovingSelectedRectangleUpdatesGeometryAndUndoRestoresIt() throws {
        let overlay = try makeOverlay()
        let image = try XCTUnwrap(makeImage(width: 800, height: 600))
        overlay.session.setEditingImageForTesting(image)
        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let window = NSWindow(
            contentRect: overlay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay.view
        overlay.view.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 300, y: 300), in: window))
        XCTAssertEqual(overlay.session.selectedAnnotation, 0)
        XCTAssertEqual(lastRectangle(in: overlay.session), CGRect(x: 200, y: 200, width: 200, height: 200))

        // The new stroke is selected; dragging its interior moves it.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 250, y: 250), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 280, y: 270), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 280, y: 270), in: window))
        XCTAssertEqual(lastRectangle(in: overlay.session), CGRect(x: 260, y: 160, width: 200, height: 200))

        overlay.session.undoAnnotation()
        XCTAssertEqual(lastRectangle(in: overlay.session), CGRect(x: 200, y: 200, width: 200, height: 200))
        XCTAssertEqual(overlay.session.selectedAnnotation, 0)
    }

    func testDeleteButtonRemovesSelectionAndUndoRestoresIt() throws {
        let overlay = try makeOverlay()
        let image = try XCTUnwrap(makeImage(width: 800, height: 600))
        overlay.session.setEditingImageForTesting(image)
        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let window = NSWindow(
            contentRect: overlay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay.view
        overlay.view.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 300, y: 300), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 300, y: 300), in: window))

        let stack = try XCTUnwrap(
            canvas.toolbarView.subviews.compactMap { $0 as? NSStackView }.first
        )
        let delete = try XCTUnwrap(
            stack.arrangedSubviews
                .compactMap { $0 as? NSButton }
                .first { $0.title == "删除" }
        )
        XCTAssertTrue(delete.isEnabled)
        delete.performClick(nil)

        XCTAssertTrue(overlay.session.annotation.strokes.isEmpty)
        XCTAssertNil(overlay.session.selectedAnnotation)
        XCTAssertFalse(delete.isEnabled)

        overlay.session.undoAnnotation()
        XCTAssertEqual(overlay.session.annotation.strokes.count, 1)
        XCTAssertEqual(overlay.session.selectedAnnotation, 0)
        XCTAssertTrue(delete.isEnabled)
    }

    func testMovingAnArrowSelectedWithAnotherTool() throws {
        let overlay = try makeOverlay()
        let image = try XCTUnwrap(makeImage(width: 800, height: 600))
        overlay.session.setEditingImageForTesting(image)
        overlay.session.setPhaseForTesting(.editing(overlay.selection))

        let window = NSWindow(
            contentRect: overlay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay.view
        overlay.view.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            overlay.view.subviews.compactMap { $0 as? AnnotationCanvasView }.first
        )

        overlay.session.setAnnotationTool(.arrow)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 350, y: 200), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 450, y: 250), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 450, y: 250), in: window))
        XCTAssertEqual(overlay.session.selectedAnnotation, 0)

        // Clear the selection with an empty click in the image.
        overlay.session.setAnnotationTool(.rectangle)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 350, y: 350), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 350, y: 350), in: window))
        XCTAssertNil(overlay.session.selectedAnnotation)

        // A click (not a drag) on the arrow selects it even with the rectangle tool.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 400, y: 225), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 400, y: 225), in: window))
        XCTAssertEqual(overlay.session.selectedAnnotation, 0)

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 400, y: 225), in: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 420, y: 235), in: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 420, y: 235), in: window))

        guard case .arrow(let start, let end, _) = overlay.session.annotation.strokes[0] else {
            return XCTFail("expected the arrow to stay first")
        }
        XCTAssertEqual(start, CGPoint(x: 540, y: 380))
        XCTAssertEqual(end, CGPoint(x: 740, y: 280))
    }

    private func selectionViewRect(_ selection: ScreenSelection, screen: NSScreen) -> CGRect {
        CGRect(
            x: selection.globalRect.minX - screen.frame.minX,
            y: selection.globalRect.minY - screen.frame.minY,
            width: selection.globalRect.width,
            height: selection.globalRect.height
        )
    }

    private func lastRectangle(in session: CaptureSession) -> CGRect? {
        guard let last = session.annotation.strokes.last,
              case .rectangle(let rect, _) = last else { return nil }
        return rect
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func makeOverlay() throws -> (
        session: CaptureSession,
        view: SelectionTrackingView,
        screen: NSScreen,
        selection: ScreenSelection
    ) {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Overlay layout needs a screen.")
        }
        let session = CaptureSession()
        let view = SelectionTrackingView(session: session, screen: screen)
        let selection = ScreenSelection(
            screenID: screen.displayID,
            screenFrame: screen.frame,
            scale: screen.backingScaleFactor,
            globalRect: CGRect(
                x: screen.frame.minX + 100,
                y: screen.frame.minY + 100,
                width: 400,
                height: 300
            )
        )
        return (session, view, screen, selection)
    }
}
