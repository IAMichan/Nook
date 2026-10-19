import Foundation

/// A turn that stopped on a usage limit: Nook remembers when the limit resets, shows it
/// above the composer, and with "Resume at reset" sends "Continue where you left off." once it has. Any message of
/// your own, archiving, or turning it off cancels that.
extension WorkspaceManager {
    /// Claude Code reported a limit during the turn: a blocked window is noted (once, in the timeline).
    func noteClaudeLimit(_ id: UUID, _ event: UsageLimits.ClaudeEvent) {
        guard turns[id] != nil else { return }
        if event.blocked {
            let first = turns[id]?.limitWindows.isEmpty ?? true
            turns[id]?.limitWindows[event.window] = .some(event.resetsAt)
            if first { append(id, RunEvent(kind: .system, text: Self.limitText(event.resetsAt))) }
        } else {
            turns[id]?.limitWindows[event.window] = nil
        }
    }

    /// After a turn: did a usage limit stop it? Then the session waits for the reset (and goes on then, if set so).
    func checkUsageLimit(_ id: UUID) {
        guard let known = limitedTurns.removeValue(forKey: id) else { return }
        guard let run = run(id), run.status == .failed else { return }
        let reset = known ?? codexLimitSnapshots[id].flatMap { UsageLimits.codexReset($0.dictionary) }
        let auto = settings.autoResumeLimited && reset != nil
        update(id) {
            $0.limitedAt = Date()
            $0.limitResetAt = reset
            $0.autoResume = auto
        }
        armLimitResume(id)
    }

    /// "Resume at reset" on or off for this session.
    func setAutoResume(_ id: UUID, _ on: Bool) {
        guard let run = run(id), run.limitedAt != nil, run.limitResetAt != nil else { return }
        update(id) { $0.autoResume = on }
        armLimitResume(id)
    }

    func clearUsageLimit(_ id: UUID) {
        limitResumes.removeValue(forKey: id)?.cancel()
        limitedTurns[id] = nil
        guard run(id)?.limitedAt != nil else { return }
        update(id) {
            $0.limitedAt = nil
            $0.limitResetAt = nil
            $0.autoResume = nil
        }
    }

    func armLimitResume(_ id: UUID) {
        limitResumes.removeValue(forKey: id)?.cancel()
        guard let run = run(id), run.autoResume == true, let reset = run.limitResetAt else { return }
        // A little after the reset, so the limit is really free again.
        let wait = max(0, reset.timeIntervalSinceNow) + 20
        limitResumes[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resumeAfterLimit(id)
        }
    }

    /// Checked again right before sending: still waiting, still wanted, nothing pending, not archived.
    private func resumeAfterLimit(_ id: UUID) {
        limitResumes[id] = nil
        guard let run = run(id), run.autoResume == true, run.limitedAt != nil, let reset = run.limitResetAt, reset <= Date(),
              !run.archived, !run.status.isActive, (approvals[id] ?? []).isEmpty, (questions[id] ?? []).isEmpty else { return }
        append(id, RunEvent(kind: .system, text: tr("ws.limit.resuming")))
        send(id, text: UsageLimits.resumeMessage)
    }

    /// "Waits for the limit, which resets in 2h 15m (14:30)."
    static func limitText(_ reset: Date?) -> String {
        guard let reset else { return tr("ws.limit.waitingUnknown") }
        let clock = DateFormatter()
        clock.timeStyle = .short
        clock.dateStyle = Calendar.current.isDateInToday(reset) ? .none : .short
        return tr("ws.limit.waiting", AgentPathFormat.duration(max(0, reset.timeIntervalSinceNow)), clock.string(from: reset))
    }
}
