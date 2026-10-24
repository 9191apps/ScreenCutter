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

    func testADifferentChordDoesNotMatchTheDefaultSystemShortcut() {
        let entries = HotKeyConflictChecker.parse([
            "28": [
                "enabled": true,
                "value": [
                    "parameters": [50, 19, 1_179_648],
                    "type": "standard",
                ],
            ],
        ])
        let chord = HotKeyChord(keyCode: 18, carbonModifiers: HotKeyChord.commandCarbon | HotKeyChord.shiftCarbon)

        XCTAssertEqual(
            HotKeyConflictChecker.resolve(entries: entries, carbonStatus: 0, chord: chord),
            .none
        )
    }

    func testRegionChordDisplayAndRoundTrip() {
        XCTAssertEqual(HotKeyChord.regionCapture.display, "⇧⌘2")
        let defaults = UserDefaults(suiteName: "HotKeyStoreTests")!
        defaults.removePersistentDomain(forName: "HotKeyStoreTests")
        let chord = HotKeyChord(keyCode: 18, carbonModifiers: HotKeyChord.commandCarbon | HotKeyChord.optionCarbon)
        HotKeyStore.saveRegion(chord, to: defaults)
        XCTAssertEqual(HotKeyStore.loadRegion(from: defaults), chord)
        XCTAssertEqual(chord.display, "⌥⌘1")
        XCTAssertTrue(HotKeyStore.isEnabled(HotKeySlotID.fullScreen, defaults: defaults))
        HotKeyStore.setEnabled(HotKeySlotID.window, false, defaults: defaults)
        XCTAssertFalse(HotKeyStore.isEnabled(HotKeySlotID.window, defaults: defaults))
    }

    func testCarbonExistingHotKeyIsAnotherApplication() {
        XCTAssertEqual(
            HotKeyConflictChecker.resolve(entries: [], carbonStatus: -9878),
            .otherApplication
        )
    }
}
