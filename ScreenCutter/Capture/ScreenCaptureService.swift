import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayUnavailable
    case emptySelection
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "找不到对应的显示器。"
        case .emptySelection:
            return "选区太小。"
        case .encodingFailed:
            return "无法生成图片。"
        }
    }
}

nonisolated struct CaptureOutput: Equatable, Sendable {
    /// Native framebuffer size. A smaller buffer, or a partial `sourceRect`, is scaled and softens text.
    var width: Int
    var height: Int
    var crop: CGRect
    var scalesToFit = false
}

enum ScreenCaptureService {
    nonisolated static func output(
        for selection: ScreenSelection,
        pixelWidth: CGFloat,
        pixelHeight: CGFloat
    ) -> CaptureOutput {
        let width = Int(pixelWidth.rounded())
        let height = Int(pixelHeight.rounded())
        let crop = selection.pixelRect
            .scaled(from: selection.metrics.pixelSize, to: CGSize(width: width, height: height))
            .clamped(toWidth: width, height: height)
        return CaptureOutput(width: width, height: height, crop: crop.cgRect, scalesToFit: false)
    }

    static func capture(_ selection: ScreenSelection) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selection.screenID }) else {
            throw CaptureError.displayUnavailable
        }

        let bounds = CGDisplayBounds(selection.screenID)
        let mode = CGDisplayCopyDisplayMode(selection.screenID)
        let pixelWidth = CGFloat(mode?.pixelWidth ?? 0)
        let pixelHeight = CGFloat(mode?.pixelHeight ?? 0)
        let frameWidth = pixelWidth > 0 ? pixelWidth : bounds.width * selection.scale
        let frameHeight = pixelHeight > 0 ? pixelHeight : bounds.height * selection.scale
        let output = output(for: selection, pixelWidth: frameWidth, pixelHeight: frameHeight)
        guard output.width > 0, output.height > 0 else {
            throw CaptureError.emptySelection
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.width = output.width
        configuration.height = output.height
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .nominal
        configuration.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let crop = selection.pixelRect
            .scaled(from: selection.metrics.pixelSize, to: CGSize(width: image.width, height: image.height))
            .clamped(toWidth: image.width, height: image.height)
        guard crop.width >= 1, crop.height >= 1, let cropped = image.cropping(to: crop.cgRect) else {
            throw CaptureError.emptySelection
        }
        return cropped
    }

    nonisolated struct DisplayRequest: Sendable {
        var displayID: CGDirectDisplayID
        var pixelSize: CGSize

        init(displayID: CGDirectDisplayID, pixelSize: CGSize) {
            self.displayID = displayID
            self.pixelSize = pixelSize
        }
    }

    /// One still frame per display with this app's own windows removed. The caller
    /// takes these before the overlay appears, so the selection UI, the loupe, and
    /// the exported pixels all describe the instant the shortcut was pressed.
    ///
    /// A display that fails to capture is simply absent from the result; the rest
    /// still freeze. Frames come back at the display mode's native pixel size, not
    /// `SCDisplay`'s logical size, so a pixel in the frame is a pixel on screen.
    static func freeze(displays: [DisplayRequest]) async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }

        var frames: [CGDirectDisplayID: CGImage] = [:]
        for request in displays {
            guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else { continue }
            let pixelWidth = Int(request.pixelSize.width.rounded())
            let pixelHeight = Int(request.pixelSize.height.rounded())
            guard pixelWidth > 0, pixelHeight > 0 else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let configuration = SCStreamConfiguration()
            configuration.width = pixelWidth
            configuration.height = pixelHeight
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.captureResolution = .nominal
            configuration.scalesToFit = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                frames[request.displayID] = image
            }
        }
        return frames
    }

    /// Cuts the selection out of a frozen display frame. The selection is in the
    /// display's native pixels, so this is a straight crop with no resampling; the
    /// scale is only a guard for a frame that came back at another size.
    nonisolated static func crop(_ image: CGImage, to selection: ScreenSelection) -> CGImage? {
        let crop = selection.pixelRect
            .scaled(from: selection.metrics.pixelSize, to: CGSize(width: image.width, height: image.height))
            .clamped(toWidth: image.width, height: image.height)
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        return image.cropping(to: crop.cgRect)
    }
}
