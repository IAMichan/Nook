import Foundation

// One prompt to several models (see `ModelComparison`).

extension WorkspaceManager {
    /// Starts one session per configuration, one after the other (each `git worktree add` on the same repository waits
    /// for the last). The first that starts leads the group; every later one points at it, so the Agents list shows them
    /// under it. A failure does not stop the others; the outcome says which target failed and why.
    func startComparison(_ configs: [NewRunConfig], targets: [ComparisonTarget]) async -> ModelComparison.Outcome {
        var outcome = ModelComparison.Outcome()
        for (config, target) in zip(configs, targets) {
            var config = config
            config.lineage = ModelComparison.lineage(leader: outcome.leader)
            do {
                let id = try await start(config)
                outcome.started.append((target, id))
            } catch {
                outcome.failed.append((target, error.localizedDescription))
            }
        }
        // The group opens on its first session.
        if let leader = outcome.leader { selectedRunID = leader }
        return outcome
    }
}
