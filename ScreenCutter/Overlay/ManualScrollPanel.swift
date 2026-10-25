import AppKit

/// Floating controls for manual scrolling. The panel never activates the app,
/// so the window under the selection keeps the user's scroll wheel. Every window
/// owned by this process is excluded from `ScreenCaptureService.capture`, so the
/// panel cannot leak into the stitched image.
@MainActor
final class ManualScrollPanel {
    private final class PanelWindow: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// A non-key window normally swallows the click that would activate it.
    /// Buttons that need to work on the first click opt in here.
    private final class FirstMouseButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private static let size = CGSize(width: 360, height: 126)

    private var panel: PanelWindow?
    private var onFinish: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var isEnding = false

    private let titleLabel = NSTextField(labelWithString: "手动滚动")
    private let instructionLabel = NSTextField(labelWithString: "在选区里向下滚，停一下再继续；完成后点「完成」。")
    private let statusLabel = NSTextField(labelWithString: "已就绪")
    private let finishButton = FirstMouseButton(title: "完成", target: nil, action: nil)
    private let cancelButton = FirstMouseButton(title: "取消", target: nil, action: nil)

    func show(
        selection: ScreenSelection,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        close()
        self.onFinish = onFinish
        self.onCancel = onCancel
        statusLabel.stringValue = "已就绪"
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        finishButton.isEnabled = true
        cancelButton.isEnabled = true

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 16, y: 94, width: 328, height: 18)

        instructionLabel.font = .systemFont(ofSize: 11)
        instructionLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        instructionLabel.lineBreakMode = .byTruncatingTail
        instructionLabel.frame = NSRect(x: 16, y: 72, width: 328, height: 16)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 16, y: 48, width: 328, height: 16)

        for button in [finishButton, cancelButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.momentaryPushIn)
            button.target = self
        }
        finishButton.action = #selector(finishClicked)
        finishButton.bezelColor = .controlAccentColor
        finishButton.keyEquivalent = "\r"
        finishButton.frame = NSRect(x: 286, y: 10, width: 58, height: 26)

        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 220, y: 10, width: 58, height: 26)

        effect.addSubview(titleLabel)
        effect.addSubview(instructionLabel)
        effect.addSubview(statusLabel)
        effect.addSubview(cancelButton)
        effect.addSubview(finishButton)

        let panel = PanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = effect
        panel.setFrame(frame(for: selection), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(_ progress: ManualScrollProgress) {
        guard panel != nil, !isEnding else { return }
        if progress.isFinishing {
            statusLabel.stringValue = "正在完成…"
            statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
            return
        }
        if let hint = progress.hint {
            statusLabel.stringValue = hint
            statusLabel.textColor = .systemOrange
            return
        }
        if progress.segments == 0 {
            statusLabel.stringValue = "起点 \(progress.height) px · 等待滚动"
        } else {
            statusLabel.stringValue = "已拼接 \(progress.segments) 段 · 高 \(progress.height) px"
        }
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        onFinish = nil
        onCancel = nil
        isEnding = false
    }

    private func markEnding(_ message: String) {
        guard !isEnding else { return }
        isEnding = true
        statusLabel.stringValue = message
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        finishButton.isEnabled = false
        cancelButton.isEnabled = false
    }

    private func frame(for selection: ScreenSelection) -> NSRect {
        let screen = selection.screenFrame
        let selectionRect = selection.globalRect
        let margin: CGFloat = 12
        var x = selectionRect.maxX - Self.size.width
        var y = selectionRect.minY - Self.size.height - margin
        if y < screen.minY + 8 {
            y = selectionRect.maxY + margin
        }
        let maximumX = max(screen.minX + 8, screen.maxX - Self.size.width - 8)
        let maximumY = max(screen.minY + 8, screen.maxY - Self.size.height - 8)
        x = min(max(x, screen.minX + 8), maximumX)
        y = min(max(y, screen.minY + 8), maximumY)
        return NSRect(x: x, y: y, width: Self.size.width, height: Self.size.height)
    }

    @objc private func finishClicked() {
        markEnding("正在完成…")
        onFinish?()
    }

    @objc private func cancelClicked() {
        markEnding("正在取消…")
        onCancel?()
    }
}
