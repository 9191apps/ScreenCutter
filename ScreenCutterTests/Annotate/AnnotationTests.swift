import CoreGraphics
import XCTest
@testable import ScreenCutter

final class AnnotationTests: XCTestCase {
    func testImagePointMapsTheSelectionTopLeftToTheImageOrigin() {
        let point = AnnotationGeometry.imagePoint(
            viewPoint: CGPoint(x: 100, y: 750),
            viewSize: CGSize(width: 1000, height: 800),
            selectionLocal: CGRect(x: 100, y: 50, width: 200, height: 100),
            imageSize: CGSize(width: 400, height: 200)
        )
        XCTAssertEqual(point, CGPoint(x: 0, y: 0))
    }

    func testUndoRemovesTheLastStrokeAndADraftFirst() {
        var document = AnnotationDocument()
        document.strokes = [
            .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), document.style),
        ]
        document.draft = .arrow(.zero, CGPoint(x: 20, y: 0), document.style)
        document.undo()
        XCTAssertNil(document.draft)
        XCTAssertEqual(document.strokes.count, 1)
        document.undo()
        XCTAssertTrue(document.strokes.isEmpty)
    }

    func testHitTestRecognizesEveryAnnotationType() {
        var document = AnnotationDocument()
        let style = AnnotationStyle(color: .red, lineWidth: 8)
        document.strokes = [
            .rectangle(CGRect(x: 10, y: 10, width: 60, height: 40), style),
            .arrow(CGPoint(x: 120, y: 20), CGPoint(x: 220, y: 20), style),
            .pen([CGPoint(x: 260, y: 10), CGPoint(x: 280, y: 40), CGPoint(x: 300, y: 10)], style),
            .text("Hi", CGPoint(x: 340, y: 10), style),
        ]

        XCTAssertEqual(document.hitTestIndex(at: CGPoint(x: 30, y: 30), tolerance: 4), 0)
        XCTAssertEqual(document.hitTestIndex(at: CGPoint(x: 170, y: 24), tolerance: 4), 1)
        XCTAssertEqual(document.hitTestIndex(at: CGPoint(x: 280, y: 40), tolerance: 4), 2)
        let bounds = AnnotationGeometry.textBounds(for: "Hi", origin: CGPoint(x: 340, y: 10), style: style)
        XCTAssertEqual(document.hitTestIndex(at: CGPoint(x: bounds.midX, y: bounds.midY), tolerance: 4), 3)
        XCTAssertNil(document.hitTestIndex(at: CGPoint(x: 400, y: 200), tolerance: 4))
    }

    func testHitTestPrefersTheTopmostStroke() {
        var document = AnnotationDocument()
        let style = AnnotationStyle(color: .red, lineWidth: 8)
        document.strokes = [
            .rectangle(CGRect(x: 100, y: 100, width: 100, height: 100), style),
            .pen([CGPoint(x: 120, y: 150), CGPoint(x: 180, y: 150)], style),
        ]
        XCTAssertEqual(document.hitTestIndex(at: CGPoint(x: 150, y: 150), tolerance: 2), 1)
    }

    func testTextBoundsSitBelowTheClick() {
        let style = AnnotationStyle(color: .red, lineWidth: 8)
        let origin = CGPoint(x: 100, y: 100)
        let bounds = AnnotationGeometry.textBounds(
            for: "测试",
            origin: origin,
            style: style
        )
        let fontSize = AnnotationGeometry.textFontSize(for: style)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        XCTAssertGreaterThan(bounds.midY, origin.y)
        XCTAssertLessThan(bounds.midY, origin.y + fontSize * 2)
    }

    func testTranslateMovesEveryStrokeTypeAndKeepsItsStyle() {
        let style = AnnotationStyle(color: .blue, lineWidth: 16)
        let delta = CGPoint(x: 5, y: -3)

        XCTAssertEqual(
            AnnotationStroke.rectangle(CGRect(x: 10, y: 20, width: 30, height: 40), style)
                .translated(by: delta),
            .rectangle(CGRect(x: 15, y: 17, width: 30, height: 40), style)
        )
        XCTAssertEqual(
            AnnotationStroke.arrow(CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4), style)
                .translated(by: delta),
            .arrow(CGPoint(x: 6, y: -1), CGPoint(x: 8, y: 1), style)
        )
        XCTAssertEqual(
            AnnotationStroke.pen([CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], style)
                .translated(by: delta),
            .pen([CGPoint(x: 6, y: -1), CGPoint(x: 8, y: 1)], style)
        )
        XCTAssertEqual(
            AnnotationStroke.text("Hi", CGPoint(x: 1, y: 2), style)
                .translated(by: delta),
            .text("Hi", CGPoint(x: 6, y: -1), style)
        )
    }

    func testClampedTranslationKeepsAnAnnotationInsideTheImage() {
        let style = AnnotationStyle(color: .red, lineWidth: 8)
        let stroke = AnnotationStroke.rectangle(
            CGRect(x: 10, y: 10, width: 40, height: 30),
            style
        )
        let image = CGRect(x: 0, y: 0, width: 200, height: 100)

        XCTAssertEqual(
            AnnotationGeometry.clampedTranslation(
                of: stroke,
                by: CGPoint(x: -100, y: -100),
                within: image
            ),
            CGPoint(x: -6, y: -6)
        )
        XCTAssertEqual(
            AnnotationGeometry.clampedTranslation(
                of: stroke,
                by: CGPoint(x: 1000, y: 1000),
                within: image
            ),
            CGPoint(x: 146, y: 56)
        )
    }

    func testRectangleSelectionFindsTheTopmostRectangle() {
        var document = AnnotationDocument()
        document.strokes = [
            .rectangle(CGRect(x: 10, y: 10, width: 100, height: 100), document.style),
            .rectangle(CGRect(x: 40, y: 40, width: 100, height: 100), document.style),
            .pen([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], document.style),
        ]
        XCTAssertEqual(document.rectangleIndex(at: CGPoint(x: 50, y: 50)), 1)
        XCTAssertEqual(document.rectangleIndex(at: CGPoint(x: 20, y: 20)), 0)
        XCTAssertNil(document.rectangleIndex(at: CGPoint(x: 300, y: 300)))
    }

    func testUpdateRectangleKeepsItsStyleAndIgnoresOtherStrokes() {
        var document = AnnotationDocument()
        let style = AnnotationStyle(color: .green, lineWidth: 16)
        document.strokes = [
            .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30), style),
            .pen([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], document.style),
        ]

        document.updateRectangle(at: 0, to: CGRect(x: 20, y: 30, width: 80, height: 60))
        guard case .rectangle(let rect, let updatedStyle) = document.strokes[0] else {
            XCTFail("expected a rectangle")
            return
        }
        XCTAssertEqual(rect, CGRect(x: 20, y: 30, width: 80, height: 60))
        XCTAssertEqual(updatedStyle, style)

        let pen = document.strokes[1]
        document.updateRectangle(at: 1, to: .zero)
        XCTAssertEqual(document.strokes[1], pen)
        document.updateRectangle(at: 9, to: .zero)
        XCTAssertEqual(document.strokes.count, 2)
    }

    func testViewRectRoundTripsToTheImageRect() {
        let imageFrame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let imageSize = CGSize(width: 800, height: 600)
        let imageRect = CGRect(x: 40, y: 60, width: 120, height: 90)

        let viewRect = AnnotationGeometry.viewRect(
            imageRect: imageRect,
            imageFrame: imageFrame,
            imageSize: imageSize
        )
        XCTAssertEqual(viewRect, CGRect(x: 120, y: 425, width: 60, height: 45))
        XCTAssertEqual(
            AnnotationGeometry.imageRect(
                viewRect: viewRect,
                imageFrame: imageFrame,
                imageSize: imageSize
            ),
            imageRect
        )
    }

    func testArrowTipIsSharpAndTheShaftStopsAtTheHead() throws {
        let base = try XCTUnwrap(solidImage(width: 120, height: 80, red: 1, green: 1, blue: 1))
        var document = AnnotationDocument()
        document.strokes = [
            .arrow(
                CGPoint(x: 20, y: 40),
                CGPoint(x: 80, y: 40),
                AnnotationStyle(color: .red, lineWidth: 8)
            ),
        ]
        let image = try XCTUnwrap(AnnotationRenderer.composite(base: base, document: document))

        // The filled head is present right behind the tip.
        let nearTip = try XCTUnwrap(pixel(image, x: 76, y: 40))
        XCTAssertGreaterThan(nearTip.0, 180)
        XCTAssertLessThan(nearTip.1, 100)

        // A round line cap at the tip used to poke past the point.
        let pastTip = try XCTUnwrap(pixel(image, x: 82, y: 40))
        XCTAssertGreaterThan(pastTip.0, 200)
        XCTAssertGreaterThan(pastTip.1, 200)
        XCTAssertGreaterThan(pastTip.2, 200)
    }

    func testRectangleStrokePaintsTheEdge() throws {
        let base = try XCTUnwrap(solidImage(width: 80, height: 80, red: 1, green: 1, blue: 1))
        var document = AnnotationDocument()
        document.strokes = [
            .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30), AnnotationStyle(color: .red, lineWidth: 8)),
        ]
        let image = try XCTUnwrap(AnnotationRenderer.composite(base: base, document: document))
        let edge = try XCTUnwrap(pixel(image, x: 30, y: 10))
        XCTAssertGreaterThan(edge.0, 180)
        XCTAssertLessThan(edge.1, 80)
        let inside = try XCTUnwrap(pixel(image, x: 30, y: 25))
        XCTAssertGreaterThan(inside.0, 200)
        XCTAssertGreaterThan(inside.1, 200)
        XCTAssertGreaterThan(inside.2, 200)
    }

    private func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(x),
                y: -CGFloat(image.height - 1 - y),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
