import SwiftUI

/// Menu key equivalents are only for displaying and triggering a shortcut while
/// the menu is open. Global handling still comes from the Carbon hot key.
extension HotKeyChord {
    var menuShortcut: (key: KeyEquivalent, modifiers: EventModifiers)? {
        guard let key = menuKeyEquivalent else { return nil }
        return (key, eventModifiers)
    }

    private var menuKeyEquivalent: KeyEquivalent? {
        switch keyCode {
        case 36, 76: return .return
        case 48: return .tab
        case 49: return .space
        case 51, 117: return .delete
        case 53: return .escape
        case 115: return .home
        case 116: return .pageUp
        case 119: return .end
        case 121: return .pageDown
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default: break
        }
        let label = HotKeyChord.keyLabel(for: keyCode)
        guard label.count == 1, let character = label.lowercased().first else { return nil }
        return KeyEquivalent(character)
    }

    private var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if carbonModifiers & Self.commandCarbon != 0 { modifiers.insert(.command) }
        if carbonModifiers & Self.shiftCarbon != 0 { modifiers.insert(.shift) }
        if carbonModifiers & Self.optionCarbon != 0 { modifiers.insert(.option) }
        if carbonModifiers & Self.controlCarbon != 0 { modifiers.insert(.control) }
        return modifiers
    }
}

extension View {
    /// Attaches the chord as a menu key equivalent when it can be represented.
    func hotKeyMenuShortcut(_ chord: HotKeyChord?) -> some View {
        modifier(HotKeyMenuShortcutModifier(chord: chord))
    }
}

private struct HotKeyMenuShortcutModifier: ViewModifier {
    var chord: HotKeyChord?

    func body(content: Content) -> some View {
        if let shortcut = chord?.menuShortcut {
            content.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            content
        }
    }
}
