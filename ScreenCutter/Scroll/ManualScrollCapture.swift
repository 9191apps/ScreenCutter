import CoreGraphics
import Foundation

/// Coordinates the two buttons of the manual panel with the capture loop.
/// The loop runs off the main actor, so a tiny actor is enough to avoid locks.
actor ManualScrollControl {
    private var finished = false
    private var cancelled = false

    func requestFinish() {
        finished = true
    }

    func requestCancel() {
        cancelled = true
    }

    var isFinished: Bool { finished }
    var isCancelled: Bool { cancelled }
}

nonisolated struct ManualScrollProgress: Equatable, Sendable {
    var segments: Int
    var height: Int
    var hint: String?
    var isFinishing: Bool
}

nonisolated enum ManualScrollOutcome {
    case finished(CGImage)
    case partial(CGImage, message: String)
    case cancelled
    case failed
}

nonisolated enum ManualScrollStep: Equatable {
    /// The frame was still changing; it becomes the reference for the next one.
    case moving
    /// The frame is stable and identical to the last appended viewport.
    case idle
    /// New rows were appended below the stitched image.
    case appended(ScrollJoin)
    /// The frame is stable but does not overlap the stitched image.
    case unmatched
    /// Appending this frame would exceed the memory cap.
    case limitReached
}

/// The pure part of manual stitching: decides what a sampled frame means.
/// Kept separate from ScreenCaptureKit so the settle/append rules can be
/// tested without a display.
nonisolated struct ManualScrollAccumulator {
    private(set) var stitched: CapturedSlice
    private(set) var lastAppended: CapturedSlice
    private var lastCaptured: CapturedSlice
    private(set) var segments = 0
    private(set) var idleSamples = 0
    private(set) var lastSettled = false

    init(first: CapturedSlice) {
        stitched = first
        lastAppended = first
        lastCaptured = first
    }

    /// True when the last sampled frame is not yet represented by the stitched
    /// image. Used to warn when "完成" times out while the screen keeps moving.
    var hasPendingContent: Bool {
        guard let delta = ScrollStitch.meanDifference(lastCaptured, lastAppended) else { return true }
        return delta >= ScrollStitch.unchangedMeanDifference
    }

    mutating func consume(
        _ next: CapturedSlice,
        maximumPixels: Int = ManualScrollCapture.maximumStitchedPixels
    ) -> ManualScrollStep {
        let delta = ScrollStitch.meanDifference(lastCaptured, next) ?? .greatestFiniteMagnitude
        lastSettled = delta < ScrollStitch.unchangedMeanDifference
        lastCaptured = next

        guard lastSettled else {
            idleSamples = 0
            return .moving
        }

        if sameContent(next, lastAppended) {
            idleSamples += 1
            return .idle
        }

        guard stitched.width > 0 else { return .limitReached }
        let maximumRows = maximumPixels / stitched.width
        guard stitched.height + next.height - ScrollStitch.minimumOverlap <= maximumRows else {
            return .limitReached
        }
        guard let joined = ScrollStitch.join(base: stitched, next: next) else {
            // The user overshot the overlap. Keep sampling quickly so a scroll
            // back into range can recover without waiting for the idle cadence.
            idleSamples = 0
            return .unmatched
        }

        stitched = joined.image
        lastAppended = next
        segments += 1
        idleSamples = 0
        return .appended(joined)
    }

    private func sameContent(_ first: CapturedSlice, _ second: CapturedSlice) -> Bool {
        guard let delta = ScrollStitch.meanDifference(first, second) else { return false }
        return delta < ScrollStitch.unchangedMeanDifference
    }
}

/// Manual counterpart to `ScrollCapture`: the user scrolls the target window,
/// and this loop samples the selection until two consecutive frames match.
/// Only settled frames are stitched, so momentum and mid-scroll repaints never
/// end up in the long image.
nonisolated enum ManualScrollCapture {
    /// 120 M pixels of RGBA is about 480 MB for the stitched buffer. One frame
    /// is allowed on top of that while the next join is being built.
    static let maximumStitchedPixels = 120_000_000
    /// Sampling while the content is moving.
    static let sampleInterval: UInt64 = 150_000_000
    /// Sampling once the content has stopped; no need to hammer ScreenCaptureKit.
    static let idleInterval: UInt64 = 600_000_000
    /// Sampling while a finish request waits for the last scroll to settle.
    static let finishInterval: UInt64 = 120_000_000
    /// How long "完成" waits for momentum to end before it gives up on the
    /// last frame. Long enough for a trackpad fling, short enough not to hang.
    static let finishTimeout: TimeInterval = 3

    static func run(
        selection: ScreenSelection,
        control: ManualScrollControl,
        onProgress: @escaping @MainActor (ManualScrollProgress) -> Void
    ) async -> ManualScrollOutcome {
        guard let firstImage = try? await ScreenCaptureService.capture(selection),
              let first = ScrollStitch.slice(from: firstImage) else {
            return .failed
        }

        var state = ManualScrollAccumulator(first: first)
        var finishStarted: Date?
        var stopReason: String?

        await onProgress(ManualScrollProgress(
            segments: 0,
            height: first.height,
            hint: nil,
            isFinishing: false
        ))

        while true {
            if await control.isCancelled {
                return .cancelled
            }
            let finishing = await control.isFinished
            if finishing {
                if finishStarted == nil {
                    finishStarted = Date()
                    await onProgress(ManualScrollProgress(
                        segments: state.segments,
                        height: state.stitched.height,
                        hint: nil,
                        isFinishing: true
                    ))
                } else if Date().timeIntervalSince(finishStarted!) > finishTimeout {
                    if state.hasPendingContent {
                        stopReason = "画面一直在动，可能少了最后一段。已保留目前拼好的部分。"
                    }
                    break
                }
            }

            let interval: UInt64
            if finishing {
                interval = finishInterval
            } else if state.lastSettled {
                interval = state.idleSamples >= 4 ? idleInterval : sampleInterval
            } else {
                interval = sampleInterval
            }
            try? await Task.sleep(nanoseconds: interval)

            guard let image = try? await ScreenCaptureService.capture(selection),
                  let next = ScrollStitch.slice(from: image) else {
                guard let stitchedImage = ScrollStitch.image(from: state.stitched) else {
                    return .failed
                }
                return .partial(stitchedImage, message: "截屏中断了。已保留目前拼好的部分。")
            }

            switch state.consume(next) {
            case .moving:
                continue
            case .idle:
                if finishing { break }
            case .appended:
                await onProgress(ManualScrollProgress(
                    segments: state.segments,
                    height: state.stitched.height,
                    hint: nil,
                    isFinishing: finishing
                ))
                if finishing { break }
            case .unmatched:
                await onProgress(ManualScrollProgress(
                    segments: state.segments,
                    height: state.stitched.height,
                    hint: "没有接上，往回滚一点再试",
                    isFinishing: finishing
                ))
                if finishing {
                    stopReason = "最后一段没有接上，已保留目前拼好的部分。"
                    break
                }
            case .limitReached:
                stopReason = "长图已达到大小上限，已保留目前拼好的部分。"
                break
            }
        }

        guard let image = ScrollStitch.image(from: state.stitched) else {
            return .failed
        }
        if let stopReason {
            return .partial(image, message: stopReason)
        }
        return .finished(image)
    }
}
