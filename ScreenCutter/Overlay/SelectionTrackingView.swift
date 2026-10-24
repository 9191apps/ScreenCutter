import AppKit
import Combine

final class SelectionTrackingView: NSView, NSPopoverDelegate {
    let session: CaptureSession
    let screenFrame: CGRect
    let metrics: DisplayMetrics
    let displayID: CGDirectDisplayID
    private let dim = DimMaskView(frame: .zero)
    private let chrome = SelectionChromeView(frame: .zero)
    private let barContainer = NSVisualEffectView()
    private let annotateButton = NSButton(title: "标注", target: nil, action: nil)
    private let scrollButton = NSButton(title: "开始滚动", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let precisionButton = NSButton(title: "精确", target: nil, action: nil)
    private var annotationCanvas: AnnotationCanvasView?
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let loupe = LoupeView()
    private var precisionPopover: NSPopover?
    private var observations: [AnyCancellable] = []
    private var trackingArea: NSTrackingArea?
    /// The phase this overlay last laid out for.
    /// `@Published` emits during `willSet`, so reading `session.phase` from the
    /// subscription would see the previous value. The publisher's value is the
    /// only reliable snapshot at layout time.
    private var laidOutPhase: CapturePhase = .idle
    /// The cursor to keep while a drag is in progress. The modal event loops
    /// below do not dispatch mouse-moved events, so the cursor has to be set
    /// explicitly when a drag starts.
    private var dragCursor: CursorIntent?
    // `@Published` emits during `willSet`; these mirror the last published values
    // so layout never reads the previous state off `session`.
    private var laidOutPreview: PixelRect?
    private var laidOutShowLoupe = true
    private var laidOutScrollIntent = false

    init(session: CaptureSession, screen: NSScreen) {
        self.session = session
        screenFrame = screen.frame
        metrics = screen.displayMetrics
        displayID = screen.displayID
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        laidOutPhase = session.phase
        laidOutPreview = session.previewRect
        laidOutShowLoupe = session.showLoupe
        laidOutScrollIntent = session.scrollIntent
        dim.frame = bounds
        dim.autoresizingMask = [.width, .height]
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(dim)
        addSubview(chrome)
        installActionBar()
        let canvas = AnnotationCanvasView(session: session)
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.isHidden = true
        addSubview(canvas)
        canvas.attachToolbar(to: self)
        annotationCanvas = canvas
        addSubview(loupe)
        observations = [
            session.$phase.sink { [weak self] next in
                self?.apply(phase: next)
            },
            session.$scrollIntent.sink { [weak self] scrolling in
                self?.laidOutScrollIntent = scrolling
                self?.layoutActionBar()
            },
            session.$snapshotVersion.sink { [weak self] _ in
                self?.refreshLoupeAtMouse()
            },
            session.$showLoupe.sink { [weak self] showLoupe in
                self?.laidOutShowLoupe = showLoupe
                self?.refreshLoupeAtMouse()
            },
            session.$previewRect.sink { [weak self] preview in
                self?.laidOutPreview = preview
                self?.layoutDim()
            },
        ]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActiveForCursor),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKeyForCursor(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        layoutDim()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if session.phase.showsActionBar {
            if let hit = barContainer.hitTest(localPoint) {
                return hit
            }
            return self
        }
        if session.phase.isEditing {
            if let toolbar = annotationCanvas?.toolbarView, !toolbar.isHidden,
               let hit = toolbar.hitTest(localPoint) {
                return hit
            }
            if let hit = annotationCanvas?.hitTest(localPoint) {
                return hit
            }
            return self
        }
        if session.phase.isSelecting || session.phase.isPickingWindow {
            return self
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshCursor()
    }

    override func resetCursorRects() {
        // The base cursor covers the whole overlay. `updateCursor(at:)` refines
        // it for selection edges, annotations, and the toolbars as the mouse moves.
        let cursor: NSCursor = laidOutPhase.isSelecting ? .crosshair : .arrow
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        updateCursor(at: local)
        if session.phase.isSelecting {
            session.ensureSnapshot(displayID: displayID)
        }
        refreshLoupe(global: globalPoint(from: event))
    }

    override func mouseExited(with event: NSEvent) {
        hideLoupe()
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let global = globalPoint(from: event)
        if session.phase.isPickingWindow {
            session.updateWindowHover(at: global, metrics: metrics)
        }
        if session.phase.isSelecting {
            session.ensureSnapshot(displayID: displayID)
        }
        updateCursor(at: local)
        refreshLoupe(global: global)
    }

    /// Reapplies the cursor for the current mouse location. Used after phase
    /// changes and when the overlay becomes key, so the shape is right even
    /// before the next mouse move.
    func refreshCursor() {
        guard let window, window.isVisible else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return }
        updateCursor(at: local)
    }

    @objc private func applicationDidBecomeActiveForCursor() {
        refreshCursor()
    }

    @objc private func windowDidBecomeKeyForCursor(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        refreshCursor()
    }

    /// Resolves the cursor for a point in this overlay's coordinates.
    func cursorIntent(at point: CGPoint) -> CursorIntent {
        if let dragCursor {
            return dragCursor
        }
        switch laidOutPhase {
        case .selecting:
            return .crosshair
        case .windowPicking(let hover):
            guard let hover, hover.screenID == displayID else { return .arrow }
            return .pointingHand
        case .actionBar(let selection):
            guard selection.screenID == displayID else { return .arrow }
            if !barContainer.isHidden, barContainer.frame.contains(point) {
                return .arrow
            }
            if let handle = SelectionGeometry.hitHandle(point: point, in: viewRect(for: selection)) {
                return handle == .move ? .openHand : .resize(handle)
            }
            return .arrow
        case .editing(let selection):
            guard selection.screenID == displayID,
                  let canvas = annotationCanvas,
                  !canvas.isHidden else { return .arrow }
            return canvas.cursorIntent(at: canvas.convert(point, from: self))
        case .working, .idle:
            return .arrow
        }
    }

    private func updateCursor(at point: CGPoint) {
        // Always set the cursor instead of caching the last intent: the system
        // can reset it when the app activates or the window becomes key, and a
        // cache would then keep skipping the correction.
        cursorIntent(at: point).cursor.set()
    }

    private func viewRect(for selection: ScreenSelection) -> CGRect {
        CGRect(
            x: selection.globalRect.minX - screenFrame.minX,
            y: selection.globalRect.minY - screenFrame.minY,
            width: selection.globalRect.width,
            height: selection.globalRect.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        if session.phase.isSelecting {
            session.refreshSnapshotIfStale(displayID: displayID)
        }
        if session.phase.isPickingWindow {
            session.confirmWindow(at: globalPoint(from: event), metrics: metrics)
            layoutActionBar()
            return
        }
        if session.phase.showsActionBar {
            let global = globalPoint(from: event)
            if case .actionBar(let selection) = session.phase,
               let handle = SelectionGeometry.hitHandle(point: global, in: selection.globalRect) {
                session.beginAdjustment(handle: handle, at: global)
                dragCursor = handle == .move ? .closedHand : .resize(handle)
                refreshCursor()
                trackAdjustment(from: event)
                return
            }
            if case .actionBar(let selection) = session.phase, !selection.globalRect.contains(global) {
                session.cancel()
            }
            return
        }
        guard session.phase.isSelecting else { return }
        session.ensureSnapshot(displayID: displayID)
        trackDrag(from: event)
    }

    private func trackDrag(from event: NSEvent) {
        defer {
            dragCursor = nil
            refreshCursor()
        }
        var anchor = session.snappedPoint(
            globalPoint(from: event),
            metrics: metrics,
            enabled: !event.modifierFlags.contains(.control)
        )
        var current = anchor
        var lastMouse = anchor
        var spaceMove: (anchor: CGPoint, current: CGPoint, mouse: CGPoint)?
        publish(
            anchor: anchor,
            current: current,
            flags: event.modifierFlags,
            snapEnabled: !event.modifierFlags.contains(.control)
        )
        refreshLoupe(global: anchor)
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .keyDown, .keyUp]
        while true {
            guard session.phase.isSelecting else { return }
            guard let next = window?.nextEvent(matching: mask, until: .distantFuture, inMode: .default, dequeue: true) else {
                return
            }
            if next.type == .keyDown, next.keyCode == CaptureKeyCode.escape {
                session.cancel()
                return
            }
            if next.type == .keyDown, next.keyCode == CaptureKeyCode.space, !next.isARepeat {
                spaceMove = (anchor, current, lastMouse)
                dragCursor = .closedHand
                refreshCursor()
                continue
            }
            if next.type == .keyUp, next.keyCode == CaptureKeyCode.space {
                spaceMove = nil
                dragCursor = nil
                refreshCursor()
                continue
            }
            if next.type == .keyDown || next.type == .keyUp {
                continue
            }
            lastMouse = globalPoint(from: next)
            if let spaceMove {
                let delta = CGPoint(x: lastMouse.x - spaceMove.mouse.x, y: lastMouse.y - spaceMove.mouse.y)
                let moved = SelectionGeometry.movedSelection(
                    anchor: spaceMove.anchor,
                    current: spaceMove.current,
                    by: delta,
                    within: screenFrame
                )
                anchor = moved.anchor
                current = moved.current
            } else {
                current = lastMouse
            }
            publish(
                anchor: anchor,
                current: current,
                flags: next.modifierFlags,
                snapEnabled: spaceMove == nil && !next.modifierFlags.contains(.control),
                constrainSquare: spaceMove == nil
            )
            refreshLoupe(global: current)
            if next.type == .leftMouseUp {
                session.endDrag(screenID: displayID)
                layoutActionBar()
                refreshLoupe(global: current)
                return
            }
        }
    }

    private func trackAdjustment(from event: NSEvent) {
        defer {
            dragCursor = nil
            refreshCursor()
        }
        var lastMouse = globalPoint(from: event)
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .keyDown, .keyUp]
        while true {
            guard let current = window?.nextEvent(matching: mask, until: .distantFuture, inMode: .default, dequeue: true) else {
                return
            }
            if current.type == .keyDown, current.keyCode == CaptureKeyCode.escape {
                session.cancel()
                return
            }
            if current.type == .keyDown, current.keyCode == CaptureKeyCode.space, !current.isARepeat {
                session.beginAdjustment(handle: .move, at: lastMouse)
                dragCursor = .closedHand
                refreshCursor()
                continue
            }
            if current.type == .keyDown || current.type == .keyUp {
                continue
            }
            lastMouse = globalPoint(from: current)
            session.updateAdjustment(
                to: lastMouse,
                snapEnabled: !current.modifierFlags.contains(.control)
            )
            refreshLoupe(global: lastMouse)
            if current.type == .leftMouseUp {
                session.endAdjustment()
                layoutActionBar()
                refreshLoupe(global: lastMouse)
                return
            }
        }
    }

