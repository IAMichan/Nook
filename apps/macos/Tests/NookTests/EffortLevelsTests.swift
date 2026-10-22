import XCTest

final class EffortLevelsTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(EffortLevels.levels(for: .codex, model: nil), ["low", "medium", "high"])
        XCTAssertEqual(EffortLevels.levels(for: .codex, model: "x", advertised: ["Minimal", "low", "low", "xhigh"]), ["minimal", "low", "xhigh"])
        XCTAssertEqual(EffortLevels.levels(for: .claude, model: nil), ["low", "medium", "high"])
        XCTAssertEqual(EffortLevels.levels(for: .gemini, model: nil), [])
        XCTAssertTrue(EffortLevels.isOffered("HIGH", for: .codex, model: nil))
        XCTAssertFalse(EffortLevels.isOffered("xhigh", for: .codex, model: nil))
        XCTAssertTrue(EffortLevels.isOffered("high", for: .claude, model: nil))
        XCTAssertFalse(EffortLevels.isOffered("max", for: .claude, model: nil))
        XCTAssertEqual(EffortLevels.label(nil), "effort.level.default")
        XCTAssertEqual(EffortLevels.label("high"), "effort.level.high")
    }

    func testStepping() {
        let l = ["low", "medium", "high"]
        XCTAssertEqual(EffortStep.next(current: nil, levels: l, direction: .up), "low")
        XCTAssertEqual(EffortStep.next(current: "low", levels: l, direction: .up), "medium")
        XCTAssertEqual(EffortStep.next(current: "high", levels: l, direction: .up), "high")
        XCTAssertEqual(EffortStep.next(current: "medium", levels: l, direction: .down), "low")
        XCTAssertNil(EffortStep.next(current: "low", levels: l, direction: .down), "down from the first level is the default")
        XCTAssertNil(EffortStep.next(current: nil, levels: l, direction: .down))
        XCTAssertEqual(EffortStep.next(current: "gone", levels: l, direction: .up), "low")
        XCTAssertNil(EffortStep.next(current: "low", levels: [], direction: .up))
    }

    func testResolveSkipsNotFails() {
        XCTAssertEqual(EffortResolution.resolve(stored: "high", offered: ["low", "high"]), EffortResolution(outcome: .use, effort: "high"))
        XCTAssertEqual(EffortResolution.resolve(stored: "xhigh", offered: ["low"]).outcome, .skip)
        XCTAssertEqual(EffortResolution.resolve(stored: nil, offered: ["low"]).outcome, .skip)
    }

    func testCodexParam() {
        XCTAssertEqual(CodexTurnEffort.param(effort: "high") as? [String: String], ["effort": "high"])
        XCTAssertTrue(CodexTurnEffort.param(effort: nil).isEmpty)
        XCTAssertTrue(CodexTurnEffort.param(effort: "").isEmpty)
    }

    // Antigravity lists one model per thinking level; the menu shows each family once.
    private let antigravity = [
        AgentModel(id: "gemini-3-pro-high", name: "Gemini 3 Pro (High)", isDefault: true),
        AgentModel(id: "gemini-3-pro-low", name: "Gemini 3 Pro (Low)"),
        AgentModel(id: "gemini-3-flash", name: "Gemini 3 Flash"),
        AgentModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5"),
        AgentModel(id: "claude-sonnet-4-5-thinking", name: "Claude Sonnet 4.5 (Thinking)"),
        AgentModel(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B (Medium)"),
    ]

    func testModelFamilies() {
        let families = ModelVariants.families(antigravity)
        XCTAssertEqual(families.map(\.name), ["Gemini 3 Pro", "Claude Sonnet 4.5"])
        XCTAssertEqual(families[0].members.map(\.level), ["low", "high"])
        XCTAssertEqual(families[1].members, [ModelVariants.Member(level: "", id: "claude-sonnet-4-5"),
                                             ModelVariants.Member(level: "thinking", id: "claude-sonnet-4-5-thinking")])
        XCTAssertNil(ModelVariants.family(of: "gpt-oss-120b-medium", in: antigravity), "a single level is not a family")
        XCTAssertNil(ModelVariants.family(of: "", in: antigravity))
        XCTAssertEqual(ModelVariants.split(AgentModel(id: "gemini-4-pro-low", name: "gemini-4-pro-low")).name, "gemini-4-pro")
    }

    func testCollapseAndPick() {
        let ids = [""] + antigravity.map(\.id)
        XCTAssertEqual(ModelVariants.collapse(ids, in: antigravity),
                       ["", "gemini-3-pro-high", "gemini-3-flash", "claude-sonnet-4-5", "gpt-oss-120b-medium"])
        XCTAssertEqual(ModelVariants.pick("gemini-3-pro-high", keeping: "gemini-3-pro-low", in: antigravity), "gemini-3-pro-low",
                       "picking the family you are in keeps its level")
        XCTAssertEqual(ModelVariants.pick("gemini-3-pro-high", keeping: "claude-sonnet-4-5-thinking", in: antigravity), "gemini-3-pro-high",
                       "a level the family lacks falls back to the default")
        XCTAssertEqual(ModelVariants.pick("gemini-3-flash", keeping: "gemini-3-pro-low", in: antigravity), "gemini-3-flash")
        XCTAssertEqual(EffortLevels.label(variant: ""), "effort.level.default")
        XCTAssertEqual(EffortLevels.label(variant: "thinking"), "effort.level.thinking")
    }
}
