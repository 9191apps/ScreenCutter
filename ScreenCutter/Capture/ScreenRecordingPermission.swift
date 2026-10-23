import AppKit
import CoreGraphics
import Foundation

enum ScreenRecordingPermission {
    static func ensureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        if CGRequestScreenCaptureAccess() {
            return true
        }
        presentDeniedAlert()
        return false
    }

    private static func presentDeniedAlert() {
        let openSettings = AppAlert.show(
            title: "需要屏幕录制权限",
            message: "请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 ScreenCutter。",
            confirm: "打开系统设置",
            cancel: "取消"
        )
        guard openSettings else { return }
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
