# ScreenCutter 演进方案

日期：2026-10-23。对照菜单栏区域截屏的现状，以及 Pinpoint、screenshot、ScreenCapture、macshot、Snapzy、Snapper、Lenscap 这类开源工具。

每一阶段都要能单独发布：做完后应用仍是菜单栏工具，区域截屏不会变坏。几何和快捷键冲突判断继续放在不依赖窗口的类型里，并用单测锁住。界面文案保持中文。部署目标维持 macOS 14，捕获继续用 ScreenCaptureKit，不启用 App Sandbox。

明确排在本方案之外，做到阶段 4 再单独立项：录屏、GIF、云上传、历史库、钉在屏幕上、打码和完整标注套件。

## 现状

已经有的路径：菜单「截取区域」或 ⌘⇧2，在拖拽开始的那一块屏幕上框选，Shift 为正方形，松开后复制、保存或取消。复制写入 PNG 和 TIFF。保存走 `NSSavePanel`，仅 PNG。启动时检查系统符号热键和 Carbon 全局热键；冲突时不绑定，菜单说明原因。

选区在 `CaptureSession.endDrag` 之后锁定。快捷键写死在 `HotKeyConflictChecker.captureKeyCode` 和 `HotKeyMonitor`。遮罩在 `Overlay/SelectionTrackingView.swift`，取图像素在 `Capture/ScreenCaptureService.swift`。

## 阶段 1：选区可改，快捷键可换

这是和 Pinpoint 最直接的差距，也解开现在「冲突了就只能用菜单」的死角。

选区松开后仍可拖边、拖角和整体移动，方向键以 1pt 微调，Shift+方向键以 10pt 微调。小于 4pt 的选区继续视为无效。松手时再做像素对齐，拖动过程中可以跟手。操作条继续用现有的 `SelectionGeometry.actionBarFrame` 贴在选区外。

快捷键存进 UserDefaults：虚拟键码加 Carbon 修饰键。冲突检测改成对「当前要注册的组合」做判断，不再写死 ⌘⇧2。菜单显示当前组合。冲突提示和菜单里都提供「更改快捷键」：按下新组合，检测通过才替换并重新注册。应用回到前台时，用存下来的组合再查一次。

改动落点：

- `Geometry/SelectionGeometry.swift`：命中移动、八个手柄，以及方向键平移。单测覆盖贴边、最小尺寸和翻转后的操作条。
- `Capture/CaptureModels.swift`、`Capture/CaptureSession.swift`：框选结束后进入可调整状态，再进入操作条。
- `Overlay/SelectionTrackingView.swift`：手柄和移动的鼠标跟踪；Esc 仍取消，Return 仍复制。
- `HotKey/HotKeyConflict.swift`、`HotKey/HotKeyMonitor.swift`：按传入的组合检测和注册。
- `App/ScreenCutterApp.swift`：菜单上的快捷键文案和「更改快捷键」。

本阶段不做窗口捕获、整屏捕获和标注。

## 阶段 2：窗口和整屏

区域截屏之外，补上光标所在屏幕的整屏，以及点选一个窗口。两者都算出一个全局矩形，交给现有的 `ScreenCaptureService.capture`，复制和保存不变。

窗口矩形来自 `SCShareableContent` 的窗口列表，转成 AppKit 全局坐标后同样做像素对齐。遮罩上悬停高亮窗口，点击确认。选区仍然不跨屏幕。

入口放在菜单，并给两个可关闭的默认快捷键。冲突检测复用阶段 1 的注册器。

本阶段不做滚动拼接，也不按窗口阴影做单独样式。

## 阶段 3：截完再标注

先把选区截进内存，再在这块图上画，最后才复制或保存。这样标注不会把桌面的后续变化画进去。现有的「藏起遮罩再截」只发生在进入标注之前。

第一套工具只做矩形、箭头、画笔、文字。颜色和线宽用一套固定选项。撤销按笔画栈，不做重做以外的工程文件。画完仍走 `ImageExport`：复制 PNG/TIFF，保存 PNG。

模型放在新的 `Annotate/` 目录，绘制用 CoreGraphics 合成到 `CGImage`，不把标注逻辑写进遮罩的鼠标跟踪里。`CaptureSession` 增加编辑阶段，遮罩只显示冻结的图和工具条。

本阶段不做模糊、打码、编号标记和背景美化。

## 阶段 4：把选区里的字放进剪贴板

对阶段 3 拿到的那张图做本机 Vision 文字识别，菜单和编辑条提供「拷贝文字」。识别失败时提示，不改掉已经截到的图。不上传图像。

## 阶段 5：滚动长图

单独做，不插进前面的状态机。框定一块可滚动区域，逐步滚动并按重叠拼接。需要合成滚动事件，失败时保留已经拼上的部分并说明没到底。先只做纵向。开始前为这一阶段另写一份实现说明，不沿用本文的粒度。

## 建议顺序

阶段 1 不依赖新的捕获种类，先做。阶段 2 复用阶段 1 的快捷键注册。阶段 3 改变「何时真正截像素」，要在窗口和整屏的矩形都能进 `ScreenCaptureService` 之后做，这样三种截法共用一张冻结图。阶段 4 吃阶段 3 的图像。阶段 5 最后做。
