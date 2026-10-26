import XCTest
@testable import ScreenCutter

final class ScrollShiftTests: XCTestCase {
    func testMeasureFindsKnownShift() {
        let previous = slice(width: 6, rows: Array(0..<80))
        let shift = 28
        let next = slice(width: 6, rows: Array(shift..<(shift + 80)))
        let alignment = ScrollShift.measure(
            previous: previous,
            next: next,
            searchRange: (shift - 4)...(shift + 4)
        )
        XCTAssertEqual(alignment?.newRows, shift)
        XCTAssertEqual(
            ScrollShift.appendNewRows(from: next, onto: previous, newRows: shift)?.height,
            80 + shift
        )
    }

    func testMeasureRejectsShiftOutsideSearchRange() {
        let previous = slice(width: 6, rows: Array(0..<80))
        let shift = 28
        let next = slice(width: 6, rows: Array(shift..<(shift + 80)))
        XCTAssertNil(ScrollShift.measure(previous: previous, next: next, searchRange: 2...10))
    }

    func testMeasureUsesFullOverlapBandNotAShortAccidentalMatch() {
        let previous = repeatingSlice(rows: 0..<100, period: 12)
        let shift = 24
        let next = repeatingSlice(rows: shift..<(shift + 100), period: 12)
        let alignment = ScrollShift.measure(
            previous: previous,
            next: next,
            searchRange: (shift - 6)...(shift + 6)
        )
        XCTAssertEqual(alignment?.newRows, shift)
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
