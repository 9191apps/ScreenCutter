import CoreGraphics
import Foundation

nonisolated enum SnapAxis: Equatable, Sendable {
    case vertical
    case horizontal

    var sortOrder: Int {
        switch self {
        case .vertical:
            return 0
        case .horizontal:
            return 1
        }
    }
}

/// A line the selection can snap to. `coordinate` is display-local: x for a
/// vertical line, y for a horizontal line, both in pixels with a top-left origin.
nonisolated struct SnapCandidate: Equatable, Sendable {
    var axis: SnapAxis
    var coordinate: Int
    /// Lower wins when two candidates are equally close: window edges beat the
    /// screen center, which beats the screen edges.
    var priority: Int
}

nonisolated enum SnapEngine {
    /// Four points, expressed in the display's pixel scale.
    static func threshold(for metrics: DisplayMetrics) -> Int {
        max(1, Int((4 * min(metrics.scaleX, metrics.scaleY)).rounded()))
    }

    static func candidates(metrics: DisplayMetrics, windows: [ListedWindow]) -> [SnapCandidate] {
        var raw: [SnapCandidate] = [
            SnapCandidate(axis: .vertical, coordinate: 0, priority: 2),
            SnapCandidate(axis: .vertical, coordinate: metrics.pixelWidth / 2, priority: 1),
            SnapCandidate(axis: .vertical, coordinate: metrics.pixelWidth, priority: 2),
            SnapCandidate(axis: .horizontal, coordinate: 0, priority: 2),
            SnapCandidate(axis: .horizontal, coordinate: metrics.pixelHeight / 2, priority: 1),
            SnapCandidate(axis: .horizontal, coordinate: metrics.pixelHeight, priority: 2),
        ]

        for window in windows {
            let rect = metrics.pixelRect(for: window.appKitFrame)
            let left = min(max(0, rect.minX), metrics.pixelWidth)
            let right = min(max(0, rect.maxX), metrics.pixelWidth)
            let top = min(max(0, rect.minY), metrics.pixelHeight)
            let bottom = min(max(0, rect.maxY), metrics.pixelHeight)
            guard right > left, bottom > top else { continue }
            raw.append(SnapCandidate(axis: .vertical, coordinate: left, priority: 0))
            raw.append(SnapCandidate(axis: .vertical, coordinate: right, priority: 0))
            raw.append(SnapCandidate(axis: .horizontal, coordinate: top, priority: 0))
            raw.append(SnapCandidate(axis: .horizontal, coordinate: bottom, priority: 0))
        }

        var deduplicated: [String: SnapCandidate] = [:]
        for candidate in raw {
            let key = "\(candidate.axis.sortOrder)-\(candidate.coordinate)"
            if let existing = deduplicated[key], existing.priority <= candidate.priority {
                continue
            }
            deduplicated[key] = candidate
        }
        return deduplicated.values.sorted {
            if $0.axis != $1.axis { return $0.axis.sortOrder < $1.axis.sortOrder }
            return $0.coordinate < $1.coordinate
        }
    }

    static func nearest(
        to coordinate: Int,
        axis: SnapAxis,
        candidates: [SnapCandidate],
        threshold: Int
    ) -> SnapCandidate? {
        guard threshold >= 0 else { return nil }
        var best: SnapCandidate?
        for candidate in candidates where candidate.axis == axis {
            let distance = abs(candidate.coordinate - coordinate)
            guard distance <= threshold else { continue }
            guard let current = best else {
                best = candidate
                continue
            }
            let currentDistance = abs(current.coordinate - coordinate)
            if distance < currentDistance
                || (distance == currentDistance && candidate.priority < current.priority) {
                best = candidate
            }
        }
        return best
    }

    /// Snaps one point, used when a drag begins.
    static func snap(
        point: PixelPoint,
        metrics: DisplayMetrics,
        candidates: [SnapCandidate],
        threshold: Int
    ) -> PixelPoint {
        var result = point
        if let candidate = nearest(to: point.x, axis: .vertical, candidates: candidates, threshold: threshold) {
            result.x = candidate.coordinate
        }
        if let candidate = nearest(to: point.y, axis: .horizontal, candidates: candidates, threshold: threshold) {
            result.y = candidate.coordinate
        }
        return result
    }

    /// Moves a whole rect and snaps only one edge per axis, so a move never changes
    /// the selection's size.
    static func snapMoved(
        _ rect: PixelRect,
        metrics: DisplayMetrics,
        candidates: [SnapCandidate],
        threshold: Int
    ) -> PixelRect {
        var shiftX = 0
        var shiftY = 0

        let left = nearest(to: rect.minX, axis: .vertical, candidates: candidates, threshold: threshold)
        let right = nearest(to: rect.maxX, axis: .vertical, candidates: candidates, threshold: threshold)
        switch (left, right) {
        case let (lhs?, rhs?):
            if abs(lhs.coordinate - rect.minX) <= abs(rhs.coordinate - rect.maxX) {
                shiftX = lhs.coordinate - rect.minX
            } else {
                shiftX = rhs.coordinate - rect.maxX
            }
        case let (lhs?, nil):
            shiftX = lhs.coordinate - rect.minX
        case let (nil, rhs?):
            shiftX = rhs.coordinate - rect.maxX
        case (nil, nil):
            break
        }

        let top = nearest(to: rect.minY, axis: .horizontal, candidates: candidates, threshold: threshold)
        let bottom = nearest(to: rect.maxY, axis: .horizontal, candidates: candidates, threshold: threshold)
        switch (top, bottom) {
        case let (lhs?, rhs?):
            if abs(lhs.coordinate - rect.minY) <= abs(rhs.coordinate - rect.maxY) {
                shiftY = lhs.coordinate - rect.minY
            } else {
                shiftY = rhs.coordinate - rect.maxY
            }
        case let (lhs?, nil):
            shiftY = lhs.coordinate - rect.minY
        case let (nil, rhs?):
            shiftY = rhs.coordinate - rect.maxY
        case (nil, nil):
            break
        }

        return PixelSelectionGeometry.moved(
            rect,
            by: PixelPoint(x: shiftX, y: shiftY),
            in: metrics
        )
    }
}
