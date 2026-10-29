import XCTest

/// A change to one coding agent is a change to all of them (`docs/INTEGRATIONS.md`): what Claude Code gets, Codex,
/// Gemini CLI, Antigravity, OpenCode, Cursor, Grok and the ACP agents get too. The sources are read as text (like
/// `UIConsistencyTests`), so the test needs nothing of the app and also runs through `scripts/core-tests.sh`.
final class AgentParityTests: XCTestCase {
    /// `apps/macos`: from the environment when the tests run as a throwaway package, else relative to this file.
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    private static var parityDoc: String {
        let url = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/INTEGRATIONS.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A check for one agent by name (`provider == .claude`, `kind != .codex`): a feature that reaches only that agent.
    /// Build it on `ProviderCapabilities` or an exhaustive `switch` instead, so the compiler asks for every agent.
    private static let singleAgentCheck = #"[=!]=\s*\.(claude|codex|gemini|antigravity|opencode|cursor|grok)\b"#

    /// How many such checks each file has today. The number may only go down: lower it here when you remove one. Raise
    /// it only for something the other agents' apps do not offer, and write that agent's gap in `docs/INTEGRATIONS.md`.
    private static let allowedSingleAgentChecks: [String: Int] = [
        "App/AppModel+Accounts.swift": 3,
        "App/AppModel+Agents.swift": 6,
        "App/AppModel+Workspace.swift": 4,
        "App/AppModel.swift": 1,
        "App/Settings/SettingsView+Brain.swift": 5,
        "App/SettingsAccounts.swift": 7,
        "Brain/AIProvider.swift": 3,
        "Brain/BrainService.swift": 2,
        "Core/AppSettings.swift": 6,
        "NotchUI/Pills/AgentsTab.swift": 1,
        "NotchUI/Pills/AgentsUsagePanel.swift": 2,
        "NotchUI/Pills/NewSessionComposer.swift": 2,
        "NotchUI/Workspace/UsageView.swift": 1,
        "Services/AgentHistory.swift": 11,
        "Services/AgentProfiles.swift": 3,
        "Services/ClaudeUsage.swift": 1,
        "Services/QuotaService.swift": 1,
        "Services/Workspace/TextGeneration.swift": 1,
        "Services/Workspace/WorkspaceManager+Acp.swift": 8,
        "Services/Workspace/WorkspaceManager+ClaudeSession.swift": 1,
        "Services/Workspace/WorkspaceManager+CodexServer.swift": 2,
        "Services/Workspace/WorkspaceManager+Models.swift": 2,
        "Services/Workspace/WorkspaceManager+Rollback.swift": 1,
        "Services/Workspace/WorkspaceManager+TextGeneration.swift": 1,
        "Services/Workspace/WorkspaceManager.swift": 10,
        "Services/Workspace/WorkspaceModels.swift": 1,
    ]

    /// "path:line: text" of every single-agent check, per file relative to `apps/macos`.
    private static let singleAgentChecks: [String: [String]] = {
        let regex = try! NSRegularExpression(pattern: singleAgentCheck)
        var result: [String: [String]] = [:]
        for folder in ["App", "NotchUI", "Services", "Brain", "Core"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let path = folder + "/" + String(url.path.dropFirst(base.path.count + 1))
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        result[path, default: []].append("\(path):\(index + 1): \(trimmed)")
                    }
                }
            }
        }
        return result
    }()

    func testTheSourcesWereFound() {
        XCTAssertNotNil(Self.singleAgentChecks["Services/Workspace/WorkspaceManager.swift"], "sources not read from \(Self.root.path)")
        XCTAssertFalse(Self.parityDoc.isEmpty, "docs/INTEGRATIONS.md not found next to \(Self.root.path)")
    }

    /// A new feature for one agent fails here: give it to every agent, or record why another agent cannot have it.
    func testNoNewSingleAgentChecks() {
        var added: [String] = []
        var removed: [String] = []
        for path in Set(Self.singleAgentChecks.keys).union(Self.allowedSingleAgentChecks.keys).sorted() {
            let lines = Self.singleAgentChecks[path] ?? []
            let allowed = Self.allowedSingleAgentChecks[path] ?? 0
            if lines.count > allowed { added.append(contentsOf: lines) }
            if lines.count < allowed { removed.append("\(path): \(lines.count) (was \(allowed))") }
        }
        XCTAssertEqual(added, [], """
            a feature for one coding agent must reach every agent (docs/INTEGRATIONS.md): build it on ProviderCapabilities \
            or an exhaustive switch. Only when another agent's app cannot offer it, raise the number in \
            AgentParityTests.allowedSingleAgentChecks and write the gap in docs/INTEGRATIONS.md.
            """)
        XCTAssertEqual(removed, [], "fewer single-agent checks: lower these in AgentParityTests.allowedSingleAgentChecks")
    }

    /// Every agent Nook runs has a column in the feature matrix, so a new agent starts from the full list of features.
    func testEveryAgentIsInTheFeatureMatrix() {
        let doc = Self.parityDoc
        guard let start = doc.range(of: "## Coding agent features") else {
            return XCTFail("docs/INTEGRATIONS.md has no \"## Coding agent features\" section")
        }
        let header = doc[start.upperBound...].split(separator: "\n").first { $0.hasPrefix("| Feature") }.map(String.init) ?? ""
        for provider in RunProvider.allCases {
            let column = provider == .acp ? "ACP agents" : provider.displayName
            XCTAssertTrue(header.contains(column), "\(column) has no column in the coding agent feature matrix")
        }
    }
}
