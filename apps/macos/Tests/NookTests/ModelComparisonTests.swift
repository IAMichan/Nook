import XCTest

final class ModelComparisonTests: XCTestCase {
    typealias M = ModelComparison
    private let opus = ComparisonTarget(provider: .claude, profileID: "claude", model: "opus")
    private let sonnet = ComparisonTarget(provider: .claude, profileID: "claude", model: "sonnet")
    private let codex = ComparisonTarget(provider: .codex, profileID: "codex", model: "gpt-5")
    private let gemini = ComparisonTarget(provider: .gemini, profileID: "gemini", model: "")
    private let haiku = ComparisonTarget(provider: .claude, profileID: "claude", model: "haiku")

    func testTogglingKeepsThePrimaryAndTheCap() {
        var extras: [ComparisonTarget] = []
        extras = M.toggling(sonnet, in: extras, primary: opus)
        extras = M.toggling(codex, in: extras, primary: opus)
        XCTAssertEqual(extras, [sonnet, codex])
        XCTAssertEqual(M.toggling(opus, in: extras, primary: opus), extras, "the chosen model always stays")
        extras = M.toggling(gemini, in: extras, primary: opus)
        XCTAssertEqual(extras.count, M.maxModels - 1)
        XCTAssertEqual(M.toggling(haiku, in: extras, primary: opus), extras, "full: nothing is added")
        XCTAssertEqual(M.toggling(sonnet, in: extras, primary: opus), [codex, gemini], "a second click removes it")
    }

    func testTargetsPutThePrimaryFirstWithoutDoubles() {
        XCTAssertEqual(M.targets(primary: opus, extras: [sonnet, opus, sonnet, codex]), [opus, sonnet, codex])
        XCTAssertEqual(M.targets(primary: opus, extras: [sonnet, codex, gemini, haiku]).count, M.maxModels)
    }

    func testConfigsGiveEachModelItsOwnWorktree() {
        var base = NewRunConfig()
        base.task = "Fix the login bug"
        base.provider = .claude
        base.profileID = "claude"
        base.model = "opus"
        base.effort = "high"
        base.isolation = .folder
        base.projectPath = "/repo"
        base.baseBranch = "main"
        let ids = [UUID(), UUID()]
        let configs = M.configs(base: base, targets: [opus, codex], ids: ids, modelName: { $0.model })
        XCTAssertEqual(configs.count, 2)
        XCTAssertTrue(configs.allSatisfy { $0.isolation == .worktree })
        XCTAssertEqual(Set(configs.map(\.branchName)).count, 2, "a branch per model")
        XCTAssertEqual(configs.map(\.title), ["Fix the login bug · opus", "Fix the login bug · gpt-5"])
        XCTAssertEqual(configs[1].provider, .codex)
        XCTAssertEqual(configs[1].profileID, "codex")
        XCTAssertEqual(configs[0].effort, "high")
        XCTAssertNil(configs[1].effort, "effort only carries over within the same agent")
        XCTAssertTrue(configs.allSatisfy { $0.task == base.task && $0.baseBranch == "main" && $0.problem == nil })
    }

    func testLineagePointsAtTheLeader() {
        XCTAssertNil(M.lineage(leader: nil))
        let leader = UUID()
        XCTAssertEqual(M.lineage(leader: leader), RunLineage(kind: .comparison, parentID: leader, atEvent: 0))
    }

    func testAPartlyFailedSendKeepsThePromptAndTheFailedModels() {
        let first = UUID()
        var outcome = M.Outcome()
        outcome.started = [(opus, first)]
        outcome.failed = [(codex, "Codex is not installed"), (gemini, "worktree failed")]
        XCTAssertEqual(outcome.leader, first)
        XCTAssertTrue(outcome.keepsPrompt)
        let retry = M.retrySelection(after: outcome)
        XCTAssertEqual(retry?.primary, codex)
        XCTAssertEqual(retry?.extras, [gemini])

        var clean = M.Outcome()
        clean.started = [(opus, first)]
        XCTAssertFalse(clean.keepsPrompt)
        XCTAssertNil(M.retrySelection(after: clean))
    }

    func testForkedFromAndItsLabel() throws {
        let parent = UUID()
        var run = TestData.run(status: .completed)
        XCTAssertNil(run.forkedFrom)
        run.lineage = RunLineage(kind: .fork, parentID: parent, atEvent: 4)
        XCTAssertEqual(run.forkedFrom, parent)
        XCTAssertEqual(run.lineage?.labelKey, "lineage.forkedFrom")
        XCTAssertEqual(run.lineage?.symbol, "arrow.triangle.branch")
        XCTAssertEqual(RunLineage(kind: .comparison, parentID: parent, atEvent: 0).labelKey, "lineage.samePromptAs")
        // A session stored before lineage existed loads without one.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        object["lineage"] = nil
        XCTAssertNil(try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object)).forkedFrom)
        let stored = try JSONDecoder().decode(WorkspaceRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(stored.forkedFrom, parent)
    }

    func testOldLineageStillDecodes() throws {
        let data = Data(#"{"kind":"fork","parentID":"8D5C2F4E-4A0B-4C68-9D41-2B7E7A1D3F10","atEvent":3}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RunLineage.self, from: data).kind, .fork)
        let comparison = RunLineage(kind: .comparison, parentID: UUID(), atEvent: 0)
        XCTAssertEqual(try JSONDecoder().decode(RunLineage.self, from: JSONEncoder().encode(comparison)), comparison)
    }
}
