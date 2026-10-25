# 选区精准方案

日期：2026-10-24。状态：P1–P4 已实施，P5 未做。

## 目标

“选区不准”在用户侧通常不是一个问题，而是四种：

1. **看不到**：4K 屏上一个像素只有 0.25pt，肉眼无法判断边界落在哪一行。
2. **遮住了**：选区边框画在边界上，正好盖住最需要看清的那一列/行像素。
3. **调不到**：方向键一次 1pt（Retina 上是 2px），没有输入宽高的地方，小选区还会被 4pt 下限挡掉。
4. **对不上**：预览按屏幕的 `backingScaleFactor` 取整，裁切又按实际截图的尺寸取整；多数机器一致，但这是两个独立的取整点。

验收按下面四条，全部可测：

- 操作条显示的 `W × H` 与最终 PNG 的像素数逐像素相等。
- 1×1 像素的选区能调到、能复制（拖拽仍保留 4pt 防误触下限）。
- 拖拽选区时，放大镜里能看清目标像素，边框不覆盖被选像素。
- 按下快捷键之后桌面上发生的任何变化，都不会出现在放大镜、标注底图或最终 PNG 里。
- 不依赖鼠标也能把选区调到任意整数像素位置。

## 现状（P1 改动前）

几何入口集中在 `Geometry/SelectionGeometry.swift`：

- `pixelAligned` 把全局点坐标按 `scale` 取整；`SelectionDrag.globalRect` 在拖拽过程中就调用它。
- `pixelCrop` 在截屏后又按 `imageWidth / screenFrame.width` 算一次比例并取整。
- `outputPixelSize` 独立地按宽高取整，供标签使用。
- `minimumSelection = 4`（点），`isSubstantial` 同时用于拖拽结束、窗口过滤和缩放下限。

遮罩与显示：

- `SelectionTrackingView.currentSelection()` 只把 `W × H` 交给 `SelectionChromeView`。
- `SelectionChromeView` 用 3pt 黑边 + 1pt 白边沿选区边界描边；描边以路径为中心，向内吃掉约 1–1.5pt。
- 八个手柄是 8×8pt，中心在角点上，同样盖住边界。
- 没有放大镜，没有坐标读数，没有像素网格。

输入：

- 操作条阶段方向键移动 1pt / Shift 10pt；不能改宽高。
- 拖边时手柄最小仍是 4pt。
- 没有精确输入宽高的入口。
- 窗口矩形只在“截取窗口”里用，区域选区不会吸附。

## 设计

### 1. 一个整数像素矩形作为唯一真相

新增 `DisplayMetrics`（每块屏幕一份）：

```swift
struct DisplayMetrics {
    var screenID: CGDirectDisplayID
    var pointFrame: CGRect      // AppKit 全局坐标，左下原点
    var pixelSize: CGSize       // 显示器当前模式的像素尺寸
    var scaleX: CGFloat { pixelSize.width / pointFrame.width }
    var scaleY: CGFloat { pixelSize.height / pointFrame.height }
}
```

新增 `PixelRect`（`Int` 的 x/y/width/height，显示器本地、左上原点），并让 `ScreenSelection` 存它而不是存 `globalRect`：

- 拖拽、窗口、整屏最终都落到一个 `PixelRect`。
- 覆盖层要画的矩形、操作条要贴的位置、标签要显示的尺寸、`ScreenCaptureService` 要裁的矩形，全部由它换算。
- 点坐标只作为鼠标输入和 AppKit 绘制的中间量，不再参与第二次取整。
- 换算在像素空间夹紧：`0...pixelWidth`、`0...pixelHeight`，不会出现“点坐标夹紧后小数又被 round 到屏幕外”的情况。
- `scale` 保留为 `metrics.scaleX` 的兼容读取，标注和滚动长图不用改语义。

`ScreenCaptureService` 仍然整屏截图再 `cropping(to:)`，不使用 `sourceRect`（会缩放、糊字）。裁切直接使用 `selection.pixelRect`；如果 SCK 返回的图片尺寸与 `metrics.pixelSize` 不一致，按图片尺寸等比换算一次并夹紧，作为兜底。

