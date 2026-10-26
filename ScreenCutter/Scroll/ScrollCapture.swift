import AppKit
import CoreGraphics
import Foundation

enum ScrollCaptureResult {
    case finished(CGImage)
    case partial(CGImage, message: String)

    static let stoppedEarly = "没有滚到底。已保留目前拼好的部分。"
    static let couldNotScroll = "未能让选区内的窗口滚动。请框选可滚动的内容区域后再试。"
    static let alignmentFailed = "画面未能对齐，已保留目前拼好的部分。"
}

enum ScrollCapture {
    static let maximumSteps = 20
    static let scrollStepFraction: CGFloat = 0.35
    static let initialSettleNanoseconds: UInt64 = 350_000_000
    static let settlePollNanoseconds: UInt64 = 120_000_000
    static let maximumSettlePolls = 5

    /// Pixel scroll distance per step when using `CGScrollUnit.pixel`.
    static func wheelDeltaPixels(for pixelHeight: Int) -> Int32 {
        Int32(max(40, CGFloat(pixelHeight) * scrollStepFraction))
    }

    static func expectedNewRows(forFrameHeight height: Int) -> Int {
        Int(CGFloat(height) * scrollStepFraction)
    }

    static func shiftSearchSlack(forExpectedNewRows expected: Int) -> Int {
        max(16, expected / 2)
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
            try? await Task.sleep(nanoseconds: initialSettleNanoseconds)
            guard var next = await captureSettled(selection: selection) else {
                return partial(stitched)
            }
            if let delta = ScrollStitch.meanDifference(previous, next), delta < ScrollStitch.unchangedMeanDifference {
                if didAppend, let image = ScrollStitch.image(from: stitched) {
                    return .finished(image)
                }
                return partial(stitched, message: ScrollCaptureResult.couldNotScroll)
            }
            let expected = expectedNewRows(forFrameHeight: next.height)
            let slack = shiftSearchSlack(forExpectedNewRows: expected)
            let range = ScrollShift.shiftSearchRange(
                frameHeight: next.height,
                expectedNewRows: expected,
                slack: slack
            )
            guard let aligned = await measureAlignment(
                previous: previous,
                selection: selection,
                range: range,
                next: next
            ) else {
                return partial(stitched, message: ScrollCaptureResult.alignmentFailed)
            }
            next = aligned.next
            guard let grown = ScrollShift.appendNewRows(
                from: next,
                onto: stitched,
                newRows: aligned.alignment.newRows
            ) else {
                return partial(stitched, message: ScrollCaptureResult.alignmentFailed)
            }
            stitched = grown
            previous = next
            didAppend = true
        }
        return partial(stitched)
    }

    private struct AlignedFrame {
        var alignment: ScrollAlignment
        var next: CapturedSlice
    }

    private static func measureAlignment(
        previous: CapturedSlice,
        selection: ScreenSelection,
        range: ClosedRange<Int>,
        next: CapturedSlice
    ) async -> AlignedFrame? {
        if let alignment = ScrollShift.measure(previous: previous, next: next, searchRange: range) {
            return AlignedFrame(alignment: alignment, next: next)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let settled = await captureSettled(selection: selection),
              let alignment = ScrollShift.measure(previous: previous, next: settled, searchRange: range) else {
            return nil
        }
        return AlignedFrame(alignment: alignment, next: settled)
    }

    /// Wait until two consecutive captures match, so alignment is not taken
    /// mid-momentum or mid-repaint.
    private static func captureSettled(selection: ScreenSelection) async -> CapturedSlice? {
        var last: CapturedSlice?
        for poll in 0..<maximumSettlePolls {
            guard let image = try? await ScreenCaptureService.capture(selection),
                  let slice = ScrollStitch.slice(from: image) else { return nil }
            if let last,
               let delta = ScrollStitch.meanDifference(last, slice),
               delta < ScrollStitch.unchangedMeanDifference {
                return slice
            }
            last = slice
            if poll + 1 < maximumSettlePolls {
                try? await Task.sleep(nanoseconds: settlePollNanoseconds)
            }
        }
        return last
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
