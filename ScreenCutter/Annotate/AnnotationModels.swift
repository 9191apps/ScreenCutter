import CoreGraphics
import CoreText
import Foundation

nonisolated enum AnnotationTool: String, CaseIterable, Equatable, Sendable {
    case rectangle
    case arrow
    case pen
    case text

    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .text: return "文字"
        }
    }
}

nonisolated enum AnnotationColor: String, CaseIterable, Equatable, Sendable {
    case red
    case yellow
    case green
    case blue
    case white
    case black

    var components: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .red: return (0.93, 0.18, 0.18)
        case .yellow: return (0.98, 0.78, 0.12)
        case .green: return (0.16, 0.72, 0.32)
        case .blue: return (0.16, 0.45, 0.95)
        case .white: return (1, 1, 1)
        case .black: return (0.08, 0.08, 0.08)
        }
    }
}

nonisolated struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor
    var lineWidth: CGFloat

    static let lineWidths: [CGFloat] = [4, 8, 16]

    var titleForWidth: String {
        switch lineWidth {
        case 4: return "细"
        case 16: return "粗"
        default: return "中"
        }
    }
}

nonisolated enum AnnotationStroke: Equatable, Sendable {
    case rectangle(CGRect, AnnotationStyle)
    case arrow(CGPoint, CGPoint, AnnotationStyle)
    case pen([CGPoint], AnnotationStyle)
    case text(String, CGPoint, AnnotationStyle)

    func translated(by delta: CGPoint) -> AnnotationStroke {
        switch self {
        case .rectangle(let rect, let style):
            return .rectangle(rect.offsetBy(dx: delta.x, dy: delta.y), style)
        case .arrow(let start, let end, let style):
            return .arrow(
                CGPoint(x: start.x + delta.x, y: start.y + delta.y),
                CGPoint(x: end.x + delta.x, y: end.y + delta.y),
                style
            )
        case .pen(let points, let style):
            return .pen(
                points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
                style
            )
        case .text(let string, let origin, let style):
            return .text(
                string,
                CGPoint(x: origin.x + delta.x, y: origin.y + delta.y),
                style
            )
        }
    }
}

