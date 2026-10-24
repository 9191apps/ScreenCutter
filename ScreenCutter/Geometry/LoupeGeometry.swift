import CoreGraphics

nonisolated enum LoupeGeometry {
    /// Maps a display-pixel focus into the snapshot's pixel space. Normally the
    /// two are equal; this keeps the loupe correct when ScreenCaptureKit returns a
    /// different-sized frame (scaled or rotated displays).
    static func sourceFocus(
        displayFocus: PixelPoint,
        sourceSize: CGSize,
        displayPixelSize: CGSize
    ) -> CGPoint {
        guard sourceSize.width > 0, sourceSize.height > 0,
              displayPixelSize.width > 0, displayPixelSize.height > 0 else {
            return CGPoint(x: displayFocus.x, y: displayFocus.y)
        }
        return CGPoint(
            x: CGFloat(displayFocus.x) * sourceSize.width / displayPixelSize.width,
            y: CGFloat(displayFocus.y) * sourceSize.height / displayPixelSize.height
        )
    }

    /// Positions the loupe next to the cursor, flipping to the other side when it
    /// would leave the screen. The returned frame is in the overlay's AppKit
    /// coordinates.
    static func frame(
        cursor: CGPoint,
        size: CGSize,
        bounds: CGRect,
        offset: CGFloat = 18,
        margin: CGFloat = 8
    ) -> CGRect {
        var originX = cursor.x + offset
        if originX + size.width > bounds.maxX - margin {
            originX = cursor.x - offset - size.width
        }
        originX = min(max(bounds.minX + margin, originX), max(bounds.minX + margin, bounds.maxX - size.width - margin))

        var originY = cursor.y - offset - size.height
        if originY < bounds.minY + margin {
            originY = cursor.y + offset
        }
        originY = min(max(bounds.minY + margin, originY), max(bounds.minY + margin, bounds.maxY - size.height - margin))

        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    /// Snaps a loupe frame's origin to the backing store. A loupe that follows the
    /// mouse at fractional points lands between device pixels, and the compositor
    /// resamples the 1px grid into a faint blur; rounding keeps it crisp.
    static func alignedToBackingStore(_ frame: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return frame }
        var aligned = frame
        aligned.origin.x = (frame.origin.x * scale).rounded() / scale
        aligned.origin.y = (frame.origin.y * scale).rounded() / scale
        return aligned
    }
}
