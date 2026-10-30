import Foundation

// Session state beyond start/stop: going on after a restart and snoozing.

extension WorkspaceManager {
    /// Sessions a restart of Nook cut off get "Continue where you left off." once. Called a moment after launch, when the
    /// agents' executables are known; with the setting off nothing happens.
    func continueInterruptedRuns(now: Date = Date()) {
        let enabled = settings.continueAfterRelaunch
        for run in runs where RestartContinuation.shouldContinue(run, enabled: enabled, hasPendingQuestion: !(questions[run.id] ?? []).isEmpty,
                                                                 settled: FinishedSessions.shared.contains(FinishedSessions.key(run: run)),
                                                                 now: now) {
            update(run.id) {
                $0.continuations = RestartContinuation.chainLength($0, now: now) + 1
                $0.lastContinuedAt = now
                // No longer "interrupted": a second launch before this turn ends must not continue it again.
                $0.statusDetail = nil
            }
            append(run.id, RunEvent(kind: .system, text: tr("ws.event.continueAfterRelaunch")))
            send(run.id, text: RestartContinuation.message)
        }
    }

    /// A turn that ended normally clears the chain of restart continuations.
    func clearContinuations(_ id: UUID) {
        guard run(id)?.continuations != nil || run(id)?.lastContinuedAt != nil else { return }
        update(id) {
            $0.continuations = nil
            $0.lastContinuedAt = nil
        }
    }

    func snooze(_ id: UUID, _ choice: SnoozePolicy.Choice, now: Date = Date()) {
        update(id) {
            $0.snoozedAt = now
            $0.snoozedUntil = choice.end(from: now)
        }
    }

    func unsnooze(_ id: UUID) {
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
            settled: settled
        )
        let base = AgentAttention.resolve(input)
        guard includeSnooze else { return base }
        input.settled = settled || SnoozePolicy.isSnoozed(until: run.snoozedUntil, since: run.snoozedAt, attention: base,
                                                          finishedAt: run.status.isActive ? nil : run.updatedAt, now: now)
        return AgentAttention.resolve(input)
    }

    /// The reasoning effort for the next turns (also chosen while a turn runs). An effort the agent does not offer is
    /// skipped, not an error.
    func setEffort(_ id: UUID, _ effort: String?) {
        guard let run = run(id) else { return }
        let offered = effortLevels(for: run.provider, profileID: run.profileID, model: run.model)
        let resolution = EffortResolution.resolve(stored: effort, offered: offered)
        update(id) { $0.effort = resolution.outcome == .use ? resolution.effort : nil }
        if !run.status.isActive { refreshWarmSession(id) }
    }
}
