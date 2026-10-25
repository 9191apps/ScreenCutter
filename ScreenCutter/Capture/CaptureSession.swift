import AppKit
import Combine
import Foundation

@MainActor
final class CaptureSession: NSObject, ObservableObject {
    /// The interactive phase. It is deliberately not `@Published`: dragging a
    /// handle republishes it once per frame, and every SwiftUI view that observes
    /// the session (`CaptureMenu`, the Settings window, which stays in the view
    /// tree while hidden) would then re-render its body in the middle of the
    /// overlay's display cycle. That layout work alone was several milliseconds
    /// per frame on a 60 Hz display and made dragging feel like it stuttered.
    ///
    /// The overlay listens to `phaseChanges` instead, and SwiftUI only sees the
    /// coarse state it actually renders (`isEditingSelection`).
    private(set) var phase: CapturePhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            phaseChanges.send(phase)
            let editing = phase.isEditing
            if isEditingSelection != editing {
                isEditingSelection = editing
            }
        }
    }

    /// The one piece of `phase` the menu renders. Published so the menu updates
    /// when annotation starts or ends, and not on every pointer move.
    @Published private(set) var isEditingSelection = false

    /// Phase changes for the overlay windows. Sent after `phase` is updated.
    let phaseChanges = PassthroughSubject<CapturePhase, Never>()

    @Published private(set) var hotKeyConflict: HotKeyConflict = .none
    @Published private(set) var regionChord: HotKeyChord = .regionCapture
    @Published private(set) var fullScreenChord: HotKeyChord = .fullScreen
    @Published private(set) var windowChord: HotKeyChord = .window
    @Published private(set) var fullScreenHotKeyEnabled = true
    @Published private(set) var windowHotKeyEnabled = true
    @Published private(set) var fullScreenConflict: HotKeyConflict = .none
    @Published private(set) var windowConflict: HotKeyConflict = .none
    @Published private(set) var hasScreenRecordingAccess = ScreenRecordingPermission.isGranted

    private let hotKeys = HotKeyMonitor()
    private let overlay = OverlayController()
    private let manualScrollPanel = ManualScrollPanel()
    private var manualScrollControl: ManualScrollControl?
    private var keyMonitor: Any?
    private let conflictAlertKey = "didShowHotKeyConflictAlert"
    private var listedWindows: [ListedWindow] = []
    private var frozenImage: CGImage?
    /// One still per display, taken before the overlay appears. The selection, the
    /// loupe, and the exported pixels all read from these, so the result is the
    /// screen as it was when the shortcut fired.
    private var frozenScreens: [CGDirectDisplayID: CGImage] = [:]
    private(set) var annotation = AnnotationDocument()
    private(set) var selectedAnnotation: Int?
    let annotationChanges = PassthroughSubject<Void, Never>()
    @Published private(set) var scrollIntent: ScrollIntent?
    @Published private(set) var showLoupe: Bool
    @Published private(set) var loupePreset: LoupePreset
    @Published private(set) var previewRect: PixelRect?

    private static let showLoupeKey = "showSelectionLoupe"
    private static let loupePresetKey = "loupePreset"

    /// One undo step: the strokes as they were before an edit. Tool, color, and
    /// line width are intentionally not stored, so undo does not change them.
    private struct AnnotationUndoStep {
        var strokes: [AnnotationStroke]
        var selectedAnnotation: Int?
    }

    private var annotationUndoStack: [AnnotationUndoStep] = []

    var editingImage: CGImage? { frozenImage }

    /// The first registered shortcut that could not be bound, in menu order.
    /// The menu surfaces it as a single item that opens Settings.
    var activeHotKeyConflict: (chord: HotKeyChord, conflict: HotKeyConflict)? {
        if hotKeyConflict != .none {
            return (regionChord, hotKeyConflict)
        }
        if fullScreenHotKeyEnabled, fullScreenConflict != .none {
            return (fullScreenChord, fullScreenConflict)
        }
        if windowHotKeyEnabled, windowConflict != .none {
            return (windowChord, windowConflict)
        }
        return nil
    }

    var usesDefaultHotKeys: Bool {
        regionChord == .regionCapture
            && fullScreenChord == .fullScreen
            && windowChord == .window
            && fullScreenHotKeyEnabled
            && windowHotKeyEnabled
    }

    private var adjustmentOrigin: PixelRect?
    private var adjustmentHandle: SelectionHandle?
    private var adjustmentAnchor: PixelPoint?
    private var snapWindows: [ListedWindow] = []

