import CoreGraphics
import Foundation

/// Selection math in two coordinate spaces.
/// Global rects use AppKit points with the origin at the bottom left.
/// Display-local rects use the top-left origin ScreenCaptureKit expects.
/// Pixel quantization lives in `DisplayMetrics` and `PixelRect`; this type covers
/// the point-space interactions that do not need the framebuffer size.
nonisolated enum SelectionGeometry {
    static let actionBarSize = CGSize(width: 360, height: 44)
    static let actionBarMargin: CGFloat = 8
    /// Release threshold for a drag, in points. Keeps a stray click from becoming
    /// a tiny selection.
    static let minimumSelection: CGFloat = 4
    /// Adjustable selections can go down to a single pixel.
    static let minimumSelectionPixels = 1

    static func displayLocalRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: selection.minX - screenFrame.minX,
            y: screenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    static func pixelSizeLabel(pixelRect: PixelRect) -> String {
        "\(pixelRect.width) × \(pixelRect.height)"
    }

    /// Places the bar just outside the selection, aligned to its trailing edge.
    /// `selection` is in top-left screen coordinates, matching the overlay view.
    static func actionBarFrame(
        selection: CGRect,
        screenSize: CGSize,
        barSize: CGSize,
        margin: CGFloat
    ) -> CGRect {
        var originX = selection.maxX - barSize.width
        var originY = selection.maxY + margin
        if originY + barSize.height > screenSize.height {
            originY = selection.minY - margin - barSize.height
        }
        if originX < 0 {
            originX = 0
        }
        if originX + barSize.width > screenSize.width {
            originX = max(0, screenSize.width - barSize.width)
        }
        if originY < 0 {
            originY = 0
        }
        if originY + barSize.height > screenSize.height {
            originY = max(0, screenSize.height - barSize.height)
        }
        return CGRect(x: originX, y: originY, width: barSize.width, height: barSize.height)
    }

    static func rect(from anchor: CGPoint, to current: CGPoint, constrainSquare: Bool) -> CGRect {
        var deltaX = current.x - anchor.x
        var deltaY = current.y - anchor.y
        if constrainSquare {
            let side = max(abs(deltaX), abs(deltaY))
            deltaX = deltaX < 0 ? -side : side
            deltaY = deltaY < 0 ? -side : side
        }
        return CGRect(
            x: min(anchor.x, anchor.x + deltaX),
            y: min(anchor.y, anchor.y + deltaY),
            width: abs(deltaX),
            height: abs(deltaY)
        )
    }

    static func clamped(_ rect: CGRect, to screen: CGRect) -> CGRect {
        let intersection = rect.intersection(screen)
        if intersection.isNull || intersection.isInfinite {
            return .zero
        }
        return intersection
    }

    static func isSubstantial(_ rect: CGRect, minimum: CGFloat = minimumSelection) -> Bool {
        rect.width >= minimum && rect.height >= minimum
    }

    static func isSubstantial(_ rect: PixelRect) -> Bool {
        rect.width >= minimumSelectionPixels && rect.height >= minimumSelectionPixels
    }

    /// Handles use the same coordinate space as `rect`. In AppKit global space, `maxY` is the visual top.
    static func hitHandle(point: CGPoint, in rect: CGRect, radius: CGFloat = 8) -> SelectionHandle? {
        let corners: [(SelectionHandle, CGPoint)] = [
            (.minXminY, CGPoint(x: rect.minX, y: rect.minY)),
            (.maxXminY, CGPoint(x: rect.maxX, y: rect.minY)),
            (.minXmaxY, CGPoint(x: rect.minX, y: rect.maxY)),
            (.maxXmaxY, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        if let hit = corners.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= radius }) {
            return hit.0
        }
        let expanded = rect.insetBy(dx: -radius, dy: -radius)
        guard expanded.contains(point) else { return nil }
        if abs(point.y - rect.maxY) <= radius { return .maxY }
        if abs(point.y - rect.minY) <= radius { return .minY }
        if abs(point.x - rect.maxX) <= radius { return .maxX }
        if abs(point.x - rect.minX) <= radius { return .minX }
        if rect.contains(point) { return .move }
        return nil
    }

    static func handleAnchors(in rect: CGRect) -> [(SelectionHandle, CGPoint)] {
        [
            (.minXminY, CGPoint(x: rect.minX, y: rect.minY)),
            (.maxXminY, CGPoint(x: rect.maxX, y: rect.minY)),
            (.minXmaxY, CGPoint(x: rect.minX, y: rect.maxY)),
            (.maxXmaxY, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.minX, CGPoint(x: rect.minX, y: rect.midY)),
            (.maxX, CGPoint(x: rect.maxX, y: rect.midY)),
            (.minY, CGPoint(x: rect.midX, y: rect.minY)),
            (.maxY, CGPoint(x: rect.midX, y: rect.maxY)),
        ]
    }

    static func resized(
        _ rect: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        minimum: CGFloat = minimumSelection
    ) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        switch handle {
        case .minX, .minXminY, .minXmaxY:
            minX = min(point.x, rect.maxX - minimum)
        case .maxX, .maxXminY, .maxXmaxY:
            maxX = max(point.x, rect.minX + minimum)
        case .move, .minY, .maxY:
            break
        }
        switch handle {
        case .minY, .minXminY, .maxXminY:
            minY = min(point.y, rect.maxY - minimum)
        case .maxY, .minXmaxY, .maxXmaxY:
            maxY = max(point.y, rect.minY + minimum)
        case .move, .minX, .maxX:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func moved(_ rect: CGRect, by delta: CGPoint, within screen: CGRect) -> CGRect {
        let maxOriginX = max(screen.minX, screen.maxX - rect.width)
        let maxOriginY = max(screen.minY, screen.maxY - rect.height)
        let x = min(max(rect.minX + delta.x, screen.minX), maxOriginX)
        let y = min(max(rect.minY + delta.y, screen.minY), maxOriginY)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    static func nudged(
        _ rect: CGRect,
        direction: NudgeDirection,
        step: CGFloat,
        within screen: CGRect
    ) -> CGRect {
        let delta: CGPoint
        switch direction {
        case .left:
            delta = CGPoint(x: -step, y: 0)
        case .right:
            delta = CGPoint(x: step, y: 0)
        case .up:
            delta = CGPoint(x: 0, y: step)
        case .down:
            delta = CGPoint(x: 0, y: -step)
        }
        return moved(rect, by: delta, within: screen)
    }

    /// Moves the two drag corners by the same amount and keeps the rectangle inside `screen`.
    static func movedSelection(
        anchor: CGPoint,
        current: CGPoint,
        by delta: CGPoint,
        within screen: CGRect
    ) -> (anchor: CGPoint, current: CGPoint) {
        let original = rect(from: anchor, to: current, constrainSquare: false)
        let shifted = moved(original, by: delta, within: screen)
        let applied = CGPoint(x: shifted.minX - original.minX, y: shifted.minY - original.minY)
        return (
            anchor: CGPoint(x: anchor.x + applied.x, y: anchor.y + applied.y),
            current: CGPoint(x: current.x + applied.x, y: current.y + applied.y)
        )
    }
}

nonisolated enum SelectionHandle: Equatable, Sendable {
    case move
    case minX
    case maxX
    case minY
    case maxY
    case minXminY
    case maxXminY
    case minXmaxY
    case maxXmaxY
}

nonisolated enum NudgeDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}
