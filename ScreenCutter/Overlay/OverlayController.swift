import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private let hud = StatusHUD()

    func present(session: CaptureSession) {
        close()
        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView = SelectionTrackingView(session: session, screen: screen)
            window.setFrame(screen.frame, display: true)
            windows.append(window)
        }

        // The overlay must take focus even when another app is interacting;
        // `activate()` alone is cooperative and may not activate the app.
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        for window in windows {
            window.orderFrontRegardless()
        }
        keyWindow?.makeKeyAndOrderFront(nil)
        refreshCursors()
        // Activation can finish after the window becomes key and reset the
        // cursor; reapply once the run loop has processed it.
        DispatchQueue.main.async { [weak self] in
            self?.refreshCursors()
        }
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
        NSCursor.arrow.set()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        refreshCursors()
        DispatchQueue.main.async { [weak self] in
            self?.refreshCursors()
        }
    }

    private func refreshCursors() {
        for window in windows {
            (window.contentView as? SelectionTrackingView)?.refreshCursor()
        }
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        NSCursor.arrow.set()
    }

    func showHUD(_ message: String, screenFrame: CGRect) {
        hud.show(message, screenFrame: screenFrame)
    }
}
