import XCTest
@testable import ScreenCutter

final class ManualScrollAccumulatorTests: XCTestCase {
    func testMovingFrameIsNotAppended() {
        var state = ManualScrollAccumulator(first: slice(rows: 0..<60))
        XCTAssertEqual(state.consume(slice(rows: 10..<70)), .moving)
        XCTAssertEqual(state.stitched.height, 60)
        XCTAssertEqual(state.segments, 0)
        XCTAssertTrue(state.hasPendingContent)
    }

    func testSettledFrameAppendsOnlyNewRows() {
        var state = ManualScrollAccumulator(first: slice(rows: 0..<60))
        XCTAssertEqual(state.consume(slice(rows: 10..<70)), .moving)
        let step = state.consume(slice(rows: 10..<70))
        guard case .appended(let join) = step else {
            return XCTFail("expected an append, got \(step)")
        }
        XCTAssertEqual(join.overlap, 50)
        XCTAssertEqual(join.appendedRows, 10)
        XCTAssertEqual(state.stitched.height, 70)
        XCTAssertEqual(state.segments, 1)
        XCTAssertFalse(state.hasPendingContent)
    }

    func testIdleFrameIsNotAppended() {
        var state = ManualScrollAccumulator(first: slice(rows: 0..<60))
        XCTAssertEqual(state.consume(slice(rows: 0..<60)), .idle)
        XCTAssertEqual(state.stitched.height, 60)
        XCTAssertEqual(state.segments, 0)
        XCTAssertEqual(state.idleSamples, 1)
    }

    func testOverscrollIsRejectedAndScrollBackRecovers() {
        var state = ManualScrollAccumulator(first: slice(rows: 0..<60))
        XCTAssertEqual(state.consume(slice(rows: 100..<160)), .moving)
        XCTAssertEqual(state.consume(slice(rows: 100..<160)), .unmatched)
        XCTAssertEqual(state.stitched.height, 60)

        // Scrolling back until the top of the new frame is above the old
        // bottom makes the next overlap valid again.
        XCTAssertEqual(state.consume(slice(rows: 10..<70)), .moving)
        guard case .appended(let join) = state.consume(slice(rows: 10..<70)) else {
            return XCTFail("expected recovery to append")
        }
        XCTAssertEqual(join.overlap, 50)
        XCTAssertEqual(state.stitched.height, 70)
    }

    func testLimitIsCheckedBeforeAppending() {
        var state = ManualScrollAccumulator(first: slice(rows: 0..<60))
        XCTAssertEqual(state.consume(slice(rows: 10..<70)), .moving)
        XCTAssertEqual(
            state.consume(slice(rows: 10..<70), maximumPixels: 4 * 60),
            .limitReached
        )
        XCTAssertEqual(state.stitched.height, 60)
    }

    private func slice(rows: Range<Int>) -> CapturedSlice {
        var pixels: [UInt8] = []
        for row in rows {
            let value = Self.pixelValue(for: row)
            for _ in 0..<4 {
                pixels.append(contentsOf: [value, 0, 0, 255])
            }
        }
        return CapturedSlice(width: 4, height: rows.count, pixels: pixels)
    }

    /// A deterministic non-linear row pattern: shifted frames have a large
    /// average difference, so a false overlap is very unlikely.
    private static func pixelValue(for row: Int) -> UInt8 {
        var value = UInt32(truncatingIfNeeded: row) &* 0x9E37_79B1
        value ^= value >> 16
        value = value &* 0x85EB_CA6B
        value ^= value >> 13
        return UInt8(truncatingIfNeeded: value)
    }
}
