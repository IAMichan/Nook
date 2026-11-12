import Foundation

/// Pi over its RPC mode (`PiRPC`, `WorkspaceManager+Pi`): a process per turn that takes `abort`, the answers to its confirm
/// dialog and steering prompts on stdin. Nothing stays open between turns.
struct PiRPCTurnDriver: ProcessTurnDriver {
    unowned let workspace: WorkspaceManager

    func interruptRequest() -> String? { PiRPC.abort() }

    func answer(requestID: String, _ pending: PendingPermission, _ decision: WorkspaceManager.Decision,
                reason: String) -> (line: String, notesReason: Bool) {
        // Pi's `confirm` dialog has no "always"; Nook remembers nothing for it.
        (PiRPC.confirmResponse(requestID: requestID, confirmed: decision != .deny), false)
    }
}
