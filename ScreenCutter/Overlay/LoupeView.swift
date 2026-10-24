import AppKit

/// A pixel-accurate loupe: one source pixel is drawn as a 5pt square with a grid,
/// the pixel under the pointer is filled white inside a blue crosshair, and the
/// coordinates stay readable while the mouse is down.
final class LoupeView: NSView {
    static let contentSide: CGFloat = 120
    static let readoutHeight: CGFloat = 30
    static let zoom: CGFloat = 5
    static let sampleCount = 24

    static var contentSize: CGSize {
        CGSize(width: contentSide, height: contentSide + readoutHeight)
    }

    private var source: CGImage?
    private var focus: PixelPoint?
    private var selection: PixelRect?
    /// The display's native pixel size. When the snapshot comes back at a
    /// different resolution, `focus` (display pixels) is mapped into image pixels.
    private var sourcePixelSize: CGSize?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = 20
    }

    convenience init() {
        self.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        source: CGImage?,
        focus: PixelPoint?,
        selection: PixelRect?,
        sourcePixelSize: CGSize? = nil
    ) {
        self.source = source
        self.focus = focus
        self.selection = selection
        self.sourcePixelSize = sourcePixelSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let background = NSBezierPath(roundedRect: outer, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.84).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        background.lineWidth = 1
        background.stroke()

        drawMagnifiedContent()
        drawReadout()
    }

    private func drawMagnifiedContent() {
        guard let source, let focus else { return }
        let displaySize = sourcePixelSize ?? CGSize(width: source.width, height: source.height)
        let sourceFocus = LoupeGeometry.sourceFocus(
            displayFocus: focus,
            sourceSize: CGSize(width: source.width, height: source.height),
            displayPixelSize: displaySize
        )
        let contentRect = CGRect(x: 0, y: 0, width: Self.contentSide, height: Self.contentSide)
        let sample = CGFloat(Self.sampleCount)
        let sourceRect = CGRect(
            x: sourceFocus.x - sample / 2,
            y: sourceFocus.y - sample / 2,
            width: sample,
            height: sample
        )
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let clipped = sourceRect.intersection(imageBounds).integral
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let crop = source.cropping(to: clipped) else { return }

        let drawRect = CGRect(
            x: (clipped.minX - sourceRect.minX) * Self.zoom,
            y: (clipped.minY - sourceRect.minY) * Self.zoom,
            width: clipped.width * Self.zoom,
            height: clipped.height * Self.zoom
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: contentRect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        let image = NSImage(cgImage: crop, size: NSSize(width: clipped.width, height: clipped.height))
        image.draw(
            in: drawRect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.none]
        )
        NSGraphicsContext.current?.imageInterpolation = .high

        drawGrid(sourceRect: sourceRect, clipped: clipped)
        drawCenterPixel(
            sourceRect: sourceRect,
            focus: PixelPoint(x: Int(sourceFocus.x.rounded()), y: Int(sourceFocus.y.rounded())),
            drawRect: drawRect
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A single white hairline is invisible on light content, so the grid uses a
    /// dark/light pair: a black pixel on the inside of each boundary and a white
    /// pixel on the outside. One of the two always contrasts, whatever the content
    /// under the loupe is.
    private func drawGrid(sourceRect: CGRect, clipped: CGRect) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let line = 1 / scale
        let half = line / 2

        let dark = NSBezierPath()
        let light = NSBezierPath()
        let top = (clipped.minY - sourceRect.minY) * Self.zoom
        let bottom = (clipped.maxY - sourceRect.minY) * Self.zoom
        let left = (clipped.minX - sourceRect.minX) * Self.zoom
        let right = (clipped.maxX - sourceRect.minX) * Self.zoom

        for pixel in Int(clipped.minX)...Int(clipped.maxX) {
            let x = (CGFloat(pixel) - sourceRect.minX) * Self.zoom
            dark.move(to: CGPoint(x: x - half, y: top))
            dark.line(to: CGPoint(x: x - half, y: bottom))
            light.move(to: CGPoint(x: x + half, y: top))
            light.line(to: CGPoint(x: x + half, y: bottom))
        }
        for pixel in Int(clipped.minY)...Int(clipped.maxY) {
            let y = (CGFloat(pixel) - sourceRect.minY) * Self.zoom
            dark.move(to: CGPoint(x: left, y: y - half))
            dark.line(to: CGPoint(x: right, y: y - half))
            light.move(to: CGPoint(x: left, y: y + half))
            light.line(to: CGPoint(x: right, y: y + half))
        }

        dark.lineWidth = line
        light.lineWidth = line
        NSColor.black.withAlphaComponent(0.38).setStroke()
        dark.stroke()
        NSColor.white.withAlphaComponent(0.50).setStroke()
        light.stroke()
    }

    private func drawCenterPixel(sourceRect: CGRect, focus: PixelPoint, drawRect: CGRect) {
        let cell = CGRect(
            x: (CGFloat(focus.x) - sourceRect.minX) * Self.zoom,
            y: (CGFloat(focus.y) - sourceRect.minY) * Self.zoom,
            width: Self.zoom,
            height: Self.zoom
        )
        let visible = cell.intersection(drawRect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        // A blue crosshair one cell thick: the arms are exactly as wide as the
        // white square, so the marker reads as a single reticle instead of a
        // hairline that disappears over light content.
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: CGRect(
            x: drawRect.minX,
            y: cell.minY,
            width: drawRect.width,
            height: cell.height
        )).fill()
        NSBezierPath(rect: CGRect(
            x: cell.minX,
            y: drawRect.minY,
            width: cell.width,
            height: drawRect.height
        )).fill()

        NSColor.white.setFill()
        NSBezierPath(rect: cell).fill()
    }

    private func drawReadout() {
        let readout = CGRect(
            x: 0,
            y: Self.contentSide,
            width: Self.contentSide,
            height: Self.readoutHeight
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        readout.fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let coordinateText = focus.map { "x \($0.x)  y \($0.y)" } ?? "x —  y —"
        let selectionText = selection.map { "选区 \($0.width) × \($0.height) px" } ?? "选区 —"
        (coordinateText as NSString).draw(
            in: CGRect(x: 8, y: Self.contentSide + 4, width: Self.contentSide - 16, height: 11),
            withAttributes: attributes
        )
        (selectionText as NSString).draw(
            in: CGRect(x: 8, y: Self.contentSide + 15, width: Self.contentSide - 16, height: 11),
            withAttributes: attributes
        )
    }
}
