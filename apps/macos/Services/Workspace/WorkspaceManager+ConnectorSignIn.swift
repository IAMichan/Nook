import AppKit
import Foundation

/// Signing in to a connector the agent cannot use yet (see ConnectorSignIn): Nook asks the agent for the sign-in page,
/// opens it in your browser, and checks back until the server connects, so the agent can use it on its next turn.
/// Claude Code answers over its control requests (`mcp_authenticate`, `mcp_status`), Codex over its app-server
/// (`mcpServer/oauth/login`, `mcpServerStatus/list`). The ACP agents (Gemini CLI, OpenCode, Cursor, Grok, Antigravity
/// and the ones you add) do not report it, so they show nothing.
extension WorkspaceManager {
    /// How long Nook checks back after opening a sign-in page, and how often.
    private static let signInWaitSeconds: UInt64 = 5 * 60
    private static let signInCheckSeconds: UInt64 = 4

    /// The agent listed the connectors that need you. An empty list clears the session's.
    func noteConnectorsNeedingSignIn(_ id: UUID, _ names: [String]) {
        let merged = ConnectorSignIns.merged(names, into: connectorSignIns[id] ?? [])
        // A waiting one that connected says so in the conversation.
        let connected = (connectorSignIns[id] ?? []).filter { $0.waiting && !names.contains($0.name) }
        for done in connected {
            connectorSignInChecks[id]?.removeValue(forKey: done.name)?.cancel()
            append(id, RunEvent(kind: .system, text: tr("ws.connector.connected", done.title)))
        }
        if merged != (connectorSignIns[id] ?? []) { connectorSignIns[id] = merged.isEmpty ? nil : merged }
        if !connected.isEmpty { shareConnectorSignIns(from: id, connected.map(\.name)) }
    }

    /// You signed in to these connectors in one session. The agent keeps the sign-in for its account, but every other
    /// session of that agent and account still lists them: its agent checked when it started, before you signed in. They
    /// leave those lists, and an agent that is open connects them again, so you sign in once instead of once per chat.
    /// A session whose agent is closed reads the sign-in when it starts again.
    private func shareConnectorSignIns(from id: UUID, _ names: [String]) {
        guard let source = run(id) else { return }
        let account = ConnectorSignIns.account(source)
        for (other, list) in connectorSignIns where other != id {
            guard let run = run(other), ConnectorSignIns.account(run) == account else { continue }
            let signedIn = list.map(\.name).filter(names.contains)
            guard !signedIn.isEmpty else { continue }
            for name in signedIn { connectorSignInChecks[other]?.removeValue(forKey: name)?.cancel() }
            let rest = list.filter { !signedIn.contains($0.name) }
            connectorSignIns[other] = rest.isEmpty ? nil : rest
            reconnectConnectors(other, provider: run.provider, signedIn)
        }
    }

    /// Asks a session's open agent to connect these servers again, now that their sign-in is there.
    private func reconnectConnectors(_ id: UUID, provider: RunProvider, _ names: [String]) {
        switch provider {
        case .claude:
            for name in names {
                _ = claudeControl(id, starts: false, { ClaudeStreamParser.mcpReconnectRequest(id: $0, server: name) }) { _, _ in }
            }
        case .codex:
            guard let client = codexServers[id], client.isRunning else { return }
            Task { _ = try? await Self.codexRequest(client, "config/mcpServer/reload", [:], timeout: 30) }
        case .gemini, .opencode, .cursor, .grok, .antigravity, .pi, .acp: return
        }
    }

    /// Opens the connector's sign-in page and waits for it to connect.
    func signInConnector(_ id: UUID, name: String) {
        guard let run = run(id) else { return }
        switch run.provider {
        case .claude: signInClaudeConnector(id, name: name)
        case .codex: signInCodexConnector(id, name: name)
        case .gemini, .opencode, .cursor, .grok, .antigravity, .pi, .acp: return
        }
    }

