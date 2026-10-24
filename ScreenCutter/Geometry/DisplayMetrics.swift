import CoreGraphics
import Foundation

/// The conversion between a screen's AppKit point space and its native pixel space.
///
/// `pointFrame` uses AppKit global coordinates with the origin at the bottom left.
/// `pixelSize` is the current display mode's framebuffer size. Keeping both in one
/// value means the selection preview, the size label, and the crop all quantize
/// against the same numbers.
nonisolated struct DisplayMetrics: Equatable, Sendable {
    var screenID: CGDirectDisplayID
    var pointFrame: CGRect
    var pixelSize: CGSize

    init(screenID: CGDirectDisplayID, pointFrame: CGRect, pixelSize: CGSize) {
        self.screenID = screenID
        self.pointFrame = pointFrame
        self.pixelSize = pixelSize
    }

    var scaleX: CGFloat {
        guard pointFrame.width > 0, pixelSize.width > 0 else { return 1 }
        return pixelSize.width / pointFrame.width
    }

    var scaleY: CGFloat {
        guard pointFrame.height > 0, pixelSize.height > 0 else { return 1 }
        return pixelSize.height / pointFrame.height
    }

    var pixelWidth: Int {
        max(1, Int(pixelSize.width.rounded()))
    }

    var pixelHeight: Int {
        max(1, Int(pixelSize.height.rounded()))
    }

    /// Converts a global point rect into an integer display-local pixel rect.
    /// The result is not clipped; callers decide whether to clamp.
    func pixelRect(for globalRect: CGRect) -> PixelRect {
        guard !globalRect.isNull, !globalRect.isInfinite else { return .zero }
        let left = (globalRect.minX - pointFrame.minX) * scaleX
        let right = (globalRect.maxX - pointFrame.minX) * scaleX
        let top = (pointFrame.maxY - globalRect.maxY) * scaleY
        let bottom = (pointFrame.maxY - globalRect.minY) * scaleY
        let x0 = Int(left.rounded())
        let x1 = Int(right.rounded())
        let y0 = Int(top.rounded())
        let y1 = Int(bottom.rounded())
        return PixelRect(
            x: min(x0, x1),
            y: min(y0, y1),
            width: abs(x1 - x0),
            height: abs(y1 - y0)
        )
    }

    /// Converts an integer display-local pixel rect back into AppKit global points.
    func globalRect(for pixelRect: PixelRect) -> CGRect {
        CGRect(
            x: pointFrame.minX + CGFloat(pixelRect.x) / scaleX,
            y: pointFrame.maxY - CGFloat(pixelRect.y + pixelRect.height) / scaleY,
            width: CGFloat(pixelRect.width) / scaleX,
            height: CGFloat(pixelRect.height) / scaleY
        )
    }

    /// The pixel that contains a global point. `rounded` chooses the nearest pixel
    /// boundary, which is what drag handles want; the default floors, which is what
    /// the magnifier wants.
    func pixelPoint(for globalPoint: CGPoint, rounded: Bool = false) -> PixelPoint {
        let x = (globalPoint.x - pointFrame.minX) * scaleX
        let y = (pointFrame.maxY - globalPoint.y) * scaleY
        let roundedX = rounded ? x.rounded() : x.rounded(.down)
        let roundedY = rounded ? y.rounded() : y.rounded(.down)
        return PixelPoint(x: Int(roundedX), y: Int(roundedY))
    }

    /// The global point at the top-left corner of a pixel.
    func globalPoint(for pixelPoint: PixelPoint) -> CGPoint {
        CGPoint(
            x: pointFrame.minX + CGFloat(pixelPoint.x) / scaleX,
            y: pointFrame.maxY - CGFloat(pixelPoint.y) / scaleY
        )
    }
}

nonisolated struct PixelPoint: Equatable, Sendable {
    var x: Int
    var y: Int

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// An integer rectangle in display-local pixels with a top-left origin. This is the
/// unit ScreenCaptureKit crops in and the unit the precision fields edit.
nonisolated struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    var minX: Int { x }
    var minY: Int { y }
    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var midX: Int { x + width / 2 }
    var midY: Int { y + height / 2 }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Clips the edges to the display. A drag can produce a zero-size rect; this
    /// keeps that state instead of forcing one pixel.
    func clampedEdges(in metrics: DisplayMetrics) -> PixelRect {
        let left = min(max(0, minX), metrics.pixelWidth)
        let right = min(max(0, maxX), metrics.pixelWidth)
        let top = min(max(0, minY), metrics.pixelHeight)
        let bottom = min(max(0, maxY), metrics.pixelHeight)
        return PixelRect(
            x: left,
            y: top,
            width: max(0, right - left),
            height: max(0, bottom - top)
        )
    }

    /// Clamps a rect that must stay selectable: at least one pixel on each side and
    /// never outside the display. Used by the action bar, keyboard, and fields.
    func clampedForSelection(in metrics: DisplayMetrics) -> PixelRect {
        let clampedWidth = min(max(1, width), metrics.pixelWidth)
        let clampedHeight = min(max(1, height), metrics.pixelHeight)
        let clampedX = min(max(0, x), max(0, metrics.pixelWidth - clampedWidth))
        let clampedY = min(max(0, y), max(0, metrics.pixelHeight - clampedHeight))
        return PixelRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    func clamped(toWidth width: Int, height: Int) -> PixelRect {
        let left = min(max(0, minX), max(0, width))
        let right = min(max(0, maxX), max(0, width))
        let top = min(max(0, minY), max(0, height))
        let bottom = min(max(0, maxY), max(0, height))
        return PixelRect(
            x: left,
            y: top,
            width: max(0, right - left),
            height: max(0, bottom - top)
        )
    }

    /// Rescales between a metrics pixel size and an actual capture size. SCK
    /// normally returns exactly `metrics.pixelSize`; this is the mismatch fallback.
    func scaled(from source: CGSize, to target: CGSize) -> PixelRect {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return self
        }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        let left = (CGFloat(x) * scaleX).rounded()
        let right = (CGFloat(maxX) * scaleX).rounded()
        let top = (CGFloat(y) * scaleY).rounded()
        let bottom = (CGFloat(maxY) * scaleY).rounded()
        return PixelRect(
            x: Int(left),
            y: Int(top),
            width: max(0, Int(right - left)),
            height: max(0, Int(bottom - top))
        )
    }
}

