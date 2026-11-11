import XCTest

final class InboxLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func row(_ id: String, _ attention: AgentAttention = .idle, age: TimeInterval = 100, title: String = "",
                     project: String = "P") -> InboxRow {
        InboxRow(id: id, title: title.isEmpty ? id : title, project: project, attention: attention,
                 lastActivity: now.addingTimeInterval(-age))
    }

    private func sections(_ rows: [InboxRow], _ state: InboxState = InboxState(), working: Bool = true,
                          limit: Int = 10, selected: String? = nil) -> [InboxSection] {
        InboxLayout.sections(rows: rows, state: state, showWorking: working, now: now, settledLimit: limit, selectedID: selected)
    }

    private func ids(_ s: [InboxSection], _ kind: InboxSection.Kind) -> [String] {
        s.first { $0.kind == kind }?.rows.map(\.id) ?? []
    }

    // MARK: Sections

    func testPinnedFirstInUserOrderAndEmptySectionsAreOmitted() {
        let s = sections([row("a"), row("b"), row("c")], InboxState(pinned: ["c", "a"]))
        XCTAssertEqual(s.map(\.kind), [.pinned, .active])
        XCTAssertEqual(ids(s, .pinned), ["c", "a"])
        XCTAssertEqual(ids(s, .active), ["b"])
    }

    func testActiveSortsByAttentionThenManualOrderThenRecency() {
        let rows = [row("idle-old", age: 500), row("idle-new", age: 10), row("fail", .failed), row("ask", .approval),
                    row("m1", age: 900), row("m2", age: 5)]
        let s = sections(rows, InboxState(order: ["m1", "m2"]))
        XCTAssertEqual(ids(s, .active), ["ask", "fail", "m1", "m2", "idle-new", "idle-old"])
    }

    func testOrderIsStableAcrossInputPermutations() {
        let rows = [row("a", age: 5), row("b", age: 5), row("c", age: 5)]
        XCTAssertEqual(ids(sections(rows), .active), ["a", "b", "c"])
        XCTAssertEqual(ids(sections(rows.reversed()), .active), ["a", "b", "c"])
    }

    func testWorkingShelfOnlyWhenShownAndNeedsYouJumpsBack() {
        var bg = row("bg"); bg.hasBackgroundWork = true
        var asks = row("asks", .working); asks.hasOpenRequest = true
        let rows = [row("w", .working), bg, asks, row("f", .failed)]
        let on = sections(rows)
        XCTAssertEqual(Set(ids(on, .working)), ["w", "bg"])
        XCTAssertEqual(ids(on, .active), ["asks", "f"])
        let off = sections(rows, working: false)
        XCTAssertTrue(ids(off, .working).isEmpty)
        XCTAssertEqual(Set(ids(off, .active)), ["w", "bg", "asks", "f"])
    }

    func testWorkingShelfSitsAboveEverythingElse() {
        let rows = [row("a"), row("w", .working), row("p"), row("z")]
        let s = sections(rows, InboxState(pinned: ["p"], settled: ["z"]))
        XCTAssertEqual(s.map(\.kind), [.working, .pinned, .active, .settled])
    }

    func testSnoozeAndWakeAreReversible() {
        var r = row("s")
        r.snoozedUntil = now.addingTimeInterval(600); r.snoozedAt = now.addingTimeInterval(-60)
        XCTAssertEqual(ids(sections([r]), .snoozed), ["s"])
        // Wake early: something needs you.
        var asks = r; asks.attention = .approval
        XCTAssertEqual(ids(sections([asks]), .active), ["s"])
        XCTAssertTrue(sections([asks])[0].rows[0].woke)
        // Cleared snooze: plain active.
        r.snoozedUntil = nil
        XCTAssertEqual(ids(sections([r]), .active), ["s"])
        XCTAssertFalse(sections([r])[0].rows[0].woke)
    }

    func testExpiredSnoozeShowsWokeUntilDismissed() {
        var r = row("s")
        r.snoozedUntil = now.addingTimeInterval(-1)
        XCTAssertTrue(sections([r])[0].rows[0].woke)
        var state = InboxState()
        state.dismissWoke("s")
        XCTAssertFalse(sections([r], state)[0].rows[0].woke)
        r.wokeDismissed = true
        XCTAssertFalse(sections([r])[0].rows[0].woke)
    }

    func testSnoozedSortedByWakeTime() {
        var a = row("a"), b = row("b")
        a.snoozedUntil = now.addingTimeInterval(900); b.snoozedUntil = now.addingTimeInterval(300)
        XCTAssertEqual(ids(sections([a, b]), .snoozed), ["b", "a"])
    }

    func testSettledNewestFirstAndPaged() {
        let rows = (0..<5).map { row("r\($0)", age: Double($0) * 10) }
        let state = InboxState(settled: Set(rows.map(\.id)))
        let s = sections(rows, state, limit: 3)
        XCTAssertEqual(ids(s, .settled), ["r0", "r1", "r2"])
        XCTAssertEqual(s[0].hiddenCount, 2)
        XCTAssertEqual(sections(rows, state, limit: 13)[0].hiddenCount, 0)
    }

    func testOpenSessionStaysOnTheSettledPage() {
        let rows = (0..<5).map { row("r\($0)", age: Double($0) * 10) }
        let state = InboxState(settled: Set(rows.map(\.id)))
        let s = sections(rows, state, limit: 3, selected: "r4")
        XCTAssertEqual(ids(s, .settled), ["r0", "r1", "r2", "r4"])
        XCTAssertEqual(s[0].hiddenCount, 1)
    }

    func testFoldedShelfStillShowsTheOpenSession() {
        let snoozed = InboxSection(kind: .snoozed, rows: sections([row("a"), row("b")], InboxState(settled: ["a", "b"]))[0].rows)
        XCTAssertEqual(InboxLayout.shownRows(snoozed, folded: true, selectedID: "b").map(\.id), ["b"])
        XCTAssertEqual(InboxLayout.shownRows(snoozed, folded: true, selectedID: "x").map(\.id), [])
        XCTAssertEqual(InboxLayout.shownRows(snoozed, folded: false, selectedID: "b").map(\.id), ["a", "b"])
    }

    func testFoldedSettledShelfShowsNothing() {
        let settled = sections([row("a"), row("b")], InboxState(settled: ["a", "b"]))[0]
        XCTAssertEqual(InboxLayout.shownRows(settled, folded: true, selectedID: "b").map(\.id), [])
        XCTAssertEqual(InboxLayout.shownRows(settled, folded: false, selectedID: "b").map(\.id), ["a", "b"])
    }

    func testSettledRowThatNeedsYouIsNotHidden() {
        var r = row("a", .approval); r.settled = true
        XCTAssertEqual(ids(sections([r]), .active), ["a"])
    }

    func testPinnedWinsOverSettledAndSnoozed() {
        var r = row("a"); r.snoozedUntil = now.addingTimeInterval(600)
        let s = sections([r], InboxState(pinned: ["a"], settled: ["a"]))
        XCTAssertEqual(ids(s, .pinned), ["a"])
    }

    func testEveryRowLandsOnce() {
        var sn = row("sn"); sn.snoozedUntil = now.addingTimeInterval(60)
        let rows = [row("a"), row("w", .working), sn, row("p"), row("z")]
        let s = sections(rows, InboxState(pinned: ["p"], settled: ["z"]))
        XCTAssertEqual(s.flatMap { $0.rows.map(\.id) }.sorted(), ["a", "p", "sn", "w", "z"])
    }

    // MARK: Projects

    func testProjectGroupsHoldWorkingAndActiveRowsPerProject() {
        let rows = [row("n1", project: "Nook"), row("w1", .working, age: 50, project: "WhoBench"),
                    row("n2", .working, age: 10, project: "Nook"), row("p", project: "Nook"), row("z", project: "Nook")]
        let groups = InboxLayout.projectGroups(sections(rows, InboxState(pinned: ["p"], settled: ["z"])))
        XCTAssertEqual(groups.map(\.project), ["Nook", "WhoBench"])
        // Newest activity first inside the project; pinned and settled keep their own sections.
        XCTAssertEqual(groups[0].rows.map(\.entry.id), ["n2", "n1"])
        XCTAssertEqual(groups[0].rows.map(\.kind), [.working, .active])
        XCTAssertEqual(groups[1].rows.map(\.entry.id), ["w1"])
    }

    func testProjectsKeepTheirPlaceWhenOneChanges() {
        // B has the newest activity and waits for you, yet the folders stay in name order.
        let rows = [row("a", age: 500, project: "A"), row("b", .approval, age: 1, project: "B")]
        let groups = InboxLayout.projectGroups(sections(rows))
        XCTAssertEqual(groups.map(\.project), ["A", "B"])
        XCTAssertFalse(groups[0].needsYou)
        XCTAssertTrue(groups[1].needsYou)
    }

    func testChangedSessionMovesToTopOfItsProject() {
        let rows = [row("old", age: 500, project: "A"), row("mid", age: 100, project: "A"),
                    row("ask", .approval, age: 900, project: "A"), row("fresh", age: 1, project: "A")]
        let groups = InboxLayout.projectGroups(sections(rows))
        XCTAssertEqual(groups[0].rows.map(\.entry.id), ["fresh", "mid", "old", "ask"])
    }

    func testNestedSessionStaysUnderItsParentInsideProject() {
        var child = row("child", age: 1, project: "A"); child.parentID = "parent"
        let rows = [row("other", age: 50, project: "A"), row("parent", age: 500, project: "A"), child]
        let groups = InboxLayout.projectGroups(sections(rows))
        XCTAssertEqual(groups[0].rows.map(\.entry.id), ["parent", "child", "other"])
    }

    // MARK: Receding

    func testRecedingRule() {
        func rec(_ r: InboxRow, woke: Bool = false, selected: Bool = false) -> Bool {
            InboxLayout.receded(r, woke: woke, selected: selected)
        }
        XCTAssertFalse(rec(row("i", .input)))
        XCTAssertTrue(rec(row("w", .working)))
        XCTAssertFalse(rec(row("w", .working), selected: true))
        var read = row("r", .ready); read.unread = false
        XCTAssertTrue(rec(read))
        XCTAssertFalse(rec(read, woke: true))
        XCTAssertFalse(rec(row("r", .ready)))
        var approvalRead = row("a", .approval); approvalRead.unread = false
        XCTAssertTrue(rec(approvalRead))
        XCTAssertFalse(rec(row("f", .failed)))
        XCTAssertFalse(rec(row("idle")))
    }

    func testSelectedRowDoesNotRecedeInLayout() {
        let s = sections([row("w", .working)], selected: "w")
        XCTAssertFalse(s[0].rows[0].receded)
        XCTAssertTrue(sections([row("w", .working)])[0].rows[0].receded)
    }

    // MARK: State

    func testPinUnpinSettleUnsettle() {
        var st = InboxState()
        st.pin("a"); st.pin("b"); st.pin("c", at: 1)
        XCTAssertEqual(st.pinned, ["b", "c", "a"])
        st.pin("a", at: 99)
        XCTAssertEqual(st.pinned, ["b", "c", "a"])
        st.unpin("c")
        XCTAssertEqual(st.pinned, ["b", "a"])
        st.settle("b")
        XCTAssertEqual(st.pinned, ["a"])
        XCTAssertTrue(st.settled.contains("b"))
        st.unsettle("b")
        XCTAssertTrue(st.settled.isEmpty)
        st.pin("a")
        XCTAssertEqual(st.settled, [])
    }

    func testUnpinAtIndexJoinsManualOrder() {
        var st = InboxState(pinned: ["a"], order: ["x", "y"])
        st.unpin("a", at: 1)
        XCTAssertEqual(st.order, ["x", "a", "y"])
        XCTAssertTrue(st.pinned.isEmpty)
    }

    func testMoveTargetStaysAmongRowsWithTheSameAttention() {
        let rows = [row("a", .input), row("b", age: 100), row("c", age: 200), row("d", age: 300)]
        let active = sections(rows).first { $0.kind == .active }!
        XCTAssertEqual(active.rows.map(\.id), ["a", "b", "c", "d"])
        // "a" needs you and sorts first by attention: it cannot trade places with the idle rows.
        XCTAssertNil(InboxLayout.moveTarget("a", up: false, in: active))
        XCTAssertNil(InboxLayout.moveTarget("b", up: true, in: active))
        XCTAssertNil(InboxLayout.moveTarget("d", up: false, in: active))
        XCTAssertEqual(InboxLayout.moveTarget("c", up: true, in: active), 1)
        XCTAssertEqual(InboxLayout.moveTarget("b", up: false, in: active), 2)

        var state = InboxState()
        state.reorder("b", toIndex: InboxLayout.moveTarget("b", up: false, in: active)!, within: active)
        XCTAssertEqual(ids(sections(rows, state), .active), ["a", "c", "b", "d"])
    }

    func testMoveTargetInPinnedIgnoresAttention() {
        let rows = [row("a", .input), row("b")]
        let pinned = sections(rows, InboxState(pinned: ["a", "b"])).first { $0.kind == .pinned }!
        XCTAssertEqual(InboxLayout.moveTarget("b", up: true, in: pinned), 0)
        XCTAssertEqual(InboxLayout.moveTarget("a", up: false, in: pinned), 1)
    }

    func testReorderWithinActiveAndPinned() {
        let rows = [row("a"), row("b"), row("c")]
        var st = InboxState(pinned: ["p", "q"])
        let active = sections(rows, st)[0].rows.isEmpty ? nil : sections(rows, st).first { $0.kind == .active }!
        st.reorder("c", toIndex: 0, within: active!)
        XCTAssertEqual(st.order, ["c", "a", "b"])
        XCTAssertEqual(ids(sections(rows, st), .active), ["c", "a", "b"])
        // Reverse.
        st.reorder("c", toIndex: 2, within: sections(rows, st).first { $0.kind == .active }!)
        XCTAssertEqual(ids(sections(rows, st), .active), ["a", "b", "c"])

        let pinRows = [row("p"), row("q")]
        st = InboxState(pinned: ["p", "q"])
        st.reorder("q", toIndex: 0, within: sections(pinRows, st)[0])
        XCTAssertEqual(st.pinned, ["q", "p"])
        // Sections without manual order are ignored.
        let settled = sections([row("z")], InboxState(settled: ["z"]))[0]
        st.reorder("z", toIndex: 0, within: settled)
        XCTAssertEqual(st.order, [])
    }

    func testStateDecodesMissingAndUnknownFields() throws {
        let st = try JSONDecoder().decode(InboxState.self, from: Data(#"{"pinned":["a"],"future":1}"#.utf8))
        XCTAssertEqual(st.pinned, ["a"])
        XCTAssertTrue(st.settled.isEmpty)
        let back = try JSONDecoder().decode(InboxState.self, from: JSONEncoder().encode(InboxState(pinned: ["x"], settled: ["y"])))
        XCTAssertEqual(back, InboxState(pinned: ["x"], settled: ["y"]))
    }

    // MARK: Search

    func testSearchIsCaseDiacriticInsensitiveAndAndsTokens() {
        let rows = [row("1", title: "Café inloggen", project: "Nook"), row("2", title: "Login bug", project: "Web"),
                    row("3", title: "cafe", project: "Web")]
        XCTAssertEqual(InboxSearch.filter(rows: rows, query: "CAFÉ").map(\.id), ["1", "3"])
        XCTAssertEqual(InboxSearch.filter(rows: rows, query: "cafe nook").map(\.id), ["1"])
        XCTAssertEqual(InboxSearch.filter(rows: rows, query: "web login").map(\.id), ["2"])
        XCTAssertEqual(InboxSearch.filter(rows: rows, query: "  ").count, 3)
        XCTAssertTrue(InboxSearch.filter(rows: rows, query: "zzz").isEmpty)
    }

    func testMessageSearchThreshold() {
        XCTAssertEqual(InboxSearch.minimumMessageQueryLength, 2)
        XCTAssertFalse(InboxSearch.searchesMessages("a"))
        XCTAssertFalse(InboxSearch.searchesMessages(" a "))
        XCTAssertTrue(InboxSearch.searchesMessages("ab"))
    }

    // MARK: Nesting

    func testSpawnedSessionSitsUnderItsParent() {
        var child = row("child", .working, age: 10)
        child.parentID = "parent"
        let s = sections([row("other", age: 5), row("parent", age: 50), child])
        XCTAssertEqual(ids(s, .working), [])
        XCTAssertEqual(ids(s, .active), ["other", "parent", "child"])
        XCTAssertEqual(s.first { $0.kind == .active }?.rows.map(\.depth), [0, 0, 1])
    }

    func testSubThreadThatNeedsYouBringsItsWorkingParentUpToActive() {
        var child = row("child", .approval)
        child.parentID = "parent"
        let s = sections([row("parent", .working), child])
        XCTAssertEqual(ids(s, .working), [])
        XCTAssertEqual(ids(s, .active), ["parent", "child"])
        XCTAssertEqual(s.first { $0.kind == .active }?.rows.map(\.depth), [0, 1])
    }

    func testSubThreadThatNeedsYouFollowsAPinnedParent() {
        var child = row("child", .input)
        child.parentID = "parent"
        let s = sections([row("parent"), child], InboxState(pinned: ["parent"]))
        XCTAssertEqual(ids(s, .pinned), ["parent", "child"])
        XCTAssertEqual(ids(s, .active), [])
    }

    func testSubThreadOfASubThreadFollowsTheWholeChain() {
        var child = row("child", .working), grandchild = row("grandchild", .working)
        child.parentID = "parent"; grandchild.parentID = "child"
        let s = sections([row("parent"), child, grandchild])
        XCTAssertEqual(ids(s, .working), [])
        XCTAssertEqual(ids(s, .active), ["parent", "child", "grandchild"])
        let active = s.first { $0.kind == .active }?.rows ?? []
        XCTAssertEqual(active.map(\.depth), [0, 1, 2])
        XCTAssertEqual(active.map(\.ancestors), [[], ["parent"], ["child", "parent"]])
    }

    func testSubThreadIsNeverAlsoATopLevelRow() {
        var child = row("child", .working)
        child.parentID = "parent"
        let s = sections([row("parent", .ready), child])
        let all = s.flatMap(\.rows)
        XCTAssertEqual(all.filter { $0.id == "child" }.count, 1)
        XCTAssertEqual(all.first { $0.id == "child" }?.depth, 1)
    }

    // MARK: Threads

    private func entries(_ rows: [InboxRow]) -> [InboxEntry] {
        InboxLayout.nest(rows.map { InboxEntry(row: $0, receded: false, woke: false) })
    }

    func testParentCountsItsSubThreadsAtEveryLevelAndWhatTheyNeed() {
        var a = row("a"), b = row("b", .approval), c = row("c", .working), d = row("d")
        a.parentID = "p"; b.parentID = "p"; c.parentID = "a"; d.parentID = "c"
        let nested = entries([row("p"), a, b, c, d, row("lone")])
        let byID = Dictionary(uniqueKeysWithValues: nested.map { ($0.id, $0) })
        XCTAssertEqual(nested.map(\.id), ["p", "a", "c", "d", "b", "lone"])
        XCTAssertEqual(byID["p"]?.subThreads, 4)
        XCTAssertEqual(byID["a"]?.subThreads, 2)
        XCTAssertEqual(byID["c"]?.subThreads, 1)
        XCTAssertEqual(byID["lone"]?.subThreads, 0)
        XCTAssertEqual(byID["p"]?.subThreadNeedsYou, true)
        XCTAssertEqual(byID["a"]?.subThreadNeedsYou, false)
        XCTAssertEqual(byID["a"]?.subThreadActive, true)
        XCTAssertEqual(byID["c"]?.subThreadActive, false)
        // Deeper than two steps the row stays at the second step; the tree is kept in `ancestors`.
        XCTAssertEqual(byID["d"]?.depth, 2)
        XCTAssertEqual(byID["d"]?.ancestors, ["c", "a", "p"])
    }

    func testThreadsOpenWhileASubThreadWorksOrAsksAndFoldWhenQuiet() {
        var busy = row("busy", .working), quiet = row("quiet"), asks = row("asks", .input)
        busy.parentID = "p1"; quiet.parentID = "p2"; asks.parentID = "p3"
        let nested = entries([row("p1"), busy, row("p2"), quiet, row("p3"), asks])
        func open(_ id: String, opened: Set<String> = [], folded: Set<String> = []) -> Bool {
            InboxLayout.threadOpen(nested.first { $0.id == id }!, opened: opened, folded: folded)
        }
        XCTAssertTrue(open("p1"))
        XCTAssertFalse(open("p2"))
        XCTAssertTrue(open("p3"))
        // What you chose wins over the default, either way.
        XCTAssertFalse(open("p1", folded: ["p1"]))
        XCTAssertTrue(open("p2", opened: ["p2"]))
    }

    func testFoldingHidesEveryLevelUnderTheSessionButKeepsTheOpenOne() {
        var a = row("a"), b = row("b"), c = row("c")
        a.parentID = "p"; b.parentID = "a"; c.parentID = "p"
        let nested = entries([row("p"), a, b, c, row("other")])
        let folded = InboxLayout.foldThreads(nested, isOpen: { $0.id != "p" }, selectedID: nil)
        XCTAssertEqual(folded.map(\.id), ["p", "other"])
        let keepsOpen = InboxLayout.foldThreads(nested, isOpen: { $0.id != "p" }, selectedID: "b")
        XCTAssertEqual(keepsOpen.map(\.id), ["p", "b", "other"])
        let inner = InboxLayout.foldThreads(nested, isOpen: { $0.id != "a" }, selectedID: nil)
        XCTAssertEqual(inner.map(\.id), ["p", "a", "c", "other"])
        XCTAssertEqual(InboxLayout.foldThreads(nested, isOpen: { _ in true }, selectedID: nil).map(\.id), nested.map(\.id))
    }

    func testSearchKeepsAMatchingSubThreadUnderItsParentOrOnItsOwn() {
        var child = row("child", title: "fix login")
        child.parentID = "parent"
        let both = [row("parent", title: "login work"), child]
        let nested = sections(InboxSearch.filter(rows: both, query: "login"))
        XCTAssertEqual(ids(nested, .active), ["parent", "child"])
        XCTAssertEqual(nested.first { $0.kind == .active }?.rows.map(\.depth), [0, 1])
        // The parent does not match: the sub-thread shows as a session of its own.
        let alone = sections(InboxSearch.filter(rows: both, query: "fix"))
        XCTAssertEqual(ids(alone, .active), ["child"])
        XCTAssertEqual(alone.first { $0.kind == .active }?.rows.first?.depth, 0)
    }

    func testFoldedThreadKeepsItsBlockTogetherInsideProject() {
        var child = row("child", age: 1, project: "A"); child.parentID = "parent"
        let groups = InboxLayout.projectGroups(sections([row("other", age: 50, project: "A"), row("parent", age: 500, project: "A"), child]))
        let rows = groups[0].rows.map(\.entry)
        XCTAssertEqual(rows.first { $0.id == "parent" }?.subThreads, 1)
        let folded = InboxLayout.foldThreads(rows, isOpen: { _ in false }, selectedID: nil)
        XCTAssertEqual(folded.map(\.id), ["parent", "other"])
    }

    func testNestingSurvivesALoopAndAMissingParent() {
        var a = row("a"), b = row("b"), c = row("c")
        a.parentID = "b"; b.parentID = "a"; c.parentID = "gone"
        let nested = InboxLayout.nest([a, b, c].map { InboxEntry(row: $0, receded: false, woke: false) })
        XCTAssertEqual(Set(nested.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(nested.first { $0.id == "c" }?.depth, 0)
    }
}
