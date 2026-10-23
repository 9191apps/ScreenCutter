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
        Button("截取区域") {
            session.begin()
        }
        .modifier(CaptureMenuShortcut(isEnabled: session.hotKeyConflict == .none))

        if let detail = session.hotKeyConflict.menuDetail {
            Button(detail) {}
                .disabled(true)
        }

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
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
