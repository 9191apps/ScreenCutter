import CoreGraphics
import Foundation

nonisolated struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int
}

/// Selection math in two coordinate spaces.
/// Global rects use AppKit points with the origin at the bottom left.
/// Display-local rects use the top-left origin ScreenCaptureKit expects.
nonisolated enum SelectionGeometry {
    static let actionBarSize = CGSize(width: 248, height: 44)
    static let actionBarMargin: CGFloat = 8
    static let minimumSelection: CGFloat = 4

    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0, !rect.isNull, !rect.isInfinite else { return rect }
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    static func displayLocalRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: selection.minX - screenFrame.minX,
            y: screenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    static func outputPixelSize(of rect: CGRect, scale: CGFloat) -> PixelSize {
        let safeScale = scale > 0 ? scale : 1
        return PixelSize(
            width: Int((rect.width * safeScale).rounded()),
            height: Int((rect.height * safeScale).rounded())
        )
    }

    static func pixelSizeLabel(globalRect: CGRect, scale: CGFloat) -> String {
        let pixels = outputPixelSize(of: globalRect, scale: scale)
        return "\(pixels.width) × \(pixels.height)"
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
}
