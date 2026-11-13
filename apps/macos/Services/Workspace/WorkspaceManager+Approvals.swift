import Foundation

/// Permission requests from every agent: answered through the session's turn driver (`TurnDriver.decide`), expired
/// when the turn or its process ends, and allowed at once when the session's rights already cover them.
extension WorkspaceManager {
    // MARK: Approvals

    enum Decision { case allow, always, deny }

    /// `reason`: what you told the agent with a denial. It reaches the agent the way its app takes it
    /// (`ProviderCapabilities.denyReason`); with an allow it is ignored.
    func decide(_ runID: UUID, requestID: String, _ decision: Decision, reason: String = "") {
        let reason = decision == .deny ? reason.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // A request Codex's app-server or an ACP agent asked; otherwise one on the turn's process.
        if connectedTurnDrivers.contains(where: { $0.decide(runID, requestID: requestID, decision, reason: reason) }) { return }
        _ = processTurnDriver(runID).decide(runID, requestID: requestID, decision, reason: reason)
    }

    /// The reason for a denial, for an agent whose answer to a request carries no text: steered into the running turn
    /// (Codex `turn/steer`; an ACP agent is interrupted and gets it as the next prompt). While more requests wait on you
    /// the turn cannot be steered, so it waits in the queue for the end of the turn.
    /// `delivery`: how this transport takes it, when it differs from the agent's own (OpenCode over ACP, where its server
    /// would carry it in the answer).
    func deliverDenyReason(_ id: UUID, _ reason: String, delivery: DenyReasonDelivery? = nil) {
        guard !reason.isEmpty, let run = run(id) else { return }
        switch delivery ?? run.provider.capabilities.denyReason {
        case .inResponse:
            return
        case .followUpMessage:
            let message = tr("ws.approval.denyMessage", reason)
            if (approvals[id]?.isEmpty ?? true), steer(id, text: message) { return }
            enqueue(id, text: message)
        }
    }

    /// An MCP server's request (a tool that wants to run, or something to confirm, from Codex or Claude Code): the same
    /// approval card as a command, titled with the tool and its server in readable words.
    func presentMcpRequest(_ id: UUID, requestID: String, server: String, tool: String, message: String,
                           arguments: [String: Any], suggestions: JSONBox?) {
        let tool = "mcp__\(server.isEmpty ? "mcp" : server)__\(tool.isEmpty ? "confirm" : tool)"
        var input = arguments
        // Without arguments to show, the server's own question says what is being allowed.
        if input.isEmpty, !message.isEmpty { input["message"] = message }
        let label = McpToolName(tool)?.label ?? tool
        let summary = message.isEmpty ? label : "\(label) · \(ToolSummary.oneLine(message, 120))"
        let event = RunEvent(kind: .approval, text: summary, tool: tool, callID: requestID, detail: ToolSummary.json(input), state: .pending)
        append(id, event)
        let pending = PendingPermission(id: requestID, runID: id, tool: tool, summary: summary, input: JSONBox(input),
                                        suggestions: suggestions, eventID: event.id, created: Date())
        approvals[id, default: []].append(pending)
        update(id) { $0.move(to: .waitingApproval) }
        if let run = run(id) { onApproval?(run, pending) }
    }

    func expireApproval(_ runID: UUID, requestID: String) {
        guard let pending = approvals[runID]?.first(where: { $0.id == requestID }) else { return }
        approvals[runID]?.removeAll { $0.id == requestID }
        mutateEvent(runID, pending.eventID) { $0.state = .expired }
        onApprovalGone?(requestID)
    }

    func expireApprovals(_ runID: UUID) {
        for pending in approvals[runID] ?? [] { expireApproval(runID, requestID: pending.id) }
        approvals[runID] = nil
    }

    /// Allows the waiting requests the session's current rights cover, as if you had pressed Allow on each.
    func allowCovered(_ id: UUID) {
        guard let run = run(id) else { return }
        for pending in approvals[id] ?? [] where coveredByRights(pending, run) { decide(id, requestID: pending.id, .allow) }
    }

    private func coveredByRights(_ pending: PendingPermission, _ run: WorkspaceRun) -> Bool {
        if let request = codexRequests[pending.id] {
            return LiveRights.coversCodex(request.kind, permission: run.permission, mode: run.mode)
        }
        if let request = acpRequests[pending.id] {
            return AcpRPC.autoAllows(request.call, permission: run.permission, mode: run.mode)
        }
        // An MCP server's question waits for you, whatever the session may do (as `LiveRights.coversCodex` for `mcpTool`).
        if pending.id.hasPrefix(ClaudeElicitation.pendingPrefix) { return false }
        return run.provider.capabilities.processChannel == .claudeStreamJSON && LiveRights.coversClaude(tool: pending.tool, permission: run.permission, mode: run.mode)
    }
}
