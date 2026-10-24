import CoreGraphics

struct ScreenSelection: Equatable {
    var screenID: CGDirectDisplayID
    var screenFrame: CGRect
    var scale: CGFloat
    var globalRect: CGRect
}

struct SelectionDrag: Equatable {
    var screenID: CGDirectDisplayID
    var screenFrame: CGRect
    var scale: CGFloat
    var anchor: CGPoint
    var current: CGPoint
    var constrainSquare: Bool

    var globalRect: CGRect {
        let raw = SelectionGeometry.rect(from: anchor, to: current, constrainSquare: constrainSquare)
        let clamped = SelectionGeometry.clamped(raw, to: screenFrame)
        return SelectionGeometry.pixelAligned(clamped, scale: scale)
    }
}

struct WindowHover: Equatable {
    var screenID: CGDirectDisplayID
    var screenFrame: CGRect
    var scale: CGFloat
    var globalRect: CGRect
    var title: String
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
}
