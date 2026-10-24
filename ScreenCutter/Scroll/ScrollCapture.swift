import AppKit
import CoreGraphics
import Foundation

enum ScrollCaptureResult {
    case finished(CGImage)
    case partial(CGImage, message: String)

    static let stoppedEarly = "没有滚到底。已保留目前拼好的部分。"
}

enum ScrollCapture {
    static let maximumSteps = 20

    static func run(selection: ScreenSelection) async -> ScrollCaptureResult? {
        guard let firstImage = try? await ScreenCaptureService.capture(selection),
              let first = ScrollStitch.slice(from: firstImage) else { return nil }
        var stitched = first
        var previous = first
        var didAppend = false

        for _ in 0..<maximumSteps {
            postScroll(at: selection)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let nextImage = try? await ScreenCaptureService.capture(selection),
                  let next = ScrollStitch.slice(from: nextImage) else {
                return partial(stitched)
            }
            if let delta = ScrollStitch.meanDifference(previous, next), delta < ScrollStitch.unchangedMeanDifference {
                if didAppend, let image = ScrollStitch.image(from: stitched) {
                    return .finished(image)
                }
                return partial(stitched)
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

    private static func partial(_ slice: CapturedSlice) -> ScrollCaptureResult? {
        guard let image = ScrollStitch.image(from: slice) else { return nil }
        return .partial(image, message: ScrollCaptureResult.stoppedEarly)
    }

    private static func postScroll(at selection: ScreenSelection) {
        let source = CGEventSource(stateID: .hidSystemState)
        let distance = Int32(max(40, selection.globalRect.height * 0.55))
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -distance,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let primaryHeight = primary?.frame.height ?? 0
        let center = CGPoint(x: selection.globalRect.midX, y: selection.globalRect.midY)
        event.location = CGPoint(x: center.x, y: primaryHeight - center.y)
        event.post(tap: .cghidEventTap)
    }
}
