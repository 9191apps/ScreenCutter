import AppKit
import CoreGraphics

enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks the system for access. The first request makes macOS show its own
    /// authorization prompt, so the app intentionally does not show one.
    @discardableResult
    static func request() -> Bool {
        if isGranted { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// The system only prompts on the first request. After a denial the user
    /// has to turn the switch on in System Settings.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }
}
