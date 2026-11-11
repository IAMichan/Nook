import XCTest

/// The workflow features that follow t3code: the message limit, snooze options, auto-settle rules for pull requests,
/// the sweep's range, pull request prompt links, the model picker's keys and the dictation context.
final class WorkflowParityTests: XCTestCase {
    // MARK: Message limit and paste as text

    func testMessageLimit() {
        XCTAssertNil(PasteRule.overLimit(String(repeating: "a", count: PasteRule.messageLimit)))
        XCTAssertEqual(PasteRule.overLimit(String(repeating: "a", count: PasteRule.messageLimit + 5)), 5)
        // Counted in characters, not UTF-16 units: an emoji is one.
        XCTAssertNil(PasteRule.overLimit(String(repeating: "👍", count: PasteRule.messageLimit)))
    }

    func testPasteAsTextKeepsABigPasteUnlessItBreaksTheLimit() {
        let big = String(repeating: "a", count: PasteRule.attachThreshold)
        XCTAssertTrue(PasteRule.attaches(big, result: big, asText: false))
        XCTAssertFalse(PasteRule.attaches(big, result: big, asText: true), "⇧⌘V keeps it as text")
        let small = "short paste"
        let tooLong = String(repeating: "a", count: PasteRule.messageLimit) + small
        XCTAssertTrue(PasteRule.attaches(small, result: tooLong, asText: false), "a small paste past the limit goes aside")
        XCTAssertTrue(PasteRule.attaches(small, result: tooLong, asText: true), "also as text")
        XCTAssertFalse(PasteRule.attaches(small, result: small, asText: false))
    }

