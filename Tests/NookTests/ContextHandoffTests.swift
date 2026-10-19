import XCTest

final class ContextHandoffTests: XCTestCase {
    private func events(_ pairs: [(RunEvent.Kind, String)]) -> [RunEvent] {
        pairs.map { RunEvent(kind: $0.0, text: $0.1) }
    }

    // MARK: Summary

    func testSummaryKeepsTheWorkAndSkipsTheNoise() throws {
        let timeline = events([(.user, "Fix the login bug"), (.thinking, "hmm"), (.tool, "Bash · npm test"),
                               (.system, "launch"), (.fileChange, "Login.swift"), (.assistant, "Done, tests pass."),
                               (.result, "1 turn"), (.approval, "Allow?")])
        let rendered = try XCTUnwrap(ContextHandoff.render(events: timeline, source: "Claude Code"))
        XCTAssertEqual(rendered.included, 4)
        XCTAssertEqual(rendered.omitted, 0)
        XCTAssertEqual(rendered.coveredEvents, timeline.count)
        let text = rendered.text
        XCTAssertTrue(text.contains("Claude Code"))
        XCTAssertTrue(text.contains("- User: Fix the login bug"))
        XCTAssertTrue(text.contains("- Ran: Bash · npm test"))
        XCTAssertTrue(text.contains("- Changed: Login.swift"))
        XCTAssertTrue(text.contains("- Agent: Done, tests pass."))
        XCTAssertFalse(text.contains("hmm"))
        XCTAssertFalse(text.contains("Allow?"))
        XCTAssertTrue(text.hasSuffix("before relying on any of this."), "ends with a pointer to check the files")
    }

    func testOrderIsOldestFirstAndFailuresAreMarked() throws {
        var failed = RunEvent(kind: .tool, text: "Bash · make")
        failed.state = .failed
        let timeline = [RunEvent(kind: .user, text: "first"), failed, RunEvent(kind: .error, text: "boom"),
                        RunEvent(kind: .assistant, text: "last")]
        let text = try XCTUnwrap(ContextHandoff.render(events: timeline, source: "Codex")).text
        let positions = ["first", "(failed)", "- Error: boom", "last"].compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, 4)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testLongItemsAreClipped() throws {
        let long = String(repeating: "word ", count: 400)
        let text = try XCTUnwrap(ContextHandoff.render(events: events([(.user, long), (.tool, long)]), source: "X")).text
        for line in text.split(separator: "\n") where line.hasPrefix("- ") {
            XCTAssertLessThanOrEqual(line.count, ContextHandoff.messageLimit + 12, String(line.prefix(30)))
        }
        XCTAssertTrue(text.contains("…"))
    }

    func testNothingToTellGivesNoSummary() {
        XCTAssertNil(ContextHandoff.render(events: [], source: "X"))
        XCTAssertNil(ContextHandoff.render(events: events([(.thinking, "a"), (.system, "b")]), source: "X"))
        XCTAssertNil(ContextHandoff.render(events: events([(.user, "a")]), from: 5, source: "X"), "a start beyond the end")
    }

    // MARK: Budget

    func testBudgetKeepsTheNewestAndSaysWhatIsLeftOut() throws {
        let many = (0..<200).map { RunEvent(kind: .user, text: "message number \($0) " + String(repeating: "x", count: 100)) }
        let rendered = try XCTUnwrap(ContextHandoff.render(events: many, source: "X", budget: 600))
        XCTAssertGreaterThan(rendered.omitted, 0)
        XCTAssertEqual(rendered.included + rendered.omitted, 200)
        XCTAssertTrue(rendered.text.contains("message number 199"), "the newest is kept")
        XCTAssertFalse(rendered.text.contains("message number 0 "), "the oldest goes first")
        XCTAssertTrue(rendered.text.contains("earlier item"))
        XCTAssertLessThanOrEqual(ContextHandoff.approxTokens(rendered.text), 600 + 120)
    }

    func testOneHugeItemStillGoesThrough() throws {
        let rendered = try XCTUnwrap(ContextHandoff.render(events: events([(.user, "short")]), source: "X", budget: 1))
        XCTAssertEqual(rendered.included, 1, "at least the newest item is always handed over")
    }

    // MARK: Delta

    func testDeltaStartsWhereTheAgentLeftOff() throws {
        let timeline = events([(.user, "old question"), (.assistant, "old answer"), (.user, "new question"), (.assistant, "new answer")])
        let rendered = try XCTUnwrap(ContextHandoff.render(events: timeline, from: 2, source: "Codex"))
        XCTAssertEqual(rendered.included, 2)
        XCTAssertFalse(rendered.text.contains("old question"))
        XCTAssertTrue(rendered.text.contains("new answer"))
        XCTAssertEqual(rendered.coveredEvents, 4)
    }

    // MARK: Strategy

