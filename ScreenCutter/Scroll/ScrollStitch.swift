import CoreGraphics
import Foundation

nonisolated struct CapturedSlice: Equatable, Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    func row(_ y: Int) -> ArraySlice<UInt8> {
        let start = y * width * 4
        return pixels[start..<(start + width * 4)]
    }
}

nonisolated struct ScrollJoin: Equatable, Sendable {
    var image: CapturedSlice
    var overlap: Int
    var appendedRows: Int
}

nonisolated enum ScrollStitch {
    static let minimumOverlap = 8
    static let maximumMeanDifference: Double = 18
    static let unchangedMeanDifference: Double = 6

    static func slice(from image: CGImage) -> CapturedSlice? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return CapturedSlice(width: width, height: height, pixels: pixels)
    }

    static func image(from slice: CapturedSlice) -> CGImage? {
        guard slice.width > 0, slice.height > 0, slice.pixels.count == slice.width * slice.height * 4 else { return nil }
        var pixels = slice.pixels
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: slice.width,
                height: slice.height,
                bitsPerComponent: 8,
                bytesPerRow: slice.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    static func meanDifference(_ first: CapturedSlice, _ second: CapturedSlice) -> Double? {
        guard first.width == second.width, first.height == second.height, first.width > 0 else { return nil }
        return difference(first, firstRow: 0, second, secondRow: 0, rows: first.height, width: first.width)
    }

    static func join(base: CapturedSlice, next: CapturedSlice) -> ScrollJoin? {
        guard base.width == next.width, base.width > 0, base.height >= minimumOverlap, next.height >= minimumOverlap else {
            return nil
        }
        let upper = min(base.height, next.height) - 1
        guard upper >= minimumOverlap else { return nil }
        var bestOverlap: Int?
        var bestScore = Double.greatestFiniteMagnitude
        for overlap in stride(from: upper, through: minimumOverlap, by: -1) {
            let score = difference(
                base,
                firstRow: base.height - overlap,
                next,
                secondRow: 0,
                rows: overlap,
                width: base.width
            )
            if score < bestScore - 1 {
                bestScore = score
                bestOverlap = overlap
            }
        }
        guard let overlap = bestOverlap, bestScore <= maximumMeanDifference else { return nil }
        let appended = next.height - overlap
        guard appended >= 2 else { return nil }
        var pixels = base.pixels
        let start = overlap * next.width * 4
        pixels.append(contentsOf: next.pixels[start...])
        return ScrollJoin(
            image: CapturedSlice(width: base.width, height: base.height + appended, pixels: pixels),
            overlap: overlap,
            appendedRows: appended
        )
    }

    private static func difference(
        _ first: CapturedSlice,
        firstRow: Int,
        _ second: CapturedSlice,
        secondRow: Int,
        rows: Int,
        width: Int
    ) -> Double {
        var total = 0.0
        let samples = min(width, 32)
        let step = max(1, width / samples)
        var count = 0
        for row in 0..<rows {
            for column in stride(from: 0, to: width, by: step) {
                let left = ((firstRow + row) * width + column) * 4
                let right = ((secondRow + row) * width + column) * 4
                for channel in 0..<3 {
                    total += abs(Double(first.pixels[left + channel]) - Double(second.pixels[right + channel]))
                }
                count += 3
            }
        }
        guard count > 0 else { return .greatestFiniteMagnitude }
        return total / Double(count)
    }
}
