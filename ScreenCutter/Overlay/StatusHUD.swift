import AppKit

@MainActor
final class StatusHUD {
    private var window: NSWindow?
    private var dismiss: DispatchWorkItem?

    func show(_ message: String, screenFrame: CGRect) {
        dismiss?.cancel()
        window?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        let textSize = label.intrinsicContentSize
        let size = NSSize(width: textSize.width + 32, height: textSize.height + 16)
        let frame = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let panel = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = 8
        label.frame = NSRect(x: 16, y: 8, width: textSize.width, height: textSize.height)
        container.addSubview(label)
        panel.contentView = container
        panel.orderFrontRegardless()
        window = panel

        let work = DispatchWorkItem { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.window = nil
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