这样得到一条可测的不变量：

```
label.pixelSize == outputPixelSize == croppedImage.size
```

### 2. 看得见：放大镜 + 不遮挡的边框

**放大镜**（新增 `Overlay/LoupeView.swift`）：

- 按下快捷键时先给每块屏幕抓一张原生像素的静态图（排除本应用窗口），再呈现遮罩；放大镜、遮罩底图、标注和导出都读这张图，选区过程中不再重新抓屏。
- 光标周围取正方形像素区域，按整数倍放大显示在浮层里，最近邻采样，不插值。视野分四档：24 px / 5×、40 px / 4×、64 px / 3×（默认）、96 px / 2×，内容边长分别为 120 / 160 / 192 / 192pt。
- 每个源像素画成 `zoom × zoom` pt 的格子，网格线压在像素边界上；每道边界用一深一浅两条 1 设备像素的细线，浅色内容上深线可见、深色内容上浅线可见，网格不会在浅色底图上消失。
- 光标所在像素填成白色方块；贯穿放大区的十字线用蓝色，线宽等于方块边长（即一格像素），在浅色和深色内容上都醒目。
- 浮层底部显示两行读数：显示器本地像素坐标 `x 1234  y 567`，以及当前选区 `640 × 400 px`。
- 浮层跟随光标偏移 18pt，靠近屏幕边缘时翻到另一侧并夹紧；浮层原点对齐到设备像素，避免细网格被合成器重采样糊掉；`hitTest` 永远返回 `nil`，不抢鼠标。
- 只在拖拽建立选区时显示；松开鼠标、选区建立后立即隐藏，拖边、移动和标注阶段都不再出现。
- 整块遮罩都建立在冻结帧上：`FrozenBackdropView` 铺底，`DimMaskView` 压 40% 黑并挖洞，洞里是同一帧的全亮像素。这样看到的就是最终会导出的内容，不追视频，也不引入 `SCStream`。设置页「通用」里有“显示选区放大镜”开关和视野选择，开关默认开，视野默认 64 px / 3×；关掉只影响放大镜，底图仍然是冻结帧。

**边框**：

- 黑白描边整体向外偏移 1.5pt，选区内一个像素都不盖。
- 手柄向外画，不压边界；选区任一边小于 12pt 时进入紧凑模式：只画角点、不画边中点，避免 8 个手柄糊成一团。
- 选区任一边小于 8pt 时隐藏手柄，只保留整块移动；精确调整走键盘和数值输入。
- 尺寸标签始终放在选区外，留 14pt 间距；上方放不下就放下方，两边都放不下就贴屏幕边。标签用等宽数字。

### 3. 落得准：键盘、数值、吸附

**键盘**（按像素，不按点）：

- 方向键：整块移动 1px；Shift+方向键：10px。
- Option+→/←：只动右边，宽度 ±1px；Option+↑/↓：只动上边，高度 ±1px；加 Shift 为 10px。
- 夹紧到屏幕、保持至少 1×1px；到边界时不动。
- 拖动阈值仍按 4pt：避免一次误点产生 1px 选区。操作条建立后，缩放和键盘可以降到 1px。

**数值输入**：

- 操作条加“精确”按钮，弹 `NSPopover`，四个字段：X、Y、W、H，单位像素，X/Y 是显示器左上角起算。
- W/H 至少 1；X/Y/W/H 越界时夹紧；Return 应用，Esc 取消；输入过程中通过 `CaptureSession.previewRect` 实时预览，取消或点外部恢复原选区。
- 字段用等宽数字和 `NumberFormatter`，非法输入不提交。弹层里附带当前的 pt 尺寸，避免用户混淆两套单位。

**吸附**：

