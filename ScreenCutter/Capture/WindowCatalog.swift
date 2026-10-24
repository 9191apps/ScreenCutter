import AppKit
import ScreenCaptureKit

enum WindowCatalog {
    static func frontToBack() async throws -> [ListedWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let primaryHeight = primary?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard window.isOnScreen, window.windowLayer == 0 else { return nil }
            guard window.owningApplication?.processID != ownPID else { return nil }
            let frame = WindowGeometry.appKitFrame(fromQuartz: window.frame, primaryHeight: primaryHeight)
            guard SelectionGeometry.isSubstantial(frame) else { return nil }
            let title = window.title ?? window.owningApplication?.applicationName ?? "窗口"
            return ListedWindow(windowID: window.windowID, appKitFrame: frame, title: title)
        }
    }
}