    // MARK: Snooze options

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-05-13 is a Wednesday.
    private func date(_ hour: Int, minute: Int = 0, day: Int = 13) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour, minute: minute))!
    }

    func testSnoozeOptionEnds() {
        XCTAssertEqual(SnoozeOption.duration(minutes: 90).end(from: date(10), calendar: calendar), date(11, minute: 30))
        XCTAssertEqual(SnoozeOption.time(.today, hour: 18).end(from: date(10), calendar: calendar), date(18))
        XCTAssertNil(SnoozeOption.time(.today, hour: 18).end(from: date(19), calendar: calendar), "a passed today option hides")
        XCTAssertEqual(SnoozeOption.time(.tomorrow, hour: 21).end(from: date(23), calendar: calendar), date(21, day: 14))
        XCTAssertEqual(SnoozeOption.time(.friday, hour: 9).end(from: date(10), calendar: calendar), date(9, day: 15))
        XCTAssertEqual(SnoozeOption.time(.wednesday, hour: 9).end(from: date(8), calendar: calendar), date(9, day: 20),
                       "a weekday is the next one after today")
        XCTAssertEqual(SnoozeOption.duration(minutes: 999_999).end(from: date(10), calendar: calendar),
                       date(10).addingTimeInterval(SnoozePolicy.maxCustom), "never past a month")
    }

    func testSnoozeMenuIsSoonestFirstWithoutPassedOptions() {
        let options: [SnoozeOption] = [.time(.tomorrow, hour: 9), .duration(minutes: 60), .time(.today, hour: 18),
                                       .duration(minutes: 600)]
        XCTAssertEqual(SnoozeOption.menu(options, now: date(10), calendar: calendar).map(\.option),
                       [.duration(minutes: 60), .time(.today, hour: 18), .duration(minutes: 600), .time(.tomorrow, hour: 9)])
        XCTAssertEqual(SnoozeOption.menu(options, now: date(19), calendar: calendar).map(\.option),
                       [.duration(minutes: 60), .duration(minutes: 600), .time(.tomorrow, hour: 9)], "600 minutes from 19:00 end at 05:00")
    }

    func testSnoozeOptionsAreCleaned() {
        XCTAssertEqual(SnoozeOption.cleaned([]), SnoozeOption.defaults)
        XCTAssertEqual(SnoozeOption.cleaned([.duration(minutes: 0), .time(.today, hour: 25)]), SnoozeOption.defaults)
        XCTAssertEqual(SnoozeOption.cleaned([.duration(minutes: 30), .duration(minutes: 30)]), [.duration(minutes: 30)])
        let many = (1...20).map { SnoozeOption.duration(minutes: $0) }
        XCTAssertEqual(SnoozeOption.cleaned(many).count, SnoozeOption.maxCount)
    }

    // MARK: Auto-settle and pull requests

    private let now = Date(timeIntervalSince1970: 10_000_000)

    private func row(ageDays: Double) -> InboxRow {
        InboxRow(id: "a", title: "t", project: "p", attention: .idle, lastActivity: now.addingTimeInterval(-ageDays * 86_400))
    }

    func testClosedAndOpenPullRequestRules() {
        var s = AutoSettlePolicy.Settings(enabled: true, inactivityDays: 3, settleOnMergedPullRequest: true)
        XCTAssertEqual(AutoSettlePolicy.decide(row: row(ageDays: 1), pullRequest: .closed, settings: s, now: now), .keep(.recentActivity),
                       "a closed request is its own rule")
        s.settleOnClosedPullRequest = true
        XCTAssertEqual(AutoSettlePolicy.decide(row: row(ageDays: 1), pullRequest: .closed, settings: s, now: now), .settle(.closedPullRequest))
        XCTAssertEqual(AutoSettlePolicy.decide(row: row(ageDays: 1), pullRequest: .merged, settings: s, now: now), .settle(.mergedPullRequest))
        XCTAssertEqual(AutoSettlePolicy.decide(row: row(ageDays: 5), pullRequest: .open, settings: s, now: now), .settle(.inactivity),
                       "an open request does not keep a quiet session by default")
        s.keepWithOpenPullRequest = true
        XCTAssertEqual(AutoSettlePolicy.decide(row: row(ageDays: 5), pullRequest: .open, settings: s, now: now), .keep(.openPullRequest))
        XCTAssertEqual(AutoSettlePolicy.decide(row: row(ageDays: 5), pullRequest: .none, settings: s, now: now), .settle(.inactivity))
    }

    func testOlderSettingsKeepSettlingOnClosedRequests() throws {
        let merged = try JSONDecoder().decode(AutoSettlePolicy.Settings.self,
                                              from: Data(#"{"enabled":true,"settleOnMergedPullRequest":true}"#.utf8))
        XCTAssertTrue(merged.settleOnClosedPullRequest, "closed settled like merged before it was a rule of its own")
        XCTAssertFalse(merged.keepWithOpenPullRequest)
        let off = try JSONDecoder().decode(AutoSettlePolicy.Settings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertFalse(off.settleOnClosedPullRequest)
        XCTAssertTrue(AutoSettlePolicy.newInstallDefaults.enabled, "the default stays on for a new install")
        XCTAssertTrue(AutoSettlePolicy.newInstallDefaults.settleOnClosedPullRequest)
    }

    func testPullRequestStateForTheRules() {
        func link(_ number: Int, _ state: PullRequestState, updated: Date?) -> PullRequestLink {
            PullRequestLink(host: .github, repository: "o/r", number: number, state: state, updatedAt: updated)
        }
        let since = now.addingTimeInterval(-3600)
        XCTAssertEqual(PullRequestSettlement.autoSettleState(links: [], since: since), .none)
        XCTAssertEqual(PullRequestSettlement.autoSettleState(links: [link(1, .open, updated: nil)], since: since), .open)
        XCTAssertEqual(PullRequestSettlement.autoSettleState(links: [link(1, .closed, updated: now)], since: since), .closed)
        XCTAssertEqual(PullRequestSettlement.autoSettleState(links: [link(1, .merged, updated: now)], since: since), .merged)
        XCTAssertEqual(PullRequestSettlement.autoSettleState(links: [link(1, .merged, updated: since.addingTimeInterval(-60))], since: since),
                       .none, "landed before you wrote again")
        XCTAssertEqual(PullRequestSettlement.autoSettleState(links: [link(1, .closed, updated: now.addingTimeInterval(-60)),
                                                                     link(2, .merged, updated: now)], since: nil), .merged, "the newest decides")
    }

    // MARK: Sweep

    func testSweepTakesTheRowsBetweenOriginAndPointer() {
        let frames: [String: CGRect] = ["a": CGRect(x: 0, y: 0, width: 100, height: 30), "b": CGRect(x: 0, y: 30, width: 100, height: 30),
                                        "c": CGRect(x: 0, y: 60, width: 100, height: 30), "d": CGRect(x: 0, y: 90, width: 100, height: 30)]
        XCTAssertEqual(RowSweepRange.ids(frames: frames, origin: "b", pointerY: 40), ["b"], "still on its own row")
        XCTAssertEqual(RowSweepRange.ids(frames: frames, origin: "b", pointerY: 100), ["b", "c", "d"])
        XCTAssertEqual(RowSweepRange.ids(frames: frames, origin: "c", pointerY: 5), ["a", "b", "c"], "upwards too")
        XCTAssertEqual(RowSweepRange.ids(frames: frames, origin: "x", pointerY: 5), [])
    }

    // MARK: Prompt links with a pull request

    private func parse(_ s: String) -> PromptLink? { URL(string: s).flatMap(PromptLink.parse) }

    func testPullRequestAndRepositoryLinks() {
        let link = parse("nook://prompt?pr=octo/app/123&text=Fix%20the%20check")
        XCTAssertEqual(link?.pullRequest, PromptLink.PullRequest(repository: "octo/app", number: 123))
        XCTAssertEqual(link?.text, "Fix the check")
        XCTAssertEqual(parse("nook://prompt?pr=https%3A%2F%2Fgithub.com%2Focto%2Fapp%2Fpull%2F7%2Ffiles")?.pullRequest?.number, 7,
                       "a pull request may come as its address")
        XCTAssertEqual(parse("nook://prompt?pr=octo/app%237")?.pullRequest?.number, 7)
        XCTAssertEqual(parse("nook://prompt?pr=octo/app/9")?.text, "", "a pull request link may come without words")
        XCTAssertNil(parse("nook://prompt?pr=nonsense"), "without a valid request the words are still needed")
        XCTAssertEqual(parse("nook://prompt?pr=nonsense&text=hi")?.warnings, [.droppedPullRequest])
        XCTAssertNil(PromptLink.validPullRequest("https://gitlab.com/octo/app/pull/1"))
        XCTAssertNil(PromptLink.validPullRequest("octo/../1"))

        XCTAssertEqual(parse("nook://prompt?text=hi&repo=octo/app")?.repository, "octo/app")
        XCTAssertEqual(PromptLink.validRepository("https://github.com/octo/app.git"), "octo/app")
        XCTAssertEqual(PromptLink.validRepository("github.com/octo/app/tree/main"), "octo/app")
        XCTAssertNil(PromptLink.validRepository("octo"))
        XCTAssertNil(PromptLink.validRepository("octo/a b"))
        XCTAssertEqual(parse("nook://prompt?text=hi&repo=..%2Fx")?.warnings, [.droppedRepository])
    }

    func testBuiltPullRequestLinksParseBack() throws {
        let pull = PromptLink.PullRequest(repository: "octo/app", number: 12)
        let url = try XCTUnwrap(PromptLink.build(text: "", repository: "octo/app", pullRequest: pull))
        let link = try XCTUnwrap(PromptLink.parse(url: url))
        XCTAssertEqual(link.pullRequest, pull)
        XCTAssertEqual(link.repository, "octo/app")
        XCTAssertNil(PromptLink.build(text: ""), "words are needed without a pull request")
    }

    func testPullRequestLinkOpensTheNewestLinkedSession() {
        let a = UUID(), b = UUID(), c = UUID()
        let request = PullRequestLink(host: .github, repository: "Octo/App", number: 5)
        let links: [UUID: [PullRequestLink]] = [a: [request], b: [request],
                                                c: [PullRequestLink(host: .github, repository: "octo/app", number: 6)]]
        XCTAssertEqual(PromptLinkSessions.linked("octo/app", 5, links: links, order: [c, b, a]), b)
        XCTAssertNil(PromptLinkSessions.linked("octo/app", 7, links: links, order: [a, b, c]))
    }

    // MARK: Model picker keys

    func testModelPickerKeys() {
        XCTAssertEqual(ModelPickerKeys.number(of: ModelPickerKeys.command(3)), 3)
        XCTAssertNil(ModelPickerKeys.number(of: "session.jump3"))
        XCTAssertEqual(ModelPickerKeys.row(2, enabled: [true, true, false]), 1)
        XCTAssertNil(ModelPickerKeys.row(3, enabled: [true, true, false]), "a disabled model keeps its number")
        XCTAssertNil(ModelPickerKeys.row(4, enabled: [true]))
        XCTAssertEqual(ModelPickerKeys.step(from: "b", by: 1, in: ["a", "b", "c"]), "c")
        XCTAssertEqual(ModelPickerKeys.step(from: "a", by: -1, in: ["a", "b", "c"]), "c", "wraps around")
        XCTAssertNil(ModelPickerKeys.step(from: "a", by: 1, in: ["a"]))
    }

    func testModelPickerKeysAndSessionJumpsDoNotMeet() {
        let rules = Keybindings.defaults
        let one = KeyChord.parse("mod+1")!
        XCTAssertEqual(Keybindings.match(one, context: [:], rules: rules), SessionJump.command(1))
        XCTAssertEqual(Keybindings.match(one, context: ["modelPickerOpen": true], rules: rules), ModelPickerKeys.command(1))
        XCTAssertEqual(Keybindings.match(KeyChord.parse("mod+shift+down")!, context: ["modelPickerOpen": true], rules: rules),
                       ModelPickerKeys.nextPlace)
        XCTAssertEqual(Keybindings.match(KeyChord.parse("mod+shift+v")!, context: ["composerFocus": true], rules: rules),
                       "composer.pasteAsText")
    }

    // MARK: Dictation context

    func testDictationContext() {
        let words = DictationContext.strings(dictionary: ["Nook", "nook", " "], projects: ["nook-companion"],
                                             branches: ["nook/fix-login", "main"])
        XCTAssertEqual(words, ["Nook", "nook-companion", "nook companion", "fix-login", "fix login", "main"])
        let many = DictationContext.strings(dictionary: (0..<200).map { "w\($0)" })
        XCTAssertEqual(many.count, DictationContext.limit)
    }
}
