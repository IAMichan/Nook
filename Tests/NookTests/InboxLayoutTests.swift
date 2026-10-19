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

    // MARK: Drops

    func testDropDecisions() {
        let r = row("a")
        typealias D = InboxDrop
        XCTAssertEqual(D.decide(row: r, from: .active, to: .pinned), .pin)
        XCTAssertEqual(D.decide(row: r, from: .pinned, to: .active), .unpin)
        XCTAssertEqual(D.decide(row: r, from: .active, to: .settled), .settle)
        XCTAssertEqual(D.decide(row: r, from: .pinned, to: .settled), .settle)
        XCTAssertEqual(D.decide(row: r, from: .settled, to: .active), .unsettle)
        XCTAssertEqual(D.decide(row: r, from: .snoozed, to: .active), .wake)
        XCTAssertEqual(D.decide(row: r, from: .snoozed, to: .settled), .settle)
        XCTAssertEqual(D.decide(row: r, from: .active, to: .snoozed), .rejected(.needsTime))
        XCTAssertEqual(D.decide(row: r, from: .settled, to: .snoozed), .rejected(.needsTime))
        XCTAssertEqual(D.decide(row: r, from: .snoozed, to: .snoozed), .rejected(.needsTime))
        XCTAssertEqual(D.decide(row: r, from: .active, to: .working), .rejected(.automatic))
        XCTAssertEqual(D.decide(row: r, from: .working, to: .active), .rejected(.automatic))
        XCTAssertEqual(D.decide(row: r, from: .active, to: .active), .reorder)
        XCTAssertEqual(D.decide(row: r, from: .pinned, to: .pinned), .reorder)
        XCTAssertEqual(D.decide(row: r, from: .settled, to: .settled), .rejected(.notReorderable))
    }

    func testDropLabelKeys() {
        XCTAssertEqual(InboxDrop.DropResult.pin.labelKey, "inbox.drop.pin")
        XCTAssertEqual(InboxDrop.DropResult.settle.labelKey, "inbox.drop.settle")
        XCTAssertEqual(InboxDrop.DropResult.wake.labelKey, "inbox.drop.wake")
        XCTAssertEqual(InboxDrop.DropResult.rejected(.needsTime).labelKey, "inbox.drop.needsTime")
        XCTAssertNil(InboxDrop.DropResult.reorder.labelKey)
    }

    func testReorderTarget() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertNil(InboxDrop.reorderTarget(ids: ids, dragged: "b", gap: 1))
        XCTAssertNil(InboxDrop.reorderTarget(ids: ids, dragged: "b", gap: 2))
        XCTAssertEqual(InboxDrop.reorderTarget(ids: ids, dragged: "b", gap: 4), 3)
        XCTAssertEqual(InboxDrop.reorderTarget(ids: ids, dragged: "c", gap: 0), 0)
        XCTAssertEqual(InboxDrop.reorderTarget(ids: ids, dragged: "a", gap: 3), 2)
        XCTAssertNil(InboxDrop.reorderTarget(ids: ids, dragged: "zz", gap: 1))
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
}
