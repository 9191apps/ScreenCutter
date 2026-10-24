import CoreGraphics
import CoreText
import Foundation

nonisolated enum AnnotationRenderer {
    static func composite(base: CGImage, document: AnnotationDocument) -> CGImage? {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: bounds)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in document.renderedStrokes {
            draw(stroke, in: context, height: CGFloat(height))
        }
        return context.makeImage()
    }

    private static func draw(_ stroke: AnnotationStroke, in context: CGContext, height: CGFloat) {
        switch stroke {
        case .rectangle(let rect, let style):
            context.setStrokeColor(color(style.color))
            context.setLineWidth(style.lineWidth)
            let flipped = CGRect(
                x: rect.minX,
                y: height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            context.stroke(flipped)
        case .arrow(let start, let end, let style):
            let from = cg(start, height: height)
            let to = cg(end, height: height)
            context.setStrokeColor(color(style.color))
            context.setFillColor(color(style.color))
            context.setLineWidth(style.lineWidth)

            let angle = atan2(to.y - from.y, to.x - from.x)
            let distance = hypot(to.x - from.x, to.y - from.y)
            let length = min(
                max(18, style.lineWidth * 4.5),
                max(distance * 0.65, 8)
            )
            let halfWidth = min(max(7, style.lineWidth * 1.6), length * 0.75)
            let base = CGPoint(
                x: to.x - cos(angle) * length,
                y: to.y - sin(angle) * length
            )
            let normal = CGPoint(x: -sin(angle), y: cos(angle))

            // Stop the shaft at the head's base: a round line cap drawn all the
            // way to the tip would round off the point.
            context.beginPath()
            context.move(to: from)
            context.addLine(to: base)
            context.strokePath()

            context.beginPath()
            context.move(to: to)
            context.addLine(to: CGPoint(
                x: base.x + normal.x * halfWidth,
                y: base.y + normal.y * halfWidth
            ))
            context.addLine(to: CGPoint(
                x: base.x - normal.x * halfWidth,
                y: base.y - normal.y * halfWidth
            ))
            context.closePath()
            context.fillPath()
        case .pen(let points, let style):
            guard let first = points.first else { return }
            context.setStrokeColor(color(style.color))
            context.setLineWidth(style.lineWidth)
            context.beginPath()
            context.move(to: cg(first, height: height))
            for point in points.dropFirst() {
                context.addLine(to: cg(point, height: height))
            }
            context.strokePath()
        case .text(let string, let origin, let style):
            let fontSize = AnnotationGeometry.textFontSize(for: style)
            let font = AnnotationGeometry.textFont(for: style)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color(style.color),
            ]
            let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
            let line = CTLineCreateWithAttributedString(attributed!)
            let flipped = cg(origin, height: height)
            context.textPosition = CGPoint(x: flipped.x, y: flipped.y - fontSize)
            CTLineDraw(line, context)
        }
    }

    private static func cg(_ point: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    private static func color(_ annotation: AnnotationColor) -> CGColor {
        let components = annotation.components
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [components.0, components.1, components.2, 1]
        )!
    }
}
