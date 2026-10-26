import AppKit
import CoreGraphics
import Foundation

enum ScrollCaptureResult {
    case finished(CGImage)
    case partial(CGImage, message: String)

    static let stoppedEarly = "没有滚到底。已保留目前拼好的部分。"
    static let couldNotScroll = "未能让选区内的窗口滚动。请框选可滚动的内容区域后再试。"
}

enum ScrollCapture {
    static let maximumSteps = 20

    /// Pixel scroll distance per step when using `CGScrollUnit.pixel`.
    static func wheelDeltaPixels(for pixelHeight: Int) -> Int32 {
        Int32(max(40, CGFloat(pixelHeight) * 0.55))
    }

    static func run(selection: ScreenSelection) async -> ScrollCaptureResult? {
        let primaryHeight = primaryDisplayHeight()
        let savedMouse = NSEvent.mouseLocation
        defer { moveMouse(toAppKit: savedMouse, primaryHeight: primaryHeight) }

        guard let firstImage = try? await ScreenCaptureService.capture(selection),
              let first = ScrollStitch.slice(from: firstImage) else { return nil }
        var stitched = first
        var previous = first
        var didAppend = false

        for _ in 0..<maximumSteps {
            postScroll(at: selection, primaryHeight: primaryHeight)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let nextImage = try? await ScreenCaptureService.capture(selection),
                  let next = ScrollStitch.slice(from: nextImage) else {
                return partial(stitched)
            }
            if let delta = ScrollStitch.meanDifference(previous, next), delta < ScrollStitch.unchangedMeanDifference {
                if didAppend, let image = ScrollStitch.image(from: stitched) {
                    return .finished(image)
                }
                return partial(stitched, message: ScrollCaptureResult.couldNotScroll)
            }
            guard let joined = ScrollStitch.join(base: stitched, next: next) else {
                return partial(stitched)
            }
            stitched = joined.image
            previous = next
            didAppend = true
        }
        return partial(stitched)
    }

    private static func partial(
        _ slice: CapturedSlice,
        message: String = ScrollCaptureResult.stoppedEarly
    ) -> ScrollCaptureResult? {
        guard let image = ScrollStitch.image(from: slice) else { return nil }
        return .partial(image, message: message)
    }

    private static func primaryDisplayHeight() -> CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        return primary?.frame.height ?? 0
    }

    private static func moveMouse(toAppKit point: CGPoint, primaryHeight: CGFloat) {
        let quartz = WindowGeometry.quartzPoint(fromAppKit: point, primaryHeight: primaryHeight)
        CGWarpMouseCursorPosition(quartz)
        if let moved = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartz,
            mouseButton: .left
        ) {
            moved.post(tap: .cghidEventTap)
        }
    }

    private static func postScroll(at selection: ScreenSelection, primaryHeight: CGFloat) {
        let center = CGPoint(x: selection.globalRect.midX, y: selection.globalRect.midY)
        moveMouse(toAppKit: center, primaryHeight: primaryHeight)

        let source = CGEventSource(stateID: .hidSystemState)
        let distance = wheelDeltaPixels(for: selection.pixelRect.height)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -distance,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        let quartzCenter = WindowGeometry.quartzPoint(fromAppKit: center, primaryHeight: primaryHeight)
        event.location = quartzCenter
        event.post(tap: .cghidEventTap)
    }
}
