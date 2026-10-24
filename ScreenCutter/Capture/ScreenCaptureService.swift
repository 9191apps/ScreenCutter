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
        let crop = SelectionGeometry.pixelCrop(
            globalRect: selection.globalRect,
            screenFrame: selection.screenFrame,
            imageWidth: width,
            imageHeight: height
        )
        return CaptureOutput(width: width, height: height, crop: crop, scalesToFit: false)
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
        let crop = SelectionGeometry.pixelCrop(
            globalRect: selection.globalRect,
            screenFrame: selection.screenFrame,
            imageWidth: image.width,
            imageHeight: image.height
        )
        guard crop.width >= 1, crop.height >= 1, let cropped = image.cropping(to: crop) else {
            throw CaptureError.emptySelection
        }
        return cropped
    }
}
