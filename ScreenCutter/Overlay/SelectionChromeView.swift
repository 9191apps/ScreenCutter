import AppKit

/// Selection border, size label, and resize handles. Drawn above the dim so it can
/// refresh without rebuilding the mask.
///
/// The border and handles live just outside `selectionRect`, so the pixels being
/// captured are never covered by the chrome.
final class SelectionChromeView: NSView {
    private var selectionRect: CGRect = .zero
    private var label = ""
    private var handlePoints: [CGPoint] = []
    private var labelText: NSString?
    private var labelTextSize: CGSize = .zero

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.white,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.zPosition = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// `rect` and `handles` are in this view's AppKit coordinates.
    func update(rect: CGRect, label: String, handles: [CGPoint]) {
        let previousBounds = chromeBounds()
        if label != self.label {
            let text = label as NSString
            labelText = label.isEmpty ? nil : text
            labelTextSize = label.isEmpty ? .zero : text.size(withAttributes: Self.labelAttributes)
            self.label = label
        }
        selectionRect = rect
        handlePoints = visibleHandles(in: rect, from: handles)
        // Resizing redraws this view once per frame. This view covers the whole
        // screen, so marking all of it dirty makes AppKit re-rasterize a 4K layer
        // for a two-pixel border. Only the old and new chrome need to be repainted.
        let dirty = previousBounds.union(chromeBounds())
        if dirty.isNull || dirty.isInfinite {
            needsDisplay = true
        } else {
            setNeedsDisplay(dirty)
        }
    }

    /// Resize knobs currently drawn, in this view's coordinates.
    var resizeHandlePoints: [CGPoint] { handlePoints }

    /// Everything `draw` can touch: the border, the handles, and the size label,
    /// which sits just outside the selection on the wide side of the screen.
    private func chromeBounds() -> CGRect {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return .null }
        var chrome = selectionRect.insetBy(dx: -12, dy: -12)
        guard labelTextSize.width > 0 else { return chrome }
        let size = CGSize(width: labelTextSize.width + 12, height: labelTextSize.height + 4)
        // The label is drawn 14pt away from the selection, above it when there is
        // room and below it otherwise. Both spots count as dirty.
        for centerY in [selectionRect.maxY + 14, selectionRect.minY - 14] {
            chrome = chrome.union(CGRect(
                x: selectionRect.midX - size.width / 2,
                y: centerY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
        return chrome
    }

    private func visibleHandles(in rect: CGRect, from points: [CGPoint]) -> [CGPoint] {
        guard rect.width >= 8, rect.height >= 8 else { return [] }
        guard rect.width < 24 || rect.height < 24 else { return points }
        return points.filter { point in
            let onLeft = abs(point.x - rect.minX) < 0.75
            let onRight = abs(point.x - rect.maxX) < 0.75
            let onTop = abs(point.y - rect.maxY) < 0.75
            let onBottom = abs(point.y - rect.minY) < 0.75
            return (onLeft || onRight) && (onTop || onBottom)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return }
        drawBorder()
        drawHandles()
        drawLabel()
    }

    private func drawBorder() {
        let compact = min(selectionRect.width, selectionRect.height) < 24
        let offset: CGFloat = compact ? 1 : 1.5
        let blackWidth: CGFloat = compact ? 2 : 3
        let borderRect = selectionRect.insetBy(dx: -offset, dy: -offset)

        NSColor.black.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: borderRect)
        border.lineWidth = blackWidth
        border.stroke()

        NSColor.white.setStroke()
        let hairline = NSBezierPath(rect: borderRect)
        hairline.lineWidth = 1
        hairline.stroke()
    }

    private func drawHandles() {
        guard !handlePoints.isEmpty else { return }
        let size: CGFloat = min(selectionRect.width, selectionRect.height) < 24 ? 6 : 8
        let offset = size / 2
        for point in handlePoints {
            let onLeft = abs(point.x - selectionRect.minX) < 0.75
            let onRight = abs(point.x - selectionRect.maxX) < 0.75
            let onTop = abs(point.y - selectionRect.maxY) < 0.75
            let onBottom = abs(point.y - selectionRect.minY) < 0.75
            let center = CGPoint(
                x: point.x + (onLeft ? -offset : (onRight ? offset : 0)),
                y: point.y + (onBottom ? -offset : (onTop ? offset : 0))
            )
            let handle = NSRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            NSColor.white.setFill()
            NSBezierPath(rect: handle).fill()
            NSColor.black.setStroke()
            let outline = NSBezierPath(rect: handle)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private func drawLabel() {
        guard let text = labelText, labelTextSize.width > 0 else { return }
        let textSize = labelTextSize
        let size = CGSize(width: textSize.width + 12, height: textSize.height + 4)
        let centerY: CGFloat
        if bounds.height - selectionRect.maxY > 28 {
            centerY = selectionRect.maxY + 14
        } else {
            centerY = max(size.height / 2, selectionRect.minY - 14)
        }
        let labelRect = CGRect(
            x: selectionRect.midX - size.width / 2,
            y: centerY - size.height / 2,
            width: size.width,
            height: size.height
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        let textRect = CGRect(
            x: labelRect.midX - textSize.width / 2,
            y: labelRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: Self.labelAttributes)
    }
}
