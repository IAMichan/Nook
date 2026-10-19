import Foundation

// Stop that always ends, and a
// turn that never leaves anything open. The decisions are in `StopCoordinator` and `OpenWork`; this carries them out.

extension WorkspaceManager {
    /// Starts the stop clock for a session: close the input after 2.5 s for a process that has not ended, and finalize by
    /// force after 10 s. The agent-specific first step (interrupt request, `turn/interrupt`) stays in `stop`.
    func beginStop(_ id: UUID) {
        guard run(id)?.status.isActive == true, stopCoordinators[id]?.isActive != true else { return }
        var coordinator = StopCoordinator(turnStarted: turns[id] != nil)
        coordinator.begin(now: Date(), turnStarted: turns[id] != nil)
        stopCoordinators[id] = coordinator
        scheduleStopCheck(id)
    }

    private func scheduleStopCheck(_ id: UUID) {
        guard let coordinator = stopCoordinators[id], let at = coordinator.nextCheck(now: Date()) else { return }
        let wait = max(0.05, at.timeIntervalSinceNow)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.stopCheck(id)
        }
    }

    private func stopCheck(_ id: UUID) {
        guard var coordinator = stopCoordinators[id] else { return }
        guard run(id)?.status.isActive == true else {
            stopCoordinators[id] = nil
            return
        }
        let actions = coordinator.actions(now: Date())
        stopCoordinators[id] = coordinator
        for action in actions {
            switch action {
            case .closeInput:
                if let process = processes[id] {
                    process.closeInput()
                    process.stop(grace: 1)
                }
            case .forceFinalize:
                forceFinalizeStop(id)
            case .sendInterrupt, .cancelPending:
                break
            }
        }
        if run(id)?.status.isActive == true, !coordinator.isFinished { scheduleStopCheck(id) } else { stopCoordinators[id] = nil }
    }

    /// The agent did not end in time: close everything, settle what was open and mark the session stopped.
    private func forceFinalizeStop(_ id: UUID) {
        guard run(id)?.status.isActive == true else { return }
        if let process = processes[id] {
            process.closeInput()
            process.stop(grace: 1)
        }
        closeCodexServer(id)
        closeClaudeProcess(id)
        closeAcpClient(id)
        processes[id] = nil
        turns[id] = nil
        finishLiveText(id)
        settleOpenWork(id, reason: .stopped)
        expireApprovals(id)
        questions[id] = nil
        update(id) { $0.move(to: .stopped) }
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopForced")))
        holdQueue(id)
        stopCoordinators[id] = nil
    }

    /// A turn ended: nothing may stay "running" (a command that never reported back, a streaming message, an approval
    /// nobody can answer any more). Each way a turn ends has its own reason; settling twice changes nothing.
    func settleOpenWork(_ id: UUID, reason: SettleReason) {
        guard var list = events[id] else { return }
        let settlements = OpenWork.settle(events: list, reason: reason)
        guard !settlements.isEmpty else { return }
        OpenWork.apply(settlements, to: &list)
        events[id] = list
        scheduleEventSave(id)
    }
}
