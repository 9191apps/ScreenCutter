import AppKit
import Combine

final class SelectionTrackingView: NSView {
    let session: CaptureSession
    let screenFrame: CGRect
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    private let dim = DimMaskView(frame: .zero)
    private let chrome = SelectionChromeView(frame: .zero)
    private let barContainer = NSVisualEffectView()
    private let annotateButton = NSButton(title: "标注", target: nil, action: nil)
    private let scrollButton = NSButton(title: "开始滚动", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private var annotationCanvas: AnnotationCanvasView?
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var observations: [AnyCancellable] = []
    private var trackingArea: NSTrackingArea?
    /// The phase this overlay last laid out for.
    /// `@Published` emits during `willSet`, so reading `session.phase` from the
    /// subscription would see the previous value. The publisher's value is the
    /// only reliable snapshot at layout time.
    private var laidOutPhase: CapturePhase = .idle

    init(session: CaptureSession, screen: NSScreen) {
        self.session = session
        screenFrame = screen.frame
        scale = screen.backingScaleFactor
        displayID = screen.displayID
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        laidOutPhase = session.phase
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
        observations = [
            session.$phase.sink { [weak self] next in
                self?.apply(phase: next)
            },
            session.$scrollIntent.sink { [weak self] _ in
                self?.layoutActionBar()
            },
        ]
        layoutDim()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    override func resetCursorRects() {
        let cursor: NSCursor = laidOutPhase.isPickingWindow ? .pointingHand : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard session.phase.isPickingWindow else { return }
        session.updateWindowHover(
            at: globalPoint(from: event),
            screenID: displayID,
            screenFrame: screenFrame,
            scale: scale
        )
    }

    override func mouseDown(with event: NSEvent) {
        if session.phase.isPickingWindow {
            session.confirmWindow(
                at: globalPoint(from: event),
                screenID: displayID,
                screenFrame: screenFrame,
                scale: scale
            )
            layoutActionBar()
            return
        }
        if session.phase.showsActionBar {
            let global = globalPoint(from: event)
            if case .actionBar(let selection) = session.phase,
               let handle = SelectionGeometry.hitHandle(point: global, in: selection.globalRect) {
                session.beginAdjustment(handle: handle, at: global)
                trackAdjustment(from: event)
                return
            }
            if case .actionBar(let selection) = session.phase, !selection.globalRect.contains(global) {
                session.cancel()
            }
            return
        }
        guard session.phase.isSelecting else { return }
        trackDrag(from: event)
    }

    private func trackDrag(from event: NSEvent) {
        var anchor = globalPoint(from: event)
        var current = anchor
        var lastMouse = anchor
        var spaceMove: (anchor: CGPoint, current: CGPoint, mouse: CGPoint)?
        publish(anchor: anchor, current: current, flags: event.modifierFlags)
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
                continue
            }
            if next.type == .keyUp, next.keyCode == CaptureKeyCode.space {
                spaceMove = nil
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
            publish(anchor: anchor, current: current, flags: next.modifierFlags, constrainSquare: spaceMove == nil)
            if next.type == .leftMouseUp {
                session.endDrag(screenID: displayID)
                layoutActionBar()
                return
            }
        }
    }

    private func trackAdjustment(from event: NSEvent) {
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
                continue
            }
            if current.type == .keyDown || current.type == .keyUp {
                continue
            }
            lastMouse = globalPoint(from: current)
            session.updateAdjustment(to: lastMouse)
            if current.type == .leftMouseUp {
                session.endAdjustment()
                layoutActionBar()
                return
            }
        }
    }

    private func publish(
        anchor: CGPoint,
        current: CGPoint,
        flags: NSEvent.ModifierFlags,
        constrainSquare: Bool = true
    ) {
        session.updateDrag(
            screenID: displayID,
            screenFrame: screenFrame,
            scale: scale,
            anchor: anchor,
            current: current,
            constrainSquare: constrainSquare && flags.contains(.shift)
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

        let buttons = [scrollButton, annotateButton, copyButton, saveButton, cancelButton]
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
        layoutDim()
        layoutActionBar()
        layoutAnnotationCanvas()
        window?.invalidateCursorRects(for: self)
    }

    private func layoutDim() {
        guard let current = currentSelection() else {
            dim.setHole(nil)
            chrome.update(rect: .zero, label: "", handles: [])
            return
        }
        let local = SelectionGeometry.displayLocalRect(selection: current.global, screenFrame: screenFrame)
        guard local.width > 0, local.height > 0 else {
            dim.setHole(nil)
            chrome.update(rect: .zero, label: "", handles: [])
            return
        }
        dim.setHole(local)
        let appKit = CGRect(
            x: current.global.minX - screenFrame.minX,
            y: current.global.minY - screenFrame.minY,
            width: current.global.width,
            height: current.global.height
        )
        let handles = current.showsHandles
            ? SelectionGeometry.handleAnchors(in: current.global).map {
                CGPoint(x: $0.1.x - screenFrame.minX, y: $0.1.y - screenFrame.minY)
            }
            : []
        chrome.update(rect: appKit, label: current.label, handles: handles)
    }

    private func currentSelection() -> (global: CGRect, label: String, showsHandles: Bool)? {
        switch laidOutPhase {
        case .selecting(let drag?):
            guard drag.screenID == displayID else { return nil }
            return (drag.globalRect, SelectionGeometry.pixelSizeLabel(globalRect: drag.globalRect, scale: drag.scale), false)
        case .actionBar(let selection):
            guard selection.screenID == displayID else { return nil }
            return (selection.globalRect, SelectionGeometry.pixelSizeLabel(globalRect: selection.globalRect, scale: selection.scale), true)
        case .editing(let selection), .working(let selection):
            guard selection.screenID == displayID else { return nil }
            return (selection.globalRect, SelectionGeometry.pixelSizeLabel(globalRect: selection.globalRect, scale: selection.scale), false)
        case .windowPicking(let hover?):
            guard hover.screenID == displayID else { return nil }
            return (hover.globalRect, hover.title, false)
        default:
            return nil
        }
    }

    private func layoutActionBar() {
        guard laidOutPhase.showsActionBar,
              case .actionBar(let selection) = laidOutPhase,
              selection.screenID == displayID else {
            barContainer.isHidden = true
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
        let scrolling = session.scrollIntent
        scrollButton.isHidden = !scrolling
        annotateButton.isHidden = scrolling
        copyButton.isHidden = scrolling
        saveButton.isHidden = scrolling
        barContainer.isHidden = false
        barContainer.frame = NSRect(
            x: frame.minX,
            y: bounds.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
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
        session.cancel()
    }
}
