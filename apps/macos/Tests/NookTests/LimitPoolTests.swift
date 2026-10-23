import XCTest

final class LimitPoolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOneAccountNeedsNoPool() {
        XCTAssertNil(LimitPool.make([LimitPool.Account(id: "a", name: "a", limits: [.init(label: "5 hours", used: 10, resetsAt: nil)])], now: now))
    }

    func testThePoolAveragesAndKeepsColumns() throws {
        let work = LimitPool.Account(id: "w", name: "Work", limits: [
            .init(label: "5 hours", used: 80, resetsAt: now.addingTimeInterval(600)),
            .init(label: "Week", used: 50, resetsAt: now.addingTimeInterval(86_400)),
        ])
        let personal = LimitPool.Account(id: "p", name: "Personal", limits: [
            .init(label: "5 hours", used: 20, resetsAt: now.addingTimeInterval(7_200)),
        ])
        let pool = try XCTUnwrap(LimitPool.make([personal, work], now: now))
        XCTAssertEqual(pool.windows.map(\.label), ["5 hours", "Week"])
        // Work refills first, so it comes first in every window.
        XCTAssertEqual(pool.windows[0].segments.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(pool.windows[1].segments.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(pool.windows[0].left, 50, accuracy: 1e-9)
        // Personal reports no weekly window: a gap, not zero.
        XCTAssertNil(pool.windows[1].segments[1].left)
        XCTAssertEqual(pool.windows[1].left, 50, accuracy: 1e-9)
        // Work's 5-hour reset hands back its 80 % of one of two accounts: 40 % of the pool.
        XCTAssertEqual(pool.windows[0].nextReset, now.addingTimeInterval(600))
        XCTAssertEqual(pool.windows[0].restores, 40, accuracy: 1e-9)
    }
}