    /// You hid these connectors: stop waiting on any sign-in page still open, so the row above the composer can go.
    func hideConnectorSignIns(_ id: UUID, names: [String]) {
        ConnectorSignIns.dismissed.formUnion(names)
        for name in names {
            connectorSignInChecks[id]?.removeValue(forKey: name)?.cancel()
            setWaiting(id, name: name, false)
        }
    }

    /// Stops waiting for the connectors of a session that closed.
    func forgetConnectorSignIns(_ id: UUID) {
        connectorSignInChecks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
        connectorSignIns[id] = nil
    }

    // MARK: Claude Code

    /// The Claude Code process of a session, working or waiting for the next message; a session whose process closed
    /// gets one again (it resumes the conversation, as when you open it) unless `starts` is off.
    private func claudeProcess(_ id: UUID, starts: Bool = true) -> AgentProcess? {
        if let process = processes[id] ?? claudeIdle[id]?.process, process.isRunning { return process }
        guard starts else { return nil }
        prewarm(id)
        return claudeIdle[id]?.process
    }

    /// Sends a control request and hands its answer to `reply` (on the main actor). With `starts` off it goes only to a
    /// process that already runs.
    func claudeControl(_ id: UUID, starts: Bool = true, _ make: (String) -> String,
                       reply: @escaping (JSONBox?, String?) -> Void) -> Bool {
        guard let process = claudeProcess(id, starts: starts) else { return false }
        let requestID = "nook-mcp-" + UUID().uuidString.prefix(8)
        claudeControlReplies[requestID] = reply
        process.send(make(requestID))
        return true
    }

    private func signInClaudeConnector(_ id: UUID, name: String) {
        let sent = claudeControl(id, { ClaudeStreamParser.mcpAuthenticateRequest(id: $0, server: name) }) { [weak self] response, error in
            guard let self else { return }
            let answer = response?.dictionary ?? [:]
            guard error == nil, let link = (answer["authUrl"] as? String).flatMap(URL.init(string:)) else {
                return self.connectorSignInFailed(id, name: name, error ?? tr("ws.connector.noPage"), recheck: error != nil)
            }
            NSWorkspace.shared.open(link)
            // A claude.ai connector is connected on claude.ai: Claude Code learns of it when it connects again.
            let reconnects = (answer["callbackExpected"] as? Bool) != true
            self.waitForConnector(id, name: name) { [weak self] in
                guard let self else { return }
                if reconnects { _ = self.claudeControl(id, { ClaudeStreamParser.mcpReconnectRequest(id: $0, server: name) }) { _, _ in } }
                self.checkClaudeConnectors(id)
            }
        }
        if !sent { connectorSignInFailed(id, name: name, tr("ws.connector.noAgent")) }
    }

    /// Asks Claude Code again which connectors need you and updates the list; `done` gets the names, nil without an answer.
    func checkClaudeConnectors(_ id: UUID, done: @escaping ([String]?) -> Void = { _ in }) {
        let sent = claudeControl(id, ClaudeStreamParser.mcpStatusRequest(id:)) { [weak self] response, _ in
            guard let self, let rows = response?.dictionary["mcpServers"] else { return done(nil) }
            let names = ConnectorSignIns.claude(rows)
            self.noteConnectorsNeedingSignIn(id, names)
            done(names)
        }
        if !sent { done(nil) }
    }

    /// Claude Code's answers to Nook's own requests, from a process that is only waiting (nothing else it prints counts).
    func handleClaudeReplies(_ lines: [String], for id: UUID) {
        for line in lines where line.contains("\"control_response\"") {
            for case .controlReply(let requestID, let response, let error) in ClaudeStreamParser.parse(line) {
                claudeControlReplies.removeValue(forKey: requestID)?(response, error)
            }
        }
    }

    // MARK: Codex

