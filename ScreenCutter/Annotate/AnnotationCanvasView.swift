import AppKit
import Combine

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    let session: CaptureSession
    private let toolbar = NSVisualEffectView()
    private var toolStack: NSStackView?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private var dragAnchor: CGPoint?
    private var penPoints: [CGPoint] = []
    private var observation: AnyCancellable?
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var widthButtons: [NSButton] = []
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private var resizeHandle: SelectionHandle?
    private var resizeOrigin: CGRect?
    private var resizeDidRecordUndo = false
    private var pendingAnnotation: Int?
    private var pendingAnnotationAnchor: CGPoint?
    private var pendingAnnotationDown: CGPoint?
    private var movingAnnotation: Int?
    private var moveStartImage: CGPoint?
    private var moveOriginalStroke: AnnotationStroke?
    private var moveDidRecordUndo = false

    init(session: CaptureSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.zPosition = 1
        installToolbar()
        observation = session.annotationChanges.sink { [weak self] _ in
            self?.refreshToolbarState()
            self?.needsDisplay = true
        }
    }

    var toolbarView: NSView { toolbar }

    func attachToolbar(to parent: NSView) {
        guard toolbar.superview !== parent else { return }
        parent.addSubview(toolbar)
        toolbar.isHidden = true
    }

    override var isOpaque: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isEditingText: Bool {
        textField != nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Include the handle ring so knobs centered on the image edge stay clickable.
        if imageFrame.insetBy(dx: -8, dy: -8).contains(local) {
            return self
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = session.editingImage,
              let composited = AnnotationRenderer.composite(base: image, document: session.annotation) else { return }
        let frame = imageFrame
        NSImage(cgImage: composited, size: frame.size).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        drawSelection()
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = imagePoint(from: event)

        // Handles stay active while any drawing tool is selected.
        if beginRectangleResize(at: viewPoint) {
            return
        }

        guard imageBounds.contains(point) else {
            session.selectAnnotation(at: nil)
            return
        }

        if session.annotation.tool != .text {
            // Topmost annotation wins. Dragging the selected one moves it;
            // dragging an unselected one draws after the drag threshold.
            if let index = session.annotation.hitTestIndex(at: point, tolerance: hitTolerance) {
                if index == session.selectedAnnotation {
                    beginMove(at: index, point: point)
                } else {
                    pendingAnnotation = index
                    pendingAnnotationAnchor = point
                    pendingAnnotationDown = viewPoint
                }
                return
            }
        }

        session.selectAnnotation(at: nil)
        if session.annotation.tool == .text {
            beginText(at: point, viewPoint: viewPoint)
        } else {
            startStroke(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if resizeHandle != nil {
            updateRectangleResize(with: event)
            return
        }
        if movingAnnotation != nil {
            updateMove(with: event)
            return
        }

        if pendingAnnotation != nil {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let down = pendingAnnotationDown ?? viewPoint
            guard hypot(viewPoint.x - down.x, viewPoint.y - down.y) >= 4 else { return }
            pendingAnnotation = nil
            pendingAnnotationDown = nil
            let anchor = pendingAnnotationAnchor ?? imagePoint(from: event)
            pendingAnnotationAnchor = nil
            session.selectAnnotation(at: nil)
            startStroke(at: anchor)
            continueStroke(to: imagePoint(from: event))
            return
        }

        continueStroke(to: imagePoint(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        if resizeHandle != nil {
            resizeHandle = nil
            resizeOrigin = nil
            resizeDidRecordUndo = false
            return
        }
        if movingAnnotation != nil {
            endMove()
            return
        }
        if let index = pendingAnnotation {
            pendingAnnotation = nil
            pendingAnnotationAnchor = nil
            pendingAnnotationDown = nil
            session.selectAnnotation(at: index)
            return
        }
        guard session.annotation.tool != .text else { return }
        session.commitAnnotationDraft()
        dragAnchor = nil
        penPoints = []
    }

    private func startStroke(at point: CGPoint) {
        switch session.annotation.tool {
        case .rectangle, .arrow:
            dragAnchor = point
            publishDrag(to: point)
        case .pen:
            penPoints = [point]
            session.setAnnotationDraft(.pen(penPoints, session.annotation.style))
        case .text:
            break
        }
    }

    private func continueStroke(to point: CGPoint) {
        switch session.annotation.tool {
        case .rectangle, .arrow:
            publishDrag(to: point)
        case .pen:
            penPoints.append(point)
            session.setAnnotationDraft(.pen(penPoints, session.annotation.style))
        case .text:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.removeFromSuperview()
            textField = nil
            textOrigin = nil
            return true
        }
        return false
    }

    private func publishDrag(to point: CGPoint) {
        guard let dragAnchor else { return }
        let style = session.annotation.style
        switch session.annotation.tool {
        case .rectangle:
            session.setAnnotationDraft(.rectangle(AnnotationGeometry.rectangle(from: dragAnchor, to: point), style))
        case .arrow:
            session.setAnnotationDraft(.arrow(dragAnchor, point, style))
        case .pen, .text:
            break
        }
    }

    // MARK: - Selection, moving, and resizing

    private var hitTolerance: CGFloat {
        guard let image = session.editingImage, imageFrame.width > 0 else { return 8 }
        let displayScale = imageFrame.width / CGFloat(image.width)
        return max(8 / max(displayScale, 0.1), 4)
    }

    private func beginRectangleResize(at viewPoint: CGPoint) -> Bool {
        guard let index = session.selectedAnnotation,
              session.annotation.strokes.indices.contains(index),
              case .rectangle = session.annotation.strokes[index],
              let viewRect = viewRect(forRectangleAt: index),
              let handle = SelectionGeometry.hitHandle(point: viewPoint, in: viewRect),
              handle != .move else {
            return false
        }
        resizeHandle = handle
        resizeOrigin = viewRect
        resizeDidRecordUndo = false
        return true
    }

    private func updateRectangleResize(with event: NSEvent) {
        guard let handle = resizeHandle,
              let origin = resizeOrigin,
              let index = session.selectedAnnotation,
              let image = session.editingImage else { return }
        if !resizeDidRecordUndo {
            session.recordAnnotationUndoPoint()
            resizeDidRecordUndo = true
        }
        let point = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(
            x: min(max(point.x, imageFrame.minX), imageFrame.maxX),
            y: min(max(point.y, imageFrame.minY), imageFrame.maxY)
        )
        let next = SelectionGeometry.resized(origin, handle: handle, to: clamped, minimum: 6)
        let imageRect = AnnotationGeometry.imageRect(
            viewRect: next,
            imageFrame: imageFrame,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        session.updateAnnotationRectangle(at: index, to: imageRect)
    }

    private func beginMove(at index: Int, point: CGPoint) {
        guard session.annotation.strokes.indices.contains(index) else { return }
        movingAnnotation = index
        moveStartImage = point
        moveOriginalStroke = session.annotation.strokes[index]
        moveDidRecordUndo = false
        resizeHandle = nil
        resizeOrigin = nil
    }

    private func updateMove(with event: NSEvent) {
        guard let index = movingAnnotation,
              let start = moveStartImage,
              let original = moveOriginalStroke,
              let image = session.editingImage else { return }
        let point = imagePoint(from: event)
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = AnnotationGeometry.clampedTranslation(of: original, by: delta, within: bounds)
        guard clamped != .zero else { return }
        if !moveDidRecordUndo {
            session.recordAnnotationUndoPoint()
            moveDidRecordUndo = true
        }
        session.updateAnnotationStroke(at: index, with: original.translated(by: clamped))
    }

    private func endMove() {
        movingAnnotation = nil
        moveStartImage = nil
        moveOriginalStroke = nil
        moveDidRecordUndo = false
    }

    private func viewRect(forRectangleAt index: Int) -> CGRect? {
        guard let image = session.editingImage,
              session.annotation.strokes.indices.contains(index),
              case .rectangle(let rect, _) = session.annotation.strokes[index] else {
            return nil
        }
        return AnnotationGeometry.viewRect(
            imageRect: rect,
            imageFrame: imageFrame,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    private func viewRect(forStrokeAt index: Int) -> CGRect? {
        guard let image = session.editingImage,
              session.annotation.strokes.indices.contains(index) else { return nil }
        let bounds = AnnotationGeometry.contentBounds(of: session.annotation.strokes[index])
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return AnnotationGeometry.viewRect(
            imageRect: bounds,
            imageFrame: imageFrame,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    private func drawSelection() {
        guard let index = session.selectedAnnotation,
              session.annotation.strokes.indices.contains(index) else { return }
        switch session.annotation.strokes[index] {
        case .rectangle:
            guard let viewRect = viewRect(forRectangleAt: index) else { return }
            // Only the handles: the rectangle's own stroke already marks its
            // bounds, so an extra outline would look like a second line.
            for (_, anchor) in SelectionGeometry.handleAnchors(in: viewRect) {
                drawHandle(at: anchor)
            }
        default:
            guard let viewRect = viewRect(forStrokeAt: index) else { return }
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: viewRect)
            path.lineWidth = 1
            var dash: [CGFloat] = [4, 3]
            path.setLineDash(&dash, count: dash.count, phase: 0)
            path.stroke()
        }
    }

    private func drawHandle(at anchor: CGPoint) {
        let handle = CGRect(x: anchor.x - 4, y: anchor.y - 4, width: 8, height: 8)
        NSColor.white.setFill()
        NSBezierPath(rect: handle).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: handle)
        border.lineWidth = 1
        border.stroke()
    }

    private func beginText(at imagePoint: CGPoint, viewPoint: CGPoint) {
        textField?.removeFromSuperview()
        let field = NSTextField(string: "")
        field.placeholderString = "文字"
        field.font = NSFont.systemFont(ofSize: 16)
        field.backgroundColor = .white
        field.isBezeled = true
        field.delegate = self
        field.frame = NSRect(x: viewPoint.x, y: viewPoint.y - 24, width: 180, height: 24)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = imagePoint
    }

    private func commitText() {
        guard let textField, let textOrigin else { return }
        let string = textField.stringValue
        textField.removeFromSuperview()
        self.textField = nil
        self.textOrigin = nil
        let stroke = AnnotationStroke.text(string, textOrigin, session.annotation.style)
        guard AnnotationDocument.isVisible(stroke) else { return }
        session.setAnnotationDraft(stroke)
        session.commitAnnotationDraft()
    }

    private func installToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .behindWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.zPosition = 5

        var buttons: [NSView] = []
        var tools: [NSButton] = []
        for tool in AnnotationTool.allCases {
            let button = NSButton(title: tool.title, target: self, action: #selector(selectTool(_:)))
            button.tag = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.pushOnPushOff)
            buttons.append(button)
            tools.append(button)
        }
        var colors: [NSButton] = []
        for color in AnnotationColor.allCases {
            let button = ColorSwatchButton(color: color)
            button.tag = AnnotationColor.allCases.firstIndex(of: color) ?? 0
            button.target = self
            button.action = #selector(selectColor(_:))
            buttons.append(button)
            colors.append(button)
        }
        var widths: [NSButton] = []
        for width in AnnotationStyle.lineWidths {
            let style = AnnotationStyle(color: .red, lineWidth: width)
            let button = NSButton(title: style.titleForWidth, target: self, action: #selector(selectWidth(_:)))
            button.tag = Int(width)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.pushOnPushOff)
            buttons.append(button)
            widths.append(button)
        }
        toolButtons = tools
        colorButtons = colors
        widthButtons = widths
        let undo = NSButton(title: "撤销", target: self, action: #selector(undoClicked))
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        let copy = NSButton(title: "复制", target: self, action: #selector(copyClicked))
        let save = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        let textCopy = NSButton(title: "拷贝文字", target: self, action: #selector(copyTextClicked))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        copy.bezelColor = .controlAccentColor
        for button in [undo, deleteButton, copy, save, textCopy, cancel] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.momentaryPushIn)
        }
        buttons.append(contentsOf: [undo, deleteButton, copy, save, textCopy, cancel])

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Size the effect view before activating the stack's edge constraints;
        // its zero-width autoresizing constraint would otherwise conflict.
        let fitting = stack.fittingSize
        toolbar.frame = NSRect(
            origin: .zero,
            size: NSSize(width: max(fitting.width, 1), height: max(fitting.height, 44))
        )
        toolbar.addSubview(stack)
        toolStack = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        refreshToolbarState()
    }

    /// Marks the current tool, color, and line width so the toolbar shows the active style.
    private func refreshToolbarState() {
        let document = session.annotation
        for button in toolButtons {
            let selected = AnnotationTool.allCases.indices.contains(button.tag)
                && AnnotationTool.allCases[button.tag] == document.tool
            button.state = selected ? .on : .off
        }
        for button in colorButtons {
            let selected = AnnotationColor.allCases.indices.contains(button.tag)
                && AnnotationColor.allCases[button.tag] == document.style.color
            button.state = selected ? .on : .off
            button.needsDisplay = true
        }
        for button in widthButtons {
            button.state = CGFloat(button.tag) == document.style.lineWidth ? .on : .off
        }
        deleteButton.isEnabled = session.selectedAnnotation != nil
    }

    /// Positions the toolbar in its superview. `viewBounds` is that superview's bounds.
    /// The selection is passed in because the overlay lays out during `@Published` `willSet`,
    /// when `session.phase` still holds the previous phase.
    func placeToolbar(in viewBounds: CGRect, selection: ScreenSelection) {
        guard viewBounds.width > 1, viewBounds.height > 1 else {
            toolbar.isHidden = true
            return
        }
        let local = SelectionGeometry.displayLocalRect(
            selection: selection.globalRect,
            screenFrame: selection.screenFrame
        )
        let fitting = toolStack?.fittingSize ?? .zero
        guard fitting.width > 1, fitting.height > 1 else {
            toolbar.isHidden = true
            return
        }
        // Size the bar to its buttons. A fixed minimum width left a blank strip
        // on the trailing edge; only the screen edge should cap the width.
        let bar = CGSize(
            width: min(fitting.width, viewBounds.width - 16),
            height: max(fitting.height, 44)
        )
        let frame = SelectionGeometry.actionBarFrame(
            selection: local,
            screenSize: viewBounds.size,
            barSize: bar,
            margin: 8
        )
        toolbar.frame = NSRect(
            x: frame.minX,
            y: viewBounds.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        toolbar.isHidden = false
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard AnnotationTool.allCases.indices.contains(sender.tag) else { return }
        session.setAnnotationTool(AnnotationTool.allCases[sender.tag])
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard AnnotationColor.allCases.indices.contains(sender.tag) else { return }
        session.setAnnotationColor(AnnotationColor.allCases[sender.tag])
    }

    @objc private func selectWidth(_ sender: NSButton) {
        session.setAnnotationLineWidth(CGFloat(sender.tag))
    }

    @objc private func undoClicked() {
        session.undoAnnotation()
    }

    @objc private func deleteClicked() {
        session.deleteSelectedAnnotation()
    }

    @objc private func copyClicked() {
        commitText()
        session.copySelection()
    }

    @objc private func saveClicked() {
        commitText()
        session.saveSelection()
    }

    @objc private func copyTextClicked() {
        commitText()
        session.copyRecognizedText()
    }

    @objc private func cancelClicked() {
        session.cancel()
    }

    private var editingSelection: ScreenSelection? {
        if case .editing(let selection) = session.phase { return selection }
        return nil
    }

    private var selectionLocal: CGRect {
        guard let selection = editingSelection else { return .zero }
        return SelectionGeometry.displayLocalRect(selection: selection.globalRect, screenFrame: selection.screenFrame)
    }

    private var imageFrame: CGRect {
        let local = selectionLocal
        return CGRect(x: local.minX, y: bounds.height - local.maxY, width: local.width, height: local.height)
    }

    private var imageBounds: CGRect {
        guard let image = session.editingImage else { return .zero }
        return CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        guard let image = session.editingImage else { return .zero }
        return AnnotationGeometry.imagePoint(
            viewPoint: convert(event.locationInWindow, from: nil),
            viewSize: bounds.size,
            selectionLocal: selectionLocal,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }
}

/// Draws the color itself instead of relying on `bezelColor`, which circular
/// AppKit buttons ignore. The active swatch gets a light ring.
private final class ColorSwatchButton: NSButton {
    private let swatchColor: NSColor

    init(color: AnnotationColor) {
        let components = color.components
        swatchColor = NSColor(
            srgbRed: components.0,
            green: components.1,
            blue: components.2,
            alpha: 1
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        title = ""
        isBordered = false
        setAccessibilityLabel(color.rawValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 4, dy: 4)
        swatchColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(ovalIn: dot)
        border.lineWidth = 1
        border.stroke()

        if state == .on {
            NSColor.black.withAlphaComponent(0.7).setStroke()
            let outer = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            outer.lineWidth = 2.5
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
            inner.lineWidth = 1
            inner.stroke()
        }

        if cell?.isHighlighted == true {
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
