import AppKit

/// Full-screen dim with a hole. The path updates in place so the overlay does not rebuild.
final class DimMaskView: NSView {
    private let shape = CAShapeLayer()
    private var topLeftHole: CGRect?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 0
        shape.fillRule = .evenOdd
        shape.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        shape.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "fillColor": NSNull(),
        ]
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        shape.frame = bounds
        applyPath()
    }

    /// `hole` uses the overlay's top-left origin.
    func setHole(_ hole: CGRect?) {
        topLeftHole = hole
        applyPath()
    }

    private func applyPath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole = topLeftHole, hole.width > 0, hole.height > 0 {
            path.addRect(CGRect(
                x: hole.minX,
                y: bounds.height - hole.maxY,
                width: hole.width,
                height: hole.height
            ))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }
}
