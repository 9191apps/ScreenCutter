import CoreGraphics
import XCTest

@testable import ScreenCutter

@MainActor
final class LoupeViewTests: XCTestCase {
    func testEveryPresetFillsItsMagnifiedContent() {
        for preset in LoupePreset.allCases {
            XCTAssertEqual(
                preset.zoom * CGFloat(preset.sampleCount),
                preset.contentSide,
                "取样格数乘以倍数必须正好填满放大区，否则会被裁切或留白"
            )
        }
    }

    func testWiderPresetsShowMorePixels() {
        XCTAssertEqual(LoupePreset.compact.sampleCount, 24)
        XCTAssertGreaterThan(LoupePreset.standard.sampleCount, LoupePreset.compact.sampleCount)
        XCTAssertGreaterThan(LoupePreset.wide.sampleCount, LoupePreset.standard.sampleCount)
        XCTAssertGreaterThan(LoupePreset.extraWide.sampleCount, LoupePreset.wide.sampleCount)
    }

    func testDefaultPresetShowsMoreThanTheOriginalLoupe() {
        XCTAssertEqual(LoupePreset.fallback, .wide)
        XCTAssertGreaterThan(LoupePreset.fallback.sampleCount, 24)
    }

    func testPresetKeepsTheLoupeInsideAReasonableSize() {
        for preset in LoupePreset.allCases {
            XCTAssertLessThanOrEqual(preset.contentSide, 192)
            XCTAssertGreaterThanOrEqual(preset.contentSide, 120)
        }
    }

    func testChangingPresetResizesTheView() {
        let view = LoupeView(preset: .compact)
        XCTAssertEqual(view.contentSize, CGSize(width: 120, height: 150))
        XCTAssertEqual(view.frame.size, CGSize(width: 120, height: 150))

        view.setPreset(.wide)
        XCTAssertEqual(view.preset, .wide)
        XCTAssertEqual(view.contentSize, CGSize(width: 192, height: 222))
        XCTAssertEqual(view.frame.size, CGSize(width: 192, height: 222))
    }
}
