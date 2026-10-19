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

    func testStoreRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)/m.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AgentModelStore(url: url)
        XCTAssertEqual(store.load(), [:])
        store.save([.codex: [AgentModel(id: "gpt-5", name: "GPT-5", isDefault: true)]])
        XCTAssertEqual(store.load()[.codex]?.first?.name, "GPT-5")
    }
}
