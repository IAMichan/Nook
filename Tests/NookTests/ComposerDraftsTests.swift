import XCTest

final class ComposerDraftsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testSaveClearAndEmptyRemoves() {
        var d = ComposerDrafts()
        d.save(sessionID: "a", text: "hello", now: t0)
        XCTAssertEqual(d.draft(for: "a"), "hello")
        d.save(sessionID: "a", text: "  \n", now: t0)
        XCTAssertNil(d.draft(for: "a"))
        d.save(sessionID: "a", text: "x", now: t0)
        d.clear(sessionID: "a")
        XCTAssertNil(d.draft(for: "a"))
    }

    func testCapsSessionsDroppingOldest() {
        var d = ComposerDrafts()
        for i in 0..<101 { d.save(sessionID: "s\(i)", text: "t", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(d.drafts.count, 100)
        XCTAssertNil(d.draft(for: "s0"))
        XCTAssertNotNil(d.draft(for: "s100"))
    }

    func testCapsDraftSizeOnCharacterBoundary() {
        var d = ComposerDrafts()
        d.save(sessionID: "a", text: String(repeating: "é", count: 150_000), now: t0)
        let size = d.draft(for: "a")!.utf8.count
        XCTAssertLessThanOrEqual(size, ComposerDrafts.maxBytes)
        XCTAssertGreaterThan(size, ComposerDrafts.maxBytes - 2)
    }

    func testPruneAndTolerantDecode() throws {
        var d = ComposerDrafts()
        d.save(sessionID: "a", text: "1", now: t0)
        d.save(sessionID: "b", text: "2", now: t0)
        d.pruneUnused(keeping: ["b"])
        XCTAssertNil(d.draft(for: "a"))
        XCTAssertEqual(try JSONDecoder().decode(ComposerDrafts.self, from: Data("{}".utf8)).drafts.count, 0)
        let odd = try JSONDecoder().decode(ComposerDrafts.self, from: Data(#"{"drafts":{"a":{"text":"x"}},"zzz":1}"#.utf8))
        XCTAssertEqual(odd.draft(for: "a"), "x")
        let round = try JSONDecoder().decode(ComposerDrafts.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(round, d)
    }

    func testStashStackSemantics() {
        var s = PromptStash()
        XCTAssertFalse(s.push("  "))
        XCTAssertTrue(s.push("one"))
        XCTAssertFalse(s.push("one"), "duplicate of the top")
        XCTAssertTrue(s.push("two"))
        XCTAssertTrue(s.push("one"), "a duplicate deeper in the stack is allowed")
        XCTAssertEqual(s.pop(), "one")
        XCTAssertEqual(s.restore(at: 0), "one")
        XCTAssertEqual(s.entries.map(\.text), ["two"])
        XCTAssertNil(s.restore(at: 5))
        s.remove(at: 0)
        XCTAssertNil(s.pop())
    }

    func testStashLimitAndTitle() throws {
        var s = PromptStash()
        for i in 0..<12 { s.push("p\(i)") }
        XCTAssertEqual(s.entries.count, 10)
        XCTAssertEqual(s.entries.first?.text, "p2")
        s.push("\n  " + String(repeating: "a", count: 60) + "\nsecond")
        XCTAssertEqual(s.entries.last?.title.count, 40)
        let back = try JSONDecoder().decode(PromptStash.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testStashAction() {
        XCTAssertEqual(StashAction.decide(composerText: "x", stashCount: 3), .stash)
        XCTAssertEqual(StashAction.decide(composerText: " ", stashCount: 0), .nothing)
        XCTAssertEqual(StashAction.decide(composerText: "", stashCount: 1), .restoreOnly)
        XCTAssertEqual(StashAction.decide(composerText: "", stashCount: 2), .openMenu)
    }
}
