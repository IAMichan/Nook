import Foundation

// Spending fewer tokens without losing quality (see TokenSavings.swift): the summary of a long idle session before its
// prompt cache expires, and the Claude Code settings that keep every request small.

extension WorkspaceManager {
    // MARK: Prompt cache

    /// The cache window after a turn: from its latest request, with the lifetime the agent reported. A request served
    /// fully from the cache reports none, but it refreshed the cache for the lifetime it already had.
    static func promptCache(after state: TurnState?, previous: PromptCacheWindow?) -> PromptCacheWindow? {
        guard let state, let started = state.lastRequestAt, let ttl = state.cacheTTL ?? previous?.ttl else { return nil }
        return PromptCacheWindow(expiresAt: started.addingTimeInterval(ttl), ttl: ttl, afterCompaction: state.compacted)
    }

    // MARK: Idle compaction

    /// Plans (or drops) the summary of this session, after a turn ended or when Nook starts.
    func scheduleIdleCompaction(_ id: UUID, now: Date = Date()) {
        idleCompactionTimers.removeValue(forKey: id)?.cancel()
        guard settings.idleCompaction, let run = run(id), let fire = IdleCompaction.fireDate(idleCandidate(run), now: now) else { return }
        let delay = max(0, fire.timeIntervalSince(now))
        idleCompactionTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.compactIdle(id)
        }
    }

    /// Every session that may still get its summary: after Nook starts, from the cache windows it saved.
    func scheduleIdleCompactions() {
        for run in runs where run.promptCache != nil { scheduleIdleCompaction(run.id) }
    }

    /// A new turn starts: whatever was planned for the idle session no longer applies.
    func cancelIdleCompaction(_ id: UUID) {
        idleCompactionTimers.removeValue(forKey: id)?.cancel()
    }

    func idleCandidate(_ run: WorkspaceRun) -> IdleCompaction.Candidate {
        let id = run.id
        let holds = !(approvals[id] ?? []).isEmpty || !(questions[id] ?? []).isEmpty || !(queued[id]?.isEmpty ?? true)
            || backgroundWork.contains(id) || processes[id] != nil || run.pendingHandoff != nil || run.pendingRollback != nil
            || awaitingCheckpoint[id] != nil
        return IdleCompaction.Candidate(
            agentReportsCacheLifetime: run.provider.capabilities.reportsPromptCacheLifetime,
            status: run.status, archived: run.archived,
            settled: FinishedSessions.shared.contains(FinishedSessions.key(run: run)),
            snoozedUntil: run.snoozedUntil, contextTokens: run.usage.contextTokens, cache: run.promptCache,
            holdsForYou: holds, isRemote: run.isRemote)
    }

    /// The moment came: if nothing changed, the agent summarizes the conversation while its history is still cached.
    private func compactIdle(_ id: UUID) {
        idleCompactionTimers[id] = nil
        let now = Date()
        guard settings.idleCompaction, let run = run(id), IdleCompaction.fireDate(idleCandidate(run), now: now) != nil else { return }
        idleCompacting.insert(id)
        guard sendHidden(id, text: "/compact") else {
            idleCompacting.remove(id)
            return
        }
        append(id, RunEvent(kind: .system, text: tr("ws.event.idleCompaction")))
    }

    // MARK: Claude Code settings

    /// `ENABLE_TOOL_SEARCH` for this session's Claude Code: on, unless your settings say otherwise (`ClaudeToolSearch`).
    /// A session on another machine keeps that machine's settings. The other agents have no such setting (their MCP
    /// tools always go with every request; see docs/INTEGRATIONS.md).
    func claudeToolSearch(_ run: WorkspaceRun) -> String? {
        switch run.provider {
        case .claude: break
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .acp: return nil
        }
        guard !run.isRemote else { return nil }
        let files = ClaudeToolSearch.settingsFiles(workingDirectory: run.workingDirectory,
                                                   configDirectory: accountEnvironment(run.profileID)["CLAUDE_CONFIG_DIR"])
        let yours = ClaudeToolSearch.userValue(in: files) ?? ProcessInfo.processInfo.environment["ENABLE_TOOL_SEARCH"]
        return ClaudeToolSearch.override(userValue: yours)
    }
}
