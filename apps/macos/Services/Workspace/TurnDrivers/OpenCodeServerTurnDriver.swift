import Foundation

/// OpenCode over its own server (`WorkspaceManager+OpenCodeServer`): one `opencode serve` per account that its sessions
/// share. A turn is a prompt, a stop an `interrupt`, and a denial's reason goes in the answer to the request.
struct OpenCodeServerTurnDriver: TurnDriver {
    unowned let workspace: WorkspaceManager

    func launch(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) {
        workspace.launchOpenCodeTurn(id, prompt: prompt, executable: executable, showPrompt: showPrompt)
    }

    func prewarm(_ id: UUID, run: WorkspaceRun, executable: String) {
        guard run.provider.capabilities.idleConnection == .acpSession, workspace.openCodeLinks[id] == nil else { return }
        workspace.connectOpenCode(id, executable: executable, prompt: nil)
    }

    func stop(_ id: UUID) -> Bool {
        workspace.stopOpenCodeTurn(id)
    }

    func decide(_ runID: UUID, requestID: String, _ decision: WorkspaceManager.Decision, reason: String) -> Bool {
        // The reason goes with the answer itself (`OpenCodeServe.permissionReply`).
        workspace.decideOpenCode(runID, requestID: requestID, decision, reason: reason)
    }
}
