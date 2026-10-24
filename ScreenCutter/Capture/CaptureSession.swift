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

    /// One undo step: the strokes as they were before an edit. Tool, color, and
    /// line width are intentionally not stored, so undo does not change them.
    private struct AnnotationUndoStep {
        var strokes: [AnnotationStroke]
        var selectedAnnotation: Int?
    }

    private var annotationUndoStack: [AnnotationUndoStep] = []

    var editingImage: CGImage? { frozenImage }
    private var adjustmentOrigin: CGRect?
    private var adjustmentHandle: SelectionHandle?
    private var adjustmentAnchor: CGPoint?

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
        guard ScreenRecordingPermission.ensureAccess() else { return }
        phase = .selecting(nil)
        overlay.present(session: self)
        installKeyMonitor()
    }

    func captureFullScreen() {
        guard phase == .idle else { return }
        guard ScreenRecordingPermission.ensureAccess() else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let rect = SelectionGeometry.pixelAligned(screen.frame, scale: screen.backingScaleFactor)
        phase = .actionBar(ScreenSelection(
            screenID: screen.displayID,
            screenFrame: screen.frame,
            scale: screen.backingScaleFactor,
            globalRect: rect
        ))
        overlay.present(session: self)
        installKeyMonitor()
    }

    func beginWindowCapture() {
        guard phase == .idle else { return }
        guard ScreenRecordingPermission.ensureAccess() else { return }
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

    func updateWindowHover(at point: CGPoint, screenID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat) {
        guard phase.isPickingWindow else { return }
        guard let hit = WindowGeometry.hit(point: point, windows: listedWindows, screenFrame: screenFrame) else {
            phase = .windowPicking(nil)
            return
        }
        phase = .windowPicking(WindowHover(
            screenID: screenID,
            screenFrame: screenFrame,
            scale: scale,
            globalRect: hit.visibleFrame,
            title: hit.window.title
        ))
    }

    func confirmWindow(at point: CGPoint, screenID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat) {
        guard phase.isPickingWindow else { return }
        guard let hit = WindowGeometry.hit(point: point, windows: listedWindows, screenFrame: screenFrame) else { return }
        var rect = SelectionGeometry.pixelAligned(hit.visibleFrame, scale: scale)
        rect = SelectionGeometry.clamped(rect, to: screenFrame)
        guard SelectionGeometry.isSubstantial(rect) else { return }
        phase = .actionBar(ScreenSelection(
            screenID: screenID,
            screenFrame: screenFrame,
            scale: scale,
            globalRect: rect
        ))
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
        screenID: CGDirectDisplayID,
        screenFrame: CGRect,
        scale: CGFloat,
        anchor: CGPoint,
        current: CGPoint,
        constrainSquare: Bool
    ) {
        guard case .selecting(let existing) = phase else { return }
        if let existing, existing.screenID != screenID { return }
        phase = .selecting(SelectionDrag(
            screenID: screenID,
            screenFrame: screenFrame,
            scale: scale,
            anchor: anchor,
            current: current,
            constrainSquare: constrainSquare
        ))
    }

    func endDrag(screenID: CGDirectDisplayID) {
        guard case .selecting(let drag) = phase, let drag, drag.screenID == screenID else { return }
        let rect = drag.globalRect
        guard SelectionGeometry.isSubstantial(rect) else {
            phase = .selecting(nil)
            return
        }
        phase = .actionBar(ScreenSelection(
            screenID: drag.screenID,
            screenFrame: drag.screenFrame,
            scale: drag.scale,
            globalRect: rect
        ))
    }

    func beginAdjustment(handle: SelectionHandle, at point: CGPoint) {
        guard case .actionBar(let selection) = phase else { return }
        adjustmentOrigin = selection.globalRect
        adjustmentHandle = handle
        adjustmentAnchor = point
    }

    func updateAdjustment(to point: CGPoint) {
        guard case .actionBar(var selection) = phase,
              let handle = adjustmentHandle,
              let origin = adjustmentOrigin,
              let anchor = adjustmentAnchor else { return }
        let next: CGRect
        if handle == .move {
            next = SelectionGeometry.moved(
                origin,
                by: CGPoint(x: point.x - anchor.x, y: point.y - anchor.y),
                within: selection.screenFrame
            )
        } else {
            let resized = SelectionGeometry.resized(origin, handle: handle, to: point)
            next = SelectionGeometry.clamped(resized, to: selection.screenFrame)
        }
        selection.globalRect = next
        phase = .actionBar(selection)
    }

    func endAdjustment() {
        guard case .actionBar(var selection) = phase else { return }
        var aligned = SelectionGeometry.pixelAligned(selection.globalRect, scale: selection.scale)
        aligned = SelectionGeometry.clamped(aligned, to: selection.screenFrame)
        if SelectionGeometry.isSubstantial(aligned) {
            selection.globalRect = aligned
        } else if let origin = adjustmentOrigin {
            selection.globalRect = origin
        }
        phase = .actionBar(selection)
        adjustmentHandle = nil
        adjustmentOrigin = nil
        adjustmentAnchor = nil
    }

    func nudge(direction: NudgeDirection, by step: CGFloat) {
        guard case .actionBar(var selection) = phase else { return }
        var next = SelectionGeometry.nudged(
            selection.globalRect,
            direction: direction,
            step: step,
            within: selection.screenFrame
        )
        next = SelectionGeometry.pixelAligned(next, scale: selection.scale)
        next = SelectionGeometry.clamped(next, to: selection.screenFrame)
        guard SelectionGeometry.isSubstantial(next) else { return }
        selection.globalRect = next
        phase = .actionBar(selection)
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
            phase = .idle
            overlay.showHUD("已复制", screenFrame: selection.screenFrame)
            if let partialMessage {
                AppAlert.show(title: "没有滚到底", message: partialMessage)
            }
        } catch {
            overlay.close()
            scrollIntent = false
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
                phase = .idle
                overlay.showHUD("已复制", screenFrame: selection.screenFrame)
            } catch {
                overlay.close()
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
            let editingText = event.window?.firstResponder is NSTextView
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                self.handleKeyCode(keyCode, nudgeStep: step, command: command, editingText: editingText)
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

    private func handleKeyCode(_ keyCode: UInt16, nudgeStep: CGFloat, command: Bool, editingText: Bool) -> Bool {
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
        case 51, 117 where phase.isEditing:
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
            nudge(direction: .left, by: nudgeStep)
            return true
        case 124 where phase.showsActionBar:
            nudge(direction: .right, by: nudgeStep)
            return true
        case 125 where phase.showsActionBar:
            nudge(direction: .down, by: nudgeStep)
            return true
        case 126 where phase.showsActionBar:
            nudge(direction: .up, by: nudgeStep)
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
        refreshHotKey(shouldAlert: true)
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
