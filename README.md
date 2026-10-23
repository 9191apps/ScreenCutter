# ScreenCutter

菜单栏里的 macOS 区域截屏工具。用全局快捷键框选一块屏幕，再复制到剪贴板，或保存为 PNG。

## 环境

- macOS 14 或更高
- Xcode 16 或更高

用 Xcode 打开 `ScreenCutter.xcodeproj`，运行 scheme **ScreenCutter**。应用不显示 Dock 图标，菜单栏会出现裁剪图标。

第一次截屏时，系统会请求屏幕录制权限。若被拒绝，可在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 ScreenCutter。

## 用法

- 菜单「截取区域」，或快捷键 **⌘⇧2**
- 拖出矩形；按住 Shift 约束为正方形
- 松开后出现操作条：复制（Return）、保存、取消（Esc 或点压暗区域）
- 保存使用系统保存对话框，默认目录是桌面，文件名形如 `ScreenCutter 2026-10-23 22.45.01.png`
- 取消保存对话框后，选区和操作条还在，可以改成复制

启动时会检查 ⌘⇧2 是否已被系统快捷键或其他应用的全局热键占用。有冲突时不注册该热键，菜单会说明原因，截屏仍可从「截取区域」开始。应用回到前台时会再检查一次，占用消失后自动重新绑定。

## 测试

```sh
xcodebuild -project ScreenCutter.xcodeproj -scheme ScreenCutter -destination 'platform=macOS,arch=arm64' test
```

## 代码怎么分

同一个 Xcode target，按职责放在子目录里。几何和快捷键冲突判断不依赖窗口，单测直接覆盖它们。

- `App`：菜单栏入口，以及通用提示框
- `Capture`：截屏状态、屏幕录制权限、ScreenCaptureKit 取图
- `Export`：剪贴板和保存对话框
- `Geometry`：像素对齐、显示器坐标、操作条位置
- `HotKey`：⌘⇧2 的注册，以及和系统符号热键、Carbon 热键的冲突判断
- `Overlay`：每块屏幕上的遮罩、拖选和操作条

截屏进行中的状态放在 `CaptureSession`。遮罩只负责显示和把鼠标事件交回会话，不自己决定复制或保存。
