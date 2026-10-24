import AppKit
import Combine
import SwiftUI

@main
struct ScreenCutterApp: App {
    @StateObject private var session = CaptureSession()

    var body: some Scene {
        MenuBarExtra("ScreenCutter", systemImage: "crop") {
            CaptureMenu(session: session)
        }
    }
}

private struct CaptureMenu: View {
    @ObservedObject var session: CaptureSession

    var body: some View {
        if !session.hasScreenRecordingAccess {
            Button("未开启屏幕录制权限，点此打开系统设置…") {
                ScreenRecordingPermission.openSystemSettings()
            }
            Divider()
        }

        Button("截取区域") {
            session.begin()
        }
        .modifier(CaptureMenuShortcut(
            isEnabled: session.hotKeyConflict == .none && session.regionChord == .regionCapture
        ))

        if session.hotKeyConflict == .none, session.regionChord != .regionCapture {
            Button(session.regionChord.display) {}
                .disabled(true)
        }
        if let detail = session.hotKeyConflict.menuDetail(for: session.regionChord) {
            Button(detail) {}
                .disabled(true)
        }
        Toggle("显示选区放大镜", isOn: Binding(
            get: { session.showLoupe },
            set: { session.setShowLoupe($0) }
        ))
        Button("拷贝文字") {
            session.copyRecognizedText()
        }
        .disabled(!session.phase.isEditing)

        Button("更改快捷键") {
            session.beginHotKeyChange()
        }

        Divider()

        Button("截取整屏") {
            session.captureFullScreen()
        }
        hotKeyStatus(
            enabled: session.fullScreenHotKeyEnabled,
            chord: .fullScreen,
            conflict: session.fullScreenConflict,
            title: "整屏快捷键"
        )
        Toggle("使用整屏快捷键", isOn: Binding(
            get: { session.fullScreenHotKeyEnabled },
            set: { session.setFullScreenHotKeyEnabled($0) }
        ))

        Button("滚动长图") {
            session.beginScrollCapture()
        }

        Button("截取窗口") {
            session.beginWindowCapture()
        }
        hotKeyStatus(
            enabled: session.windowHotKeyEnabled,
            chord: .window,
            conflict: session.windowConflict,
            title: "窗口快捷键"
        )
        Toggle("使用窗口快捷键", isOn: Binding(
            get: { session.windowHotKeyEnabled },
            set: { session.setWindowHotKeyEnabled($0) }
        ))

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@ViewBuilder
private func hotKeyStatus(
    enabled: Bool,
    chord: HotKeyChord,
    conflict: HotKeyConflict,
    title: String
) -> some View {
    if enabled, let detail = conflict.menuDetail(for: chord) {
        Button(detail) {}
            .disabled(true)
    } else if enabled, conflict == .none {
        Button("\(title) \(chord.display)") {}
            .disabled(true)
    }
}

private struct CaptureMenuShortcut: ViewModifier {
    var isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.keyboardShortcut("2", modifiers: [.command, .shift])
        } else {
            content
        }
    }
}
