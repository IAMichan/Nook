import XCTest

/// "Auto" in the model menus: the model for a turn from what it asks for and the room the usage limits leave.
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

    func testPicksByNeedWhileTheLimitsHaveRoom() {
        let relaxed = [AutoModel.Window(percent: 20, elapsed: 0.5)]
        XCTAssertEqual(AutoModel.pick(all, need: .light, windows: relaxed)?.model, lite.id)
        XCTAssertEqual(AutoModel.pick(all, need: .standard, windows: relaxed)?.model, core.id)
        XCTAssertEqual(AutoModel.pick(all, need: .strong, windows: relaxed)?.model, max.id)
    }

    func testStepsDownAsTheLimitsRunFull() {
        let tight = [AutoModel.Window(percent: 80, elapsed: 0.9)]
        let decision = AutoModel.pick(all, need: .strong, windows: tight)
        XCTAssertEqual(decision?.model, core.id)
        XCTAssertEqual(decision.map(AutoModel.reasonKey), "auto.reason.tight")
        XCTAssertEqual(AutoModel.pick(all, need: .light, windows: tight).map(AutoModel.reasonKey), "auto.reason.light",
                       "a light turn needs no excuse")
        let critical = [AutoModel.Window(percent: 95, elapsed: 0.5)]
        XCTAssertEqual(AutoModel.pick(all, need: .strong, windows: critical)?.model, lite.id)
        XCTAssertEqual(AutoModel.pick(all, need: .strong, windows: critical)?.fullest, 95)
    }

    func testOnlyTheAllowedModels() {
        XCTAssertNil(AutoModel.pick([], need: .strong, windows: []), "nothing allowed: the agent's default")
        XCTAssertEqual(AutoModel.pick([core, lite], need: .strong, windows: [])?.model, core.id, "the closest one")
        XCTAssertEqual(AutoModel.pick([lite, max], need: .standard, windows: [])?.model, max.id,
                       "between two equally far, the stronger one while there is room")
        XCTAssertEqual(AutoModel.pick([lite, max], need: .standard, windows: [.init(percent: 75, elapsed: nil)])?.model, lite.id,
                       "and the lighter one under pressure")
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
    }
}