    /// After its thread opened: which of Codex's MCP servers wait for you to sign in.
    /// `done` gets the names, nil without an answer.
    func checkCodexConnectors(_ id: UUID, _ client: CodexAppServerClient, done: @escaping ([String]?) -> Void = { _ in }) {
        guard let thread = client.threadID else { return done(nil) }
        Task { [weak self] in
            guard let response = try? await Self.codexRequest(client, "mcpServerStatus/list",
                                                              ["threadId": thread, "detail": "toolsAndAuthOnly"], timeout: 30),
                  let self else { return done(nil) }
            let names = ConnectorSignIns.codex(response)
            self.noteConnectorsNeedingSignIn(id, names)
            done(names)
        }
    }

    private func signInCodexConnector(_ id: UUID, name: String) {
        guard let client = codexServers[id], client.isRunning else {
            return connectorSignInFailed(id, name: name, tr("ws.connector.noAgent"))
        }
        Task { [weak self] in
            do {
                let response = try await Self.codexRequest(client, "mcpServer/oauth/login", ["name": name], timeout: 30)
                guard let self else { return }
                guard let link = (response["authorizationUrl"] as? String).flatMap(URL.init(string:)) else {
                    return self.connectorSignInFailed(id, name: name, tr("ws.connector.noPage"))
                }
                NSWorkspace.shared.open(link)
                self.waitForConnector(id, name: name) { [weak self] in
                    guard let self, let client = self.codexServers[id], client.isRunning else { return }
                    self.checkCodexConnectors(id, client)
                }
            } catch {
                self?.connectorSignInFailed(id, name: name, error.localizedDescription, recheck: true)
            }
        }
    }

    // MARK: Waiting

    /// Marks the connector as waiting and runs `check` every few seconds, until it connected or five minutes passed.
    private func waitForConnector(_ id: UUID, name: String, check: @escaping () -> Void) {
        setWaiting(id, name: name, true)
        var checks = connectorSignInChecks[id] ?? [:]
        checks[name]?.cancel()
        checks[name] = Task { [weak self] in
            let rounds = Self.signInWaitSeconds / Self.signInCheckSeconds
            for _ in 0..<rounds {
                try? await Task.sleep(nanoseconds: Self.signInCheckSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self, self.connectorSignIns[id]?.contains(where: { $0.name == name && $0.waiting }) == true else { return }
                check()
            }
            guard !Task.isCancelled, let self else { return }
            self.setWaiting(id, name: name, false)
            self.connectorSignInChecks[id]?[name] = nil
        }
        connectorSignInChecks[id] = checks
    }

    private func setWaiting(_ id: UUID, name: String, _ waiting: Bool) {
        guard var list = connectorSignIns[id], let index = list.firstIndex(where: { $0.name == name }) else { return }
        list[index].waiting = waiting
        connectorSignIns[id] = list
    }

    /// The agent turned the sign-in down. With `recheck` Nook first asks it again which connectors need you: the list
    /// comes from the start of a turn, and an agent can drop a connector later (Claude Code drops a plugin's server once
    /// a claude.ai connector covers the same service, and then answers "Server not found"). One that is gone just
    /// leaves the list; only one that still needs you gets the error.
    private func connectorSignInFailed(_ id: UUID, name: String, _ error: String, recheck: Bool = false) {
        setWaiting(id, name: name, false)
        let report = { [weak self] (names: [String]?) in
            guard let self else { return }
            if let names, !names.contains(name) {
                self.append(id, RunEvent(kind: .system, text: tr("ws.connector.gone", ConnectorSignIns.title(name))))
            } else {
                self.append(id, RunEvent(kind: .error, text: tr("ws.connector.failed", ConnectorSignIns.title(name), error)))
            }
        }
        guard recheck, let run = run(id) else { return report(nil) }
        switch run.provider {
        case .claude: checkClaudeConnectors(id, done: report)
        case .codex:
            guard let client = codexServers[id], client.isRunning else { return report(nil) }
            checkCodexConnectors(id, client, done: report)
        case .gemini, .opencode, .cursor, .grok, .antigravity, .pi, .acp: report(nil)
        }
    }
}