nonisolated struct AnnotationDocument: Equatable, Sendable {
    var tool: AnnotationTool = .rectangle
    var style = AnnotationStyle(color: .red, lineWidth: 8)
    var strokes: [AnnotationStroke] = []
    var draft: AnnotationStroke?

    var renderedStrokes: [AnnotationStroke] {
        var all = strokes
        if let draft, Self.isVisible(draft) {
            all.append(draft)
        }
        return all
    }

    mutating func undo() {
        if draft != nil {
            draft = nil
            return
        }
        _ = strokes.popLast()
    }

    /// Index of the topmost rectangle containing `point`, in image coordinates.
    func rectangleIndex(at point: CGPoint) -> Int? {
        for index in strokes.indices.reversed() {
            guard case .rectangle(let rect, _) = strokes[index] else { continue }
            if rect.contains(point) {
                return index
            }
        }
        return nil
    }

    /// Index of the topmost annotation hit by `point`, in image coordinates.
    func hitTestIndex(at point: CGPoint, tolerance: CGFloat) -> Int? {
        for index in strokes.indices.reversed() {
            if AnnotationGeometry.contains(strokes[index], point: point, tolerance: tolerance) {
                return index
            }
        }
        return nil
    }

    /// Replaces the rectangle's geometry while keeping its style.
    mutating func updateRectangle(at index: Int, to rect: CGRect) {
        guard strokes.indices.contains(index),
              case .rectangle(_, let style) = strokes[index] else { return }
        strokes[index] = .rectangle(rect, style)
    }

    mutating func commitDraft() {
        guard let draft, Self.isVisible(draft) else {
            self.draft = nil
            return
        }
        strokes.append(draft)
        self.draft = nil
    }

    static func isVisible(_ stroke: AnnotationStroke) -> Bool {
        switch stroke {
        case .rectangle(let rect, _):
            return rect.width >= 2 && rect.height >= 2
        case .arrow(let start, let end, _):
            return hypot(end.x - start.x, end.y - start.y) >= 2
        case .pen(let points, _):
            return points.count >= 2
        case .text(let string, _, _):
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

nonisolated enum AnnotationGeometry {
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// `selectionLocal` uses the overlay's top-left origin. `viewPoint` uses AppKit's bottom-left origin.
    static func imagePoint(
        viewPoint: CGPoint,
        viewSize: CGSize,
        selectionLocal: CGRect,
        imageSize: CGSize
    ) -> CGPoint {
        guard selectionLocal.width > 0, selectionLocal.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let fromTop = CGPoint(x: viewPoint.x, y: viewSize.height - viewPoint.y)
        return CGPoint(
            x: (fromTop.x - selectionLocal.minX) / selectionLocal.width * imageSize.width,
            y: (fromTop.y - selectionLocal.minY) / selectionLocal.height * imageSize.height
        )
    }

    /// Maps an image-coordinate rect (top-left origin) into the canvas view.
    static func viewRect(imageRect: CGRect, imageFrame: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              imageFrame.width > 0, imageFrame.height > 0 else { return .zero }
        let scaleX = imageFrame.width / imageSize.width
        let scaleY = imageFrame.height / imageSize.height
        return CGRect(
            x: imageFrame.minX + imageRect.minX * scaleX,
            y: imageFrame.maxY - imageRect.maxY * scaleY,
            width: imageRect.width * scaleX,
            height: imageRect.height * scaleY
        )
    }

    /// Inverse of `viewRect(imageRect:imageFrame:imageSize:)`.
    static func imageRect(viewRect: CGRect, imageFrame: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              imageFrame.width > 0, imageFrame.height > 0 else { return .zero }
        let scaleX = imageSize.width / imageFrame.width
        let scaleY = imageSize.height / imageFrame.height
        return CGRect(
            x: (viewRect.minX - imageFrame.minX) * scaleX,
            y: (imageFrame.maxY - viewRect.maxY) * scaleY,
            width: viewRect.width * scaleX,
            height: viewRect.height * scaleY
        )
    }

    // MARK: - Text metrics and annotation bounds

    static func textFontSize(for style: AnnotationStyle) -> CGFloat {
        max(18, style.lineWidth * 4)
    }

    static func textFont(for style: AnnotationStyle) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, textFontSize(for: style), nil)
    }

    /// Visible text bounds in image coordinates. Mirrors what `AnnotationRenderer` draws.
    static func textBounds(for string: String, origin: CGPoint, style: AnnotationStyle) -> CGRect {
        let attributes: [CFString: Any] = [kCTFontAttributeName: textFont(for: style)]
        guard let attributed = CFAttributedStringCreate(
            nil,
            string as CFString,
            attributes as CFDictionary
        ) else { return .zero }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGRect(
            x: origin.x + bounds.minX,
            y: origin.y + textFontSize(for: style) - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }

    /// Bounds used for selection boxes and for keeping a moved annotation on screen.
    static func contentBounds(of stroke: AnnotationStroke) -> CGRect {
        switch stroke {
        case .rectangle(let rect, let style):
            let pad = max(style.lineWidth / 2, 1)
            return rect.insetBy(dx: -pad, dy: -pad)
        case .arrow(let start, let end, let style):
            let pad = max(style.lineWidth * 1.8, 8)
            return CGRect(
                x: min(start.x, end.x) - pad,
                y: min(start.y, end.y) - pad,
                width: abs(end.x - start.x) + pad * 2,
                height: abs(end.y - start.y) + pad * 2
            )
        case .pen(let points, let style):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            let pad = max(style.lineWidth / 2, 1)
            return CGRect(
                x: minX - pad,
                y: minY - pad,
                width: maxX - minX + pad * 2,
                height: maxY - minY + pad * 2
            )
        case .text(let string, let origin, let style):
            let bounds = textBounds(for: string, origin: origin, style: style)
            guard bounds.width > 0, bounds.height > 0 else { return .zero }
            let pad = max(style.lineWidth / 4, 2)
            return bounds.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Hit testing in image coordinates. `tolerance` is in image pixels.
    static func contains(_ stroke: AnnotationStroke, point: CGPoint, tolerance: CGFloat) -> Bool {
        switch stroke {
        case .rectangle(let rect, _):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .arrow(let start, let end, let style):
            let slack = style.lineWidth / 2 + tolerance
            return distanceToSegment(point, start, end) <= slack
        case .pen(let points, let style):
            guard let first = points.first else { return false }
            let slack = style.lineWidth / 2 + tolerance
            if points.count == 1 {
                return hypot(first.x - point.x, first.y - point.y) <= slack
            }
            for index in 1..<points.count {
                if distanceToSegment(point, points[index - 1], points[index]) <= slack {
                    return true
                }
            }
            return false
        case .text(let string, let origin, let style):
            let bounds = textBounds(for: string, origin: origin, style: style)
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// Clamps a translation so the annotation's bounds stay inside `bounds`.
    static func clampedTranslation(
        of stroke: AnnotationStroke,
        by delta: CGPoint,
        within bounds: CGRect
    ) -> CGPoint {
        let content = contentBounds(of: stroke)
        guard content.width > 0, content.height > 0 else { return .zero }
        let minX = bounds.minX - content.minX
        let maxX = bounds.maxX - content.maxX
        let minY = bounds.minY - content.minY
        let maxY = bounds.maxY - content.maxY
        let x = minX <= maxX ? min(max(delta.x, minX), maxX) : 0
        let y = minY <= maxY ? min(max(delta.y, minY), maxY) : 0
        return CGPoint(x: x, y: y)
    }

    static func distanceToSegment(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projected = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - projected.x, point.y - projected.y)
    }
}
