import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Small, dependency-free helpers for driving the real ScreenCutter app.
/// This is not part of the Xcode project or the test scheme; build it with
/// `scripts/e2e/build.sh` and run it only with `E2E=1`.
@main
struct E2ETools {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage() }
        args.removeFirst()

        switch command {
        case "check-permissions": checkPermissions()
        case "screens": screens()
        case "key": key(args)
        case "type": type(args)
        case "move": move(args)
        case "click": click(args)
        case "drag": drag(args)
        case "screenshot": screenshot(args)
        case "windows": windows(args)
        case "overlay-window": overlayWindow(args)
        case "ax-dump": axDump(args)
        case "ax-exists": axExists(args)
        case "ax-press": axPress(args)
        case "frontmost": frontmost(args)
        case "pb-dump": pbDump(args)
        case "pb-restore": pbRestore(args)
        case "pb-save-image": pbSaveImage(args)
        case "help", "-h", "--help": usage()
        default:
            FileHandle.standardError.write(Data(("unknown command: \(command)\n").utf8))
            usage()
        }
    }

    // MARK: - Permissions and display

    private static func checkPermissions() {
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let sessionLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let loginwindow = frontmost?.bundleIdentifier == "com.apple.loginwindow"
        print("accessibility=\(accessibility)")
        print("screenRecording=\(screenRecording)")
        print("frontmost=\(frontmost?.localizedName ?? "?") locked=\(sessionLocked || loginwindow)")
        if sessionLocked || loginwindow {
            print("The screen is locked. Unlock it before running E2E.")
            exit(1)
        }
        if !accessibility || !screenRecording {
            print("Allow the terminal in 系统设置 → 隐私与安全性 → 辅助功能 and 屏幕录制.")
            exit(1)
        }
    }

    private static func screens() {
        for (index, screen) in NSScreen.screens.enumerated() {
            let frame = screen.frame
            let isMain = screen === NSScreen.main ? " main" : ""
            print(
                "screen\(index) \(Int(frame.width))x\(Int(frame.height)) "
                    + "x=\(Int(frame.minX)) y=\(Int(frame.minY)) "
                    + "scale=\(screen.backingScaleFactor)\(isMain)"
            )
        }
    }

    // MARK: - Keyboard and mouse

    private static func key(_ args: [String]) {
        guard let raw = args.first, let code = UInt16(raw) else {
            fail("usage: key <keycode> [cmd+shift+alt+ctrl]")
        }
        let flags = args.count > 1 ? parseFlags(args[1]) : []
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        down.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }

    private static func type(_ args: [String]) {
        let text = args.joined(separator: " ")
        for scalar in text.unicodeScalars {
            var unit = UniChar(scalar.value)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            down.flags = []
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
            up.flags = []
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    private static func move(_ args: [String]) {
        guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
            fail("usage: move <x> <y>")
        }
        postMouse(.mouseMoved, CGPoint(x: x, y: y))
    }

    private static func click(_ args: [String]) {
        guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
            fail("usage: click <x> <y>")
        }
        let point = CGPoint(x: x, y: y)
        postMouse(.mouseMoved, point)
        usleep(80_000)
        postMouse(.leftMouseDown, point)
        usleep(60_000)
        postMouse(.leftMouseUp, point)
    }

    private static func drag(_ args: [String]) {
        guard args.count >= 4,
              let x1 = Double(args[0]), let y1 = Double(args[1]),
              let x2 = Double(args[2]), let y2 = Double(args[3]) else {
            fail("usage: drag <x1> <y1> <x2> <y2> [steps]")
        }
        let steps = args.count > 4 ? max(1, Int(args[4]) ?? 20) : 20
        let start = CGPoint(x: x1, y: y1)
        let end = CGPoint(x: x2, y: y2)
        postMouse(.mouseMoved, start)
        usleep(100_000)
        postMouse(.leftMouseDown, start)
        usleep(120_000)
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            postMouse(.leftMouseDragged, point)
            usleep(15_000)
        }
        postMouse(.leftMouseUp, end)
    }

    private static func postMouse(_ type: CGEventType, _ point: CGPoint) {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )!
        // Synthetic hot keys can leave modifiers "stuck" on the event source.
        // Mouse gestures must not inherit them, or Shift will constrain a drag.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private static func parseFlags(_ text: String) -> CGEventFlags {
        var flags: CGEventFlags = []
        for part in text.split(separator: "+") {
            switch part {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    // MARK: - Screenshots and windows

    private static func screenshot(_ args: [String]) {
        guard let path = args.first else { fail("usage: screenshot <path> [windowID]") }
        var arguments = ["-x"]
        if args.count > 1 {
            arguments.append(contentsOf: ["-l", args[1]])
        }
        arguments.append(path)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let status = run("/usr/sbin/screencapture", arguments)
        if status != 0 {
            fail("screencapture exited with \(status)")
        }
    }

    private static func windows(_ args: [String]) {
        guard let raw = args.first, let pid = Int32(raw) else {
            fail("usage: windows <pid>")
        }
        for window in windowList(pid: pid) {
            print(
                "id=\(window.id) layer=\(window.layer) onscreen=\(window.onscreen ? 1 : 0) "
                    + "x=\(Int(window.bounds.minX)) y=\(Int(window.bounds.minY)) "
                    + "w=\(Int(window.bounds.width)) h=\(Int(window.bounds.height))"
            )
        }
    }

    private static func overlayWindow(_ args: [String]) {
        guard let raw = args.first, let pid = Int32(raw) else {
            fail("usage: overlay-window <pid> [timeoutSeconds]")
        }
        let timeout = args.count > 1 ? Double(args[1]) ?? 5 : 5
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let window = windowList(pid: pid).first(where: { $0.onscreen && $0.layer >= 2_000_000_000 }) {
                print(window.id)
                return
            }
            if Date() >= deadline {
                exit(1)
            }
            usleep(100_000)
        }
    }

    private struct WindowInfo {
        var id: Int
        var layer: Int
        var onscreen: Bool
        var bounds: CGRect
    }

    private static func windowList(pid: Int32) -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            let onscreen = (entry[kCGWindowIsOnscreen as String] as? Int ?? 0) == 1
            var bounds = CGRect.zero
            if let rawBounds = entry[kCGWindowBounds as String] as? [String: Any] {
                func value(_ key: String) -> CGFloat {
                    CGFloat((rawBounds[key] as? NSNumber)?.doubleValue ?? 0)
                }
                bounds = CGRect(
                    x: value("X"),
                    y: value("Y"),
                    width: value("Width"),
                    height: value("Height")
                )
            }
            return WindowInfo(id: number, layer: layer, onscreen: onscreen, bounds: bounds)
        }
    }

    // MARK: - Accessibility

    private static func axDump(_ args: [String]) {
        guard let raw = args.first, let pid = Int32(raw) else {
            fail("usage: ax-dump <pid>")
        }
        let app = AXUIElementCreateApplication(pid)
        print("frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        dump(app, depth: 0)
    }

    private static func dump(_ element: AXUIElement, depth: Int) {
        guard depth < 8 else { return }
        let indent = String(repeating: "  ", count: depth)
        let role = axAttribute(element, kAXRoleAttribute as CFString) as? String ?? "?"
        let title = axAttribute(element, kAXTitleAttribute as CFString) as? String ?? ""
        let description = axAttribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
        let value = axAttribute(element, kAXValueAttribute as CFString).map { "\($0)" } ?? ""
        var frame = ""
        if let positionValue = axAttribute(element, kAXPositionAttribute as CFString) {
            var point = CGPoint.zero
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) {
                var size = CGSize.zero
                if let sizeValue = axAttribute(element, kAXSizeAttribute as CFString) {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }
                frame = " frame=\(Int(point.x)),\(Int(point.y)) \(Int(size.width))x\(Int(size.height))"
            }
        }
        print("\(indent)\(role) title='\(title)' desc='\(description)' value='\(value)'\(frame)")
        if let children = axAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                dump(child, depth: depth + 1)
            }
        }
    }

    private static func axExists(_ args: [String]) {
        guard args.count >= 2, let pid = Int32(args[0]) else {
            fail("usage: ax-exists <pid> <title>")
        }
        let app = AXUIElementCreateApplication(pid)
        exit(find(app, title: args[1], description: nil) == nil ? 1 : 0)
    }

    private static func axPress(_ args: [String]) {
        guard args.count >= 2, let pid = Int32(args[0]) else {
            fail("usage: ax-press <pid> <title> [--desc <description>]")
        }
        var description: String?
        if args.count >= 4, args[2] == "--desc" {
            description = args[3]
        }
        let app = AXUIElementCreateApplication(pid)
        guard let element = find(app, title: args[1], description: description) else {
            fail("not found: title='\(args[1])' desc='\(description ?? "-")'")
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        print("AXPress result=\(result.rawValue)")
        if result != .success {
            // Modal transitions can report cannotComplete even though the action
            // was handled. The caller should verify the next UI state.
            print("warning: AXPress did not report success; verify the next UI state")
        }
    }

    private static func find(_ element: AXUIElement, title: String, description: String?) -> AXUIElement? {
        let role = axAttribute(element, kAXRoleAttribute as CFString) as? String ?? ""
        if role == "AXButton" || role == "AXCheckBox" {
            if let descriptionValue = description {
                let value = axAttribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
                if value == descriptionValue { return element }
            } else if !title.isEmpty {
                let value = axAttribute(element, kAXTitleAttribute as CFString) as? String ?? ""
                if value == title { return element }
            }
        }
        if let children = axAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                if let hit = find(child, title: title, description: description) {
                    return hit
                }
            }
        }
        return nil
    }

    private static func axAttribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    private static func frontmost(_ args: [String]) {
        let app = NSWorkspace.shared.frontmostApplication
        print("\(app?.localizedName ?? "?") pid=\(app?.processIdentifier ?? -1)")
        if let raw = args.first, let pid = Int32(raw), app?.processIdentifier != pid {
            exit(1)
        }
    }

    // MARK: - Pasteboard

    private static func pbDump(_ args: [String]) {
        guard let path = args.first else { fail("usage: pb-dump <directory>") }
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: directory)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.general
        var manifest: [[String: String]] = []
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            var entry: [String: String] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                let name = "item\(index)-\(type.rawValue.replacingOccurrences(of: "/", with: "_")).bin"
                try! data.write(to: directory.appendingPathComponent(name))
                entry[type.rawValue] = name
            }
            manifest.append(entry)
        }
        let json = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try! json.write(to: directory.appendingPathComponent("manifest.json"))
        print("dumped \(manifest.count) pasteboard item(s)")
    }

    private static func pbRestore(_ args: [String]) {
        guard let path = args.first else { fail("usage: pb-restore <directory>") }
        let directory = URL(fileURLWithPath: path)
        let json = try! Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try! JSONSerialization.jsonObject(with: json) as! [[String: String]]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var items: [NSPasteboardItem] = []
        for entry in manifest {
            let item = NSPasteboardItem()
            for (type, filename) in entry {
                let data = try! Data(contentsOf: directory.appendingPathComponent(filename))
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            items.append(item)
        }
        pasteboard.writeObjects(items)
        print("restored \(items.count) pasteboard item(s)")
    }

    private static func pbSaveImage(_ args: [String]) {
        guard let path = args.first else { fail("usage: pb-save-image <path>") }
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) {
            try! png.write(to: URL(fileURLWithPath: path))
            print("saved PNG (\(png.count) bytes)")
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            try! png.write(to: URL(fileURLWithPath: path))
            print("saved PNG from TIFF (\(png.count) bytes)")
        } else {
            fail("no image on the pasteboard")
        }
    }

    // MARK: - Utilities

    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func usage() -> Never {
        print(
            """
            usage: e2e-tools <command> [options]
              check-permissions
              screens
              key <keycode> [cmd+shift+alt+ctrl]
              type <text>
              move <x> <y>
              click <x> <y>
              drag <x1> <y1> <x2> <y2> [steps]
              screenshot <path> [windowID]
              windows <pid>
              overlay-window <pid> [timeoutSeconds]
              ax-dump <pid>
              ax-exists <pid> <title>
              ax-press <pid> <title> [--desc <description>]
              frontmost [pid]
              pb-dump <directory>
              pb-restore <directory>
              pb-save-image <path>
            """
        )
        exit(2)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(2)
    }
}
