import AppKit

/// The display's still frame from the moment the capture started. It sits under
/// `DimMaskView`: outside the selection the frame is dimmed, inside the hole it is
/// shown at full brightness. The desktop may keep changing behind the overlay, but
/// everything the selection UI shows comes from this one frame.
final class FrozenBackdropView: NSView {
    private let imageLayer = CALayer()
    private(set) var image: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    func setImage(_ image: CGImage?) {
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        layoutImage()
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutImage()
        CATransaction.commit()
    }

    /// Matches the layer's drawing scale to the frame's pixels, so the still maps
    /// 1:1 onto the display instead of being resampled by the compositor.
    private func layoutImage() {
        imageLayer.frame = bounds
        guard let image, bounds.width > 0 else { return }
        imageLayer.contentsScale = CGFloat(image.width) / bounds.width
    }
}
