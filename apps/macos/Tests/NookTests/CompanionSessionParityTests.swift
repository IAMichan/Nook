import XCTest

/// The Agents tab on the phone as on the Mac (`CompanionSessions.swift`, `CompanionFeature.agentsTab`).
final class CompanionSessionParityTests: XCTestCase {
    private func session(_ id: String, attention: String = "idle", updated: Double = 0, items: [SessionDigest.Item] = [],
                         pinned: Bool? = nil, settled: Bool? = nil, snoozedUntil: Double? = nil) -> SessionDigest {
        var digest = SessionDigest(id: id, title: id, agent: "Claude Code", attention: attention, folder: "nook", branch: nil,
                                   updated: updated, excerpt: "", items: items)
        digest.pinned = pinned
        digest.settled = settled
        digest.snoozedUntil = snoozedUntil
        return digest
    }

    private func question(_ id: String, options: [String] = ["A", "B", "C"], multi: Bool = false, other: Bool = false) -> SessionQuestion {
        SessionQuestion(id: id, header: "", question: "Which?", options: options, multiSelect: multi, allowsOther: other)
    }

    // MARK: Shelves

    func testEverySessionLandsOnTheMacsShelf() {
        let approval = SessionDigest.Item(id: "i", kind: .approval, title: "Run", detail: "", canAllow: true, options: [])
        XCTAssertEqual(SessionShelf.of(session("a", items: [approval], pinned: true), showWorking: true, now: 10), .needsYou)
        XCTAssertEqual(SessionShelf.of(session("b", attention: "working", pinned: true), showWorking: true, now: 10), .pinned)
        XCTAssertEqual(SessionShelf.of(session("c", settled: true, snoozedUntil: 20), showWorking: true, now: 10), .settled)
        XCTAssertEqual(SessionShelf.of(session("d", snoozedUntil: 20), showWorking: true, now: 10), .snoozed)
        // A snooze that ended puts it back among the others.
        XCTAssertEqual(SessionShelf.of(session("e", snoozedUntil: 5), showWorking: true, now: 10), .active)
        XCTAssertEqual(SessionShelf.of(session("f", attention: "working"), showWorking: true, now: 10), .working)
        XCTAssertEqual(SessionShelf.of(session("f", attention: "working"), showWorking: false, now: 10), .active)
        // A failed or limited session needs you, also when it is settled.
        XCTAssertEqual(SessionShelf.of(session("g", attention: "failed", settled: true), showWorking: true, now: 10), .needsYou)
    }

    func testThePhoneKeepsEverySessionAtWorkOnTop() {
        let question = SessionDigest.Item(id: "q", kind: .question, title: "Which?", detail: "", canAllow: false, options: [])
        // What needs you still comes first, also while the agent reads as working.
        XCTAssertEqual(SessionShelf.onPhone(session("a", attention: "working", items: [question]), now: 10), .needsYou)
        // Work in progress is never tucked away on a shelf of the Mac.
        XCTAssertEqual(SessionShelf.onPhone(session("b", attention: "working", pinned: true), now: 10), .working)
        XCTAssertEqual(SessionShelf.onPhone(session("c", attention: "working", settled: true), now: 10), .working)
        XCTAssertEqual(SessionShelf.onPhone(session("d", attention: "working", snoozedUntil: 20), now: 10), .working)
        // The rest keeps the Mac's shelves.
        XCTAssertEqual(SessionShelf.onPhone(session("e", pinned: true), now: 10), .pinned)
        XCTAssertEqual(SessionShelf.onPhone(session("f", snoozedUntil: 20), now: 10), .snoozed)
        XCTAssertEqual(SessionShelf.onPhone(session("g", settled: true), now: 10), .settled)
        XCTAssertEqual(SessionShelf.onPhone(session("h", attention: "ready"), now: 10), .active)
    }

    func testAnOlderMacPutsEverySessionWhereTheListHadIt() {
        // Without the Agents tab's flags nothing is pinned, settled or snoozed.
        let shelves = SessionShelf.place([session("a", updated: 1), session("b", attention: "working", updated: 2),
                                          session("c", updated: 3)], showWorking: true, now: 10)
        XCTAssertEqual(shelves[.active]?.map(\.id), ["c", "a"])
        XCTAssertEqual(shelves[.working]?.map(\.id), ["b"])
        XCTAssertNil(shelves[.pinned])
        XCTAssertNil(shelves[.settled])
    }

    // MARK: Menus

    func testMenusFollowTheMacsOrderAndOnlyWhatIsOffered() {
        let offered = ["archive", "markUnread", "fork", "rename", "pin", "snoozeHour", "settle", "delete", "unknownFromANewerMac"]
        XCTAssertEqual(SessionMenu.items(SessionMenu.row, offered: offered),
                       [.rename, .pin, .settle, .snoozeHour, .fork, .markUnread, .archive, .delete])
        XCTAssertEqual(SessionMenu.items(SessionMenu.header, offered: ["delete", "retry", "regenerateTitle", "rename"]),
                       [.retry, .rename, .regenerateTitle, .delete])
        XCTAssertEqual(SessionMenu.items(SessionMenu.row, offered: nil), [])
    }

