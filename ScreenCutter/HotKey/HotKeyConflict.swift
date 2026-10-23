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

    var menuDetail: String? {
        switch self {
        case .none:
            return nil
        case .systemShortcut:
            return "⌘⇧2 与系统快捷键冲突"
        case .otherApplication:
            return "⌘⇧2 已被其他应用占用"
        }
    }

    var alertMessage: String? {
        switch self {
        case .none:
            return nil
        case .systemShortcut:
            return "⌘⇧2 与系统快捷键冲突。截屏仍可从菜单「截取区域」开始。"
        case .otherApplication:
            return "⌘⇧2 已被其他应用占用。截屏仍可从菜单「截取区域」开始。"
        }
    }
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

    static func resolve(entries: [SymbolicHotKeyEntry], carbonStatus: Int32?) -> HotKeyConflict {
        if hasSystemConflict(in: entries) {
            return .systemShortcut
        }
        guard let carbonStatus else { return .none }
        if carbonStatus == 0 {
            return .none
        }
        return .otherApplication
    }

    private static func hasSystemConflict(in entries: [SymbolicHotKeyEntry]) -> Bool {
        entries.contains { entry in
            entry.enabled
                && entry.keyCode == captureKeyCode
                && (entry.modifiers & relevantModifiers) == captureModifiers
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
