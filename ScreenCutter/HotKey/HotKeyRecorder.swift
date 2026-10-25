import AppKit

enum HotKeyRecorder {
    /// Shows a modal recorder. `suspend` runs before the panel appears so the
    /// key press being recorded cannot trigger an existing global hot key;
    /// `resume` always runs afterwards.
    static func capture(
        title: String = "更改快捷键",
        suspend: () -> Void = {},
        resume: () -> Void = {}
    ) -> HotKeyChord? {
        suspend()
        defer { resume() }
        let panel = HotKeyCaptureWindow(title: title)
        let previous = NSApp.activationPolicy()
        // The recorder may be opened from the Settings window. Remember it so
        // closing the modal returns the user to where they started.
        let previousKeyWindow = NSApp.keyWindow
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        NSApp.setActivationPolicy(previous)
        if let previousKeyWindow {
            previousKeyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return panel.chord
    }
}

private final class HotKeyCaptureWindow: NSWindow {
    var chord: HotKeyChord?

    init(title: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 88),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        self.title = title
        let label = NSTextField(wrappingLabelWithString: "按下新的快捷键。需要包含 ⌘、⌥ 或 ⌃。Esc 取消。")
        label.frame = NSRect(x: 16, y: 16, width: 288, height: 56)
        contentView = label
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == CaptureKeyCode.escape {
            NSApp.stopModal()
            return
        }
        let ignored: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if ignored.contains(event.keyCode) { return }
        let candidate = HotKeyChord(event: event)
        guard candidate.hasCommandOptionOrControl else {
            NSSound.beep()
            return
        }
        chord = candidate
        NSApp.stopModal()
    }
}

extension HotKeyChord {
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Self.commandCarbon }
        if flags.contains(.shift) { modifiers |= Self.shiftCarbon }
        if flags.contains(.option) { modifiers |= Self.optionCarbon }
        if flags.contains(.control) { modifiers |= Self.controlCarbon }
        self.init(keyCode: Int(event.keyCode), carbonModifiers: modifiers)
    }
}
