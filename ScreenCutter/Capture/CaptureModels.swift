import CoreGraphics

struct ScreenSelection: Equatable {
    var metrics: DisplayMetrics
    var pixelRect: PixelRect

    init(metrics: DisplayMetrics, pixelRect: PixelRect) {
        self.metrics = metrics
        self.pixelRect = pixelRect.clampedEdges(in: metrics)
    }

    /// Compatibility initializer for call sites that still think in points. New
    /// production code should pass `DisplayMetrics` so the pixel size comes from
    /// the real display mode.
    init(screenID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat, globalRect: CGRect) {
        let safeScale = scale > 0 ? scale : 1
        let metrics = DisplayMetrics(
            screenID: screenID,
            pointFrame: screenFrame,
            pixelSize: CGSize(
                width: (screenFrame.width * safeScale).rounded(),
                height: (screenFrame.height * safeScale).rounded()
            )
        )
        self.init(metrics: metrics, pixelRect: metrics.pixelRect(for: globalRect))
    }

    var screenID: CGDirectDisplayID { metrics.screenID }
    var screenFrame: CGRect { metrics.pointFrame }
    var scale: CGFloat { metrics.scaleX }
    var globalRect: CGRect { metrics.globalRect(for: pixelRect) }
}

struct SelectionDrag: Equatable {
    var metrics: DisplayMetrics
    var anchor: CGPoint
    var current: CGPoint
    var constrainSquare: Bool

    init(metrics: DisplayMetrics, anchor: CGPoint, current: CGPoint, constrainSquare: Bool) {
        self.metrics = metrics
        self.anchor = anchor
        self.current = current
        self.constrainSquare = constrainSquare
    }

    init(
        screenID: CGDirectDisplayID,
        screenFrame: CGRect,
        scale: CGFloat,
        anchor: CGPoint,
        current: CGPoint,
        constrainSquare: Bool
    ) {
        let safeScale = scale > 0 ? scale : 1
        let metrics = DisplayMetrics(
            screenID: screenID,
            pointFrame: screenFrame,
            pixelSize: CGSize(
                width: (screenFrame.width * safeScale).rounded(),
                height: (screenFrame.height * safeScale).rounded()
            )
        )
        self.init(metrics: metrics, anchor: anchor, current: current, constrainSquare: constrainSquare)
    }

    var screenID: CGDirectDisplayID { metrics.screenID }
    var screenFrame: CGRect { metrics.pointFrame }
    var scale: CGFloat { metrics.scaleX }

    var pixelRect: PixelRect {
        let raw = SelectionGeometry.rect(from: anchor, to: current, constrainSquare: constrainSquare)
        return metrics.pixelRect(for: raw).clampedEdges(in: metrics)
    }

    var globalRect: CGRect { metrics.globalRect(for: pixelRect) }
}

struct WindowHover: Equatable {
    var metrics: DisplayMetrics
    var pixelRect: PixelRect
    var title: String

    init(metrics: DisplayMetrics, pixelRect: PixelRect, title: String) {
        self.metrics = metrics
        self.pixelRect = pixelRect.clampedEdges(in: metrics)
        self.title = title
    }

    init(screenID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat, globalRect: CGRect, title: String) {
        let safeScale = scale > 0 ? scale : 1
        let metrics = DisplayMetrics(
            screenID: screenID,
            pointFrame: screenFrame,
            pixelSize: CGSize(
                width: (screenFrame.width * safeScale).rounded(),
                height: (screenFrame.height * safeScale).rounded()
            )
        )
        self.init(metrics: metrics, pixelRect: metrics.pixelRect(for: globalRect), title: title)
    }

    var screenID: CGDirectDisplayID { metrics.screenID }
    var screenFrame: CGRect { metrics.pointFrame }
    var scale: CGFloat { metrics.scaleX }
    var globalRect: CGRect { metrics.globalRect(for: pixelRect) }
}

/// Which scrolling-capture flow the next action bar starts. `nil` is a normal
/// region capture.
enum ScrollIntent: Equatable {
    case automatic
    case manual
}

enum CapturePhase: Equatable {
    case idle
    case selecting(SelectionDrag?)
    case windowPicking(WindowHover?)
    case actionBar(ScreenSelection)
    case editing(ScreenSelection)
    case working(ScreenSelection)

    var isSelecting: Bool {
        if case .selecting = self { return true }
        return false
    }

    var isPickingWindow: Bool {
        if case .windowPicking = self { return true }
        return false
    }

    var showsActionBar: Bool {
        if case .actionBar = self { return true }
        return false
    }

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    /// True when both phases are the same step of the interaction, so only the
    /// geometry inside the payload differs. Drags republish this way once per
    /// frame; the overlay uses it to skip work that only a step change needs.
    func isSameInteraction(as other: CapturePhase) -> Bool {
        switch (self, other) {
        case (.selecting, .selecting), (.windowPicking, .windowPicking), (.actionBar, .actionBar):
            return true
        default:
            return false
        }
    }
}
