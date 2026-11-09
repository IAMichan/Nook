import XCTest

final class ByteBudgetCacheTests: XCTestCase {
    func testStaysWithinItsBudgetAndDropsTheLeastRecentlyUsed() {
        var cache = ByteBudgetCache<String, Int>(budget: 100)
        cache.set(1, for: "a", cost: 30)
        cache.set(2, for: "b", cost: 30)
        cache.set(3, for: "c", cost: 30)
        XCTAssertEqual(cache.value("a"), 1, "used last, so it stays")
        cache.set(4, for: "d", cost: 30)
        XCTAssertLessThanOrEqual(cache.bytes, 100)
        XCTAssertNil(cache.peek("b"))
        XCTAssertEqual(cache.peek("a"), 1)
        XCTAssertEqual(cache.peek("d"), 4)
    }

    func testReplacingAKeyCountsItOnce() {
        var cache = ByteBudgetCache<String, Int>(budget: 100)
        cache.set(1, for: "a", cost: 40)
        cache.set(2, for: "a", cost: 50)
        XCTAssertEqual(cache.bytes, 50)
        XCTAssertEqual(cache.count, 1)
    }

    func testAValueHeavierThanTheBudgetIsNotKept() {
        var cache = ByteBudgetCache<String, Int>(budget: 100)
        cache.set(1, for: "a", cost: 10)
        cache.set(2, for: "b", cost: 101)
        XCTAssertNil(cache.peek("b"))
        XCTAssertEqual(cache.peek("a"), 1)
        cache.removeAll()
        XCTAssertEqual(cache.bytes, 0)
        XCTAssertNil(cache.peek("a"))
    }
}
