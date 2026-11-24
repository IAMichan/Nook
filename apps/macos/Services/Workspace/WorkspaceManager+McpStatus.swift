import Foundation

/// `/mcp` in a session (see `McpStatus`): Nook asks the agent which MCP servers it has and how each one is doing, and puts
/// the answer in the session. Claude Code answers over its `mcp_status` control request, Codex over its app-server
/// (`mcpServerStatus/list`), OpenCode over its server (`GET /api/mcp`). Gemini CLI, Cursor, Grok, Antigravity, Pi and
/// the ACP agents you add do not report their servers: they get no `/mcp` from Nook, only one they announce themselves.
extension WorkspaceManager {
    /// Asks the session's agent for its MCP servers and adds the list to the session.
    func showMcpStatus(_ id: UUID) {
        guard let run = run(id) else { return }
        switch run.provider {
        case .claude:
            let sent = claudeControl(id, ClaudeStreamParser.mcpStatusRequest(id:)) { [weak self] response, error in
                guard let self else { return }
                guard error == nil, let rows = response?.dictionary["mcpServers"] else {
                    return self.mcpStatusFailed(id, error)
                }
                self.noteConnectorsNeedingSignIn(id, ConnectorSignIns.claude(rows))
                self.append(id, McpStatus.event(McpStatus.claude(rows)))
            }
            if !sent { mcpStatusFailed(id, nil) }
        case .codex:
            guard let client = codexServers[id], client.isRunning, let thread = client.threadID else { return mcpStatusFailed(id, nil) }
            Task { [weak self] in
                do {
                    let response = try await Self.codexRequest(client, "mcpServerStatus/list",
                                                               ["threadId": thread, "detail": "toolsAndAuthOnly"], timeout: 30)
                    guard let self else { return }
                    self.noteConnectorsNeedingSignIn(id, ConnectorSignIns.codex(response))
                    self.append(id, McpStatus.event(McpStatus.codex(response)))
                } catch {
                    self?.mcpStatusFailed(id, error.localizedDescription)
                }
            }
        case .opencode:
            guard let link = openCodeLinks[id], let host = openCodeHosts[link.host], host.isRunning else { return mcpStatusFailed(id, nil) }
            Task { [weak self] in
                let reply = await host.send("GET", "/api/mcp", query: OpenCodeServe.locationQuery(link.directory))
                guard let self else { return }
                guard reply.ok else { return self.mcpStatusFailed(id, reply.error) }
                self.append(id, McpStatus.event(McpStatus.openCode(reply.json?.object)))
            }
        case .gemini, .antigravity, .cursor, .grok, .pi, .acp:
            return
        }
    }

    private func mcpStatusFailed(_ id: UUID, _ error: String?) {
        let text = error.map { tr("ws.mcp.failed", $0) } ?? tr("ws.mcp.notOpen")
        append(id, RunEvent(kind: .error, text: text))
    }

    /// Once per Claude Code process: the `/` commands it has in this session (its own, your skills and the project's), with
    /// what each one does, from its `initialize` reply.
    func loadClaudeCommands(_ id: UUID) {
        guard acpCommands[id] == nil else { return }
        acpCommands[id] = []
        let sent = claudeControl(id, starts: false, ClaudeStreamParser.initializeRequest(id:)) { [weak self] response, _ in
            guard let self else { return }
            let commands = AgentSlashCommand.claude(response?.dictionary["commands"])
            self.offerCommands(id, commands)
        }
        if !sent { acpCommands[id] = nil }
    }

    /// The commands a session's agent offers: shown in its `/` list, and remembered for its agent so a session that has
    /// not started yet lists them too (`AgentCommandMemory`).
    func offerCommands(_ id: UUID, _ commands: [AgentSlashCommand]) {
        if acpCommands[id] != commands { acpCommands[id] = commands }
        if let provider = run(id)?.provider { AgentCommandMemory.remember(commands, for: provider) }
    }

    /// The commands a new session with `provider` in `folder` will have: those of a session of that agent running in the
    /// same folder (its project's commands too), else what the agent offered last.
    func knownCommands(for provider: RunProvider, folder: String) -> [AgentSlashCommand] {
        let live = runs.filter { $0.provider == provider && !(acpCommands[$0.id] ?? []).isEmpty }
        if let same = live.first(where: { $0.workingDirectory == folder || $0.projectPath == folder }) {
            return acpCommands[same.id] ?? []
        }
        return AgentCommandMemory.recalled(for: provider)
    }

    /// `/status`: the session's agent, model and settings as a line you open (`SessionCommands.statusRows`).
    func showStatus(_ id: UUID) {
        guard let run = run(id) else { return }
        append(id, SessionCommands.statusEvent(run))
    }
}
