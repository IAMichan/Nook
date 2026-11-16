import Foundation

/// Codex over `codex app-server` (`WorkspaceManager+CodexServer`): one client per session that stays connected between
/// turns. A turn is `turn/start`, a stop `turn/interrupt`, and approvals are answered over the same connection.
struct CodexServerTurnDriver: TurnDriver {
    unowned let workspace: WorkspaceManager

    func launch(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) {
        workspace.launchCodexServerTurn(id, prompt: prompt, executable: executable, showPrompt: showPrompt)
    }

    func prewarm(_ id: UUID, run: WorkspaceRun, executable: String) {
        guard workspace.codexServers[id] == nil else { return }
        workspace.connectCodexServer(id, executable: executable, prompt: nil)
    }

    func stop(_ id: UUID) -> Bool {
        workspace.stopCodexServerTurn(id)
    }

    func decide(_ runID: UUID, requestID: String, _ decision: WorkspaceManager.Decision, reason: String) -> Bool {
        guard workspace.decideCodex(runID, requestID: requestID, decision) else { return false }
        workspace.deliverDenyReason(runID, reason)
        return true
    }
}
