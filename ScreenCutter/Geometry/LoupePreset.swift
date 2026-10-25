import CoreGraphics

/// How much of the screen the loupe shows and how large each source pixel is.
/// Zoom stays an integer so a source pixel maps to whole points; fractional
/// zoom would make the pixel grid blur when the compositor resamples it.
nonisolated enum LoupePreset: String, CaseIterable, Hashable, Identifiable, Sendable {
    case compact
    case standard
    case wide
    case extraWide

    /// Wider than the original 24 px loupe, but still compact enough to sit
    /// beside the cursor without covering the area being selected.
    static let fallback: LoupePreset = .wide

    var id: String { rawValue }

    /// Display pixels sampled across the magnified square.
    var sampleCount: Int {
        switch self {
        case .compact:
            return 24
        case .standard:
            return 40
        case .wide:
            return 64
        case .extraWide:
            return 96
        }
    }

    /// Points per source pixel.
    var zoom: CGFloat {
        switch self {
        case .compact:
            return 5
        case .standard:
            return 4
        case .wide:
            return 3
        case .extraWide:
            return 2
        }
    }

    /// Side length of the magnified square in points.
    var contentSide: CGFloat {
        CGFloat(sampleCount) * zoom
    }

    var title: String {
        switch self {
        case .compact:
            return "紧凑"
        case .standard:
            return "标准"
        case .wide:
            return "宽阔"
        case .extraWide:
            return "超宽"
        }
    }

    var detail: String {
        "\(sampleCount) px，\(Int(zoom))×"
    }

    var settingsTitle: String {
        "\(title)（\(detail)）"
    }

    var accessibilityLabel: String {
        "\(title)，显示 \(sampleCount) 像素，放大 \(Int(zoom)) 倍"
    }
}