    func testSwitchResumesAnAgentThatTookPartBefore() {
        XCTAssertEqual(ContextTransfer.forSwitch(hasNativeSession: true, cursor: 7), .delta(sinceEvent: 7))
        XCTAssertEqual(ContextTransfer.forSwitch(hasNativeSession: false, cursor: 7), .fullSummary, "no conversation to resume")
        XCTAssertEqual(ContextTransfer.forSwitch(hasNativeSession: true, cursor: nil), .fullSummary)
        XCTAssertEqual(ContextTransfer.forSwitch(hasNativeSession: false, cursor: nil), .fullSummary)
    }

    func testForkIsNativeOnlyWhenTheAgentCanAndHasAConversation() {
        XCTAssertEqual(ContextTransfer.forFork(nativeFork: true, hasNativeSession: true), .native)
        XCTAssertEqual(ContextTransfer.forFork(nativeFork: true, hasNativeSession: false), .fullSummary)
        XCTAssertEqual(ContextTransfer.forFork(nativeFork: false, hasNativeSession: true), .fullSummary)
    }

    func testCapabilitiesDescribeWhatNookDoes() {
        XCTAssertTrue(RunProvider.claude.capabilities.nativeFork)
        XCTAssertTrue(RunProvider.claude.capabilities.steering)
        XCTAssertTrue(RunProvider.codex.capabilities.steering)
        XCTAssertFalse(RunProvider.codex.capabilities.nativeFork, "Nook forks Codex from a summary")
        for provider in [RunProvider.gemini, .opencode, .cursor, .grok, .antigravity] {
            XCTAssertFalse(provider.capabilities.nativeFork, provider.rawValue)
        }
    }

    // MARK: Selection transitions

    private func decide(_ provider: RunProvider = .claude, _ profile: String = "a", _ model: String = "opus",
                        to target: RunProvider = .claude, _ targetProfile: String = "a", _ targetModel: String = "opus",
                        sameHome: Bool = false, available: Bool = true) -> SelectionTransition {
        SelectionTransition.decide(currentProvider: provider, currentProfile: profile, currentModel: model,
                                   targetProvider: target, targetProfile: targetProfile, targetModel: targetModel,
                                   sameAccountHome: sameHome, available: available)
    }

    func testNothingChangesWhenNothingIsPicked() {
        XCTAssertEqual(decide(), .reuse)
    }

    func testAnotherModelCountsFromTheNextTurn() {
        XCTAssertEqual(decide(to: .claude, "a", "sonnet"), .applyOnNextTurn)
    }

    func testAnotherAgentStartsItsOwnConversationWithAHandoff() {
        XCTAssertEqual(decide(to: .codex, "codex", "gpt-5"), .createWithHandoff)
        XCTAssertEqual(decide(to: .codex, "a", "opus", sameHome: true), .createWithHandoff, "never the same conversation across agents")
    }

    func testAnotherAccountOfTheSameAgentIsItsOwnConversationUnlessItSharesTheLogin() {
        XCTAssertEqual(decide(to: .claude, "b", "opus"), .createWithHandoff)
        XCTAssertEqual(decide(to: .claude, "b", "opus", sameHome: true), .applyOnNextTurn)
    }

    func testAnUnavailableTargetIsRefused() {
        XCTAssertEqual(decide(to: .codex, "codex", "", available: false), .reject("unavailable"))
    }

    func testInstancesKeepAccountsApart() {
        XCTAssertNotEqual(ProviderInstance.key(.claude, "a"), ProviderInstance.key(.claude, "b"))
        XCTAssertNotEqual(ProviderInstance.key(.claude, "a"), ProviderInstance.key(.codex, "a"))
        XCTAssertEqual(ProviderInstance.key(.claude, "a"), "claude|a")
    }

    // MARK: Prompt

    func testComposeAddsTheSummaryBeforeYourMessage() {
        XCTAssertEqual(ContextHandoff.compose(handoff: nil, message: "hi"), "hi")
        XCTAssertEqual(ContextHandoff.compose(handoff: "", message: "hi"), "hi")
        XCTAssertEqual(ContextHandoff.compose(handoff: "SUMMARY", message: "hi"), "SUMMARY\n\nhi")
    }

    // MARK: Storage

    func testNewFieldsRoundTripAndOldFilesStillLoad() throws {
        var run = TestData.run(status: .completed)
        run.providerSessions = ["claude": "s1"]
        run.handoffCursors = ["claude": 4]
        run.pendingHandoff = "SUMMARY"
        run.lineage = RunLineage(kind: .fork, parentID: UUID(), atEvent: 9)
        let copy = try JSONDecoder().decode(WorkspaceRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(copy.providerSessions, ["claude": "s1"])
        XCTAssertEqual(copy.handoffCursors, ["claude": 4])
        XCTAssertEqual(copy.pendingHandoff, "SUMMARY")
        XCTAssertEqual(copy.lineage, run.lineage)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TestData.run(status: .completed))) as? [String: Any])
        for key in ["providerSessions", "handoffCursors", "pendingHandoff", "lineage"] { object[key] = nil }
        let old = try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.pendingHandoff)
        XCTAssertNil(old.lineage)
    }
}
