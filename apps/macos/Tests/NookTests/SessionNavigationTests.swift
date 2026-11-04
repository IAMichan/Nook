import XCTest

final class SessionNavigationTests: XCTestCase {
    // MARK: Back and forward

    func testBackAndForwardRetraceTheVisits() {
        var trail = SessionTrail()
        for id in ["a", "b", "c"] { trail.visit(id) }
        XCTAssertEqual(trail.goBack(), "b")
        XCTAssertEqual(trail.goBack(), "a")
        XCTAssertNil(trail.goBack(), "nothing before the first")
        XCTAssertEqual(trail.goForward(), "b")
        XCTAssertEqual(trail.goForward(), "c")
        XCTAssertNil(trail.goForward())
        XCTAssertEqual(trail.current, "c")
    }

    func testANewVisitClearsForward() {
        var trail = SessionTrail()
        for id in ["a", "b", "c"] { trail.visit(id) }
        _ = trail.goBack()
        trail.visit("d")
        XCTAssertFalse(trail.canGoForward)
        XCTAssertEqual(trail.goBack(), "b")
    }

    func testRevisitingTheCurrentSessionIsNoVisit() {
        var trail = SessionTrail()
        trail.visit("a")
        trail.visit("a")
        XCTAssertFalse(trail.canGoBack)
    }

    func testGoneSessionsAreSkipped() {
        var trail = SessionTrail()
        for id in ["a", "b", "c"] { trail.visit(id) }
        XCTAssertEqual(trail.goBack(exists: { $0 != "b" }), "a")
        XCTAssertEqual(trail.goForward(exists: { $0 != "b" }), "c")
    }

    func testTheTrailIsBounded() {
        var trail = SessionTrail()
        for n in 0..<(SessionTrail.limit + 20) { trail.visit("s\(n)") }
        XCTAssertEqual(trail.back.count, SessionTrail.limit)
    }

    // MARK: ⌘1–⌘9

    func testJumpTargetsTheShownRows() {
        let shown = ["a", "b", "c"]
        XCTAssertEqual(SessionJump.target(1, in: shown), "a")
        XCTAssertEqual(SessionJump.target(3, in: shown), "c")
        XCTAssertNil(SessionJump.target(4, in: shown), "past the end the key goes on")
        XCTAssertNil(SessionJump.target(0, in: shown))
        XCTAssertNil(SessionJump.target(10, in: (0..<12).map { "s\($0)" }))
    }

    func testHintsCoverTheFirstNineRows() {
        let shown = (1...12).map { "s\($0)" }
        let hints = SessionJump.hints(shown)
        XCTAssertEqual(hints.count, 9)
        XCTAssertEqual(hints["s1"], 1)
        XCTAssertEqual(hints["s9"], 9)
        XCTAssertNil(hints["s10"])
    }

    func testJumpCommandsRoundTrip() {
        for n in 1...9 { XCTAssertEqual(SessionJump.number(of: SessionJump.command(n)), n) }
        XCTAssertNil(SessionJump.number(of: "session.jump0"))
        XCTAssertNil(SessionJump.number(of: "session.pin"))
    }

    func testJumpKeysAreDefaultsWithoutConflicts() {
        for n in 1...9 {
            XCTAssertEqual(Keybindings.match(KeyChord.parse("mod+\(n)")!, context: [:], rules: Keybindings.defaults),
                           SessionJump.command(n))
        }
        XCTAssertEqual(Keybindings.conflicts(Keybindings.defaults), [])
    }

    // MARK: The palette

    func testQueryParsesTheActionPrefix() {
        let query = PaletteQuery(" > pin  it ")
        XCTAssertTrue(query.actionsOnly)
        XCTAssertEqual(query.words, ["pin", "it"])
        XCTAssertFalse(PaletteQuery("pin").actionsOnly)
        XCTAssertTrue(PaletteQuery(">").isEmpty)
    }

