import AppKit

/// The cursor shape an interaction should show. Keeping this as a value type
/// lets the phase-to-cursor decision be tested without moving the real cursor.
enum CursorIntent: Equatable {
    case arrow
    case crosshair
    case pointingHand
    case openHand
    case closedHand
    case iBeam
    case resize(SelectionHandle)
}

@MainActor
extension CursorIntent {
    var cursor: NSCursor {
        switch self {
        case .arrow:
            return .arrow
        case .crosshair:
            return .crosshair
        case .pointingHand:
            return .pointingHand
        case .openHand:
            return .openHand
        case .closedHand:
            return .closedHand
        case .iBeam:
            return .iBeam
        case .resize(let handle):
            return SelectionResizeCursor.cursor(for: handle)
        }
    }
}

/// macOS 15 added frame-resize cursors with proper diagonal arrows. macOS 14
/// only has horizontal and vertical built-ins, so make matching diagonal
/// cursors from SF Symbols for the four corners.
@MainActor
private enum SelectionResizeCursor {
    static func cursor(for handle: SelectionHandle) -> NSCursor {
        guard handle != .move else { return .openHand }
        if #available(macOS 15.0, *) {
            return .frameResize(position: framePosition(for: handle), directions: .all)
        }
        switch handle {
        case .move:
            return .openHand
        case .minX, .maxX:
            return .resizeLeftRight
        case .minY, .maxY:
            return .resizeUpDown
        case .minXminY, .maxXmaxY:
            return DiagonalCursor.upRightDownLeft
        case .minXmaxY, .maxXminY:
            return DiagonalCursor.upLeftDownRight
        }
    }

    @available(macOS 15.0, *)
    private static func framePosition(for handle: SelectionHandle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .move:
            return .top
        case .minX:
            return .left
        case .maxX:
            return .right
        case .minY:
            return .bottom
        case .maxY:
            return .top
        case .minXminY:
            return .bottomLeft
        case .maxXminY:
            return .bottomRight
        case .minXmaxY:
            return .topLeft
        case .maxXmaxY:
            return .topRight
        }
    }
}

/// Fallback diagonal cursors for macOS 14. They mirror the black-on-white
/// system cursor style and use the center as the hot spot.
@MainActor
private enum DiagonalCursor {
    static let upLeftDownRight = make("arrow.up.left.and.arrow.down.right")
    static let upRightDownLeft = make("arrow.up.right.and.arrow.down.left")

    private static func make(_ symbolName: String) -> NSCursor {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return .crosshair
        }
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolRect = rect.insetBy(dx: 2, dy: 2)
            if let white = symbol.withSymbolConfiguration(configuration(color: .white)) {
                let offsets: [CGFloat] = [-1, 0, 1]
                for dx in offsets {
                    for dy in offsets where dx != 0 || dy != 0 {
                        white.draw(
                            in: symbolRect.offsetBy(dx: dx, dy: dy),
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1
                        )
                    }
                }
            }
            symbol.withSymbolConfiguration(configuration(color: .black))?
                .draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: size.width / 2, y: size.height / 2)
        )
    }

    private static func configuration(color: NSColor) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    }
}
