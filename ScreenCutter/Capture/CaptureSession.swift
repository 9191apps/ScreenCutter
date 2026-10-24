import AppKit
import Combine
import Foundation

@MainActor
final class CaptureSession: NSObject, ObservableObject {
    @Published private(set) var phase: CapturePhase = .idle
    @Published private(set) var hotKeyConflict: HotKeyConflict = .none
    @Published private(set) var regionChord: HotKeyChord = .regionCapture
    @Published private(set) var fullScreenHotKeyEnabled = true
    @Published private(set) var windowHotKeyEnabled = true
    @Published private(set) var fullScreenConflict: HotKeyConflict = .none
    @Published private(set) var windowConflict: HotKeyConflict = .none
    @Published private(set) var hasScreenRecordingAccess = ScreenRecordingPermission.isGranted

    private let hotKeys = HotKeyMonitor()
    private let overlay = OverlayController()
    private var keyMonitor: Any?
    private let conflictAlertKey = "didShowHotKeyConflictAlert"
    private var listedWindows: [ListedWindow] = []
    private var frozenImage: CGImage?
    private(set) var annotation = AnnotationDocument()
    private(set) var selectedAnnotation: Int?
    let annotationChanges = PassthroughSubject<Void, Never>()
    @Published private(set) var scrollIntent = false
    @Published private(set) var showLoupe: Bool
    @Published private(set) var previewRect: PixelRect?
    @Published private(set) var snapshotVersion = 0

    private static let showLoupeKey = "showSelectionLoupe"

    /// One undo step: the strokes as they were before an edit. Tool, color, and
    /// line width are intentionally not stored, so undo does not change them.
    private struct AnnotationUndoStep {
        var strokes: [AnnotationStroke]
        var selectedAnnotation: Int?
    }

    private var annotationUndoStack: [AnnotationUndoStep] = []

    var editingImage: CGImage? { frozenImage }
    private var adjustmentOrigin: PixelRect?
    private var adjustmentHandle: SelectionHandle?
    private var adjustmentAnchor: PixelPoint?
    private var snapWindows: [ListedWindow] = []
    private var displaySnapshots: [CGDirectDisplayID: CGImage] = [:]
    private var snapshotDates: [CGDirectDisplayID: Date] = [:]
    private var snapshotRequests: Set<CGDirectDisplayID> = []

#if DEBUG
    /// Testing hook: drives the overlay without screen recording permission or a live capture.
    func setPhaseForTesting(_ phase: CapturePhase) {
        self.phase = phase
    }

    /// Testing hook: supplies the frozen image that annotation drawing operates on.
    func setEditingImageForTesting(_ image: CGImage?) {
        frozenImage = image
        annotationChanges.send()
    }
#endif

    override init() {
        showLoupe = UserDefaults.standard.object(forKey: Self.showLoupeKey) as? Bool ?? true
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
        scrollIntent = false
        startSelection()
    }

    func beginScrollCapture() {
        guard phase == .idle else { return }
        scrollIntent = true
        startSelection()
    }