    func testMatchNeedsEveryWordAndPrefersTheTitleStart() {
        let query = PaletteQuery("cal ui")
        XCTAssertNotNil(query.match(title: "Calm UI", detail: ""))
        XCTAssertNil(query.match(title: "Calm", detail: "nothing"))
        XCTAssertNotNil(query.match(title: "Calm", detail: "the ui folder"), "a word may match the detail")
        let start = PaletteQuery("cal").match(title: "Calm list", detail: "")!
        let middle = PaletteQuery("cal").match(title: "Local list", detail: "")!
        let detail = PaletteQuery("cal").match(title: "List", detail: "calm")!
        XCTAssertGreaterThan(start, middle)
        XCTAssertGreaterThan(middle, detail)
    }

    func testRecentSessionsRankByUseThenByNewest() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var usage = SessionUsage()
        for _ in 0..<5 { usage.record("often", at: now.addingTimeInterval(-3600)) }
        usage.record("once", at: now.addingTimeInterval(-60))
        let candidates = [
            PaletteRanking.Candidate(id: "new", title: "New", detail: "", updated: now),
            PaletteRanking.Candidate(id: "once", title: "Once", detail: "", updated: now.addingTimeInterval(-100)),
            PaletteRanking.Candidate(id: "often", title: "Often", detail: "", updated: now.addingTimeInterval(-200)),
            PaletteRanking.Candidate(id: "old", title: "Old", detail: "", updated: now.addingTimeInterval(-900)),
        ]
        let ranked = PaletteRanking.sessions(candidates, query: PaletteQuery(""), usage: usage, now: now).map(\.id)
        XCTAssertEqual(ranked, ["often", "once", "new", "old"])
    }

    func testOldVisitsFadeBehindRecentOnes() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var usage = SessionUsage()
        for _ in 0..<4 { usage.record("lastMonth", at: now.addingTimeInterval(-30 * 86_400)) }
        usage.record("today", at: now.addingTimeInterval(-600))
        XCTAssertGreaterThan(usage.score("today", now: now), usage.score("lastMonth", now: now))
        XCTAssertEqual(usage.score("never", now: now), 0)
    }

    func testRankingFiltersAndLimits() {
        let now = Date()
        let candidates = (0..<30).map { PaletteRanking.Candidate(id: "s\($0)", title: "Session \($0)", detail: "app",
                                                                 updated: now.addingTimeInterval(Double(-$0))) }
        XCTAssertEqual(PaletteRanking.sessions(candidates, query: PaletteQuery(""), usage: SessionUsage(), limit: 5).count, 5)
        XCTAssertEqual(PaletteRanking.sessions(candidates, query: PaletteQuery("session 7"), usage: SessionUsage()).first?.id, "s7")
        XCTAssertEqual(PaletteRanking.sessions(candidates, query: PaletteQuery("nope"), usage: SessionUsage()), [])
    }

    // MARK: Small pieces

    func testReferenceTextNamesFolderAndBranch() {
        XCTAssertEqual(SessionReference.text(path: "/code/app", branch: "feat/x"), "/code/app (feat/x)")
        XCTAssertEqual(SessionReference.text(path: "/code/app", branch: nil), "/code/app")
        XCTAssertEqual(SessionReference.text(path: "", branch: "main"), "main")
        XCTAssertNil(SessionReference.text(path: "", branch: " "))
    }

    func testHighlightSkipsRowsThatCannotBePicked() {
        let enabled = [false, true, false, true]
        XCTAssertEqual(ListHighlight.clamped(0, in: enabled), 1)
        XCTAssertEqual(ListHighlight.clamped(9, in: enabled), 3)
        XCTAssertEqual(ListHighlight.step(1, by: 1, in: enabled), 3)
        XCTAssertEqual(ListHighlight.step(3, by: 1, in: enabled), 3, "stays at the end")
        XCTAssertEqual(ListHighlight.step(3, by: -1, in: enabled), 1)
        XCTAssertNil(ListHighlight.clamped(0, in: [false, false]))
        XCTAssertNil(ListHighlight.clamped(0, in: []))
    }
}
