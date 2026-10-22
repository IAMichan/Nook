import XCTest

final class NoticeLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func entry(_ key: String, _ title: String = "Done", at date: Date) -> NoticeEntry {
        NoticeEntry(key: key, kind: .done, title: title, date: date)
    }

    func testNewestFirst() {
        var log = NoticeLog()
        log.add(entry("a", at: t0), now: t0)
        log.add(entry("b", at: at(1)), now: at(1))
        XCTAssertEqual(log.entries.map(\.key), ["b", "a"])
        XCTAssertEqual(log.unseen, 2)
    }

    func testSameKeyReplacesOlderEntry() {
        var log = NoticeLog()
        log.add(entry("chat", "First", at: t0), now: t0)
        log.add(entry("other", at: at(1)), now: at(1))
        log.add(entry("chat", "Second", at: at(2)), now: at(2))
        XCTAssertEqual(log.entries.map(\.title), ["Second", "Done"])
    }

    func testEmptyTitleIsLeftOut() {
        var log = NoticeLog()
        log.add(entry("a", "  ", at: t0), now: t0)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testLongDetailIsCut() {
        var log = NoticeLog()
        var long = entry("a", at: t0)
        long.detail = String(repeating: "x", count: NoticeLog.detailLimit + 50)
        log.add(long, now: t0)
        XCTAssertEqual(log.entries.first?.detail.count, NoticeLog.detailLimit + 1)
        XCTAssertTrue(log.entries.first?.detail.hasSuffix("…") ?? false)
    }

    func testKeepsAtMostLimit() {
        var log = NoticeLog()
        for index in 0..<(NoticeLog.limit + 5) {
            log.add(entry("k\(index)", at: at(TimeInterval(index))), now: at(TimeInterval(index)))
        }
        XCTAssertEqual(log.entries.count, NoticeLog.limit)
        XCTAssertEqual(log.entries.first?.key, "k\(NoticeLog.limit + 4)")
        XCTAssertFalse(log.entries.contains { $0.key == "k0" })
    }

    func testOldEntriesFallOff() {
        var log = NoticeLog()
        log.add(entry("old", at: t0), now: t0)
        log.add(entry("new", at: at(NoticeLog.maxAge)), now: at(NoticeLog.maxAge + 1))
        XCTAssertEqual(log.entries.map(\.key), ["new"])
    }

    func testMarkSeenAndClear() {
        var log = NoticeLog()
        log.add(entry("a", at: t0), now: t0)
        log.add(entry("b", at: t0), now: t0)
        log.markAllSeen()
        XCTAssertEqual(log.unseen, 0)
        log.add(entry("c", at: at(1)), now: at(1))
        XCTAssertEqual(log.unseen, 1)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }
}
