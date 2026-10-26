import CoreGraphics
import XCTest
@testable import ScreenCutter

final class ScrollStitchTests: XCTestCase {
    func testJoinAppendsOnlyTheRowsBelowTheOverlap() {
        let base = slice(width: 4, rows: Array(0..<40))
        let next = slice(width: 4, rows: Array(20..<60))
        let joined = ScrollStitch.join(base: base, next: next)
        XCTAssertEqual(joined?.overlap, 20)
        XCTAssertEqual(joined?.appendedRows, 20)
        XCTAssertEqual(joined?.image.height, 60)
        XCTAssertEqual(joined?.image.pixels[0], 0)
        XCTAssertEqual(joined?.image.pixels[59 * 4 * 4], UInt8(59 * 4))
    }

    func testJoinRejectsSlicesThatDoNotOverlap() {
        let base = slice(width: 4, rows: Array(0..<30))
        let next = CapturedSlice(width: 4, height: 30, pixels: [UInt8](repeating: 255, count: 4 * 30 * 4))
        XCTAssertNil(ScrollStitch.join(base: base, next: next))
    }

    /// Manual mode calls `join` again when the content has settled. An
    /// unchanged frame must not be appended, otherwise finishing while idle
    /// would duplicate the last viewport.
    func testJoinRejectsAnUnchangedFrame() {
        let frame = slice(width: 4, rows: Array(0..<40))
        XCTAssertNil(ScrollStitch.join(base: frame, next: frame))
    }

    /// A small manual scroll still has a valid overlap and appends only the
    /// rows that scrolled into view.
    func testJoinAppendsASmallManualScroll() {
        let base = slice(width: 4, rows: Array(0..<40))
        let next = slice(width: 4, rows: Array(3..<43))
        let joined = ScrollStitch.join(base: base, next: next)
        XCTAssertEqual(joined?.overlap, 37)
        XCTAssertEqual(joined?.appendedRows, 3)
        XCTAssertEqual(joined?.image.height, 43)
    }

    func testSliceKeepsTheTopRowAtTheStartOfTheBuffer() throws {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("无法创建图片")
            return
        }
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 6, width: 4, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let sliced = try XCTUnwrap(ScrollStitch.slice(from: image))
        XCTAssertGreaterThan(sliced.pixels[0], 200)
        XCTAssertLessThan(sliced.pixels[1], 40)
        let restored = try XCTUnwrap(ScrollStitch.image(from: sliced))
        let roundTrip = try XCTUnwrap(ScrollStitch.slice(from: restored))
        XCTAssertEqual(roundTrip.pixels[0], sliced.pixels[0])
        XCTAssertEqual(roundTrip.pixels[(7 * 4 * 4) + 2], sliced.pixels[(7 * 4 * 4) + 2])
    }

    func testUnchangedFramesHaveNoMeanDifference() {
        let frame = slice(width: 4, rows: Array(0..<20))
        XCTAssertEqual(ScrollStitch.meanDifference(frame, frame), 0)
    }

    /// Repeating row bands can score well at several overlap lengths. A short
    /// accidental match would skip most of the scrolled content (folded line
    /// numbers in real captures). Prefer the overlap closest to the expected
    /// scroll step.
    func testJoinPicksExpectedOverlapOnRepeatingRows() {
        let base = repeatingSlice(rows: 0..<100, period: 12)
        let shift = 24
        let next = repeatingSlice(rows: shift..<(shift + 100), period: 12)
        let expected = 100 - shift
        let joined = ScrollStitch.join(
            base: base,
            next: next,
            preferredOverlap: expected,
            overlapRange: (expected - 20)...(expected + 20)
        )
        XCTAssertEqual(joined?.overlap, expected)
        XCTAssertEqual(joined?.image.height, 100 + shift)
    }

    private func repeatingSlice(rows: Range<Int>, period: Int) -> CapturedSlice {
        slice(width: 8, rows: rows.map { UInt8(($0 % period) * 17) })
    }

    private func slice(width: Int, rows: [UInt8]) -> CapturedSlice {
        var pixels: [UInt8] = []
        for row in rows {
            for _ in 0..<width {
                pixels.append(contentsOf: [row &* 4, 0, 0, 255])
            }
        }
        return CapturedSlice(width: width, height: rows.count, pixels: pixels)
    }
}