#if DEBUG
    /// Testing hook: drives the overlay without screen recording permission or a live capture.
    /// An unchanged phase is republished so a test can force a re-layout.
    func setPhaseForTesting(_ phase: CapturePhase) {
        let unchanged = self.phase == phase
        self.phase = phase
        if unchanged {
            phaseChanges.send(phase)
        }
    }

    /// Testing hook: supplies the frozen image that annotation drawing operates on.
    func setEditingImageForTesting(_ image: CGImage?) {
        frozenImage = image
        annotationChanges.send()
    }

    /// Testing hook: installs the display stills the overlay would have taken.
    func setFrozenScreensForTesting(_ frames: [CGDirectDisplayID: CGImage]) {
        frozenScreens = frames
    }
#endif

    override init() {
        showLoupe = UserDefaults.standard.object(forKey: Self.showLoupeKey) as? Bool ?? true
        loupePreset = UserDefaults.standard.string(forKey: Self.loupePresetKey)
            .flatMap { LoupePreset(rawValue: $0) } ?? .fallback
        super.init()
        regionChord = HotKeyStore.loadRegion()
        hotKeys.onPressed = { [weak self] id in
            switch id {
            case HotKeySlotID.fullScreen:
                self?.captureFullScreen()
            case HotKeySlotID.window:
                self?.beginWindowCapture()
            default:
                self?.begin()
            }
        }
        guard !Self.isRunningTests else { return }
        refreshHotKey(shouldAlert: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // Permission can change in System Settings while the app keeps running.
        // Re-check whenever a menu opens so the hint is always current.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
    }

    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    func begin() {
        scrollIntent = nil
        startSelection()
    }

    func beginScrollCapture() {
        guard phase == .idle else { return }
        scrollIntent = .automatic
        startSelection()
    }

    func beginManualScrollCapture() {
        guard phase == .idle else { return }
        scrollIntent = .manual
        startSelection()
    }

    private func startSelection() {
        guard phase == .idle else { return }
        guard requestScreenRecordingAccess() else { return }
        phase = .selecting(nil)
        presentFrozenOverlay { [weak self] in
            self?.refreshSnapWindows()
        }
    }

    /// Freezes every display, then presents the overlay. The order matters: if the
    /// overlay went up first, the capture would include the dim and the overlay's
    /// own windows. The delay is the capture itself, a few tens of milliseconds.
    private func presentFrozenOverlay(onReady: @escaping () -> Void = {}) {
        let requests = NSScreen.screens.map {
            ScreenCaptureService.DisplayRequest(
                displayID: $0.displayID,
                pixelSize: $0.displayMetrics.pixelSize
            )
        }
        Task { [weak self] in
            let frames = (try? await ScreenCaptureService.freeze(displays: requests)) ?? [:]
            guard let self, self.phase != .idle else { return }
            // A black selection surface would be worse than an honest failure: the
            // user could frame a region that never made it into the frame.
            guard !frames.isEmpty else {
                self.cancel()
                AppAlert.show(
                    title: "无法截屏",
                    message: "没有读到屏幕画面。请在「系统设置 → 隐私与安全性 → 屏幕录制」里允许 ScreenCutter，然后重新启动应用。"
                )
                return
            }
            self.frozenScreens = frames
            self.overlay.present(session: self)
            self.installKeyMonitor()
            onReady()
        }
    }

    /// macOS shows its own authorization prompt the first time; afterwards the
    /// menu hint is the way back to System Settings.
    private func requestScreenRecordingAccess() -> Bool {
        let granted = ScreenRecordingPermission.request()
        refreshScreenRecordingAccess()
        return granted
    }

    private func refreshScreenRecordingAccess() {
        let granted = ScreenRecordingPermission.isGranted
        guard granted != hasScreenRecordingAccess else { return }
        hasScreenRecordingAccess = granted
    }

    func captureFullScreen() {
        guard phase == .idle else { return }
        scrollIntent = nil
        guard requestScreenRecordingAccess() else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let metrics = screen.displayMetrics
        phase = .actionBar(ScreenSelection(
            metrics: metrics,
            pixelRect: PixelRect(x: 0, y: 0, width: metrics.pixelWidth, height: metrics.pixelHeight)
        ))
        presentFrozenOverlay()
    }

    func beginWindowCapture() {
        guard phase == .idle else { return }
        scrollIntent = nil
        guard requestScreenRecordingAccess() else { return }
        listedWindows = []
        phase = .windowPicking(nil)
        presentFrozenOverlay { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let windows = try await WindowCatalog.frontToBack()
                    guard self.phase.isPickingWindow else { return }
                    self.listedWindows = windows
                } catch {
                    guard self.phase.isPickingWindow else { return }
                    self.cancel()
                    AppAlert.show(title: "无法读取窗口", message: error.localizedDescription)
                }
            }
        }
    }

    func updateWindowHover(at point: CGPoint, metrics: DisplayMetrics) {
        guard phase.isPickingWindow else { return }
        guard let hit = WindowGeometry.hit(point: point, windows: listedWindows, screenFrame: metrics.pointFrame) else {
            phase = .windowPicking(nil)
            return
        }
        phase = .windowPicking(WindowHover(
            metrics: metrics,
            pixelRect: metrics.pixelRect(for: hit.visibleFrame),
            title: hit.window.title
        ))
    }

    func confirmWindow(at point: CGPoint, metrics: DisplayMetrics) {
        guard phase.isPickingWindow else { return }
        guard let hit = WindowGeometry.hit(point: point, windows: listedWindows, screenFrame: metrics.pointFrame) else { return }
        let pixelRect = metrics.pixelRect(for: hit.visibleFrame).clampedForSelection(in: metrics)
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return }
        phase = .actionBar(ScreenSelection(metrics: metrics, pixelRect: pixelRect))
    }

    func setFullScreenHotKeyEnabled(_ enabled: Bool) {
        HotKeyStore.setEnabled(HotKeySlotID.fullScreen, enabled)
        refreshHotKey(shouldAlert: false)
    }

    func setWindowHotKeyEnabled(_ enabled: Bool) {
        HotKeyStore.setEnabled(HotKeySlotID.window, enabled)
        refreshHotKey(shouldAlert: false)
    }

    func updateDrag(
        metrics: DisplayMetrics,
        anchor: CGPoint,
        current: CGPoint,
        constrainSquare: Bool,
        snapEnabled: Bool
    ) {
        guard case .selecting(let existing) = phase else { return }
        if let existing, existing.metrics.screenID != metrics.screenID { return }
        clearPreview()

        var currentPoint = current
        if snapEnabled, !constrainSquare {
            let pixel = metrics.pixelPoint(for: current, rounded: true)
            currentPoint = metrics.globalPoint(for: SnapEngine.snap(
                point: pixel,
                metrics: metrics,
                candidates: snapCandidates(for: metrics),
                threshold: SnapEngine.threshold(for: metrics)
            ))
        }
        phase = .selecting(SelectionDrag(
            metrics: metrics,
            anchor: anchor,
            current: currentPoint,
            constrainSquare: constrainSquare
        ))
    }

    /// Rounds a drag start to the nearest pixel and, if enabled, to a screen or
    /// window edge. The returned point is in global AppKit coordinates.
    func snappedPoint(_ point: CGPoint, metrics: DisplayMetrics, enabled: Bool) -> CGPoint {
        guard enabled else { return point }
        let pixel = metrics.pixelPoint(for: point, rounded: true)
        return metrics.globalPoint(for: SnapEngine.snap(
            point: pixel,
            metrics: metrics,
            candidates: snapCandidates(for: metrics),
            threshold: SnapEngine.threshold(for: metrics)
        ))
    }

    func endDrag(screenID: CGDirectDisplayID) {
        guard case .selecting(let drag) = phase, let drag, drag.screenID == screenID else { return }
        clearPreview()
        guard SelectionGeometry.isSubstantial(drag.globalRect) else {
            phase = .selecting(nil)
            return
        }
        phase = .actionBar(ScreenSelection(metrics: drag.metrics, pixelRect: drag.pixelRect))
    }

    func beginAdjustment(handle: SelectionHandle, at point: CGPoint) {
        guard case .actionBar(let selection) = phase else { return }
        clearPreview()
        adjustmentOrigin = selection.pixelRect
        adjustmentHandle = handle
        adjustmentAnchor = selection.metrics.pixelPoint(for: point, rounded: true)
    }

    func updateAdjustment(to point: CGPoint, snapEnabled: Bool) {
        guard case .actionBar(var selection) = phase,
              let handle = adjustmentHandle,
              let origin = adjustmentOrigin,
              let anchor = adjustmentAnchor else { return }

        let metrics = selection.metrics
        clearPreview()
        let pointPixel = metrics.pixelPoint(for: point, rounded: true)
        let candidates = snapCandidates(for: metrics)
        let threshold = SnapEngine.threshold(for: metrics)
        var next: PixelRect

        if handle == .move {
            let delta = PixelPoint(x: pointPixel.x - anchor.x, y: pointPixel.y - anchor.y)
            next = PixelSelectionGeometry.moved(origin, by: delta, in: metrics)
            if snapEnabled {
                next = SnapEngine.snapMoved(
                    next,
                    metrics: metrics,
                    candidates: candidates,
                    threshold: threshold
                )
            }
        } else {
            var target = pointPixel
            if snapEnabled {
                if PixelSelectionGeometry.movesX(handle),
                   let candidate = SnapEngine.nearest(to: target.x, axis: .vertical, candidates: candidates, threshold: threshold) {
                    target.x = candidate.coordinate
                }
                if PixelSelectionGeometry.movesY(handle),
                   let candidate = SnapEngine.nearest(to: target.y, axis: .horizontal, candidates: candidates, threshold: threshold) {
                    target.y = candidate.coordinate
                }
            }
            next = PixelSelectionGeometry.resized(origin, handle: handle, to: target, minimum: 1, in: metrics)
        }

        selection.pixelRect = next
        phase = .actionBar(selection)
    }

    func endAdjustment() {
        guard case .actionBar(var selection) = phase else { return }
        clearPreview()
        selection.pixelRect = selection.pixelRect.clampedForSelection(in: selection.metrics)
        adjustmentHandle = nil
        adjustmentOrigin = nil
        adjustmentAnchor = nil
        phase = .actionBar(selection)
    }

    func nudge(direction: NudgeDirection, step: Int) {
        guard case .actionBar(var selection) = phase else { return }
        clearPreview()
        selection.pixelRect = PixelSelectionGeometry.nudged(
            selection.pixelRect,
            direction: direction,
            step: max(1, step),
            in: selection.metrics
        )
        phase = .actionBar(selection)
    }

    func resizeSelection(direction: NudgeDirection, step: Int) {
        guard case .actionBar(var selection) = phase else { return }
        clearPreview()
        selection.pixelRect = PixelSelectionGeometry.adjustedTrailingEdge(
            selection.pixelRect,
            direction: direction,
            step: max(1, step),
            in: selection.metrics
        )
        phase = .actionBar(selection)
    }

    func setSelection(pixelRect: PixelRect) {
        guard case .actionBar(var selection) = phase else { return }
        clearPreview()
        selection.pixelRect = pixelRect.clampedForSelection(in: selection.metrics)
        phase = .actionBar(selection)
    }

    /// Updates only the preview chrome while the precision fields are edited. The
    /// action bar keeps its position, so the popover does not chase the selection.
    func previewSelection(_ pixelRect: PixelRect?) {
        guard case .actionBar(let selection) = phase else {
            previewRect = nil
            return
        }
        guard let pixelRect else {
            previewRect = nil
            return
        }
        previewRect = pixelRect.clampedForSelection(in: selection.metrics)
    }

    private func clearPreview() {
        if previewRect != nil {
            previewRect = nil
        }
    }

    private func adjustSelection(direction: NudgeDirection, step: Int, resizing: Bool) {
        if resizing {
            resizeSelection(direction: direction, step: step)
        } else {
            nudge(direction: direction, step: step)
        }
    }

    private func snapCandidates(for metrics: DisplayMetrics) -> [SnapCandidate] {
        SnapEngine.candidates(metrics: metrics, windows: snapWindows)
    }

    private func refreshSnapWindows() {
        Task {
            guard let windows = try? await WindowCatalog.frontToBack() else { return }
            guard phase.isSelecting || phase.showsActionBar else { return }
            snapWindows = windows
        }
    }

    func setShowLoupe(_ enabled: Bool) {
        showLoupe = enabled
        UserDefaults.standard.set(enabled, forKey: Self.showLoupeKey)
    }

    func setLoupePreset(_ preset: LoupePreset) {
        guard preset != loupePreset else { return }
        loupePreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: Self.loupePresetKey)
    }

    /// The frozen still for a display, taken when the overlay was requested.
    /// Selecting a region never re-grabs the screen, so the magnifier and the
    /// export show the same pixels.
    func frozenFrame(for displayID: CGDirectDisplayID) -> CGImage? {
        frozenScreens[displayID]
    }

    /// The selection's pixels out of the frozen frame, or nil when that display
    /// was not captured. Callers fall back to a live grab in that case.
    func frozenImage(for selection: ScreenSelection) -> CGImage? {
        guard let frame = frozenScreens[selection.screenID] else { return nil }
        return ScreenCaptureService.crop(frame, to: selection)
    }

    private func clearFrozenState() {
        clearPreview()
        frozenScreens.removeAll()
        snapWindows.removeAll()
    }

    func cancel() {
        guard phase != .idle else { return }
        removeKeyMonitor()
        overlay.close()
        frozenImage = nil
        selectedAnnotation = nil
        replaceAnnotation(AnnotationDocument())
        annotationUndoStack.removeAll()
        listedWindows = []
        scrollIntent = nil
        manualScrollPanel.close()
        if let control = manualScrollControl {
            Task { await control.requestCancel() }
            manualScrollControl = nil
        }
        clearPreview()
        clearFrozenState()
        phase = .idle
    }

    /// Starts whichever scrolling flow the menu or action bar selected.
    func startPendingScroll() {
        switch scrollIntent {
        case .automatic:
            startScrollStitch()
        case .manual:
            startManualScrollStitch()
        case nil:
            break
        }
    }

    private func startScrollStitch() {
        guard scrollIntent == .automatic, case .actionBar(let selection) = phase else { return }
        phase = .working(selection)
        overlay.hide()
        removeKeyMonitor()
        // Stitching follows the live screen, so the frozen frames are dead weight
        // from here on. Release them before the scroll loop allocates its slices.
        clearFrozenState()
        Task {
            await waitForOverlayToDisappear()
            let result = await ScrollCapture.run(selection: selection)
            guard phase == .working(selection) else { return }
            switch result {
            case .finished(let image):
                deliverScrollImage(image, selection: selection, partialMessage: nil)
            case .partial(let image, let message):
                deliverScrollImage(image, selection: selection, partialMessage: message)
            case nil:
                overlay.close()
                scrollIntent = nil
                clearFrozenState()
                phase = .idle
                AppAlert.show(title: "滚动长图失败", message: "没有截到可拼接的画面。")
            }
        }
    }

    /// The user drives the scroll; the capture loop only watches for the
    /// content to settle and appends what it sees.
    private func startManualScrollStitch() {
        guard scrollIntent == .manual, case .actionBar(let selection) = phase else { return }
        phase = .working(selection)
        overlay.hide()
        removeKeyMonitor()
        clearFrozenState()

        let control = ManualScrollControl()
        manualScrollControl = control
        manualScrollPanel.show(
            selection: selection,
            onFinish: { Task { await control.requestFinish() } },
            onCancel: { Task { await control.requestCancel() } }
        )
        Task {
            await waitForOverlayToDisappear()
            let outcome = await ManualScrollCapture.run(
                selection: selection,
                control: control
            ) { progress in
                self.manualScrollPanel.update(progress)
            }
            guard phase == .working(selection) else { return }
            finishManualScroll(outcome, selection: selection)
        }
    }

    private func finishManualScroll(_ outcome: ManualScrollOutcome, selection: ScreenSelection) {
        manualScrollControl = nil
        switch outcome {
        case .cancelled:
            manualScrollPanel.close()
            overlay.close()
            scrollIntent = nil
            clearFrozenState()
            phase = .idle
            overlay.showHUD("已取消", screenFrame: selection.screenFrame)
        case .failed:
            manualScrollPanel.close()
            overlay.close()
            scrollIntent = nil
            clearFrozenState()
            phase = .idle
            AppAlert.show(title: "手动滚动失败", message: "没有截到可拼接的画面。")
        case .finished(let image):
            deliverScrollImage(image, selection: selection, partialMessage: nil)
        case .partial(let image, let message):
            deliverScrollImage(
                image,
                selection: selection,
                partialMessage: message,
                partialTitle: "手动滚动未完成"
            )
        }
    }

    private func deliverScrollImage(
        _ image: CGImage,
        selection: ScreenSelection,
        partialMessage: String?,
        partialTitle: String = "没有滚到底"
    ) {
        manualScrollControl = nil
        do {
            // Encoding a tall PNG can take a moment. Keep the manual panel's
            // "正在完成…" state on screen until the clipboard is ready.
            try ImageExport.copyToPasteboard(image)
            manualScrollPanel.close()
            overlay.close()
            scrollIntent = nil
            clearFrozenState()
            phase = .idle
            overlay.showHUD("已复制", screenFrame: selection.screenFrame)
            if let partialMessage {
                AppAlert.show(title: partialTitle, message: partialMessage)
            }
        } catch {
            manualScrollPanel.close()
            overlay.close()
            scrollIntent = nil
            clearFrozenState()
            phase = .idle
            AppAlert.show(title: "滚动长图失败", message: error.localizedDescription)
        }
    }

    func beginAnnotation() {
        guard case .actionBar(let selection) = phase else { return }
        selectedAnnotation = nil
        replaceAnnotation(AnnotationDocument())
        annotationUndoStack.removeAll()
        phase = .editing(selection)
        // The frozen frame is already the right pixels, so annotation starts
        // synchronously. Only a display that failed to freeze falls back to a
        // live grab.
        if let image = frozenImage(for: selection) {
            frozenImage = image
            annotationChanges.send()
            return
        }
        Task {
            do {
                let image = try await ScreenCaptureService.capture(selection)
                guard case .editing(let current) = phase, current == selection else { return }
                frozenImage = image
                annotationChanges.send()
            } catch {
                guard case .editing(let current) = phase, current == selection else { return }
                restoreActionBar(selection)
                AppAlert.show(title: "截屏失败", message: error.localizedDescription)
            }
        }
    }

    func setAnnotationTool(_ tool: AnnotationTool) {
        guard phase.isEditing else { return }
        mutateAnnotation { $0.tool = tool }
    }

    func setAnnotationColor(_ color: AnnotationColor) {
        guard phase.isEditing else { return }
        mutateAnnotation { $0.style.color = color }
    }

    func setAnnotationLineWidth(_ width: CGFloat) {
        guard phase.isEditing else { return }
        mutateAnnotation { $0.style.lineWidth = width }
    }

    func setAnnotationDraft(_ stroke: AnnotationStroke?) {
        guard phase.isEditing else { return }
        mutateAnnotation { $0.draft = stroke }
    }

    func updateAnnotationRectangle(at index: Int, to rect: CGRect) {
        guard phase.isEditing else { return }
        mutateAnnotation { $0.updateRectangle(at: index, to: rect) }
    }

    /// Replaces any annotation's geometry, keeping the array order.
    func updateAnnotationStroke(at index: Int, with stroke: AnnotationStroke) {
        guard phase.isEditing, annotation.strokes.indices.contains(index) else { return }
        mutateAnnotation { $0.strokes[index] = stroke }
    }

    func selectAnnotation(at index: Int?) {
        guard phase.isEditing else { return }
        if let index, annotation.strokes.indices.contains(index) {
            selectedAnnotation = index
        } else {
            selectedAnnotation = nil
        }
        // Selection is view state, but observers still need a redraw.
        annotationChanges.send()
    }

    func deleteSelectedAnnotation() {
        guard phase.isEditing,
              let index = selectedAnnotation,
              annotation.strokes.indices.contains(index) else { return }
        recordAnnotationUndoPoint()
        selectedAnnotation = nil
        mutateAnnotation { $0.strokes.remove(at: index) }
    }

    /// Moves the selection by `delta`, in image pixels, without leaving the screenshot.
    func moveSelectedAnnotation(by delta: CGPoint) {
        guard phase.isEditing,
              let index = selectedAnnotation,
              let image = frozenImage,
              annotation.strokes.indices.contains(index) else { return }
        let stroke = annotation.strokes[index]
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = AnnotationGeometry.clampedTranslation(of: stroke, by: delta, within: bounds)
        guard clamped != .zero else { return }
        recordAnnotationUndoPoint()
        updateAnnotationStroke(at: index, with: stroke.translated(by: clamped))
    }

    /// Records an undo step before an in-place edit such as resizing, moving, or deleting.
    func recordAnnotationUndoPoint() {
        guard phase.isEditing else { return }
        annotationUndoStack.append(AnnotationUndoStep(
            strokes: annotation.strokes,
            selectedAnnotation: selectedAnnotation
        ))
    }

    func commitAnnotationDraft() {
        guard phase.isEditing else { return }
        guard let draft = annotation.draft, AnnotationDocument.isVisible(draft) else {
            mutateAnnotation { $0.draft = nil }
            return
        }
        recordAnnotationUndoPoint()
        var document = annotation
        document.commitDraft()
        selectedAnnotation = document.strokes.isEmpty ? nil : document.strokes.count - 1
        replaceAnnotation(document)
    }

    func undoAnnotation() {
        guard phase.isEditing else { return }
        if annotation.draft != nil {
            mutateAnnotation { $0.undo() }
            return
        }
        if let step = annotationUndoStack.popLast() {
            var document = annotation
            document.strokes = step.strokes
            document.draft = nil
            selectedAnnotation = step.selectedAnnotation
            replaceAnnotation(document)
            return
        }
        mutateAnnotation { $0.undo() }
    }

    func copyRecognizedText() {
        guard case .editing(let selection) = phase, let image = frozenImage else { return }
        do {
            let text = try TextRecognition.recognize(image)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            overlay.showHUD("已拷贝文字", screenFrame: selection.screenFrame)
        } catch {
            AppAlert.show(title: "没有识别到文字", message: "这张图里的文字没有被识别出来，截图还在。")
        }
    }

    func copySelection() {
        if case .editing(let selection) = phase {
            exportEditing(selection, save: false)
            return
        }
        guard case .actionBar(let selection) = phase else { return }
        if let image = frozenImage(for: selection) {
            deliverSelectionImage(image, selection: selection, save: false)
            return
        }
        captureLiveSelection(selection, save: false)
    }

    func saveSelection() {
        if case .editing(let selection) = phase {
            exportEditing(selection, save: true)
            return
        }
        guard case .actionBar(let selection) = phase else { return }
        if let image = frozenImage(for: selection) {
            deliverSelectionImage(image, selection: selection, save: true)
            return
        }
        captureLiveSelection(selection, save: true)
    }

    /// Fallback for a display that failed to freeze: hide the overlay, let it leave
    /// the screen, then grab the pixels now. The normal path never does this.
    private func captureLiveSelection(_ selection: ScreenSelection, save: Bool) {
        phase = .working(selection)
        overlay.hide()
        removeKeyMonitor()
        Task {
            do {
                await waitForOverlayToDisappear()
                let image = try await ScreenCaptureService.capture(selection)
                deliverSelectionImage(image, selection: selection, save: save)
            } catch {
                restoreActionBar(selection)
                AppAlert.show(
                    title: save ? "无法保存截屏" : "截屏失败",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Copies or saves an image that was already taken. The save panel changes the
    /// activation policy, so the overlay steps aside and comes back if it is cancelled.
    private func deliverSelectionImage(_ image: CGImage, selection: ScreenSelection, save: Bool) {
        if !save {
            do {
                try ImageExport.copyToPasteboard(image)
                overlay.close()
                clearFrozenState()
                phase = .idle
                overlay.showHUD("已复制", screenFrame: selection.screenFrame)
            } catch {
                restoreActionBar(selection)
                AppAlert.show(title: "截屏失败", message: error.localizedDescription)
            }
            return
        }
        overlay.hide()
        removeKeyMonitor()
        do {
            switch try ImageExport.saveWithPanel(image) {
            case .saved:
                overlay.close()
                clearFrozenState()
                phase = .idle
                overlay.showHUD("已保存", screenFrame: selection.screenFrame)
            case .cancelled:
                restoreActionBar(selection)
            }
        } catch {
            restoreActionBar(selection)
            AppAlert.show(title: "无法保存截屏", message: error.localizedDescription)
        }
    }

    func refreshHotKey(shouldAlert: Bool) {
        regionChord = HotKeyStore.load(HotKeySlotID.region)
        fullScreenChord = HotKeyStore.load(HotKeySlotID.fullScreen)
        windowChord = HotKeyStore.load(HotKeySlotID.window)
        fullScreenHotKeyEnabled = HotKeyStore.isEnabled(HotKeySlotID.fullScreen)
        windowHotKeyEnabled = HotKeyStore.isEnabled(HotKeySlotID.window)
        let conflicts = hotKeys.refresh(registrations())
        let conflict = conflicts[HotKeySlotID.region] ?? .none
        hotKeyConflict = conflict
        fullScreenConflict = fullScreenHotKeyEnabled ? (conflicts[HotKeySlotID.fullScreen] ?? .none) : .none
        windowConflict = windowHotKeyEnabled ? (conflicts[HotKeySlotID.window] ?? .none) : .none
        guard shouldAlert, conflict != .none else { return }
        guard !UserDefaults.standard.bool(forKey: conflictAlertKey) else { return }
        UserDefaults.standard.set(true, forKey: conflictAlertKey)
        presentConflictAlert(conflict)
    }

    private func registrations() -> [HotKeyRegistration] {
        var items = [HotKeyRegistration(id: HotKeySlotID.region, chord: regionChord)]
        if fullScreenHotKeyEnabled {
            items.append(HotKeyRegistration(id: HotKeySlotID.fullScreen, chord: fullScreenChord))
        }
        if windowHotKeyEnabled {
            items.append(HotKeyRegistration(id: HotKeySlotID.window, chord: windowChord))
        }
        return items
    }

    private func mutateAnnotation(_ body: (inout AnnotationDocument) -> Void) {
        var copy = annotation
        body(&copy)
        replaceAnnotation(copy)
    }

    private func replaceAnnotation(_ document: AnnotationDocument) {
        annotation = document
        if let index = selectedAnnotation, !document.strokes.indices.contains(index) {
            selectedAnnotation = nil
        }
        annotationChanges.send()
    }

    private func compositedImage() -> CGImage? {
        guard let frozenImage else { return nil }
        return AnnotationRenderer.composite(base: frozenImage, document: annotation)
    }

    private func exportEditing(_ selection: ScreenSelection, save: Bool) {
        guard let image = compositedImage() else {
            AppAlert.show(title: "无法生成图片", message: "标注后的图片没有生成。")
            return
        }
        if !save {
            do {
                try ImageExport.copyToPasteboard(image)
                removeKeyMonitor()
                overlay.close()
                frozenImage = nil
                replaceAnnotation(AnnotationDocument())
                clearFrozenState()
                phase = .idle
                overlay.showHUD("已复制", screenFrame: selection.screenFrame)
            } catch {
                AppAlert.show(title: "截屏失败", message: error.localizedDescription)
            }
            return
        }
        overlay.hide()
        removeKeyMonitor()
        do {
            switch try ImageExport.saveWithPanel(image) {
            case .saved:
                overlay.close()
                frozenImage = nil
                replaceAnnotation(AnnotationDocument())
                clearFrozenState()
                phase = .idle
                overlay.showHUD("已保存", screenFrame: selection.screenFrame)
            case .cancelled:
                phase = .editing(selection)
                // The save panel temporarily changes the activation policy, so
                // reactivate on the next run loop turn instead of while it closes.
                DispatchQueue.main.async { [weak self] in
                    guard let self, case .editing = self.phase else { return }
                    self.overlay.show()
                    self.installKeyMonitor()
                }
            }
        } catch {
            phase = .editing(selection)
            overlay.show()
            installKeyMonitor()
            AppAlert.show(title: "无法保存截屏", message: error.localizedDescription)
        }
    }

    private func restoreActionBar(_ selection: ScreenSelection) {
        phase = .actionBar(selection)
        DispatchQueue.main.async { [weak self] in
            guard let self, case .actionBar = self.phase else { return }
            self.overlay.show()
            self.installKeyMonitor()
        }
    }

    private func waitForOverlayToDisappear() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let command = event.modifierFlags.contains(.command)
            let option = event.modifierFlags.contains(.option)
            let editingText = event.window?.firstResponder is NSTextView
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                self.handleKeyCode(
                    keyCode,
                    nudgeStep: step,
                    command: command,
                    editingText: editingText,
                    option: option
                )
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func nudgeSelectedAnnotation(dx: Int, dy: Int, step: CGFloat) {
        guard case .editing(let selection) = phase,
              let image = frozenImage,
              selection.globalRect.width > 0 else { return }
        // Nudge in screen points, translated to image pixels for Retina captures.
        let imageScale = CGFloat(image.width) / selection.globalRect.width
        moveSelectedAnnotation(by: CGPoint(
            x: CGFloat(dx) * step * imageScale,
            y: CGFloat(dy) * step * imageScale
        ))
    }

    private func handleKeyCode(
        _ keyCode: UInt16,
        nudgeStep: CGFloat,
        command: Bool,
        editingText: Bool,
        option: Bool
    ) -> Bool {
        if editingText { return false }
        switch keyCode {
        case CaptureKeyCode.escape:
            if phase.isEditing, annotation.draft != nil {
                undoAnnotation()
                return true
            }
            cancel()
            return true
        case 6 where command && phase.isEditing:
            undoAnnotation()
            return true
        case 51 where phase.isEditing, 117 where phase.isEditing:
            guard selectedAnnotation != nil else { return false }
            deleteSelectedAnnotation()
            return true
        case 123 where phase.isEditing && selectedAnnotation != nil:
            nudgeSelectedAnnotation(dx: -1, dy: 0, step: nudgeStep)
            return true
        case 124 where phase.isEditing && selectedAnnotation != nil:
            nudgeSelectedAnnotation(dx: 1, dy: 0, step: nudgeStep)
            return true
        case 125 where phase.isEditing && selectedAnnotation != nil:
            nudgeSelectedAnnotation(dx: 0, dy: 1, step: nudgeStep)
            return true
        case 126 where phase.isEditing && selectedAnnotation != nil:
            nudgeSelectedAnnotation(dx: 0, dy: -1, step: nudgeStep)
            return true
        case CaptureKeyCode.returnKey, CaptureKeyCode.keypadEnter:
            if phase.showsActionBar {
                if scrollIntent != nil {
                    startPendingScroll()
                } else {
                    copySelection()
                }
                return true
            }
            return false
        case 123 where phase.showsActionBar:
            adjustSelection(direction: .left, step: Int(nudgeStep), resizing: option)
            return true
        case 124 where phase.showsActionBar:
            adjustSelection(direction: .right, step: Int(nudgeStep), resizing: option)
            return true
        case 125 where phase.showsActionBar:
            adjustSelection(direction: .down, step: Int(nudgeStep), resizing: option)
            return true
        case 126 where phase.showsActionBar:
            adjustSelection(direction: .up, step: Int(nudgeStep), resizing: option)
            return true
        default:
            return false
        }
    }

    func beginHotKeyChange(for slot: UInt32) {
        let captured = HotKeyRecorder.capture(
            title: "更改\(HotKeySlotID.title(for: slot))快捷键",
            suspend: { self.hotKeys.suspend() },
            resume: { self.refreshHotKey(shouldAlert: false) }
        )
        guard let captured else { return }
        let conflict = hotKeys.probe(captured, restoring: registrations())
        guard conflict == .none else {
            AppAlert.show(
                title: "快捷键不可用",
                message: conflict.alertMessage(for: captured) ?? "这个快捷键无法使用。"
            )
            return
        }
        HotKeyStore.save(captured, for: slot)
        refreshHotKey(shouldAlert: false)
    }

    /// Restores the built-in chords and re-enables the optional shortcuts.
    func resetHotKeys() {
        for slot in HotKeySlotID.all {
            HotKeyStore.reset(slot)
        }
        HotKeyStore.setEnabled(HotKeySlotID.fullScreen, true)
        HotKeyStore.setEnabled(HotKeySlotID.window, true)
        refreshHotKey(shouldAlert: false)
    }

    @objc private func applicationDidBecomeActive() {
        refreshScreenRecordingAccess()
        refreshHotKey(shouldAlert: true)
    }

    @objc private func menuDidBeginTracking() {
        refreshScreenRecordingAccess()
    }

    private func presentConflictAlert(_ conflict: HotKeyConflict) {
        guard let message = conflict.alertMessage(for: regionChord) else { return }
        DispatchQueue.main.async { [weak self] in
            let choice = AppAlert.choose(
                title: "快捷键不可用",
                message: message,
                buttons: ["更改快捷键", "好"]
            )
            if choice == 0 {
                self?.beginHotKeyChange(for: HotKeySlotID.region)
            }
        }
    }
}