    private func publish(
        anchor: CGPoint,
        current: CGPoint,
        flags: NSEvent.ModifierFlags,
        snapEnabled: Bool,
        constrainSquare: Bool = true
    ) {
        session.updateDrag(
            metrics: metrics,
            anchor: anchor,
            current: current,
            constrainSquare: constrainSquare && flags.contains(.shift),
            snapEnabled: snapEnabled
        )
    }

    private func globalPoint(from event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        return CGPoint(x: screenFrame.minX + location.x, y: screenFrame.minY + location.y)
    }

    private func installActionBar() {
        barContainer.material = .hudWindow
        barContainer.blendingMode = .behindWindow
        barContainer.state = .active
        barContainer.wantsLayer = true
        barContainer.layer?.cornerRadius = 10
        barContainer.layer?.zPosition = 5
        barContainer.isHidden = true
        // Give the effect view its real size before pinning an Auto Layout
        // stack inside it; a zero-width autoresizing constraint would conflict.
        barContainer.frame = NSRect(origin: .zero, size: SelectionGeometry.actionBarSize)
        addSubview(barContainer)

        let buttons = [scrollButton, annotateButton, copyButton, saveButton, precisionButton, cancelButton]
        for button in buttons {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.momentaryPushIn)
        }
        scrollButton.action = #selector(scrollClicked)
        scrollButton.bezelColor = .controlAccentColor
        annotateButton.action = #selector(annotateClicked)
        copyButton.action = #selector(copyClicked)
        copyButton.bezelColor = .controlAccentColor
        saveButton.action = #selector(saveClicked)
        precisionButton.action = #selector(precisionClicked)
        cancelButton.action = #selector(cancelClicked)

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.distribution = .fillEqually
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: barContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
        ])
    }

    private func apply(phase next: CapturePhase) {
        laidOutPhase = next
        if !next.showsActionBar {
            laidOutPreview = nil
            closePrecisionPopover()
        }
        layoutDim()
        layoutActionBar()
        layoutAnnotationCanvas()
        window?.invalidateCursorRects(for: self)
        refreshCursor()
        refreshLoupeAtMouse()
    }

    private struct DisplaySelection {
        var metrics: DisplayMetrics
        var pixelRect: PixelRect
        var label: String
        var showsHandles: Bool
    }

    private func layoutDim() {
        guard let current = previewSelection() ?? currentSelection() else {
            dim.setHole(nil)
            chrome.update(rect: .zero, label: "", handles: [])
            return
        }
        let global = current.metrics.globalRect(for: current.pixelRect)
        let local = SelectionGeometry.displayLocalRect(selection: global, screenFrame: screenFrame)
        guard local.width > 0, local.height > 0 else {
            dim.setHole(nil)
            chrome.update(rect: .zero, label: "", handles: [])
            return
        }
        dim.setHole(local)
        let appKit = CGRect(
            x: global.minX - screenFrame.minX,
            y: global.minY - screenFrame.minY,
            width: global.width,
            height: global.height
        )
        let handles = current.showsHandles
            ? SelectionGeometry.handleAnchors(in: global).map {
                CGPoint(x: $0.1.x - screenFrame.minX, y: $0.1.y - screenFrame.minY)
            }
            : []
        chrome.update(
            rect: appKit,
            label: current.label,
            handles: handles
        )
    }

    private func previewSelection() -> DisplaySelection? {
        guard let preview = laidOutPreview,
              case .actionBar(let selection) = laidOutPhase,
              selection.screenID == displayID else { return nil }
        return DisplaySelection(
            metrics: selection.metrics,
            pixelRect: preview,
            label: SelectionGeometry.pixelSizeLabel(pixelRect: preview),
            showsHandles: false
        )
    }

    private func currentSelection() -> DisplaySelection? {
        switch laidOutPhase {
        case .selecting(let drag?):
            guard drag.screenID == displayID else { return nil }
            return DisplaySelection(
                metrics: drag.metrics,
                pixelRect: drag.pixelRect,
                label: SelectionGeometry.pixelSizeLabel(pixelRect: drag.pixelRect),
                showsHandles: false
            )
        case .actionBar(let selection):
            guard selection.screenID == displayID else { return nil }
            return DisplaySelection(
                metrics: selection.metrics,
                pixelRect: selection.pixelRect,
                label: SelectionGeometry.pixelSizeLabel(pixelRect: selection.pixelRect),
                showsHandles: true
            )
        case .editing(let selection), .working(let selection):
            guard selection.screenID == displayID else { return nil }
            return DisplaySelection(
                metrics: selection.metrics,
                pixelRect: selection.pixelRect,
                label: SelectionGeometry.pixelSizeLabel(pixelRect: selection.pixelRect),
                showsHandles: false
            )
        case .windowPicking(let hover?):
            guard hover.screenID == displayID else { return nil }
            return DisplaySelection(
                metrics: hover.metrics,
                pixelRect: hover.pixelRect,
                label: hover.title,
                showsHandles: false
            )
        default:
            return nil
        }
    }

    private func layoutActionBar() {
        guard laidOutPhase.showsActionBar,
              case .actionBar(let selection) = laidOutPhase,
              selection.screenID == displayID else {
            barContainer.isHidden = true
            closePrecisionPopover()
            refreshLoupeAtMouse()
            return
        }
        let local = SelectionGeometry.displayLocalRect(
            selection: selection.globalRect,
            screenFrame: screenFrame
        )
        let frame = SelectionGeometry.actionBarFrame(
            selection: local,
            screenSize: screenFrame.size,
            barSize: SelectionGeometry.actionBarSize,
            margin: SelectionGeometry.actionBarMargin
        )
        let scrolling = laidOutScrollIntent
        scrollButton.isHidden = !scrolling
        annotateButton.isHidden = scrolling
        copyButton.isHidden = scrolling
        saveButton.isHidden = scrolling
        precisionButton.isHidden = false
        barContainer.isHidden = false
        barContainer.frame = NSRect(
            x: frame.minX,
            y: bounds.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        refreshLoupeAtMouse()
    }

    private func refreshLoupeAtMouse() {
        guard let window, window.isVisible else {
            hideLoupe()
            return
        }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else {
            hideLoupe()
            return
        }
        updateLoupe(atLocal: local)
    }

    private func refreshLoupe(global: CGPoint) {
        updateLoupe(atLocal: CGPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY))
    }

    private func updateLoupe(atLocal local: CGPoint) {
        // The loupe is a drawing aid for the initial drag. Once the selection
        // exists the border, handles, and precision fields are enough.
        guard laidOutShowLoupe,
              laidOutPhase.isSelecting,
              precisionPopover?.isShown != true,
              let image = session.snapshot(for: displayID) else {
            hideLoupe()
            return
        }
        if !barContainer.isHidden, barContainer.frame.contains(local) {
            hideLoupe()
            return
        }
        let global = CGPoint(x: screenFrame.minX + local.x, y: screenFrame.minY + local.y)
        let pixel = metrics.pixelPoint(for: global)
        loupe.update(
            source: image,
            focus: pixel,
            selection: currentSelection()?.pixelRect,
            sourcePixelSize: metrics.pixelSize
        )
        var loupeFrame = LoupeGeometry.frame(
            cursor: local,
            size: LoupeView.contentSize,
            bounds: bounds
        )
        // The loupe follows the mouse at fractional points. Landing on half a
        // device pixel blurs the 1px grid and the magnified pixels, so snap the
        // frame to the backing store before showing it.
        if let scale = window?.backingScaleFactor {
            loupeFrame = LoupeGeometry.alignedToBackingStore(loupeFrame, scale: scale)
        }
        loupe.frame = loupeFrame
        loupe.isHidden = false
    }

    private func hideLoupe() {
        loupe.isHidden = true
    }

    private func closePrecisionPopover() {
        precisionPopover?.close()
        precisionPopover = nil
    }

    @objc private func precisionClicked() {
        guard case .actionBar(let selection) = session.phase else { return }
        closePrecisionPopover()
        let controller = PrecisionFieldsViewController(metrics: selection.metrics, rect: selection.pixelRect)
        controller.onPreview = { [weak self] rect in
            self?.session.previewSelection(rect)
        }
        controller.onApply = { [weak self] rect in
            self?.session.previewSelection(nil)
            self?.session.setSelection(pixelRect: rect)
            self?.closePrecisionPopover()
            self?.refreshLoupeAtMouse()
        }
        controller.onCancel = { [weak self] in
            self?.session.previewSelection(nil)
            self?.closePrecisionPopover()
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self
        precisionPopover = popover
        hideLoupe()
        popover.show(relativeTo: precisionButton.bounds, of: precisionButton, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        session.previewSelection(nil)
        if (notification.object as? NSPopover) === precisionPopover {
            precisionPopover = nil
        }
    }

    private func layoutAnnotationCanvas() {
        guard let canvas = annotationCanvas else { return }
        guard laidOutPhase.isEditing,
              case .editing(let selection) = laidOutPhase,
              selection.screenID == displayID else {
            canvas.isHidden = true
            canvas.toolbarView.isHidden = true
            return
        }
        canvas.frame = bounds
        canvas.placeToolbar(in: bounds, selection: selection)
        canvas.needsDisplay = true
        canvas.isHidden = false
        barContainer.isHidden = true
        closePrecisionPopover()
        hideLoupe()
    }

    @objc private func scrollClicked() {
        session.startScrollStitch()
    }

    @objc private func annotateClicked() {
        session.beginAnnotation()
    }

    @objc private func copyClicked() {
        session.copySelection()
    }

    @objc private func saveClicked() {
        session.saveSelection()
    }

    @objc private func cancelClicked() {
        closePrecisionPopover()
        hideLoupe()
        session.cancel()
    }
}
