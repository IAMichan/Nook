import XCTest

/// "Auto" in the model menu: the agent, account and model for a turn from what it asks for and the room each account's
/// usage limits leave.
final class AutoModelTests: XCTestCase {
    private let lite = AutoModel.Candidate(id: "acme-lite-2", name: "Acme Lite 2")
    private let core = AutoModel.Candidate(id: "acme-core-2", name: "Acme Core 2")
    private let max = AutoModel.Candidate(id: "acme-max-2", name: "Acme Max 2")
    private var all: [AutoModel.Candidate] { [core, max, lite] }

    func testAModelsWeightComesFromItsName() {
        XCTAssertEqual(AutoModel.tier(of: lite), .light)
        XCTAssertEqual(AutoModel.tier(of: core), .standard)
        XCTAssertEqual(AutoModel.tier(of: max), .strong)
        XCTAssertEqual(AutoModel.tier(of: .init(id: "acme-9-mini", name: "acme-9-mini")), .light)
        XCTAssertEqual(AutoModel.tier(of: .init(id: "acme-pro", name: "Acme Pro (High)")), .strong)
        XCTAssertEqual(AutoModel.tier(of: .init(id: "acme-flash-pro", name: "Acme Flash Pro")), .light, "a light word wins")
        XCTAssertEqual(AutoModel.tier(of: .init(id: "acme-provider", name: "Acme Provider")), .standard, "whole words only")
    }

    func testWhatATurnAsksFor() {
        XCTAssertEqual(AutoModel.need(prompt: "fix the typo in the README"), .light)
        XCTAssertEqual(AutoModel.need(prompt: "wat doet deze functie?"), .light)
        XCTAssertEqual(AutoModel.need(prompt: "Add a button to the settings screen that clears the cache"), .standard)
        XCTAssertEqual(AutoModel.need(prompt: "Refactor the sync engine and redesign its architecture"), .strong)
        XCTAssertEqual(AutoModel.need(prompt: String(repeating: "word ", count: 400)), .strong, "a long brief is heavy")
        XCTAssertEqual(AutoModel.need(prompt: "fix the typo", effort: "high"), .standard, "a high effort asks for more")
        XCTAssertEqual(AutoModel.need(prompt: "Refactor and redesign everything", effort: "low"), .standard)
    }

    func testThePressureOfTheWindows() {
        XCTAssertEqual(AutoModel.pressure([]), .relaxed)
        XCTAssertEqual(AutoModel.pressure([.init(percent: 30, elapsed: 0.5)]), .relaxed)
        XCTAssertEqual(AutoModel.pressure([.init(percent: 75, elapsed: nil)]), .tight)
        XCTAssertEqual(AutoModel.pressure([.init(percent: 55, elapsed: 0.2)]), .tight, "well ahead of an even pace")
        XCTAssertEqual(AutoModel.pressure([.init(percent: 55, elapsed: 0.5)]), .relaxed, "on pace")
        XCTAssertEqual(AutoModel.pressure([.init(percent: 10, elapsed: 0.1), .init(percent: 92, elapsed: 0.9)]), .critical)
    }

    /// The candidates of one account with these windows.
    private func on(_ windows: [AutoModel.Window], _ models: [AutoModel.Candidate]? = nil) -> [AutoModel.Candidate] {
        (models ?? all).map { var model = $0; model.windows = windows; return model }
    }

    func testPicksByNeedWhileTheLimitsHaveRoom() {
        let relaxed = [AutoModel.Window(percent: 20, elapsed: 0.5)]
        XCTAssertEqual(AutoModel.pick(on(relaxed), need: .light)?.model, lite.id)
        XCTAssertEqual(AutoModel.pick(on(relaxed), need: .standard)?.model, core.id)
        XCTAssertEqual(AutoModel.pick(on(relaxed), need: .strong)?.model, max.id)
    }

    func testStepsDownAsTheLimitsRunFull() {
        let tight = [AutoModel.Window(percent: 80, elapsed: 0.9)]
        let decision = AutoModel.pick(on(tight), need: .strong)
        XCTAssertEqual(decision?.model, core.id)
        XCTAssertEqual(decision.map(AutoModel.reasonKey), "auto.reason.tight")
        XCTAssertEqual(AutoModel.pick(on(tight), need: .light).map(AutoModel.reasonKey), "auto.reason.light",
                       "a light turn needs no excuse")
        let critical = [AutoModel.Window(percent: 95, elapsed: 0.5)]
        XCTAssertEqual(AutoModel.pick(on(critical), need: .strong)?.model, lite.id)
        XCTAssertEqual(AutoModel.pick(on(critical), need: .strong)?.fullest, 95)
    }

