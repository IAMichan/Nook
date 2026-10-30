import XCTest

/// One agent's model and effort controls (`AgentModelMenu`), the same for every surface and every agent.
final class AgentModelMenuTests: XCTestCase {
    private let antigravity: [AgentModel] = [
        AgentModel(id: "gemini-3-pro-high", name: "Gemini 3 Pro (High)", isDefault: true),
        AgentModel(id: "gemini-3-pro-low", name: "Gemini 3 Pro (Low)"),
        AgentModel(id: "claude-sonnet", name: "Claude Sonnet")
    ]

    func testTheMenuStartsWithTheDefaultAndFavorites() {
        let menu = AgentModelMenu(provider: .opencode, offered: [AgentModel(id: "a", name: "A"), AgentModel(id: "b", name: "B")],
                                  custom: ["typed"], favorites: ["b"])
        XCTAssertEqual(menu.ids(extra: ["recent", "a"]), ["", "b", "a", "typed", "recent"])
        XCTAssertEqual(menu.name("a"), "A")
        XCTAssertEqual(menu.name("unknown"), "unknown")
        XCTAssertNil(menu.name(""), "the agent's default has no name of its own")
    }

    func testLevelsAreFamiliesOnlyForAgentsOverAcp() {
        let acp = AgentModelMenu(provider: .antigravity, offered: antigravity)
        XCTAssertEqual(acp.family(of: "gemini-3-pro-low")?.name, "Gemini 3 Pro")
        XCTAssertEqual(acp.collapsed(["gemini-3-pro-high", "gemini-3-pro-low", "claude-sonnet"]), ["gemini-3-pro-high", "claude-sonnet"])
        XCTAssertEqual(acp.pick("gemini-3-pro-high", keeping: "gemini-3-pro-low"), "gemini-3-pro-low")
        let codex = AgentModelMenu(provider: .codex, offered: antigravity)
        XCTAssertNil(codex.family(of: "gemini-3-pro-low"), "Codex takes its level as a setting: its names are not levels")
    }

    func testEffortLevelsComeFromTheAgentOrItsSession() {
        XCTAssertEqual(AgentModelMenu(provider: .claude).effortLevels(model: nil), ["low", "medium", "high"])
        XCTAssertEqual(AgentModelMenu(provider: .gemini).effortLevels(model: nil), [], "nothing offered, no control")
        let offered = AgentModelMenu(provider: .acp, offeredEfforts: [AgentModel(id: "low", name: "Low"), AgentModel(id: "max", name: "Maximum")])
        XCTAssertEqual(offered.effortLevels(model: nil), ["low", "max"])
        XCTAssertEqual(AgentModelMenu.effortKey("low"), "effort.level.low")
        XCTAssertEqual(AgentModelMenu.effortKey(nil), "effort.level.default")
        XCTAssertNil(AgentModelMenu.effortKey("max"))
        XCTAssertEqual(offered.effortName("max"), "Maximum", "a level Nook has no word for reads as the agent names it")
    }

    func testAliasesNeverWaitOnAnUpdate() throws {
        let json = #"{"version":1,"updatedAt":"2026-10-01T00:00:00Z","agents":{"claude":{"defaultModel":"claude-opus-9","models":[{"id":"claude-opus-9","name":"Claude Opus 9","status":"current","aliases":["opus"],"adapter":{"claude":{"minVersion":"9.0.0"}}}]}}}"#
        let manifest = try ModelManifest.parse(Data(json.utf8))
        let menu = AgentModelMenu(provider: .claude, manifest: manifest, installed: "1.0.0")
        XCTAssertEqual(menu.choice("claude-opus-9")?.requiredVersion, "9.0.0")
        XCTAssertNil(menu.choice("opus")?.requiredVersion, "the agent resolves an alias to the newest model it knows")
        XCTAssertTrue(menu.same("opus", "claude-opus-9"))
        XCTAssertEqual(menu.ids(extra: ["opus"]), ["", "claude-opus-9"], "an alias of a listed model shows once")
    }
}
