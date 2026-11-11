import Foundation

/// `session_suggest`: an agent offers a side task as a new session (see `SessionSuggestion`). The card goes into the
/// caller's own timeline and nothing starts until you choose on it, so it needs no approval; the call is in the audit log.
extension WorkspaceBridge {
    func suggestSession(_ arguments: [String: Any], _ caller: BridgeCaller) -> BridgeRPC.ToolResult {
        guard case .run(let runID) = caller.kind, let workspace = app?.workspace, workspace.run(runID) != nil else {
            return .error("session_suggest shows a card in a session Nook runs; this session runs outside Nook. Use session_start, which asks the user first.")
        }
        if case .refuse(let reason) = verdict(.sessionSuggest, caller) { return .error(Self.refusal(reason)) }
        let suggestion: SessionSuggestion
        switch SessionSuggestion.parse(arguments) {
        case .failure(let error): return .error(error.message)
        case .success(let value): suggestion = value
        }
        if !suggestion.agent.isEmpty, RunProvider.named(suggestion.agent) == nil {
            return .error("Unknown agent \"\(suggestion.agent)\". Call orchestrator_capabilities for the list, or leave agent out.")
        }
        workspace.append(runID, suggestion.event())
        audit(.sessionSuggest, caller, suggestion.title, "shown")
        return BridgeRPC.ToolResult(text: SessionSuggestion.toolAnswer)
    }
}
