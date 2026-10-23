import CoreGraphics
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

enum ScreenCaptureService {
    static func capture(_ selection: ScreenSelection) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selection.screenID }) else {
            throw CaptureError.displayUnavailable
        }

        let local = SelectionGeometry.displayLocalRect(
            selection: selection.globalRect,
            screenFrame: selection.screenFrame
        )
        let pixels = SelectionGeometry.outputPixelSize(of: selection.globalRect, scale: selection.scale)
        guard pixels.width > 0, pixels.height > 0 else {
            throw CaptureError.emptySelection
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
