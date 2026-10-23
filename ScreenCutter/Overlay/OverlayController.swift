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
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView = SelectionTrackingView(session: session, screen: screen)
            window.setFrame(screen.frame, display: true)
            windows.append(window)
        }

        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        for window in windows {
            window.orderFrontRegardless()
        }
        keyWindow?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
    }

    func show() {
        NSApp.activate()
        for window in windows {
            window.orderFrontRegardless()
        }
        windows.first?.makeKey()
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    func showHUD(_ message: String, screenFrame: CGRect) {
        hud.show(message, screenFrame: screenFrame)
    }
}
