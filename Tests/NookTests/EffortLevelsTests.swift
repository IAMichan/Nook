import XCTest

final class EffortLevelsTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(EffortLevels.levels(for: .codex, model: nil), ["low", "medium", "high"])
        XCTAssertEqual(EffortLevels.levels(for: .codex, model: "x", advertised: ["Minimal", "low", "low", "xhigh"]), ["minimal", "low", "xhigh"])
        XCTAssertEqual(EffortLevels.levels(for: .claude, model: nil), [])
        XCTAssertEqual(EffortLevels.levels(for: .gemini, model: nil), [])
        XCTAssertTrue(EffortLevels.isOffered("HIGH", for: .codex, model: nil))
        XCTAssertFalse(EffortLevels.isOffered("xhigh", for: .codex, model: nil))
        XCTAssertFalse(EffortLevels.isOffered("high", for: .claude, model: nil))
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
}
