import Foundation

/// The checklist a new worktree shows while it is set up (`WorktreeSetupProgress`): its steps as they really run, and
/// the end of it once the agent answers.
extension WorkspaceManager {
    /// Changes the setup of session `id`, if it has one under way.
    func setupStep(_ id: UUID, _ change: (inout WorktreeSetupProgress) -> Void) {
        guard var progress = worktreeSetups[id] else { return }
        change(&progress)
        worktreeSetups[id] = progress
    }

    func recordFetch(_ id: UUID, _ result: RemoteBaseRefresh, base: String, now: Date = Date()) {
        setupStep(id) {
            switch result {
            case .fetched:
                $0.finish(.fetchBase, now: now)
                $0.note(.fetchBase, tr("ws.setup.note.fetched", base))
            case .local:
                $0.skip(.fetchBase)
                $0.note(.fetchBase, tr("ws.setup.note.localBase", base))
            case .failed(let message):
                // Offline or without access: the worktree starts from what was fetched last, so the setup goes on.
                $0.finish(.fetchBase, now: now)
                $0.note(.fetchBase, tr("ws.setup.note.fetchFailed", base, message))
            }
        }
    }

    /// Called for every event of a session: the agent's first output ends "Start agent", and with it the checklist.
    func noteSetupEvent(_ id: UUID, _ event: RunEvent) {
        guard let progress = worktreeSetups[id], progress.isRunning(.startAgent) else { return }
        switch event.kind {
        case .assistant, .thinking, .tool, .fileChange, .approval, .result, .page:
            worktreeSetups[id] = nil
        case .error:
            setupStep(id) { $0.fail(.startAgent, event.text) }
        case .user, .system:
            break
        }
    }

    /// A turn that starts later (your next message after a setup that failed or was stopped) has no setup to show; only
    /// the first turn, launched while the session is still preparing, keeps it.
    func dropFinishedSetup(_ id: UUID) {
        guard let progress = worktreeSetups[id] else { return }
        if progress.isRunning(.startAgent), run(id)?.status == .preparing { return }
        worktreeSetups[id] = nil
    }

    /// The checklist to show for a session right now: while it is set up, and after a setup that failed or was stopped
    /// until the next turn. Nil once the agent runs, and when the setup ended with the session waiting for your message.
    func visibleSetup(_ run: WorkspaceRun) -> WorktreeSetupProgress? {
        guard let progress = worktreeSetups[run.id] else { return nil }
        if run.status.isActive { return progress }
        if run.status == .failed || run.status == .stopped { return progress }
        return nil
    }
}
