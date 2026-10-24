import AppKit

/// Selection border, size label, and resize handles. Drawn above the dim so it can refresh without rebuilding the mask.
final class SelectionChromeView: NSView {
    private var selectionRect: CGRect = .zero
    private var label = ""
    private var handlePoints: [CGPoint] = []

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
        selectionRect = rect
        self.label = label
        handlePoints = handles
        needsDisplay = true
    }

    /// Resize knobs currently drawn, in this view's coordinates.
    var resizeHandlePoints: [CGPoint] { handlePoints }

    override func draw(_ dirtyRect: NSRect) {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return }
        NSColor.black.setStroke()
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 3
        border.stroke()
        NSColor.white.setStroke()
        let hairline = NSBezierPath(rect: selectionRect)
        hairline.lineWidth = 1
        hairline.stroke()

        for point in handlePoints {
            let handle = NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(rect: handle).fill()
            NSColor.black.setStroke()
            let outline = NSBezierPath(rect: handle)
            outline.lineWidth = 1
            outline.stroke()
        }

        drawLabel()
    }

    private func drawLabel() {
        guard !label.isEmpty else { return }
        let text = label as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
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
        text.draw(in: textRect, withAttributes: attributes)
    }
}
