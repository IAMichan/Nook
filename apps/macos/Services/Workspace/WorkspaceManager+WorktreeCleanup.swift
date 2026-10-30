import Foundation

/// Worktrees that remove themselves when you asked for it (Settings › Workspace): once the session's pull request is
/// merged, or some days after the session settled. The rules are in `WorktreeCleanup`; this looks at the sessions now
/// and then, asks git for uncommitted changes, and removes through the same path as **Delete with worktree** (Git
/// refuses a worktree with changes, so nothing you did not commit is lost). Every removal lands in the audit log.
extension WorkspaceManager {
    /// At most this often: each look asks git about every candidate worktree.
    private static let worktreeCleanupInterval: TimeInterval = 10 * 60

    /// The serialization key for a session's folder (see `FolderLease`).
    func folderKey(_ run: WorkspaceRun) -> String {
        FolderLease.key(run.workingDirectory, machine: run.remote?.machineID)
    }

    func applyWorktreeCleanup(now: Date = Date()) {
        let rules = settings.worktreeCleanupRules
        guard rules.isEnabled, runsLoaded, let git = gitService else { return }
        if let last = worktreeCleanupAt, now.timeIntervalSince(last) < Self.worktreeCleanupInterval { return }
        worktreeCleanupAt = now
        // Candidates for which a rule applies; git is asked only about those.
        var candidates: [(id: UUID, repo: String, path: String, reason: WorktreeCleanup.RemoveReason)] = []
        var seen: Set<String> = []
        for run in runs where run.isolation == .worktree && run.statusDetail != "worktreeRemoved" {
            var facts = worktreeFacts(run)
            guard case .keep(.unknownChanges) = WorktreeCleanup.decide(facts, rules: rules, now: now),
                  let repo = run.repoRoot, let path = run.worktreePath, seen.insert(WorkspacePathPolicy.normalize(path)).inserted else { continue }
            // Which rule applied: decide again as if clean.
            facts.uncommittedFiles = 0
            guard case .remove(let reason) = WorktreeCleanup.decide(facts, rules: rules, now: now) else { continue }
            candidates.append((run.id, repo, path, reason))
        }
        guard !candidates.isEmpty else { return }
        Task { [weak self] in
            for candidate in candidates {
                let path = candidate.path
                let changes = await Task.detached(priority: .utility) { () -> Int? in
                    FileManager.default.fileExists(atPath: path) ? git.changedFileCount(path) : nil
                }.value
                guard let self else { return }
                await self.removeWorktreeByRule(candidate.id, repo: candidate.repo, path: path, changes: changes, rules: rules)
            }
        }
    }

    private func worktreeFacts(_ run: WorkspaceRun) -> WorktreeCleanup.Facts {
        let others = runs.filter { $0.id != run.id }.flatMap { [$0.workingDirectory] + ($0.worktreePath.map { [$0] } ?? []) }
        return WorktreeCleanup.Facts(
            worktree: run.worktreePath, repoRoot: run.repoRoot, isRemote: run.isRemote,
            active: run.status.isActive || processes[run.id] != nil, otherFolders: others,
            pullRequestMerged: PullRequestSync.shared.merged(run.id) || run.prWatch?.state == "merged",
            settled: run.archived || FinishedSessions.shared.contains(FinishedSessions.key(run: run)),
            lastActivity: run.updatedAt)
    }

    /// Decides once more with what git said and the sessions as they are now, then removes.
    private func removeWorktreeByRule(_ id: UUID, repo: String, path: String, changes: Int?, rules: WorktreeCleanup.Rules) async {
        guard let run = run(id), run.worktreePath == path else { return }
        var facts = worktreeFacts(run)
        facts.uncommittedFiles = changes
        guard case .remove(let reason) = WorktreeCleanup.decide(facts, rules: rules, now: Date()) else { return }
        let why = reason == .mergedPullRequest ? "pull request merged" : "settled \(rules.daysAfterSettled) days"
        do {
            try await removeWorktree(repo: repo, path: path, force: false)
            onAudit?("worktree_cleanup", "\(AgentPathFormat.tilde(path)) · \(why)", "removed")
            append(id, RunEvent(kind: .system, text: tr(reason == .mergedPullRequest ? "ws.worktree.cleanedMerged" : "ws.worktree.cleanedSettled")))
        } catch {
            onAudit?("worktree_cleanup", "\(AgentPathFormat.tilde(path)) · \(why)", "kept: \(error.localizedDescription)")
        }
    }
}

extension WorkspaceManager {
    /// At most this often: each sweep lists the temporary folders, scratchpads and DerivedData.
    private static let buildLeftoversInterval: TimeInterval = 6 * 60 * 60

    /// Builds agents left where removing a worktree does not reach (see `BuildLeftovers`). Every removal lands in the
    /// audit log.
    func sweepBuildLeftovers(now: Date = Date()) {
        guard settings.buildLeftoverCleanup else { return }
        if let last = buildLeftoversAt, now.timeIntervalSince(last) < Self.buildLeftoversInterval { return }
        buildLeftoversAt = now
        Task.detached(priority: .background) { [weak self] in
            let removed = BuildLeftovers.sweep()
            guard !removed.isEmpty else { return }
            await MainActor.run {
                for item in removed {
                    self?.onAudit?("build_cleanup", "\(AgentPathFormat.tilde(item.leftover.url.path)) · \(item.leftover.kind.rawValue)",
                                   "removed \(DiskUsage.format(item.bytes))")
                }
            }
        }
    }
}