- 候选边：当前屏幕的四边和中线、`WindowCatalog.frontToBack()` 返回的窗口矩形（只要和当前屏幕相交的部分）。
- 阈值 4pt；只吸附正在移动的那条边/那个角；鼠标按下时先把起点吸到最近的候选边。
- 吸附不画贯穿屏幕的参考线：参考线总是和选区边重合，延伸出去只是噪声，边框停在候选边上就是反馈。
- 按住 Control 临时关闭吸附；Shift 约束正方形时也关闭（两边同时吸会破坏正方形）。
- 这一阶段不做基于 Accessibility 的控件级吸附，避免新增辅助功能权限。
- 后续可选：从放大镜底图做“内容边”磁吸——沿移动方向扫描 ±8px 的亮度/色差梯度，超过阈值才吸。纯 CPU、可单测，但要单独评估误吸率。

### 4. 拖起来跟手：每帧只做必须做的事

选区建立后拖边、拖角或整体移动时，`phase` 每一帧都要变一次。选区本身很小，但这一步曾经明显发卡，原因不在几何计算：

- **`phase` 曾经是 `@Published`。** 菜单栏内容和设置窗口都 `@ObservedObject` 整个 `CaptureSession`，而设置窗口关掉后仍留在视图树里。于是每拖动一次，SwiftUI 就在遮罩提交显示周期的同一帧里重算这些 body。`sample` 采样（拖边 3 秒，Debug 构建）显示：显示周期相关的工作占主线程墙钟时间约 42%，其中近一半是隐藏窗口的 `NSHostingView.layout`（约 400/1850 个采样）。现在 `phase` 是普通属性，遮罩订阅 `phaseChanges`，SwiftUI 只看 `isEditingSelection` 这种粗粒度状态。同一手势下这部分降到约 1%，`NSHostingView` 采样为零。
- **同一阶段内只有几何变化。** `SelectionTrackingView.apply(phase:)` 用 `isSameInteraction(as:)` 分开两条路径：同一交互内只重画遮罩、边框和操作条位置；只有阶段切换才重算光标区域、光标形状、放大镜、标注画布和按钮显隐。
- **拖拽事件按帧合并。** 显示一帧最多提交一次，回放队列里每个 `leftMouseDragged` 只会让选区越拖越落后于指针。两个跟踪循环都用 `newestPendingDrag(after:)` 取最新位置，`.eventTracking` 模式消费，不惊动其它 run loop 源。
- **边框视图只重画变化区域。** `SelectionChromeView` 覆盖整屏，整视图标脏会让 AppKit 每帧重新光栅化一块 4K 图层，只为画 4px 边框。现在只把旧、新 chrome 的并集标脏，并缓存尺寸标签的文字度量。

改完后同一个拖拽手势里主线程约 89% 的时间在等下一个事件，一帧的显示工作降到 1ms 量级。回归测试在 `ScreenCutterTests/Overlay/PhaseObservationTests.swift`。

## 分阶段

| 阶段 | 内容 | 规模 | 可独立发布 |
| --- | --- | --- | --- |
| P1 | `DisplayMetrics` + `PixelRect`，统一裁切/标签/绘制；操作条/缩放下限 1px（拖拽仍 4pt）；边框外移；紧凑手柄 | M | 是 |
| P2 | 选区放大镜、像素网格、坐标读数、底图快照 | M | 是 |
| P3 | 像素级方向键、Option 调边、精确输入弹层 | S | 是 |
| P4 | 屏幕/窗口边吸附、Control 临时关闭 | M | 是 |
| P5 | 内容边磁吸；Accessibility 控件吸附 | L | 单独评估 |

P1 是地基，先做；P2 是用户感知最强的一步；P3 补“不靠鼠标”；P4 减少手感抖动。P5 不放进这一轮。

P1–P4 已落地：`DisplayMetrics`/`PixelRect` 成为唯一像素模型，放大镜、像素级键盘、精确输入、屏幕/窗口吸附都接在 `CaptureSession` 和遮罩上。P5 的“内容边磁吸”和 Accessibility 控件吸附仍未做。

## 改动落点

新增：

