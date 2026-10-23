import AppKit
import Combine
import Foundation

@MainActor
final class CaptureSession: NSObject, ObservableObject {
    @Published private(set) var phase: CapturePhase = .idle
    @Published private(set) var hotKeyConflict: HotKeyConflict = .none

    private let hotKeys = HotKeyMonitor()
    private let overlay = OverlayController()
    private var keyMonitor: Any?
    private let conflictAlertKey = "didShowHotKeyConflictAlert"

    override init() {
        super.init()
        hotKeys.onPressed = { [weak self] in
            self?.begin()
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
        guard phase == .idle else { return }
        guard ScreenRecordingPermission.ensureAccess() else { return }
        phase = .selecting(nil)
        overlay.present(session: self)
        installKeyMonitor()
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

    func cancel() {
        guard phase != .idle else { return }
        removeKeyMonitor()
        overlay.close()
        phase = .idle
    }

    func copySelection() {
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
        let conflict = hotKeys.refresh()
        hotKeyConflict = conflict
        guard shouldAlert, conflict != .none else { return }
        guard !UserDefaults.standard.bool(forKey: conflictAlertKey) else { return }
        UserDefaults.standard.set(true, forKey: conflictAlertKey)
        presentConflictAlert(conflict)
    }

    private func restoreActionBar(_ selection: ScreenSelection) {
        phase = .actionBar(selection)
        overlay.show()
        installKeyMonitor()
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
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                self.handleKeyCode(keyCode)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func handleKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case CaptureKeyCode.escape:
            cancel()
            return true
        case CaptureKeyCode.returnKey, CaptureKeyCode.keypadEnter:
            if phase.showsActionBar {
                copySelection()
                return true
            }
            return false
        default:
            return false
        }
    }

    @objc private func applicationDidBecomeActive() {
        refreshHotKey(shouldAlert: true)
    }

    private func presentConflictAlert(_ conflict: HotKeyConflict) {
        guard let message = conflict.alertMessage else { return }
        DispatchQueue.main.async {
            AppAlert.show(title: "快捷键不可用", message: message)
        }
    }
}
