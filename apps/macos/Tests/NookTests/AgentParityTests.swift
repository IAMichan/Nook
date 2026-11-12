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

    /// A check for one agent by name: a feature that reaches only that agent. Build it on `ProviderCapabilities` or an
    /// exhaustive `switch` instead, so the compiler asks for every agent. Three forms count, for every `RunProvider` and
    /// `AgentKind` case (Pi and the ACP agents too) and the brain's Claude Code (`AIProvider.claudeCode`):
    /// - a comparison, `provider == .claude`, `kind != .codex`;
    /// - a list that holds one, `[.claude, .claudeCode].contains(…)`;
    /// - an agent's id or name as text, `name == "Antigravity"`, `agentID.hasPrefix("claude")`.
    /// A line that starts with `case` is a switch (or a pattern in one) and does not count.
    private static let agentCase = "claude|claudeCode|codex|gemini|antigravity|opencode|cursor|grok|pi|acp"
    private static let singleAgentChecks = [
        #"[=!]=\s*\.("# + agentCase + #")\b"#,
        #"\[[^\[\]]*\.("# + agentCase + #")\b[^\[\]]*\]\s*\.contains\("#,
        #"(?i)(==|!=|hasPrefix\(|hasSuffix\()\s*"(claude|claude-code|claude code|codex|gemini|gemini cli|antigravity|agy|opencode|cursor|cursor-agent|grok|pi)""#,
    ]

    /// How many such checks each file has today, and why they may stay. The number may only go down: lower it here when
    /// you remove one. Raise it only for something the other agents' apps do not offer, and write that agent's gap in
    /// `docs/INTEGRATIONS.md`.
    private static let allowedSingleAgentChecks: [String: (count: Int, reason: String)] = [
        "App/AppModel+Accounts.swift": (5, "ACP agents are listed per account; Antigravity signs in through its app; Claude Code's API-key login"),
        "App/AppModel+AgentSessionTools.swift": (4, "`.acp` is the placeholder for agents you add, not one agent to offer by name"),
        "App/AppModel+Agents.swift": (6, "Antigravity's conversations are read through its own app (AntigravityClient); Nook as Claude Code's brain"),
        "App/AppModel+Workspace.swift": (4, "Antigravity's installer; Claude Code's API-key accounts"),
        "App/AppModel.swift": (1, "Claude's API has its own web search (AIProvider, not a coding agent)"),
        "App/Settings/SettingsBlocks.swift": (4, "`.acp` is the placeholder for agents you add"),
        "App/SettingsAccounts.swift": (9, "per-agent sign-in help (API key for Claude Code, Antigravity's app, Gemini's Google login); `.acp` placeholder"),
        "Brain/BrainService.swift": (1, "the brain's Claude Code subscription runs Claude Code's own CLI (AIProvider)"),
        "Brain/SubscriptionBrain.swift": (1, "Claude Code's executable is found by ClaudeCodeBrain (AIProvider)"),
        "Core/AppSettings.swift": (3, "Claude's model is stored as `model` from before providers had their own (AIProvider)"),
        "NotchUI/Components/BrandLogo.swift": (1, "which brand marks are monochrome (a palette, not a feature)"),
        "NotchUI/Pills/NewSessionComposer.swift": (2, "Antigravity has to be installed first"),
        "NotchUI/Workspace/UsageView.swift": (1, "only Gemini CLI reports usage per profile from disk"),
        "Services/AgentHistory.swift": (13, "where each agent keeps its files and logins on disk; `.acp` placeholder"),
        "Services/AgentHub.swift": (1, "Claude Code's hook id says which Claude runs it (desktop or CLI)"),
        "Services/AgentProfiles.swift": (3, "only Claude Code takes an API key per account"),
        "Services/ClaudeUsage.swift": (1, "Claude's plan usage endpoint"),
        "Services/CodexRateLimits.swift": (1, "Codex's own rate-limit payload"),
        "Services/Companion/CompanionServer+Remote.swift": (1, "`.acp` placeholder"),
        "Services/QuotaService.swift": (1, "Codex's quota endpoint"),
        "Services/Workspace/AgentModelCatalog.swift": (1, "Claude's model catalog names"),
        "Services/Workspace/AgentProcess.swift": (1, "an ACP agent you added runs its own command line"),
        "Services/Workspace/TextGeneration.swift": (1, "text generation engines are Claude Code and Codex only"),
        "Services/Workspace/UsageLimits.swift": (1, "Codex's own rate-limit payload"),
        "Services/Workspace/WorkspaceBridgeProtocol.swift": (1, "parses an agent name the bridge was given"),
        "Services/Workspace/WorkspaceManager+Acp.swift": (9, "Antigravity's ACP quirks, Gemini CLI's headless fallback, an added agent's environment"),
        "Services/Workspace/WorkspaceManager+Models.swift": (3, "an added ACP agent keeps its models per account"),
        "Services/Workspace/WorkspaceManager+Remote.swift": (1, "an added ACP agent's environment"),
        "Services/Workspace/WorkspaceManager+TextGeneration.swift": (1, "text generation engines are Claude Code and Codex only"),
        "Services/Workspace/WorkspaceModels.swift": (1, "Antigravity cannot run on another machine"),
    ]

    /// "path:line: text" of every single-agent check, per file relative to `apps/macos`.
    private static let foundSingleAgentChecks: [String: [String]] = {
        let regexes = singleAgentChecks.map { try! NSRegularExpression(pattern: $0) }
        var result: [String: [String]] = [:]
        for folder in ["App", "NotchUI", "Services", "Brain", "Core"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let path = folder + "/" + String(url.path.dropFirst(base.path.count + 1))
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("case ") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                        result[path, default: []].append("\(path):\(index + 1): \(trimmed)")
                    }
                }
            }
        }
        return result
    }()

    func testTheSourcesWereFound() {
        XCTAssertNotNil(Self.foundSingleAgentChecks["Services/AgentHistory.swift"], "sources not read from \(Self.root.path)")
        XCTAssertFalse(Self.parityDoc.isEmpty, "docs/INTEGRATIONS.md not found next to \(Self.root.path)")
    }

    /// A new feature for one agent fails here: give it to every agent, or record why another agent cannot have it.
    func testNoNewSingleAgentChecks() {
        var added: [String] = []
        var removed: [String] = []
        for path in Set(Self.foundSingleAgentChecks.keys).union(Self.allowedSingleAgentChecks.keys).sorted() {
            let lines = Self.foundSingleAgentChecks[path] ?? []
            let allowed = Self.allowedSingleAgentChecks[path]?.count ?? 0
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

    /// The patterns find what they are meant to, and leave a switch alone.
    func testThePatternsCatchEveryForm() {
        let regexes = Self.singleAgentChecks.map { try! NSRegularExpression(pattern: $0) }
        func caught(_ line: String) -> Bool {
            regexes.contains { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        }
        XCTAssertTrue(caught("if run.provider == .pi {"))
        XCTAssertTrue(caught("guard kind != .acp else"))
        XCTAssertTrue(caught("if [.claude, .claudeCode].contains(settings.provider) {"))
        XCTAssertTrue(caught("if [.ask, .cursor].contains(x) {"))
        XCTAssertTrue(caught(#"if name == "Antigravity" {"#))
        XCTAssertTrue(caught(#"let always = agentID.hasPrefix("claude")"#))
        XCTAssertFalse(caught("if run.provider.capabilities.processChannel == .piRPC {"))
        XCTAssertFalse(caught("if [.ask, .bypass].contains(policy) {"))
        XCTAssertFalse(caught(#"if kind == "PreToolUse" {"#))
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
