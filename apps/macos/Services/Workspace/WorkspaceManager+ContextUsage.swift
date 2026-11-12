import Foundation

/// The card behind the composer's context ring: what fills the window, part by part where the agent says it.
extension WorkspaceManager {
    /// What fills the session's window: the agent's own breakdown when it gave one for the context the session has now,
    /// else an estimate from the tokens it reported (`ContextUsage.estimate`). Nil before the agent said its window.
    func contextUsage(_ run: WorkspaceRun) -> ContextUsage? {
        guard let window = run.usage.contextWindow, let used = run.usage.contextTokens, window > 0 else { return nil }
        if let known = contextUsages[run.id], known.contextTokens == used { return known.usage }
        return ContextUsage.estimate(used: used, window: window, autoCompactAt: autoCompactAt(run))
    }

    /// Asks the agent for its breakdown, when it can give one: as the card opens. Only a process that already runs is
    /// asked; hovering over an old session does not start one.
    func refreshContextUsage(_ id: UUID) {
        guard let run = run(id), !run.isRemote else { return }
        switch run.provider {
        case .claude:
            let tokens = run.usage.contextTokens
            _ = claudeControl(id, starts: false, ClaudeStreamParser.contextUsageRequest(id:)) { [weak self] response, error in
                guard let self, error == nil, let usage = response.flatMap({ ContextUsage.claude($0.dictionary) }) else { return }
                self.contextUsages[id] = (usage, tokens)
            }
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp:
            // They report the conversation's size but not what it is made of (see docs/INTEGRATIONS.md).
            break
        }
    }
}
