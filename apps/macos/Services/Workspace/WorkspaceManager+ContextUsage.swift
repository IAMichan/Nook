import Foundation

/// The card behind the composer's context ring: what fills the window, part by part where the agent says it.
extension WorkspaceManager {
    /// What fills the session's window: the agent's own breakdown when it gave one for the context the session has now,
    /// else an estimate from the tokens it reported (`ContextUsage.estimate`). During a turn it follows the turn's latest
    /// figures, so the ring shows from the first answer of a new session too. Nil before Nook knows the window.
    func contextUsage(_ run: WorkspaceRun) -> ContextUsage? {
        let known = contextUsages[run.id]
        let live = turns[run.id].flatMap { $0.finished ? nil : $0 }
        guard let used = live?.lastContext ?? run.usage.contextTokens,
              let window = run.usage.contextWindow ?? live?.contextWindow ?? known?.usage.window, window > 0 else { return nil }
        if let known, known.contextTokens == used { return known.usage }
        return ContextUsage.estimate(used: used, window: window, autoCompactAt: autoCompactAt(run))
    }

    /// The tokens the session's context holds now: the running turn's latest, else what the last turn ended with.
    func currentContextTokens(_ run: WorkspaceRun) -> Int? {
        turns[run.id].flatMap { $0.finished ? nil : $0.lastContext } ?? run.usage.contextTokens
    }

    /// Claude Code says its window only when a turn ends, so in a session's first turn (which steering messages can make
    /// long) the ring had nothing to measure against. Asked once, as soon as the turn reports tokens; the other agents
    /// report their window during the turn already.
    func askContextWindowIfUnknown(_ id: UUID) {
        guard let state = turns[id], !state.windowAsked, state.contextWindow == nil,
              let run = run(id), run.usage.contextWindow == nil, contextUsages[id] == nil else { return }
        turns[id]?.windowAsked = true
        let tokens = state.lastContext
        _ = claudeControl(id, starts: false, ClaudeStreamParser.contextUsageRequest(id:)) { [weak self] response, error in
            guard let self, error == nil, let usage = response.flatMap({ ContextUsage.claude($0.dictionary) }) else { return }
            self.turns[id]?.contextWindow = usage.window
            self.contextUsages[id] = (usage, tokens)
        }
    }

    /// Asks the agent for its breakdown, when it can give one: as the card opens. Only a process that already runs is
    /// asked; hovering over an old session does not start one.
    func refreshContextUsage(_ id: UUID) {
        guard let run = run(id), !run.isRemote else { return }
        switch run.provider {
        case .claude:
            let tokens = currentContextTokens(run)
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
