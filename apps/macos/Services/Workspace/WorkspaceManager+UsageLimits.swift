import Foundation

/// A turn that stopped on a usage limit: Nook remembers when the limit resets, shows it
/// above the composer, and with "Resume at reset" sends "Continue where you left off." once it has. When the limit
/// stops it again (the reset came early, or was unknown) it keeps trying, further apart each time, until a turn ends
/// normally. Any message of your own, archiving, or turning it off cancels the wait.
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

    /// A turn of any agent failed with this text: when it says a usage limit stopped it (a 429, "rate limit", a gateway's
    /// reset time), the session waits for the reset like a Claude Code turn stopped by its own limit event. One classifier
    /// for every agent (`FailureClassifier`), so "Resume at reset" works for each of them.
    func noteFailure(_ id: UUID, text: String?) {
        // A limit already noted without a reset (Codex's error code) still takes the reset this text names.
        let noted = limitedTurns[id]
        guard noted == nil || noted == .some(nil), let text, !text.isEmpty else { return }
        let evidence = FailureEvidence(isError: true, messageText: text)
        if case .usageLimit(let resetAt) = FailureClassifier.classify(evidence), noted == nil || resetAt != nil {
            limitedTurns[id] = .some(resetAt)
        }
    }

    /// After a turn: did a usage limit stop it? Then the session waits for the reset (and goes on then, if set so).
    /// A turn that ends without a limit ends a run of automatic resumes.
    func checkUsageLimit(_ id: UUID) {
        guard let known = limitedTurns.removeValue(forKey: id) else {
            if run(id)?.limitRetries != nil { update(id) { $0.limitRetries = nil } }
            return
        }
        guard let run = run(id), run.status == .failed else { return }
        onLimitReached?()
        let now = Date()
        // The turn's own reset first, then what the account's limits say. A reset already past is no reset: the limit
        // is evidently not free yet, so Nook tries again later instead of at once.
        let reset = [known, codexLimitSnapshots[id].flatMap { UsageLimits.codexReset($0.dictionary) }, limitResetHint?(run)]
            .lazy.compactMap { $0 }.first { $0 > now }
        // On with the setting, and also when this limit came right after Nook went on by itself: "Resume at reset"
        // stays on until a turn ends normally or you turn it off, whether or not the reset time is known.
        let auto = settings.autoResumeLimited || run.limitRetries != nil
        update(id) {
            $0.limitedAt = now
            $0.limitResetAt = reset
            $0.autoResume = auto
        }
        armLimitResume(id)
    }

    /// "Resume at reset" on or off for this session.
    func setAutoResume(_ id: UUID, _ on: Bool) {
        guard let run = run(id), run.limitedAt != nil else { return }
        update(id) {
            $0.autoResume = on
            if !on { $0.limitRetries = nil }
        }
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

    /// When this session goes on by itself; nil when it does not.
    func limitResumeDue(_ run: WorkspaceRun) -> Date? {
        guard run.autoResume == true, let limitedAt = run.limitedAt else { return nil }
        return UsageLimits.resumeDue(limitedAt: limitedAt, reset: run.limitResetAt,
                                     retries: run.limitRetries.map { $0 + 1 } ?? 0)
    }

    func armLimitResume(_ id: UUID) {
        limitResumes.removeValue(forKey: id)?.cancel()
        guard let run = run(id), let due = limitResumeDue(run) else { return }
        limitResumes[id] = Task { [weak self] in
            // Task.sleep stands still while the Mac sleeps, so one long sleep would fire hours late after a night
            // with the lid closed: wait in short steps against the wall clock instead.
            var left = due.timeIntervalSinceNow
            while left > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(left, Self.limitResumeStep) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                left = due.timeIntervalSinceNow
            }
            guard !Task.isCancelled else { return }
            self?.resumeAfterLimit(id)
        }
    }

    /// How often a waiting resume looks at the clock: at most this long late after the Mac wakes.
    static let limitResumeStep: TimeInterval = 30

    /// Checked again right before sending: still waiting, still wanted, not archived. What only holds it up for now (a
    /// turn still working, an approval or question open, a message that cannot go out yet) tries again a minute later
    /// instead of dropping the resume.
    private func resumeAfterLimit(_ id: UUID) {
        limitResumes[id] = nil
        guard let run = run(id), run.autoResume == true, run.limitedAt != nil, !run.archived else { return }
        // A reset unknown until now that the account's limits name meanwhile: wait for that one instead.
        if run.limitResetAt == nil, let hint = limitResetHint?(run), hint > Date() {
            update(id) { $0.limitResetAt = hint }
            armLimitResume(id)
            return
        }
        guard run.canContinue, processes[id] == nil, (approvals[id] ?? []).isEmpty, (questions[id] ?? []).isEmpty else {
            return retryLimitResume(id)
        }
        let retries = (run.limitRetries ?? -1) + 1
        update(id) { $0.limitRetries = retries }
        append(id, RunEvent(kind: .system, text: tr("ws.limit.resuming")))
        if !send(id, text: UsageLimits.resumeMessage) {
            update(id) { $0.limitRetries = run.limitRetries }
            retryLimitResume(id)
        }
    }

    private func retryLimitResume(_ id: UUID) {
        limitResumes[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.resumeAfterLimit(id)
        }
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
