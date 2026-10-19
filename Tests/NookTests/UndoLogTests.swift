import XCTest

final class UndoLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 5_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testRecordAndUndoRoundTrip() {
        var log = UndoLog()
        log.record(.settled, ids: ["a"], now: t0)
        XCTAssertEqual(log.current(now: at(1))?.ids, ["a"])
        let e = log.undo(now: at(2))
        XCTAssertEqual(e?.kind, .settled)
        XCTAssertNil(log.current(now: at(2)))
        XCTAssertNil(log.undo(now: at(2)))
    }

    func testSameKindMergesAndRestartsWindow() {
        var log = UndoLog()
        log.record(.settled, ids: ["a"], now: t0)
        log.record(.settled, ids: ["b", "a"], now: at(4))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.current(now: at(8))?.ids, ["a", "b"])
        XCTAssertEqual(log.current(now: at(8))?.messageKey, "undo.settled.other")
        XCTAssertNil(log.current(now: at(9)))
    }

    func testDifferentKindStacksAndUndoPopsLatestFirst() {
        var log = UndoLog()
        log.record(.settled, ids: ["a"], now: t0)
        log.record(.pinned, ids: ["b"], now: at(1))
        XCTAssertEqual(log.current(now: at(2))?.kind, .pinned)
        XCTAssertEqual(log.undo(now: at(2))?.kind, .pinned)
        XCTAssertEqual(log.current(now: at(2))?.kind, .settled)
        XCTAssertEqual(log.current(now: at(2))?.messageKey, "undo.settled.one")
    }

    func testExpiryAfterFiveSeconds() {
        var log = UndoLog()
        log.record(.archived, ids: ["a"], now: t0)
        XCTAssertNotNil(log.current(now: at(4.9)))
        XCTAssertNil(log.current(now: at(5)))
        XCTAssertNil(log.undo(now: at(5)))
        // A new record after expiry starts fresh instead of merging.
        log.record(.archived, ids: ["b"], now: at(20))
        XCTAssertEqual(log.current(now: at(20))?.ids, ["b"])
    }

    func testEmptyRecordIgnoredAndEveryKindHasKey() {
        var log = UndoLog()
        log.record(.snoozed, ids: [], now: t0)
        XCTAssertNil(log.current(now: t0))
        for kind in [UndoEntry.Kind.settled, .snoozed, .unsettled, .pinned, .unpinned, .archived, .discarded] {
            XCTAssertEqual(UndoEntry(kind: kind, ids: ["a"], createdAt: t0).messageKey, "undo.\(kind.rawValue).one")
        }
    }
}