- `Geometry/DisplayMetrics.swift`：`DisplayMetrics`、`PixelRect`、像素空间选择编辑、精确输入夹紧。
- `Geometry/SnapEngine.swift`：候选边、最近边、阈值判断（纯值类型，可单测）。
- `Geometry/LoupeGeometry.swift`：放大镜的翻边、夹紧和设备像素对齐。
- `Overlay/LoupeView.swift`：放大镜绘制。
- `Overlay/PrecisionFieldsView.swift`：精确输入弹层。
- `Capture/ScreenCaptureService.swift` 的 `snapshot(displayID:)`：排除本应用窗口的整屏快照。

修改：

- `Capture/CaptureModels.swift`：`ScreenSelection` 改存 `pixelRect + metrics`；`SelectionDrag` 由点输入生成 `pixelRect`。
- `Capture/CaptureSession.swift`：缩放/键盘/数值/吸附的状态变更；精确输入的预览通道；快照生命周期；1px 与 4pt 两套下限。
- `Capture/ScreenCaptureService.swift`：直接用 `pixelRect` 裁切；尺寸不一致时的兜底。
- `Geometry/SelectionGeometry.swift`：删除 `pixelAligned`/`pixelCrop`/`outputPixelSize`；保留点空间手柄、操作条和 4pt 拖拽下限。
- `Overlay/SelectionChromeView.swift`：外移描边、紧凑手柄、标签外置。
- `Overlay/SelectionTrackingView.swift`：放大镜挂载与显隐、精确按钮。
- `README.md`、`docs/e2e.md`：更新选区说明和手工检查项。

测试：

- `DisplayMetricsTests`：1x/2x、非整数比例、负原点、夹紧、往返转换、图片尺寸不一致时的兜底。
- `SelectionGeometryTests`：1px 选区、屏幕边缘、`PixelRect` 裁切、标签与输出一致。
- `SnapEngineTests`：候选去重、最近候选、并列优先级、阈值边界、单点吸附、整块移动吸附。
- `CaptureSessionPrecisionTests`：像素方向键、Option 调边、数值夹紧、4pt 拖拽下限、1px 选区、拖拽吸附。
- `LoupeGeometryTests`：翻边、夹紧、快照分辨率映射。
- `SelectionTrackingViewTests`：紧凑手柄、小选区无手柄、放大镜显隐、精确按钮可用性。
- `ContentEdgeTests`（P5，未实现）：合成图上的竖线/横线/平坦区域。
- 手工清单：Retina + 外接 1x、旋转屏、多屏、1px 线、窗口边缘、整屏、窗口截取、滚动长图、标注导出各回归一次。

## 取舍

- **不跨屏**：维持现状，选区仍限制在起始屏幕。跨屏会牵动坐标模型、遮罩和截图裁剪，单独做。
- **整屏冻结**：按下快捷键时，每块屏幕各抓一张静态图，遮罩、放大镜、标注和导出都从这张图读。桌面后续的变化一律不进入结果，代价是每次触发多一次全屏抓图，并在遮罩存活期间占住每块屏幕一份原生像素的内存。
- **保留整屏截图 + 裁剪**：不用 `sourceRect`，避免缩放导致的文字发虚；导出直接在冻结帧上 `cropping`，不重采样。
- **不引入新权限**：P1–P4 只用现有的屏幕录制权限；Accessibility 控件吸附放到 P5。
- **4pt 拖拽下限 / 1px 调整下限**：用两套常量分别防误触和保证精度，不共用 `minimumSelection`。
- **单位**：对外读数统一用像素；pt 只在精确输入弹层里作为辅助信息。

## 验收脚本

1. 2x 屏上拖出约 200×100pt 的选区，读数为 400×200，复制后 PNG 为 400×200。
2. 用方向键把选区移到奇数像素位置，再复制，PNG 尺寸不变、内容偏移 1px 可见。
3. 用 Option+方向键把宽度缩到 1px，复制结果严格是 1px 宽。
4. 选区贴住窗口左边缘和屏幕顶部，边框不盖住第一行/列像素。
5. 在外接 1x 屏和旋转屏上重复 1、2；标签与输出仍一致。
6. 旧路径回归：整屏、窗口、滚动长图、标注、保存取消后再复制。
