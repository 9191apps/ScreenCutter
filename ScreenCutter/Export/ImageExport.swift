import AppKit
import Foundation
import UniformTypeIdentifiers

enum ImageExport {
    enum SaveOutcome: Sendable {
        case saved
        case cancelled
    }

    nonisolated static func suggestedFilename(date: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "ScreenCutter \(formatter.string(from: date)).png"
    }

    static func copyToPasteboard(_ image: CGImage) throws {
        let encoded = try encodedImage(image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = encoded.png {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = encoded.tiff {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    static func saveWithPanel(_ image: CGImage) throws -> SaveOutcome {
        let encoded = try encodedImage(image)
        guard let png = encoded.png else {
            throw CaptureError.encodingFailed
        }

        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        defer {
            NSApp.setActivationPolicy(previousPolicy)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFilename()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }
        try png.write(to: url, options: .atomic)
        return .saved
    }

    private static func encodedImage(_ image: CGImage) throws -> (png: Data?, tiff: Data?) {
        let rep = NSBitmapImageRep(cgImage: image)
        let png = rep.representation(using: .png, properties: [:])
        let tiff = rep.tiffRepresentation
        guard png != nil || tiff != nil else {
            throw CaptureError.encodingFailed
        }
        return (png, tiff)
    }
}
