import XCTest
@testable import ScreenCutter

final class ManualScrollControlTests: XCTestCase {
    func testFinishAndCancelStartOutFalse() async {
        let control = ManualScrollControl()
        let finished = await control.isFinished
        let cancelled = await control.isCancelled
        XCTAssertFalse(finished)
        XCTAssertFalse(cancelled)
    }

    func testFinishDoesNotCancel() async {
        let control = ManualScrollControl()
        await control.requestFinish()
        let finished = await control.isFinished
        let cancelled = await control.isCancelled
        XCTAssertTrue(finished)
        XCTAssertFalse(cancelled)
    }

    func testCancelDoesNotFinish() async {
        let control = ManualScrollControl()
        await control.requestCancel()
        let finished = await control.isFinished
        let cancelled = await control.isCancelled
        XCTAssertFalse(finished)
        XCTAssertTrue(cancelled)
    }
}
