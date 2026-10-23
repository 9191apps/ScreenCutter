import AppKit
import Combine
import SwiftUI

final class SelectionTrackingView: NSView {
    let session: CaptureSession
    let screenFrame: CGRect
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    private let hosting: NSHostingView<SelectionOverlayView>
    private let barContainer = NSVisualEffectView()
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var phaseObservation: AnyCancellable?

    init(session: CaptureSession, screen: NSScreen) {
        self.session = session
        screenFrame = screen.frame
        scale = screen.backingScaleFactor
        displayID = screen.displayID
        hosting = NSHostingView(rootView: SelectionOverlayView(
            session: session,
            screenFrame: screen.frame,
            scale: screen.backingScaleFactor,
            displayID: screen.displayID
        ))
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addSubview(hosting)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        installActionBar()
        phaseObservation = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.layoutActionBar()
            }
        }
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
        if session.phase.isSelecting {
            return self
        }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        if session.phase.showsActionBar {
            let global = globalPoint(from: event)
            if case .actionBar(let selection) = session.phase, !selection.globalRect.contains(global) {
                session.cancel()
            }
            return
        }
        guard session.phase.isSelecting else { return }
        trackDrag(from: event)
    }

    private func trackDrag(from event: NSEvent) {
        let anchor = globalPoint(from: event)
        publish(anchor: anchor, current: anchor, flags: event.modifierFlags)
        while true {
            guard session.phase.isSelecting else { return }
            guard let current = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: .distantFuture,
                inMode: .default,
                dequeue: true
            ) else { return }

            if current.type == .keyDown, current.keyCode == CaptureKeyCode.escape {
                session.cancel()
                return
            }
            publish(
                anchor: anchor,
                current: globalPoint(from: current),
                flags: current.modifierFlags
            )
            if current.type == .leftMouseUp {
                session.endDrag(screenID: displayID)
                layoutActionBar()
                return
            }
        }
    }

    private func publish(anchor: CGPoint, current: CGPoint, flags: NSEvent.ModifierFlags) {
        session.updateDrag(
            screenID: displayID,
            screenFrame: screenFrame,
            scale: scale,
            anchor: anchor,
            current: current,
            constrainSquare: flags.contains(.shift)
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
        barContainer.isHidden = true
        addSubview(barContainer)

        let buttons = [copyButton, saveButton, cancelButton]
        for button in buttons {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.momentaryPushIn)
        }
        copyButton.action = #selector(copyClicked)
        copyButton.bezelColor = .controlAccentColor
        saveButton.action = #selector(saveClicked)
        cancelButton.action = #selector(cancelClicked)

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: barContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
        ])
    }

    private func layoutActionBar() {
        guard session.phase.showsActionBar,
              case .actionBar(let selection) = session.phase,
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
        barContainer.isHidden = false
        barContainer.frame = NSRect(
            x: frame.minX,
            y: bounds.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
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