    func testOnlyTheAllowedModels() {
        XCTAssertNil(AutoModel.pick([], need: .strong), "nothing allowed: the agent's default")
        XCTAssertEqual(AutoModel.pick([core, lite], need: .strong)?.model, core.id, "the closest one")
        XCTAssertEqual(AutoModel.pick([lite, max], need: .standard)?.model, max.id,
                       "between two equally far, the stronger one while there is room")
        XCTAssertEqual(AutoModel.pick(on([.init(percent: 75, elapsed: nil)], [lite, max]), need: .standard)?.model, lite.id,
                       "and the lighter one under pressure")
    }

    // MARK: Over every agent

    private func agent(_ provider: RunProvider, _ profileID: String, _ windows: [AutoModel.Window],
                       _ models: [AutoModel.Candidate]) -> [AutoModel.Candidate] {
        models.map { var model = $0; model.provider = provider; model.profileID = profileID; model.windows = windows; return model }
    }

    func testMovesToAnotherAgentWhenTheAccountInUseRunsOut() {
        let claude = AutoModel.Account(provider: .claude, profileID: "claude")
        let full = agent(.claude, "claude", [.init(percent: 95, elapsed: 0.5)], [max, lite])
        let roomy = agent(.codex, "codex", [.init(percent: 10, elapsed: 0.5)], [core, max])
        let decision = AutoModel.pick(full + roomy, need: .strong, current: claude)
        XCTAssertEqual(decision?.provider, .codex)
        XCTAssertEqual(decision?.model, max.id)
        XCTAssertEqual(decision?.pressure, .relaxed)
    }

    func testStaysWithTheAgentInUseUnlessAnotherIsClearlyBetter() {
        let claude = AutoModel.Account(provider: .claude, profileID: "claude")
        let room = [AutoModel.Window(percent: 20, elapsed: 0.5)]
        let inUse = agent(.claude, "claude", room, [core])
        let other = agent(.codex, "codex", room, [max])
        XCTAssertEqual(AutoModel.pick(inUse + other, need: .strong, current: claude)?.provider, .claude,
                       "one step lighter is not worth handing the conversation over")
        XCTAssertEqual(AutoModel.pick(agent(.claude, "claude", room, [lite]) + other, need: .strong, current: claude)?.provider,
                       .codex, "two steps is")
        XCTAssertEqual(AutoModel.pick(inUse + other, need: .strong)?.provider, .codex, "a new session takes the best fit")
    }

    func testAnotherAccountOfTheSameAgentCounts() {
        let work = AutoModel.Account(provider: .claude, profileID: "work")
        let candidates = agent(.claude, "work", [.init(percent: 92, elapsed: nil)], [max])
            + agent(.claude, "home", [.init(percent: 5, elapsed: nil)], [max])
        XCTAssertEqual(AutoModel.pick(candidates, need: .strong, current: work)?.profileID, "home")
    }

    func testAmongEqualsTheAccountWithMoreRoom() {
        let candidates = agent(.claude, "claude", [.init(percent: 75, elapsed: nil)], [lite])
            + agent(.codex, "codex", [.init(percent: 5, elapsed: nil)], [lite])
        XCTAssertEqual(AutoModel.pick(candidates, need: .light)?.provider, .codex)
    }

    func testTheCandidates() {
        let choices = [
            ModelChoice(id: "acme-core-2", name: "Acme Core 2", isDefault: true),
            ModelChoice(id: "acme-core-1", name: "Acme Core 1", isLegacy: true),
            ModelChoice(id: "acme-max-3", name: "Acme Max 3", requiredVersion: "9.0"),
            ModelChoice(id: "acme-lite-2", name: "Acme Lite 2"),
        ]
        let same: (String, String) -> Bool = { $0 == $1 || ($0 == "lite" && $1 == "acme-lite-2") }
        XCTAssertEqual(AutoModel.candidates(choices, allowed: [], same: same).map(\.id), ["acme-core-2", "acme-lite-2"],
                       "every current model, none waiting on an update")
        XCTAssertEqual(AutoModel.candidates(choices, allowed: ["lite", "acme-max-3", "acme-core-1"], same: same).map(\.id),
                       ["acme-core-1", "acme-lite-2"], "your choice, also an older one, under an alias too")
        XCTAssertEqual(AutoModel.candidates(choices, allowed: AutoModel.none, same: same), [], "all unticked: the agent sits out")
        let account = AutoModel.Account(provider: .codex, profileID: "work")
        let placed = AutoModel.candidates(choices, allowed: [], same: same, account: account, windows: [.init(percent: 50, elapsed: nil)])
        XCTAssertEqual(placed.first?.provider, .codex)
        XCTAssertEqual(placed.first?.profileID, "work")
        XCTAssertEqual(placed.first?.windows.first?.percent, 50)
    }
}
