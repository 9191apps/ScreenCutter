import SwiftUI

enum SettingsTab: Int {
    case general
    case shortcuts

    static let defaultsKey = "settingsSelectedTab"
}

struct SettingsView: View {
    @ObservedObject var session: CaptureSession
    @AppStorage(SettingsTab.defaultsKey) private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(session: session)
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
                .tag(SettingsTab.general.rawValue)

            ShortcutSettingsView(session: session)
                .tabItem {
                    Label("快捷键", systemImage: "command")
                }
                .tag(SettingsTab.shortcuts.rawValue)
        }
        .frame(width: 480, height: 360)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var session: CaptureSession

    var body: some View {
        Form {
            Section {
                Toggle("显示选区放大镜", isOn: Binding(
                    get: { session.showLoupe },
                    set: { session.setShowLoupe($0) }
                ))
                Picker("放大镜视野", selection: Binding(
                    get: { session.loupePreset },
                    set: { session.setLoupePreset($0) }
                )) {
                    ForEach(LoupePreset.allCases) { preset in
                        Text(preset.settingsTitle)
                            .tag(preset)
                            .accessibilityLabel(preset.accessibilityLabel)
                    }
                }
                .disabled(!session.showLoupe)
            } header: {
                Text("选区")
            } footer: {
                Text("拖动选区时在光标旁显示像素网格、坐标和尺寸，松开后自动隐藏。视野越大，单个像素的放大倍数越低。")
            }

            Section {
                LabeledContent("屏幕录制") {
                    PermissionStatusLabel(granted: session.hasScreenRecordingAccess)
                }
                if !session.hasScreenRecordingAccess {
                    Button("打开系统设置…") {
                        ScreenRecordingPermission.openSystemSettings()
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("截屏需要屏幕录制权限，ScreenCutter 不会上传图像。修改后如果仍无法截屏，请重新启动应用。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionStatusLabel: View {
    var granted: Bool

    var body: some View {
        Label(
            granted ? "已允许" : "未允许",
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(granted ? Color.green : Color.orange)
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject var session: CaptureSession

    var body: some View {
        Form {
            Section {
                ShortcutRow(
                    title: HotKeySlotID.title(for: HotKeySlotID.region),
                    detail: "拖出一块区域，然后复制、保存或标注。",
                    chord: session.regionChord,
                    conflict: session.hotKeyConflict,
                    isEnabled: true,
                    onChange: { session.beginHotKeyChange(for: HotKeySlotID.region) }
                )
            } header: {
                Text("截屏快捷键")
            } footer: {
                Text("点「更改…」后按下新组合，需要包含 ⌘、⌥ 或 ⌃。")
            }

            Section {
                ShortcutRow(
                    title: HotKeySlotID.title(for: HotKeySlotID.fullScreen),
                    detail: "截取光标所在的整块屏幕。",
                    chord: session.fullScreenChord,
                    conflict: session.fullScreenConflict,
                    isEnabled: session.fullScreenHotKeyEnabled,
                    onChange: { session.beginHotKeyChange(for: HotKeySlotID.fullScreen) },
                    onToggle: { session.setFullScreenHotKeyEnabled($0) }
                )
                ShortcutRow(
                    title: HotKeySlotID.title(for: HotKeySlotID.window),
                    detail: "悬停高亮窗口，点击确认。",
                    chord: session.windowChord,
                    conflict: session.windowConflict,
                    isEnabled: session.windowHotKeyEnabled,
                    onChange: { session.beginHotKeyChange(for: HotKeySlotID.window) },
                    onToggle: { session.setWindowHotKeyEnabled($0) }
                )
            } header: {
                Text("可选快捷键")
            } footer: {
                HStack(spacing: 12) {
                    Text("关掉开关后，仍可以从菜单使用对应的截屏。")
                    Spacer(minLength: 0)
                    Button("全部恢复默认") {
                        session.resetHotKeys()
                    }
                    .controlSize(.small)
                    .disabled(session.usesDefaultHotKeys)
                    .accessibilityLabel("全部恢复默认快捷键")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    var title: String
    var detail: String
    var chord: HotKeyChord
    var conflict: HotKeyConflict
    var isEnabled: Bool
    var onChange: () -> Void
    var onToggle: ((Bool) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let onToggle {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("启用\(title)快捷键")
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = conflict.settingsMessage(for: chord) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                HotKeyChip(chord: chord, dimmed: !isEnabled)
                Button("更改…", action: onChange)
                    .controlSize(.small)
                    .disabled(!isEnabled)
                    .accessibilityLabel("更改\(title)快捷键")
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 3)
    }
}

private struct HotKeyChip: View {
    var chord: HotKeyChord
    var dimmed: Bool

    var body: some View {
        Text(chord.display)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityLabel("快捷键 \(chord.display)")
    }
}
