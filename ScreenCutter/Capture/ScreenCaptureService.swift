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

    /// A full-display frame with this app's own windows removed, used by the
    /// selection magnifier. It is a one-shot snapshot, not a live stream. The
    /// requested pixels come from the display mode, not `SCDisplay`'s logical
    /// size, so the loupe's focus maps 1:1 on Retina screens.
    static func snapshot(displayID: CGDirectDisplayID, pixelSize: CGSize? = nil) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let mode = CGDisplayCopyDisplayMode(displayID)
        let requestedWidth = Int((pixelSize?.width ?? 0).rounded())
        let requestedHeight = Int((pixelSize?.height ?? 0).rounded())
        let pixelWidth = requestedWidth > 0 ? requestedWidth : (mode?.pixelWidth ?? display.width)
        let pixelHeight = requestedHeight > 0 ? requestedHeight : (mode?.pixelHeight ?? display.height)
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw CaptureError.displayUnavailable
        }
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .nominal
        configuration.scalesToFit = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
