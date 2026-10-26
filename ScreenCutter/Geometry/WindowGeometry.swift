import CoreGraphics
import Foundation

nonisolated struct ListedWindow: Equatable, Sendable {
    var windowID: UInt32
    var appKitFrame: CGRect
    var title: String
}

nonisolated enum WindowGeometry {
    /// ScreenCaptureKit reports window frames in Quartz space: origin at the top left of the primary display.
    static func appKitFrame(fromQuartz frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// Global point in AppKit space (origin at the bottom left of the primary display).
    static func quartzPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func appKitPoint(fromQuartz point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Front-to-back. The returned frame is clipped to `screenFrame`, so a window cannot select across displays.
    static func hit(point: CGPoint, windows: [ListedWindow], screenFrame: CGRect) -> (window: ListedWindow, visibleFrame: CGRect)? {
        for window in windows {
            guard let visible = selectionFrame(for: window, on: screenFrame), visible.contains(point) else { continue }
            return (window, visible)
        }
        return nil
    }

    static func selectionFrame(for window: ListedWindow, on screenFrame: CGRect) -> CGRect? {
        let visible = window.appKitFrame.intersection(screenFrame)
        guard SelectionGeometry.isSubstantial(visible) else { return nil }
        return visible
    }
}