/// Pixel-space selection edits. AppKit handle names still use `minY` as the visual
/// bottom and `maxY` as the visual top; this type maps them to the top-left pixel
/// coordinates used by `PixelRect`.
nonisolated enum PixelSelectionGeometry {
    static func rect(from anchor: PixelPoint, to current: PixelPoint) -> PixelRect {
        PixelRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    static func moved(_ rect: PixelRect, by delta: PixelPoint, in metrics: DisplayMetrics) -> PixelRect {
        let maxOriginX = max(0, metrics.pixelWidth - rect.width)
        let maxOriginY = max(0, metrics.pixelHeight - rect.height)
        return PixelRect(
            x: min(max(0, rect.x + delta.x), maxOriginX),
            y: min(max(0, rect.y + delta.y), maxOriginY),
            width: rect.width,
            height: rect.height
        )
    }

    static func nudged(
        _ rect: PixelRect,
        direction: NudgeDirection,
        step: Int,
        in metrics: DisplayMetrics
    ) -> PixelRect {
        let delta: PixelPoint
        switch direction {
        case .left:
            delta = PixelPoint(x: -step, y: 0)
        case .right:
            delta = PixelPoint(x: step, y: 0)
        case .up:
            delta = PixelPoint(x: 0, y: -step)
        case .down:
            delta = PixelPoint(x: 0, y: step)
        }
        return moved(rect, by: delta, in: metrics)
    }

    static func resized(
        _ rect: PixelRect,
        handle: SelectionHandle,
        to point: PixelPoint,
        minimum: Int = 1,
        in metrics: DisplayMetrics
    ) -> PixelRect {
        let minSize = max(1, minimum)
        var minX = rect.x
        var minY = rect.y
        var maxX = rect.maxX
        var maxY = rect.maxY

        switch handle {
        case .minX, .minXminY, .minXmaxY:
            minX = min(max(0, point.x), maxX - minSize)
        case .maxX, .maxXminY, .maxXmaxY:
            maxX = min(metrics.pixelWidth, max(minX + minSize, point.x))
        case .move, .minY, .maxY:
            break
        }

        switch handle {
        case .minY, .minXminY, .maxXminY:
            // AppKit bottom edge: the bottom of the pixel rect.
            maxY = min(metrics.pixelHeight, max(minY + minSize, point.y))
        case .maxY, .minXmaxY, .maxXmaxY:
            // AppKit top edge: the top of the pixel rect.
            minY = max(0, min(maxY - minSize, point.y))
        case .move, .minX, .maxX:
            break
        }

        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Option-arrow edits one edge: right/left change the trailing edge, up/down
    /// change the top edge. The opposite edges stay put.
    static func adjustedTrailingEdge(
        _ rect: PixelRect,
        direction: NudgeDirection,
        step: Int,
        in metrics: DisplayMetrics
    ) -> PixelRect {
        let delta = max(1, step)
        var next = rect
        switch direction {
        case .right:
            next.width = min(metrics.pixelWidth - rect.x, rect.width + delta)
        case .left:
            next.width = max(1, rect.width - delta)
        case .up:
            let newY = max(0, rect.y - delta)
            next.y = newY
            next.height = rect.height + (rect.y - newY)
        case .down:
            let removed = min(delta, rect.height - 1)
            next.y = rect.y + removed
            next.height = rect.height - removed
        }
        return next.clampedForSelection(in: metrics)
    }

    static func movesX(_ handle: SelectionHandle) -> Bool {
        switch handle {
        case .minX, .maxX, .minXminY, .maxXminY, .minXmaxY, .maxXmaxY:
            return true
        case .move, .minY, .maxY:
            return false
        }
    }

    static func movesY(_ handle: SelectionHandle) -> Bool {
        switch handle {
        case .minY, .maxY, .minXminY, .maxXminY, .minXmaxY, .maxXmaxY:
            return true
        case .move, .minX, .maxX:
            return false
        }
    }
}

/// Validation for the four precision fields. Keeping it out of the view makes the
/// clamping rules testable.
nonisolated enum PrecisionInput {
    static func rect(x: Int, y: Int, width: Int, height: Int, in metrics: DisplayMetrics) -> PixelRect {
        PixelRect(x: x, y: y, width: width, height: height).clampedForSelection(in: metrics)
    }
}
