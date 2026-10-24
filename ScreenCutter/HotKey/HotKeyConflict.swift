import Foundation

struct SymbolicHotKeyEntry: Equatable, Sendable {
    var enabled: Bool
    var keyCode: Int
    var modifiers: UInt
}

nonisolated enum HotKeyConflict: Equatable, Sendable {
    case none
    case systemShortcut
    case otherApplication

    func menuDetail(for chord: HotKeyChord) -> String? {
        switch self {
        case .none:
            return nil
        case .systemShortcut:
            return "\(chord.display) 与系统快捷键冲突"
        case .otherApplication:
            return "\(chord.display) 已被其他应用占用"
        }
    }

    func alertMessage(for chord: HotKeyChord) -> String? {
        switch self {
        case .none:
            return nil
        case .systemShortcut:
            return "\(chord.display) 与系统快捷键冲突。截屏仍可从菜单开始。"
        case .otherApplication:
            return "\(chord.display) 已被其他应用占用。截屏仍可从菜单开始。"
        }
    }
}

nonisolated struct HotKeyChord: Equatable, Sendable {
    var keyCode: Int
    var carbonModifiers: UInt32

    static let commandCarbon: UInt32 = 1 << 8
    static let shiftCarbon: UInt32 = 1 << 9
    static let optionCarbon: UInt32 = 1 << 11
    static let controlCarbon: UInt32 = 1 << 12

    static let regionCapture = HotKeyChord(
        keyCode: HotKeyConflictChecker.captureKeyCode,
        carbonModifiers: commandCarbon | shiftCarbon
    )

    /// Option-Shift-3. System screenshots already own Command-Shift-3/4/5.
    static let fullScreen = HotKeyChord(
        keyCode: 20,
        carbonModifiers: optionCarbon | shiftCarbon
    )

    /// Option-Shift-4.
    static let window = HotKeyChord(
        keyCode: 21,
        carbonModifiers: optionCarbon | shiftCarbon
    )

    var symbolicModifiers: UInt {
        var modifiers: UInt = 0
        if carbonModifiers & Self.commandCarbon != 0 { modifiers |= HotKeyConflictChecker.commandModifier }
        if carbonModifiers & Self.shiftCarbon != 0 { modifiers |= HotKeyConflictChecker.shiftModifier }
        if carbonModifiers & Self.optionCarbon != 0 { modifiers |= HotKeyConflictChecker.optionModifier }
        if carbonModifiers & Self.controlCarbon != 0 { modifiers |= HotKeyConflictChecker.controlModifier }
        return modifiers
    }

    var hasCommandOptionOrControl: Bool {
        carbonModifiers & (Self.commandCarbon | Self.optionCarbon | Self.controlCarbon) != 0
    }

    var display: String {
        var label = ""
        if carbonModifiers & Self.controlCarbon != 0 { label += "⌃" }
        if carbonModifiers & Self.optionCarbon != 0 { label += "⌥" }
        if carbonModifiers & Self.shiftCarbon != 0 { label += "⇧" }
        if carbonModifiers & Self.commandCarbon != 0 { label += "⌘" }
        label += Self.keyLabel(for: keyCode)
        return label
    }

    static func keyLabel(for keyCode: Int) -> String {
        labels[keyCode] ?? "#\(keyCode)"
    }

    private static let labels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space",
        36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
    ]
}

nonisolated enum HotKeyStore {
    private static let keyCodeKey = "regionHotKey.keyCode"
    private static let modifiersKey = "regionHotKey.carbonModifiers"

    static func loadRegion(from defaults: UserDefaults = .standard) -> HotKeyChord {
        guard defaults.object(forKey: keyCodeKey) != nil else { return .regionCapture }
        return HotKeyChord(
            keyCode: defaults.integer(forKey: keyCodeKey),
            carbonModifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }

    static func saveRegion(_ chord: HotKeyChord, to defaults: UserDefaults = .standard) {
        defaults.set(chord.keyCode, forKey: keyCodeKey)
        defaults.set(Int(chord.carbonModifiers), forKey: modifiersKey)
    }

    static func isEnabled(_ id: UInt32, defaults: UserDefaults = .standard) -> Bool {
        let key = enabledKey(id)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ id: UInt32, _ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey(id))
    }

    private static func enabledKey(_ id: UInt32) -> String {
        "hotKey.\(id).enabled"
    }
}

nonisolated struct HotKeyRegistration: Equatable, Sendable {
    var id: UInt32
    var chord: HotKeyChord
}

nonisolated enum HotKeySlotID {
    static let region: UInt32 = 1
    static let fullScreen: UInt32 = 2
    static let window: UInt32 = 3
}

nonisolated enum HotKeyConflictChecker {
    static let captureKeyCode = 19
    static let commandModifier: UInt = 1 << 20
    static let shiftModifier: UInt = 1 << 17
    static let optionModifier: UInt = 1 << 19
    static let controlModifier: UInt = 1 << 18
    static let relevantModifiers = commandModifier | shiftModifier | optionModifier | controlModifier
    static let captureModifiers = commandModifier | shiftModifier
    static let carbonHotKeyExists: Int32 = -9878

    static func loadSystemEntries() -> [SymbolicHotKeyEntry] {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let raw = defaults.dictionary(forKey: "AppleSymbolicHotKeys") else {
            return []
        }
        return parse(raw)
    }

    static func parse(_ raw: [String: Any]) -> [SymbolicHotKeyEntry] {
        raw.values.compactMap(entry(from:))
    }

    static func resolve(
        entries: [SymbolicHotKeyEntry],
        carbonStatus: Int32?,
        chord: HotKeyChord = .regionCapture
    ) -> HotKeyConflict {
        if hasSystemConflict(in: entries, chord: chord) {
            return .systemShortcut
        }
        guard let carbonStatus else { return .none }
        if carbonStatus == 0 {
            return .none
        }
        return .otherApplication
    }

    private static func hasSystemConflict(in entries: [SymbolicHotKeyEntry], chord: HotKeyChord) -> Bool {
        entries.contains { entry in
            entry.enabled
                && entry.keyCode == chord.keyCode
                && (entry.modifiers & relevantModifiers) == chord.symbolicModifiers
        }
    }

    private static func entry(from value: Any) -> SymbolicHotKeyEntry? {
        guard let item = dictionary(value),
              let payload = dictionary(item["value"] as Any),
              let parameters = parameterList(payload["parameters"] as Any),
              parameters.count >= 3,
              let keyCode = integer(parameters[1]),
              let modifiers = unsigned(parameters[2]) else {
            return nil
        }
        return SymbolicHotKeyEntry(
            enabled: boolean(item["enabled"] as Any),
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    private static func dictionary(_ value: Any) -> [String: Any]? {
        if let value = value as? [String: Any] {
            return value
        }
        if let value = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, entry) in value {
                guard let key = key as? String else { continue }
                result[key] = entry
            }
            return result
        }
        return nil
    }

    private static func parameterList(_ value: Any) -> [Any]? {
        if let value = value as? [Int] {
            return value.map { $0 as Any }
        }
        if let value = value as? [NSNumber] {
            return value.map { $0 as Any }
        }
        if let value = value as? [Any] {
            return value
        }
        if let value = value as? NSArray {
            return value.map { $0 as Any }
        }
        return nil
    }

    private static func boolean(_ value: Any) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private static func integer(_ value: Any) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func unsigned(_ value: Any) -> UInt? {
        if let value = value as? UInt {
            return value
        }
        if let value = value as? Int {
            return UInt(value)
        }
        if let value = value as? NSNumber {
            return value.uintValue
        }
        return nil
    }
}