    private func startSelection() {
        guard phase == .idle else { return }
        guard requestScreenRecordingAccess() else { return }
        phase = .selecting(nil)
        overlay.present(session: self)
        installKeyMonitor()
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            ensureSnapshot(displayID: screen.displayID)
        }
        refreshSnapWindows()
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
        guard requestScreenRecordingAccess() else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let metrics = screen.displayMetrics
        phase = .actionBar(ScreenSelection(
            metrics: metrics,
            pixelRect: PixelRect(x: 0, y: 0, width: metrics.pixelWidth, height: metrics.pixelHeight)
        ))
        overlay.present(session: self)
        installKeyMonitor()
    }

    func beginWindowCapture() {
        guard phase == .idle else { return }
        guard requestScreenRecordingAccess() else { return }
        listedWindows = []
        phase = .windowPicking(nil)
        overlay.present(session: self)
        installKeyMonitor()
        Task {
            do {
                let windows = try await WindowCatalog.frontToBack()
                guard phase.isPickingWindow else { return }
                listedWindows = windows
            } catch {
                guard phase.isPickingWindow else { return }
                cancel()
                AppAlert.show(title: "无法读取窗口", message: error.localizedDescription)
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
        // The loupe only runs during the drag; do not keep a full-screen frame
        // alive for the action bar phase.
        clearSnapshots()
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
        guard enabled, phase.isSelecting else { return }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            ensureSnapshot(displayID: screen.displayID)
        }
    }

    func ensureSnapshot(displayID: CGDirectDisplayID) {
        ensureSnapshot(displayID: displayID, force: false)
    }

    /// The loupe is a freeze-frame. Take a fresh one when a drag starts after the
    /// previous capture has gone stale, while keeping the old image visible until
    /// the new one arrives.
    func refreshSnapshotIfStale(displayID: CGDirectDisplayID) {
        guard showLoupe else { return }
        if let date = snapshotDates[displayID], Date().timeIntervalSince(date) < 1 {
            return
        }
        ensureSnapshot(displayID: displayID, force: true)
    }

    private func ensureSnapshot(displayID: CGDirectDisplayID, force: Bool) {
        guard showLoupe, !snapshotRequests.contains(displayID) else { return }
        if !force, displaySnapshots[displayID] != nil { return }
        snapshotRequests.insert(displayID)
        Task {
            defer { snapshotRequests.remove(displayID) }
            let pixelSize = NSScreen.screens
                .first(where: { $0.displayID == displayID })?
                .displayMetrics.pixelSize
            guard let image = try? await ScreenCaptureService.snapshot(
                displayID: displayID,
                pixelSize: pixelSize
            ) else { return }
            guard phase.isSelecting else { return }
            displaySnapshots[displayID] = image
            snapshotDates[displayID] = Date()
            snapshotVersion += 1
        }
    }

    func snapshot(for displayID: CGDirectDisplayID) -> CGImage? {
        displaySnapshots[displayID]
    }

    private func clearSnapshots() {
        displaySnapshots.removeAll()
        snapshotDates.removeAll()
        snapshotRequests.removeAll()
    }

    private func clearSnapshotState() {
        clearPreview()
        clearSnapshots()
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
        scrollIntent = false
        clearPreview()
        clearSnapshotState()
        phase = .idle
    }

    func startScrollStitch() {
        guard scrollIntent, case .actionBar(let selection) = phase else { return }
        phase = .working(selection)
        overlay.hide()
        removeKeyMonitor()
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
                scrollIntent = false
                clearSnapshotState()
                phase = .idle
                AppAlert.show(title: "滚动长图失败", message: "没有截到可拼接的画面。")
            }
        }
    }

    private func deliverScrollImage(_ image: CGImage, selection: ScreenSelection, partialMessage: String?) {
        do {
            try ImageExport.copyToPasteboard(image)
            overlay.close()
            scrollIntent = false
            clearSnapshotState()
            phase = .idle
            overlay.showHUD("已复制", screenFrame: selection.screenFrame)
            if let partialMessage {
                AppAlert.show(title: "没有滚到底", message: partialMessage)
            }
        } catch {
            overlay.close()
            scrollIntent = false
            clearSnapshotState()
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
        phase = .working(selection)
        overlay.hide()
        removeKeyMonitor()
        Task {
            do {
                await waitForOverlayToDisappear()
                let image = try await ScreenCaptureService.capture(selection)
                try ImageExport.copyToPasteboard(image)
                overlay.close()
                clearSnapshotState()
                phase = .idle
                overlay.showHUD("已复制", screenFrame: selection.screenFrame)
            } catch {
                overlay.close()
                clearSnapshotState()
                phase = .idle
                AppAlert.show(title: "截屏失败", message: error.localizedDescription)
            }
        }
    }

    func saveSelection() {
        if case .editing(let selection) = phase {
            exportEditing(selection, save: true)
            return
        }
        guard case .actionBar(let selection) = phase else { return }
        phase = .working(selection)
        overlay.hide()
        removeKeyMonitor()
        Task {
            do {
                await waitForOverlayToDisappear()
                let image = try await ScreenCaptureService.capture(selection)
                switch try ImageExport.saveWithPanel(image) {
                case .saved:
                    overlay.close()
                    clearSnapshotState()
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
    }

    func refreshHotKey(shouldAlert: Bool) {
        regionChord = HotKeyStore.loadRegion()
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
            items.append(HotKeyRegistration(id: HotKeySlotID.fullScreen, chord: .fullScreen))
        }
        if windowHotKeyEnabled {
            items.append(HotKeyRegistration(id: HotKeySlotID.window, chord: .window))
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
                clearSnapshotState()
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
                clearSnapshotState()
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
                if scrollIntent {
                    startScrollStitch()
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

    func beginHotKeyChange() {
        guard let chord = HotKeyRecorder.capture() else { return }
        let conflict = hotKeys.probe(chord, restoring: registrations())
        guard conflict == .none else {
            AppAlert.show(
                title: "快捷键不可用",
                message: conflict.alertMessage(for: chord) ?? "这个快捷键无法使用。"
            )
            return
        }
        HotKeyStore.saveRegion(chord)
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
                self?.beginHotKeyChange()
            }
        }
    }
}
