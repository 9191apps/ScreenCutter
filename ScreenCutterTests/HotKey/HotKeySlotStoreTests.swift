import XCTest

@testable import ScreenCutter

final class HotKeySlotStoreTests: XCTestCase {
    private let suiteName = "HotKeySlotStoreTests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testEachSlotFallsBackToItsOwnDefault() {
        XCTAssertEqual(HotKeyStore.load(HotKeySlotID.region, from: defaults), .regionCapture)
        XCTAssertEqual(HotKeyStore.load(HotKeySlotID.fullScreen, from: defaults), .fullScreen)
        XCTAssertEqual(HotKeyStore.load(HotKeySlotID.window, from: defaults), .window)
    }

    func testSavedChordOnlyAffectsItsSlot() {
        let custom = HotKeyChord(keyCode: 0, carbonModifiers: HotKeyChord.controlCarbon)

        HotKeyStore.save(custom, for: HotKeySlotID.window, to: defaults)

        XCTAssertEqual(HotKeyStore.load(HotKeySlotID.window, from: defaults), custom)
        XCTAssertEqual(HotKeyStore.load(HotKeySlotID.region, from: defaults), .regionCapture)
        XCTAssertEqual(HotKeyStore.load(HotKeySlotID.fullScreen, from: defaults), .fullScreen)
    }

    func testResetFallsBackToDefault() {
        HotKeyStore.save(
            HotKeyChord(keyCode: 1, carbonModifiers: HotKeyChord.commandCarbon),
            for: HotKeySlotID.fullScreen,
            to: defaults
        )

        HotKeyStore.reset(HotKeySlotID.fullScreen, to: defaults)

        XCTAssertEqual(HotKeyStore.load(HotKeySlotID.fullScreen, from: defaults), .fullScreen)
    }

    func testRegionKeepsReadingLegacyDefaultKeys() {
        defaults.set(0, forKey: "regionHotKey.keyCode")
        defaults.set(Int(HotKeyChord.controlCarbon | HotKeyChord.optionCarbon), forKey: "regionHotKey.carbonModifiers")

        XCTAssertEqual(
            HotKeyStore.load(HotKeySlotID.region, from: defaults),
            HotKeyChord(keyCode: 0, carbonModifiers: HotKeyChord.controlCarbon | HotKeyChord.optionCarbon)
        )
    }

    func testEnabledDefaultsToTrue() {
        XCTAssertTrue(HotKeyStore.isEnabled(HotKeySlotID.window, defaults: defaults))

        HotKeyStore.setEnabled(HotKeySlotID.window, false, defaults: defaults)
        XCTAssertFalse(HotKeyStore.isEnabled(HotKeySlotID.window, defaults: defaults))

        HotKeyStore.setEnabled(HotKeySlotID.window, true, defaults: defaults)
        XCTAssertTrue(HotKeyStore.isEnabled(HotKeySlotID.window, defaults: defaults))
    }
}
