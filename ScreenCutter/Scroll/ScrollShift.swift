import Foundation

/// Measures how far content moved between two consecutive viewports and appends
/// only the new strip. Auto scroll uses this instead of searching all overlap
/// heights and picking the lowest mean difference.
nonisolated struct ScrollAlignment: Equatable, Sendable {
    /// Rows of `next` that were not visible at the bottom of `previous`.
    var newRows: Int
    /// Mean absolute difference across the shared band at this shift.
    var overlapScore: Double
}

nonisolated enum ScrollShift {
    static let minimumNewRows = 2

    /// `newRows` is the number of fresh rows at the bottom of `next` after the
    /// content moved up. Equivalently, `next[i]` should match `previous[i + newRows]`.
    static func measure(
        previous: CapturedSlice,
        next: CapturedSlice,
        searchRange: ClosedRange<Int>
    ) -> ScrollAlignment? {
        guard previous.width == next.width, previous.width > 0,
              previous.height == next.height,
              previous.height >= ScrollStitch.minimumOverlap + minimumNewRows else {
            return nil
        }
        let height = previous.height
        var bestAlignment: ScrollAlignment?
        for newRows in searchRange {
            guard newRows >= minimumNewRows, newRows <= height - ScrollStitch.minimumOverlap else { continue }
            let overlapRows = height - newRows
            let score = ScrollStitch.meanDifference(
                previous,
                firstRow: newRows,
                next,
                firstRow: 0,
                rows: overlapRows
            )
            guard score <= ScrollStitch.maximumMeanDifference else { continue }
            let candidate = ScrollAlignment(newRows: newRows, overlapScore: score)
            if let current = bestAlignment {
                if score < current.overlapScore - 0.5 {
                    bestAlignment = candidate
                } else if abs(score - current.overlapScore) <= 0.5, newRows > current.newRows {
                    // Same alignment quality: prefer the larger measured scroll so
                    // we do not append too little and skip content.
                    bestAlignment = candidate
                }
            } else {
                bestAlignment = candidate
            }
        }
        return bestAlignment
    }

    static func appendNewRows(
        from next: CapturedSlice,
        onto stitched: CapturedSlice,
        newRows: Int
    ) -> CapturedSlice? {
        guard stitched.width == next.width, newRows >= minimumNewRows, newRows <= next.height else {
            return nil
        }
        let start = (next.height - newRows) * next.width * 4
        var pixels = stitched.pixels
        pixels.append(contentsOf: next.pixels[start...])
        return CapturedSlice(width: stitched.width, height: stitched.height + newRows, pixels: pixels)
    }

    static func shiftSearchRange(
        frameHeight: Int,
        expectedNewRows: Int,
        slack: Int
    ) -> ClosedRange<Int> {
        let low = max(minimumNewRows, expectedNewRows - slack)
        let high = min(frameHeight - ScrollStitch.minimumOverlap, expectedNewRows + slack)
        return low...max(low, high)
    }
}
