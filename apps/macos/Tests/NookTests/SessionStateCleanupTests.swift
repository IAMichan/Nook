import XCTest

/// WorkspaceManager keeps per-session state in properties keyed by the session's id. A deleted session must leave none of
/// it behind (a process, a timer, a token), so every such property is forgotten in one place: `forgetSessionState`. The
/// source is read as text, like `AgentParityTests`, so this also runs through `scripts/core-tests.sh`.
final class SessionStateCleanupTests: XCTestCase {
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    /// Per-session properties that are not forgotten in `forgetSessionState`, each with why.
    private static let keptOnPurpose: [String: String] = [
        // The list of sessions itself: `delete` removes the session from it.
        "runs": "the sessions themselves",
        // `delete` refuses a session whose agent process still runs, so there is none to forget.
        "processes": "delete refuses a session with a running process",
    ]

    func testEveryPerSessionPropertyIsForgottenInOnePlace() throws {
        let url = Self.root.appendingPathComponent("Services/Workspace/WorkspaceManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // Stored properties of the class: four spaces in, keyed by a session id.
        let pattern = #"(?m)^    (?:@Published\s+)?(?:private\(set\)\s+|private\s+|fileprivate\s+)?var\s+(\w+):\s*(?:\[UUID\s*:|Set<UUID>)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let names = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertGreaterThan(names.count, 40, "the pattern no longer finds WorkspaceManager's properties")

        let start = try XCTUnwrap(source.range(of: "func forgetSessionState(_ id: UUID) {"))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])

        for name in names where Self.keptOnPurpose[name] == nil {
            let named = body.range(of: #"\b"# + name + #"\b"#, options: .regularExpression) != nil
            let helper = Self.helpers.contains { helper in helper.value.contains(name) && body.contains(helper.key) }
            XCTAssertTrue(named || helper, "\(name) is per-session state: forget it in WorkspaceManager.forgetSessionState")
        }
    }

    /// Helpers `forgetSessionState` calls, and what each one forgets.
    private static let helpers: [String: Set<String>] = [
        "forgetConnectorSignIns(id)": ["connectorSignIns", "connectorSignInChecks"],
        "closeCodexServer(id)": ["codexServers", "codexIdleClose"],
        "closeClaudeProcess(id)": ["claudeIdle", "claudeIdleClose"],
        "dropNextPrompt(id)": ["nextPrompts", "nextPromptTasks"],
        "closeAcpClient(id)": ["acpClients", "acpIdleClose", "acpWakeBuffer", "acpReplays", "acpWakeFinish"],
    ]
}
