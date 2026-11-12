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
        return run.provider.capabilities.processChannel == .claudeStreamJSON && LiveRights.coversClaude(tool: pending.tool, permission: run.permission, mode: run.mode)
    }
}