    func testTheNewActionsAreOnlyThoseOfTheAgentsTab() {
        // An older phone knows none of them: its menus stay as they were. `model` is the composer's model menu that came
        // before the Agents tab (a Mac without `agentsTab` may list it).
        let old: [SessionAction] = [.rename, .archive, .snoozeHour, .snoozeEvening, .snoozeTomorrow, .unsnooze, .snoozeUntil,
                                    .snoozeLimitReset, .end, .mainThreadOn, .mainThreadOff, .model]
        XCTAssertTrue(SessionAction.agentsTab.isDisjoint(with: old))
        XCTAssertEqual(Set(SessionAction.allCases), SessionAction.agentsTab.union(old))
        XCTAssertTrue(SessionMenu.confirms(.delete))
        XCTAssertTrue(SessionMenu.confirms(.deleteWithWorktree))
        XCTAssertFalse(SessionMenu.confirms(.pin))
    }

    // MARK: Questions

    func testAnswersToEveryQuestionAreChecked() {
        let questions = [question("q1"), question("q2", multi: true), question("q3", other: true)]
        let good = ["q1": ["A"], "q2": ["B", "C"], "q3": ["my own words"]]
        XCTAssertEqual(SessionAnswers.validated(good, for: questions), good)
        // A question left out, two answers where one may be picked, words where only options count, a repeat.
        XCTAssertNil(SessionAnswers.validated(["q1": ["A"], "q2": ["B"]], for: questions))
        XCTAssertNil(SessionAnswers.validated(["q1": ["A", "B"], "q2": ["B"], "q3": ["x"]], for: questions))
        XCTAssertNil(SessionAnswers.validated(["q1": ["Z"], "q2": ["B"], "q3": ["x"]], for: questions))
        XCTAssertNil(SessionAnswers.validated(["q1": ["A"], "q2": ["B", "B"], "q3": ["x"]], for: questions))
        XCTAssertNil(SessionAnswers.validated(nil, for: questions))
        // Spaces around an answer go; an empty one does not count.
        XCTAssertEqual(SessionAnswers.validated(["q1": [" A "]], for: [question("q1")]), ["q1": ["A"]])
        XCTAssertNil(SessionAnswers.validated(["q1": ["  "]], for: [question("q1")]))
    }

    func testPickingAnOptionTogglesItOnlyWhereSeveralMayBePicked() {
        XCTAssertEqual(SessionAnswers.toggle("A", in: ["B"], multiSelect: false), ["A"])
        XCTAssertEqual(SessionAnswers.toggle("A", in: ["B"], multiSelect: true), ["B", "A"])
        XCTAssertEqual(SessionAnswers.toggle("B", in: ["B", "A"], multiSelect: true), ["A"])
    }

    // MARK: Travelling

    func testTheNewFieldsTravelAndAnOlderMacsDigestStillReads() throws {
        var digest = session("s", pinned: true, settled: nil, snoozedUntil: 99)
        digest.path = "/Users/me/nook"
        digest.controls = SessionControls(effort: "", efforts: [.init(id: "", name: "Default"), .init(id: "high", name: "High")],
                                          mode: "plan", model: "opus", models: [.init(id: "opus", name: "Opus")])
        digest.queued = [QueuedDigest.clipped(id: "m1", text: String(repeating: "x", count: 500))]
        var item = SessionDigest.Item(id: "q", kind: .question, title: "Which?", detail: "", canAllow: false, options: [])
        item.questions = [question("q1", multi: true)]
        item.canAlways = true
        digest.items = [item]
        let back = try JSONDecoder().decode(SessionDigest.self, from: JSONEncoder().encode(digest))
        XCTAssertEqual(back, digest)
        XCTAssertEqual(back.queued?.first?.text.count, QueuedDigest.limit + 1)
        // What an older Mac sends has none of them.
        let old = #"{"id":"s","title":"t","agent":"Codex","attention":"idle","folder":"f","updated":1,"excerpt":"","items":[]}"#
        let read = try JSONDecoder().decode(SessionDigest.self, from: Data(old.utf8))
        XCTAssertNil(read.pinned)
        XCTAssertNil(read.controls)
        XCTAssertEqual(SessionShelf.of(read, showWorking: true), .active)
    }

    func testARequestCarriesTheDecisionAnswersAndLaunchChoices() throws {
        var request = CompanionRequest(op: .decide, session: "S", item: "I", allow: true)
        request.decision = ApprovalChoice.always.rawValue
        request.answers = ["q1": ["A", "B"]]
        var launch = LaunchRequest(agent: "claude", project: "/p", task: "t", title: "Name")
        launch.effort = "high"
        launch.permission = "acceptEdits"
        launch.baseBranch = "main"
        request.launch = launch
        let back = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(back, request)
        XCTAssertEqual(back.launch?.baseBranch, "main")
    }
}
