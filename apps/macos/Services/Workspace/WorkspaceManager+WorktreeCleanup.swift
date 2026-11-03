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
        // Worktrees: Nook's own (`<root>/<repo>/<name>`), the sessions' wherever they are, and Claude Code's in the
        // repositories Nook works in (`<repo>/.claude/worktrees/<name>`).
        let local = runs.filter { !$0.isRemote }
        let sessionWorktrees = local.compactMap(\.worktreePath)
        let containers = [(settings.worktreeRoot, 2)] + Set(local.compactMap(\.repoRoot)).map { ($0 + "/.claude/worktrees", 1) }
        Task.detached(priority: .background) { [weak self] in
            var worktrees = Set(sessionWorktrees.map { URL(fileURLWithPath: $0) })
            for (container, depth) in containers {
                var level = [URL(fileURLWithPath: (container as NSString).expandingTildeInPath)]
                for _ in 0..<depth {
                    level = level.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                }
                worktrees.formUnion(level)
            }
            let removed = BuildLeftovers.sweep(.standard(worktrees: Array(worktrees)))
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

extension WorkspaceManager {
    /// A session of its own worktree on this Mac whose folder is gone: removed after its pull request merged, after it
    /// settled, or by hand.
    func needsWorktreeReopen(_ run: WorkspaceRun) -> Bool {
        guard !run.isRemote, run.isolation == .worktree, run.repoRoot != nil, let path = run.worktreePath,
              WorkspacePathPolicy.normalize(path) == WorkspacePathPolicy.normalize(run.workingDirectory) else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// Makes the session's worktree again at the same path (the agent's conversation is kept per folder), then sends the
    /// message. Its own branch comes back while its work is not done; after the pull request merged, new work starts on
    /// a new branch from the base, so it gets a pull request of its own. Messages sent meanwhile wait in the queue.
    func reopenWorktree(_ id: UUID, message: String, shown: Bool) {
        guard let run = run(id), let git = gitService, let repo = run.repoRoot, let path = run.worktreePath,
              reopeningWorktrees.insert(id).inserted else { return }
        let merged = PullRequestSync.shared.merged(id) || run.prWatch?.state == "merged"
        let branch = run.branch
        let base = run.baseBranch
        let newBranch = ProjectSettings.branchName(WorktreeNaming.branchName(task: message, id: UUID()),
                                                   globalPrefix: WorktreeNaming.branchPrefix,
                                                   projectPrefix: settings.sessionDefaults(for: repo).branchPrefix)
        let refreshBase = base.map { shouldRefreshRemoteBase(root: repo, base: $0) } ?? false
        let gone = tr("ws.error.folderGone", path)
        Task { [weak self] in
            let result: Result<WorktreeCleanup.Reopen, Error>
            do {
                let plan = try await FolderLease.shared.run(FolderLease.key(repo), priority: .userInitiated) { () throws -> WorktreeCleanup.Reopen in
                    git.pruneWorktrees(repo)
                    let exists = branch.map { git.localBranchExists($0, in: repo) } ?? false
                    let plan = WorktreeCleanup.reopen(branch: branch, branchExists: exists, merged: merged, base: base, newBranch: newBranch)
                    switch plan {
                    case .branch(let name): try git.addWorktree(repo: repo, path: path, existingBranch: name)
                    case .newBranch(let name, let base): try git.addWorktree(repo: repo, path: path, branch: name, base: base, refreshBase: refreshBase)
                    case .impossible: throw GitError(gone)
                    }
                    return plan
                }
                result = .success(plan)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.reopeningWorktrees.remove(id)
            guard self.run(id) != nil else { return }
            switch result {
            case .failure(let error):
                self.append(id, RunEvent(kind: .error, text: tr("ws.worktree.reopenFailed", error.localizedDescription)))
                return
            case .success(.newBranch(let name, _)):
                self.followBranch(id, to: name)
                if self.run(id)?.prWatch != nil { self.watchPullRequest(id, url: nil) }
                self.append(id, RunEvent(kind: .system, text: tr("ws.worktree.reopenedNewBranch", name, AgentPathFormat.tilde(path))))
            case .success:
                self.append(id, RunEvent(kind: .system, text: tr("ws.worktree.reopened", AgentPathFormat.tilde(path))))
            }
            if self.run(id)?.statusDetail == "worktreeRemoved" { self.update(id) { $0.statusDetail = nil } }
            self.refreshGit(id)
            self.refreshWorktrees()
            if shown { self.sendHidden(id, text: message) } else { self.send(id, text: message) }
            // The project's setup (nook.json `runOnWorktreeCreate`), as for a new worktree.
            let setup = await Task.detached(priority: .userInitiated) { ProjectScripts.load(folder: path) }.value
            for script in setup where script.runOnWorktreeCreate {
                self.runScript?(path, script.command, script.name)
                self.append(id, RunEvent(kind: .system, text: tr("ws.event.setupScript", script.name)))
            }
        }
    }
}

extension WorkspaceManager {
    /// A file the conversation links to that is not at its path any more, found again. Its worktree was removed (after
    /// the pull request merged, after it settled, or by hand), or made again without the drafts it had: its
    /// `.scratch` copy from `WorktreeArchive`, else the file as committed on the session's branch or, once merged, its
    /// base (written to the caches). A link by file name alone, resolved against the worktree's root, finds the render
    /// of that name in `.scratch`. Nil when it is in none of those.
    func recoverFile(_ path: String) async -> String? {
        let candidates = runs.filter { !$0.isRemote && $0.repoRoot != nil }
            .compactMap { run -> (run: WorkspaceRun, root: String, relative: String)? in
                guard let root = run.worktreePath, let relative = WorktreeArchive.relativePath(path, in: root) else { return nil }
                return (run, root, relative)
            }
        guard let match = candidates.first, let repo = match.run.repoRoot else { return nil }
        let root = match.root
        let relative = match.relative
        let refs = [match.run.branch, match.run.baseBranch].compactMap { $0 }.flatMap { [$0, "origin/" + $0] }
        let git = gitService
        return await Task.detached(priority: .userInitiated) { () -> String? in
            if let kept = WorktreeArchive.archived(path, worktree: root) { return kept }
            if !relative.contains("/") {
                let archive = WorktreeArchive.location(worktree: root).path
                if let found = WorktreeArchive.scratchFile(named: relative, in: root) ?? WorktreeArchive.scratchFile(named: relative, in: archive) {
                    return found
                }
            }
            guard let git, FileManager.default.fileExists(atPath: repo) else { return nil }
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Nook/Worktree files", isDirectory: true)
            for ref in refs {
                let destination = WorktreeArchive.location(worktree: root, root: caches).appendingPathComponent(ref)
                    .appendingPathComponent(relative)
                if git.exportFile(repo: repo, ref: ref, path: relative, to: destination) { return destination.path }
            }
            return nil
        }.value
    }
}
