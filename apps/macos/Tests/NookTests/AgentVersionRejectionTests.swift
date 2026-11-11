import XCTest

final class AgentVersionRejectionTests: XCTestCase {
    private let claude = "API Error: 400 Claude Code 2.1.100 does not support this model; version 2.1.200 or newer is required. Run claude update to upgrade."

    func testClaudeTextGivesBothVersions() {
        XCTAssertEqual(AgentVersionRejection.parse(claude), .init(reported: "2.1.100", required: "2.1.200"))
    }

    func testOtherAgentsWordingIsRecognized() {
        let codex = #"{"detail":"The 'gpt-5.5' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}"#
        XCTAssertEqual(AgentVersionRejection.parse(codex), .init(reported: nil, required: nil))
        XCTAssertNil(AgentVersionRejection.parse("Error: connection reset"))
        XCTAssertNil(AgentVersionRejection.parse(nil))
    }

    func testOutdatedAgentIsOfferedTheUpdate() {
        let rejection = AgentVersionRejection.parse(claude)!
        XCTAssertEqual(AgentVersionRejection.verdict(rejection, installed: "2.1.100", endpointHost: "gateway.example.com"),
                       .update(required: "2.1.200"))
        XCTAssertEqual(AgentVersionRejection.verdict(rejection, installed: "2.1.300", endpointHost: nil), .update(required: "2.1.200"))
        XCTAssertEqual(AgentVersionRejection.verdict(rejection, installed: nil, endpointHost: "gateway.example.com"),
                       .update(required: "2.1.200"))
    }

    func testCurrentAgentBehindACustomEndpointBlamesTheEndpoint() {
        let rejection = AgentVersionRejection.parse(claude)!
        XCTAssertEqual(AgentVersionRejection.verdict(rejection, installed: "2.1.200", endpointHost: "gateway.example.com"),
                       .endpointRewrote(host: "gateway.example.com", reported: "2.1.100", installed: "2.1.200"))
    }

    func testOnlyAnotherHostThanTheAgentsOwnIsACustomEndpoint() {
        XCTAssertEqual(AgentVersionRejection.customHost("https://Gateway.Example.com/v1", official: ["api.anthropic.com"]), "gateway.example.com")
        XCTAssertNil(AgentVersionRejection.customHost("https://api.anthropic.com", official: ["api.anthropic.com"]))
        XCTAssertNil(AgentVersionRejection.customHost("not a url", official: []))
        XCTAssertNil(AgentVersionRejection.customHost("", official: []))
    }

    func testStrongestEnvironmentDecides() {
        let host = AgentVersionRejection.endpointHost(.claude, environments: [
            [:], ["ANTHROPIC_BASE_URL": "https://proxy.local:8080"], ["ANTHROPIC_BASE_URL": "https://other.example"],
        ])
        XCTAssertEqual(host, "proxy.local")
        // The account sets Anthropic's own API: no custom endpoint, whatever Nook's environment says.
        XCTAssertNil(AgentVersionRejection.endpointHost(.claude, environments: [
            ["ANTHROPIC_BASE_URL": "https://api.anthropic.com"], ["ANTHROPIC_BASE_URL": "https://other.example"],
        ]))
        XCTAssertEqual(AgentVersionRejection.endpointHost(.codex, environments: [["OPENAI_BASE_URL": "http://localhost:4000/v1"]]), "localhost")
    }

    func testEveryAgentHasAnEndpointRule() {
        for provider in RunProvider.allCases {
            let (names, official) = AgentVersionRejection.endpointVariables(provider)
            XCTAssertEqual(names.isEmpty, official.isEmpty, "\(provider)")
        }
    }

    func testClaudeSettingsEnvIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("settings.local.json")
        let shared = folder.appendingPathComponent("settings.json")
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://local.example"}}"#.utf8).write(to: local)
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://shared.example","OTHER":"x"}}"#.utf8).write(to: shared)
        let env = AgentVersionRejection.settingsEnvironment([local, shared, folder.appendingPathComponent("missing.json")])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://local.example")
        XCTAssertEqual(env["OTHER"], "x")
    }

    func testFailureClassifierNamesTheRejection() {
        XCTAssertEqual(FailureClassifier.classify(FailureEvidence(isError: true, messageText: claude)),
                       .versionRejected(reported: "2.1.100", required: "2.1.200"))
        XCTAssertTrue(FailureClassifier.isFailure(FailureEvidence(isError: true, messageText: claude)))
    }
}
