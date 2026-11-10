import Foundation

// Session state beyond start/stop: going on after a restart and snoozing.

extension WorkspaceManager {
    /// Sessions a restart of Nook cut off get "Continue where you left off." once. Called a moment after launch, when the
    /// agents' executables are known; with the setting off nothing happens.
    func continueInterruptedRuns(now: Date = Date()) {
        let enabled = settings.continueAfterRelaunch
        for run in runs where RestartContinuation.shouldContinue(run, enabled: enabled, hasPendingQuestion: waitsOnQuestion(run.id),
                                                                 settled: FinishedSessions.shared.contains(FinishedSessions.key(run: run)),
                                                                 now: now) {
            let message = RestartContinuation.message(for: run)
            let waited = run.cutBackgroundWork != nil
            update(run.id) {
                $0.continuations = RestartContinuation.chainLength($0, now: now) + 1
                $0.lastContinuedAt = now
                // No longer "interrupted" or waiting: a second launch before this turn ends must not continue it again.
                $0.statusDetail = nil
                $0.cutBackgroundWork = nil
            }
            append(run.id, RunEvent(kind: .system, text: tr(waited ? "ws.event.continueAfterBackgroundStop" : "ws.event.continueAfterRelaunch")))
            send(run.id, text: message)
        }
        // Summaries planned before Nook quit, for the sessions whose cache is still warm.
        scheduleIdleCompactions()
    }

    /// A question holds the agent until you answer it; one it asked while it goes on (`answersAsMessage`) does not.
    func waitsOnQuestion(_ id: UUID) -> Bool {
        (questions[id] ?? []).contains { !$0.answersAsMessage }
    }

    /// A turn that ended normally clears the chain of restart continuations.
    func clearContinuations(_ id: UUID) {
        guard run(id)?.continuations != nil || run(id)?.lastContinuedAt != nil || run(id)?.cutBackgroundWork != nil else { return }
        update(id) {
            $0.continuations = nil
            $0.lastContinuedAt = nil
            $0.cutBackgroundWork = nil
        }
    }

    func snooze(_ id: UUID, _ choice: SnoozePolicy.Choice, now: Date = Date()) {
        snooze(id, until: choice.end(from: now), now: now)
    }

    /// Snoozed until `end`: a custom moment, or when the session's usage limit resets.
    func snooze(_ id: UUID, until end: Date, now: Date = Date()) {
        guard end > now else { return }
        update(id) {
            $0.snoozedAt = now
            $0.snoozedUntil = end
        }
    }

    func unsnooze(_ id: UUID) {
        defer { scheduleIdleCompaction(id) }
        update(id) {
            $0.snoozedAt = nil
            $0.snoozedUntil = nil
        }
    }

    /// What this session asks of you right now (see `AgentAttention`).
    func attention(_ run: WorkspaceRun, unseen: Bool, settled: Bool = false, includeSnooze: Bool = true, now: Date = Date()) -> AgentAttention {
        var input = AgentAttention.Input(
            status: run.status,
            pendingApprovals: (approvals[run.id] ?? []).count,
            pendingQuestions: (questions[run.id] ?? []).count,
            limitedAt: run.limitedAt,
            unseen: unseen,
            settled: settled,
            subagentsWorking: subagentsWorking.contains(run.id),
            quietTurn: idleCompacting.contains(run.id)
        )
        let base = AgentAttention.resolve(input)
        guard includeSnooze else { return base }
        input.settled = settled || SnoozePolicy.isSnoozed(until: run.snoozedUntil, since: run.snoozedAt, attention: base,
                                                          finishedAt: run.status.isActive ? nil : run.updatedAt,
                                                          limitedAt: run.limitedAt, now: now)
        return AgentAttention.resolve(input)
    }

    /// The reasoning effort for the next turns (also chosen while a turn runs). An effort the agent does not offer is
    /// skipped, not an error.
    func setEffort(_ id: UUID, _ effort: String?) {
        guard let run = run(id) else { return }
        let offered = effortLevels(for: run.provider, profileID: run.profileID, model: run.model)
        let resolution = EffortResolution.resolve(stored: effort, offered: offered)
        let before = switchEndpoint(run)
        update(id) { $0.effort = resolution.outcome == .use ? resolution.effort : nil }
        noteModelSwitch(id, from: before)
        if run.status.isActive, let updated = self.run(id) { applyLive(id, from: run, to: updated) }
        if !run.status.isActive { refreshWarmSession(id) }
    }

    /// Ultracode as a launch passes it: what you chose, while the session's model offers it (`Ultracode`).
    func ultracode(_ run: WorkspaceRun) -> Bool? {
        Ultracode.offered(provider: run.provider, model: run.model) ? run.ultracode : nil
    }

    /// Ultracode for the next turns. Claude Code reads it as it starts, as fast mode: an idle session's waiting process
    /// starts again with it, and a running turn keeps what it had.
    func setUltracode(_ id: UUID, _ on: Bool) {
        guard let run = run(id), run.ultracode != on else { return }
        update(id) { $0.ultracode = on }
        if run.status.isActive { claudeChangedDuringTurn.insert(id) } else { refreshWarmSession(id) }
    }

    /// The speed tiers the session's agent offers for its model (`SpeedTiers`).
    func speedTiers(for run: WorkspaceRun) -> [SpeedTier] {
        SpeedTiers.tiers(for: run.provider, model: run.model, listed: offeredModels(run.provider, profileID: run.profileID))
    }

    /// The tier a launch uses: the chosen one while the model still offers it.
    func speedTier(_ run: WorkspaceRun) -> String? {
        SpeedTiers.resolve(run.speedTier, offered: speedTiers(for: run))
    }

    /// The speed tier for the next turns. Codex takes it with the next `turn/start`; Claude Code reads fast mode as it
    /// starts, so an idle session's waiting process starts again with it, and a running turn keeps its speed.
    func setSpeedTier(_ id: UUID, _ tier: String?) {
        guard let run = run(id), run.speedTier != tier else { return }
        update(id) { $0.speedTier = SpeedTiers.resolve(tier, offered: self.speedTiers(for: run)) }
        // Only a parked Claude Code process reads this set: it then starts again with the new tier.
        if run.status.isActive { claudeChangedDuringTurn.insert(id) }
        if !run.status.isActive { refreshWarmSession(id) }
    }
}
