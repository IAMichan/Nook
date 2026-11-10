import XCTest

/// The models an agent offers itself.
final class AgentModelsTests: XCTestCase {
    func testCodexModelListPage() {
        let response: [String: Any] = [
            "data": [
                ["id": "a", "model": "gpt-5.1-codex", "displayName": "gpt-5.1-codex", "hidden": false, "isDefault": true],
                ["id": "b", "model": "gpt-secret", "displayName": "gpt-secret", "hidden": true, "isDefault": false],
                ["id": "c", "model": "gpt-5.1-codex-max", "displayName": "", "hidden": false, "isDefault": false]
            ],
            "nextCursor": "p2"
        ]
        let page = AgentModelCatalog.codexPage(response)
        XCTAssertEqual(page.models.map(\.id), ["gpt-5.1-codex", "gpt-5.1-codex-max"], "hidden models stay out, Codex's order stays")
        XCTAssertEqual(page.models.map(\.name), ["GPT-5.1-Codex", "GPT-5.1-Codex-Max"])
        XCTAssertTrue(page.models[0].isDefault)
        XCTAssertEqual(page.next, "p2")
        XCTAssertNil(AgentModelCatalog.codexPage(["data": [], "nextCursor": NSNull()]).next)
    }

    func testAcpModelsFromConfigOptionGroups() {
        let result: [String: Any] = [
            "sessionId": "s",
            "configOptions": [
                ["id": "mode", "category": "mode", "type": "select", "currentValue": "default", "options": [["value": "default", "name": "Default"]]],
                ["id": "model", "category": "model", "type": "select", "currentValue": "pro",
                 "options": [["groupId": "g", "name": "Gemini", "options": [["value": "pro", "name": "Gemini Pro"], ["value": "flash", "name": "Flash"]]]]]
            ],
            "models": ["currentModelId": "x", "availableModels": [["modelId": "x", "name": "X"]]]
        ]
        let models = AgentModelCatalog.acp(result)
        XCTAssertEqual(models.map(\.id), ["pro", "flash"], "the config option wins over the legacy list")
        XCTAssertEqual(models.first { $0.isDefault }?.name, "Gemini Pro")
        XCTAssertEqual(AgentModelCatalog.acpModelOptionID(result), "model")
    }

    func testAcpLegacyModelsAndGrokInitialize() {
        let legacy: [String: Any] = ["models": ["currentModelId": "sonnet", "availableModels": [["modelId": "sonnet", "name": "Sonnet"], ["modelId": "opus"]]]]
        XCTAssertEqual(AgentModelCatalog.acp(legacy), [AgentModel(id: "sonnet", name: "Sonnet", isDefault: true), AgentModel(id: "opus", name: "opus")])
        XCTAssertNil(AgentModelCatalog.acpModelOptionID(legacy))
        let grok: [String: Any] = ["protocolVersion": 1, "_meta": ["modelState": ["currentModelId": "grok-4", "availableModels": [["modelId": "grok-4", "name": "Grok 4"]]]]]
        XCTAssertEqual(AgentModelCatalog.acp(grok).map(\.name), ["Grok 4"])
        XCTAssertEqual(AgentModelCatalog.acp([:]), [])
    }

    /// Claude Code's `initialize` reply: full ids (an alias reads as the model it stands for), the "default" entry only
    /// marks its model, and a model nothing else knows yet is listed as Claude Code names it.
    func testClaudeInitializeModels() {
        let reply: [String: Any] = [
            "models": [
                ["value": "default", "resolvedModel": "claude-alpha-9", "displayName": "Default (recommended)"],
                ["value": "alpha", "resolvedModel": "claude-alpha-9", "displayName": "Alpha 9"],
                ["value": "claude-beta-2", "resolvedModel": "claude-beta-2", "displayName": "Beta 2"],
                ["value": "beta", "resolvedModel": "claude-beta-2", "displayName": "Beta 2"],
                ["value": "gamma", "displayName": "Claude Gamma"],
                ["value": "-bad", "displayName": "Bad"],
                ["value": "claude-delta-1"]
            ] as [[String: Any]],
            "account": [:] as [String: Any]
        ]
        let models = AgentModelCatalog.claude(reply)
        XCTAssertEqual(models.map(\.id), ["claude-alpha-9", "claude-beta-2", "gamma", "claude-delta-1"], "aliases resolve, each model once")
        XCTAssertEqual(models.map(\.name), ["Claude Alpha 9", "Claude Beta 2", "Claude Gamma", "claude-delta-1"])
        XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["claude-alpha-9"])
        XCTAssertEqual(AgentModelCatalog.claude([:]), [])
    }

    /// A model the agent offers that the manifest does not name yet is in the menu at once.
    func testAnOfferedModelTheManifestDoesNotKnowIsListed() {
        let offered = [AgentModel(id: "claude-alpha-9", name: "Claude Alpha 9"), AgentModel(id: "claude-zeta-1", name: "Claude Zeta 1")]
        let choices = ModelChoice.list(manifest: nil, provider: .claude, offered: offered, installed: nil)
        XCTAssertEqual(choices.map(\.id), ["claude-alpha-9", "claude-zeta-1"])
    }

    /// ACP agents that name their models only in a session: removed again when they can, and never a sign-in page.
    func testAcpModelProbe() {
        let initialize: [String: Any] = ["agentCapabilities": ["sessionCapabilities": ["delete": [:] as [String: Any], "close": [:] as [String: Any], "list": NSNull()]]]
        let capabilities = AcpSessionCapabilities(initialize: initialize)
        XCTAssertTrue(capabilities.delete)
        XCTAssertTrue(capabilities.close)
        XCTAssertFalse(capabilities.list)
        XCTAssertEqual(AcpModelProbe.cleanup(capabilities), "session/delete")
        XCTAssertEqual(AcpModelProbe.cleanup(AcpSessionCapabilities(close: true)), "session/close")
        XCTAssertNil(AcpModelProbe.cleanup(AcpSessionCapabilities()))
        XCTAssertEqual(AcpModelProbe.signIn(.antigravity, savedLogin: false), .skip)
        XCTAssertEqual(AcpModelProbe.signIn(.antigravity, savedLogin: true), .savedLogin)
        for provider in RunProvider.allCases where provider.usesACP && provider != .antigravity {
            XCTAssertEqual(AcpModelProbe.signIn(provider, savedLogin: false), .direct, "\(provider) signs in itself")
        }
        XCTAssertTrue(AcpModelProbe.isProbe("/private/var/folders/x/T/nook-models/", folder: "/var/folders/x/T/nook-models"))
        XCTAssertFalse(AcpModelProbe.isProbe("/Users/me/project", folder: "/var/folders/x/T/nook-models"))
    }

    func testStoreRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)/m.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AgentModelStore(url: url)
        XCTAssertEqual(store.load(), [:])
        store.save([.codex: [AgentModel(id: "gpt-5", name: "GPT-5", isDefault: true)]])
        XCTAssertEqual(store.load()[.codex]?.first?.name, "GPT-5")
    }
}
