import XCTest

@testable import ScreenCutter

final class HotKeyConflictTests: XCTestCase {
    func testEnabledSymbolicHotKeyWithSameChordConflicts() {
        let entries = HotKeyConflictChecker.parse([
            "28": [
                "enabled": true,
                "value": [
                    "parameters": [50, 19, 1_179_648],
                    "type": "standard",
                ],
            ],
        ])

        XCTAssertEqual(
            HotKeyConflictChecker.resolve(entries: entries, carbonStatus: nil),
            .systemShortcut
        )
    }

    func testDisabledSymbolicHotKeyDoesNotConflict() {
        let entries = HotKeyConflictChecker.parse([
            "28": [
                "enabled": false,
                "value": [
                    "parameters": [50, 19, 1_179_648],
                    "type": "standard",
                ],
            ],
        ])

        XCTAssertEqual(
            HotKeyConflictChecker.resolve(entries: entries, carbonStatus: 0),
            .none
        )
    }

    func testDifferentModifiersDoNotConflict() {
        let entries = HotKeyConflictChecker.parse([
            "28": [
                "enabled": true,
                "value": [
                    "parameters": [50, 19, 1_048_576],
                    "type": "standard",
                ],
            ],
        ])

        XCTAssertEqual(
            HotKeyConflictChecker.resolve(entries: entries, carbonStatus: 0),
            .none
        )
    }

    func testCarbonExistingHotKeyIsAnotherApplication() {
        XCTAssertEqual(
            HotKeyConflictChecker.resolve(entries: [], carbonStatus: -9878),
            .otherApplication
        )
    }
}
