import AppKit
import SwiftUI

@main
struct ScreenCutterApp: App {
    @StateObject private var session = CaptureSession()

    var body: some Scene {
        MenuBarExtra("ScreenCutter", systemImage: "crop") {
            CaptureMenu(session: session)
        }

        Settings {
            SettingsView(session: session)
        }
    }
}

private struct CaptureMenu: View {
    @ObservedObject var session: CaptureSession
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.defaultsKey) private var selectedSettingsTab = SettingsTab.general.rawValue

    var body: some View {
        if !session.hasScreenRecordingAccess {
            Button("未开启屏幕录制权限，点此打开系统设置…") {
                ScreenRecordingPermission.openSystemSettings()
            }
            Divider()
        }

        if let problem = session.activeHotKeyConflict,
           let detail = problem.conflict.menuDetail(for: problem.chord) {
            Button("\(detail)，点此打开设置…") {
                showSettings(.shortcuts)
            }
            Divider()
        }

        Button("截取区域") {
            session.begin()
        }
        .hotKeyMenuShortcut(session.hotKeyConflict == .none ? session.regionChord : nil)

        Button("截取整屏") {
            session.captureFullScreen()
        }
        .hotKeyMenuShortcut(
            session.fullScreenHotKeyEnabled && session.fullScreenConflict == .none
                ? session.fullScreenChord
                : nil
        )

        Button("截取窗口") {
            session.beginWindowCapture()
        }
        .hotKeyMenuShortcut(
            session.windowHotKeyEnabled && session.windowConflict == .none
                ? session.windowChord
                : nil
        )

        Button("滚动长图") {
            session.beginScrollCapture()
        }

        Button("手动滚动长图") {
            session.beginManualScrollCapture()
        }

        if session.isEditingSelection {
            Divider()
            Button("拷贝文字") {
                session.copyRecognizedText()
            }
        }

        Divider()

        Button("设置…") {
            showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Opens the settings window, optionally switching to a specific tab.
    private func showSettings(_ tab: SettingsTab? = nil) {
        if let tab {
            selectedSettingsTab = tab.rawValue
        }
        NSApp.activate()
        openSettings()
    }
}
