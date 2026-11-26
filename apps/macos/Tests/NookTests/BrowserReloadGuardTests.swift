import XCTest

final class BrowserReloadGuardTests: XCTestCase {
    func testReloadLoopStopsAfterLimit() {
        var guardian = BrowserReloadGuard(limit: 3, window: 30)
        let start = Date()
        for step in 0..<3 { XCTAssertTrue(guardian.pageReloads(at: start.addingTimeInterval(Double(step)))) }
        XCTAssertFalse(guardian.pageReloads(at: start.addingTimeInterval(4)))
        // Stays stopped, also once the window has passed, until Nook or you reload.
        XCTAssertFalse(guardian.pageReloads(at: start.addingTimeInterval(120)))
        guardian.reset()
        XCTAssertTrue(guardian.pageReloads(at: start.addingTimeInterval(121)))
    }

    func testSpreadOutReloadsKeepWorking() {
        var guardian = BrowserReloadGuard(limit: 3, window: 30)
        let start = Date()
        for step in 0..<20 { XCTAssertTrue(guardian.pageReloads(at: start.addingTimeInterval(Double(step) * 11))) }
    }
}
