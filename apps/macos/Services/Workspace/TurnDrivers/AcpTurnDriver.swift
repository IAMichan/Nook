import Foundation

/// The agents that speak ACP (`WorkspaceManager+Acp`): Gemini CLI, OpenCode, Cursor, Grok, Antigravity and the agents
/// you add. One client per session; a turn is `session/prompt`, a stop `session/cancel`.
struct AcpTurnDriver: TurnDriver {
    unowned let workspace: WorkspaceManager

    func launch(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) {
        workspace.launchAcpTurn(id, prompt: prompt, executable: executable, showPrompt: showPrompt)
    }

    func prewarm(_ id: UUID, run: WorkspaceRun, executable: String) {
        // Only an agent whose session stays loaded between turns (`IdleConnection.acpSession`): Antigravity is not
        // opened ahead of time, as it could open Google's sign-in page.
        guard run.provider.capabilities.idleConnection == .acpSession, workspace.acpClients[id] == nil else { return }
        workspace.connectAcp(id, executable: executable, prompt: nil)
    }

    func stop(_ id: UUID) -> Bool {
        workspace.stopAcpTurn(id)
    }

    func decide(_ runID: UUID, requestID: String, _ decision: WorkspaceManager.Decision, reason: String) -> Bool {
        guard workspace.decideAcp(runID, requestID: requestID, decision) else { return false }
        // ACP's reject outcome has no text, whatever the agent's own server could carry (OpenCode's).
        workspace.deliverDenyReason(runID, reason, delivery: .followUpMessage)
        return true
    }
}
