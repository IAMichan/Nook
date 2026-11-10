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
        // A process still attached is not a hold: Claude Code's stays until it is parked, just after the turn ends. A
        // running turn shows in `status`, and `send` refuses while a process works.
        let holds = !(approvals[id] ?? []).isEmpty || !(questions[id] ?? []).isEmpty || !(queued[id]?.isEmpty ?? true)
            || backgroundWork.contains(id) || run.pendingHandoff != nil || run.pendingRollback != nil
            || awaitingCheckpoint[id] != nil
        return IdleCompaction.Candidate(
            agentReportsCacheLifetime: run.provider.capabilities.reportsPromptCacheLifetime,
            status: run.status, archived: run.archived,
            settled: FinishedSessions.shared.contains(FinishedSessions.key(run: run)),
            snoozedUntil: run.snoozedUntil, contextTokens: run.usage.contextTokens, cache: run.promptCache,
            holdsForYou: holds, isRemote: run.isRemote)
    }

    /// The moment came: if nothing changed, the agent summarizes the conversation while its history is still cached. It
    /// stays with the session's own agent and account (no Auto move, see `send`), and the timeline says so only once
    /// the agent reports the compaction (`.notice("compact")`). Logged like Nook's other automatic actions.
    private func compactIdle(_ id: UUID) {
        idleCompactionTimers[id] = nil
        let now = Date()
        guard settings.idleCompaction, let run = run(id), IdleCompaction.fireDate(idleCandidate(run), now: now) != nil else { return }
        idleCompacting.insert(id)
        let sent = sendHidden(id, text: "/compact")
        if !sent { idleCompacting.remove(id) }
        onAudit?("idle_compaction", "\(run.provider.displayName) · \(run.title) · \(run.usage.contextTokens ?? 0) tokens",
                 sent ? "sent" : "not sent")
    }

    // MARK: Compact on return

    func returnCandidate(_ run: WorkspaceRun) -> ReturnCompaction.Candidate {
        ReturnCompaction.Candidate(
            agentReportsCacheLifetime: run.provider.capabilities.reportsPromptCacheLifetime,
            canCompact: AgentCommands.canCompact(run.provider, offered: acpCommands[run.id] ?? []),
            enabled: settings.idleCompaction, status: run.status, contextTokens: run.usage.contextTokens,
            cache: run.promptCache, isRemote: run.isRemote)
    }

    /// The chip by the send button shows for this session (`ReturnCompaction`).
    func offersCompactFirst(_ run: WorkspaceRun, now: Date = Date()) -> Bool {
        ReturnCompaction.offers(returnCandidate(run), now: now)
    }

    /// The chip is on: the next message goes after a summary.
    func compactsFirst(_ run: WorkspaceRun, now: Date = Date()) -> Bool {
        offersCompactFirst(run, now: now) && !keepsHistory.contains(run.id)
    }

    /// The chip's click: Compact or Keep for your next message.
    func toggleCompactFirst(_ id: UUID) {
        if keepsHistory.contains(id) { keepsHistory.remove(id) } else { keepsHistory.insert(id) }
    }

    /// Your message, after a summary when the chip says Compact: the summary goes out quietly as the idle one does, and
    /// your message waits in line behind it (`turnDidFinish` sends it). False when it went no special way, so it goes as
    /// any message does.
    func submitAfterCompacting(_ id: UUID, text: String) -> Bool {
        defer { if keepsHistory.contains(id) { keepsHistory.remove(id) } }
        guard let run = run(id), compactsFirst(run), processes[id] == nil, !checkpointing.contains(id),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !idleCompacting.contains(id) else { return false }
        idleCompacting.insert(id)
        guard sendHidden(id, text: "/compact") else {
            idleCompacting.remove(id)
            return false
        }
        enqueue(id, text: text)
        onAudit?("return_compaction", "\(run.provider.displayName) · \(run.title) · \(run.usage.contextTokens ?? 0) tokens", "sent")
        return true
    }

    // MARK: Auto-compact mark

    /// Where this session's agent summarizes by itself (`AutoCompactMark`), or nil when it does not say and Nook's own
    /// limit is off or does not apply.
    func autoCompactAt(_ run: WorkspaceRun) -> Int? {
        let nook = AgentCommands.canCompact(run.provider, offered: acpCommands[run.id] ?? [])
            ? SizeCompaction.limit(setting: settings.autoCompactTokens, contextWindow: run.usage.contextWindow) : nil
        return AutoCompactMark.tokens(nookLimit: nook, agentThreshold: agentCompactThreshold(run))
    }

    /// The agent's own threshold. Only Claude Code tells it (`autoCompactWindow` in its settings); Codex, Pi and the ACP
    /// agents compact at a point they do not report (see docs/INTEGRATIONS.md).
    private func agentCompactThreshold(_ run: WorkspaceRun) -> Int? {
        switch run.provider {
        case .claude:
            guard !run.isRemote else { return nil }
            let configDirectory = accountEnvironment(run.profileID)["CLAUDE_CONFIG_DIR"]
            let model = run.resolvedModel ?? run.model
            let key = run.workingDirectory + "|" + (configDirectory ?? "") + "|" + model
            let window: Int?
            if let cached = claudeCompactWindows[key], Date().timeIntervalSince(cached.read) < 60 {
                window = cached.window
            } else {
                let files = ClaudeToolSearch.settingsFiles(workingDirectory: run.workingDirectory, configDirectory: configDirectory)
                window = AutoCompactMark.claudeWindow(in: files, model: model)
                claudeCompactWindows[key] = (window, Date())
            }
            return AutoCompactMark.claudeThreshold(window: window, contextWindow: run.usage.contextWindow)
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp:
            return nil
        }
    }

    // MARK: Size compaction

    /// A turn ended with the context past your limit: the agent summarizes the conversation now, for every agent that
    /// takes `/compact`. It waits a moment so the agent's process is parked first, then goes the way the idle summary
    /// does: quiet (no notification), and what you queued meanwhile goes on after it.
    func compactForSize(_ id: UUID) {
        guard let run = run(id) else { return }
        let holds = !(approvals[id] ?? []).isEmpty || !(questions[id] ?? []).isEmpty
            || run.pendingHandoff != nil || run.pendingRollback != nil || awaitingCheckpoint[id] != nil
        guard SizeCompaction.shouldCompact(
            setting: settings.autoCompactTokens, contextTokens: run.usage.contextTokens, contextWindow: run.usage.contextWindow,
            canCompact: AgentCommands.canCompact(run.provider, offered: acpCommands[id] ?? []),
            completed: run.status == .completed, holdsForYou: holds, isRemote: run.isRemote,
            alreadyCompacted: turns[id]?.compacted ?? false) else { return }
        let tokens = run.usage.contextTokens ?? 0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let run = self.run(id), run.status == .completed, self.processes[id] == nil,
                  !self.idleCompacting.contains(id) else { return }
            self.idleCompacting.insert(id)
            self.sizeCompacting.insert(id)
            let sent = self.sendHidden(id, text: "/compact")
            if !sent {
                self.idleCompacting.remove(id)
                self.sizeCompacting.remove(id)
            }
            self.onAudit?("size_compaction", "\(run.provider.displayName) · \(run.title) · \(tokens) tokens", sent ? "sent" : "not sent")
        }
    }

    /// The setting changed: plan every session again, or drop what was planned.
    func idleCompactionSettingChanged() {
        if settings.idleCompaction {
            scheduleIdleCompactions()
        } else {
            for (_, timer) in idleCompactionTimers { timer.cancel() }
            idleCompactionTimers.removeAll()
        }
    }

    // MARK: Claude Code settings

    /// `ENABLE_TOOL_SEARCH` for this session's Claude Code: on, unless your settings say otherwise (`ClaudeToolSearch`).
    /// A session on another machine keeps that machine's settings. The other agents have no such setting (their MCP
    /// tools always go with every request; see docs/INTEGRATIONS.md).
    /// The token suggestions you applied (Settings › Sessions › Tokens) were made from this Mac's own Claude Code account,
    /// so they go only to sessions of that account here: another account or machine has its own plugins and connectors.
    func appliedTuning(_ run: WorkspaceRun) -> AgentTuning.Applied {
        guard !run.isRemote, (accountEnvironment(run.profileID)["CLAUDE_CONFIG_DIR"] ?? "").isEmpty else { return AgentTuning.Applied() }
        return AgentTuning.Applied.load()
    }

    func claudeToolSearch(_ run: WorkspaceRun) -> String? {
        switch run.provider {
        case .claude: break
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp: return nil
        }
        guard !run.isRemote else { return nil }
        let files = ClaudeToolSearch.settingsFiles(workingDirectory: run.workingDirectory,
                                                   configDirectory: accountEnvironment(run.profileID)["CLAUDE_CONFIG_DIR"])
        let yours = ClaudeToolSearch.userValue(in: files) ?? ProcessInfo.processInfo.environment["ENABLE_TOOL_SEARCH"]
        return ClaudeToolSearch.override(userValue: yours)
    }
}
