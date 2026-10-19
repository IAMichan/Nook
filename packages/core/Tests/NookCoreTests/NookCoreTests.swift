import XCTest
@testable import NookCore

final class NookCoreTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(NookCore.version.isEmpty)
    }
}
