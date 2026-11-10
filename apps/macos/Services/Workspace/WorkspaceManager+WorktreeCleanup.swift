import Foundation

/// Worktrees that remove themselves when you asked for it (Settings › Workspace): once the session's pull request is
/// merged, some days after the session settled or went quiet, when it holds nothing beyond its base, or when its last
/// session is deleted. Every rule is off by default. The rules are in `WorktreeCleanup`; this looks at the sessions at
/// launch and every hour (or when you press "Clean up now"), asks git about the worktrees a rule applies to, and removes
/// through the same path as **Delete with worktree**. What it did, and the folders no session uses, is in
/// `worktreeCleanupReport`; every removal lands in the audit log too. The branch stays, and the session's next message
/// makes the worktree again (`reopenWorktree`).
extension WorkspaceManager {
    /// At most this often by itself: each look asks git about every candidate worktree.
    private static let worktreeCleanupInterval: TimeInterval = 60 * 60

    private struct CleanupCandidate: Sendable {
        var id: UUID
        var repo: String
        var path: String
        var title: String
        var base: String?
        var rules: WorktreeCleanup.Rules
    }

    /// The serialization key for a session's folder (see `FolderLease`).
    func folderKey(_ run: WorkspaceRun) -> String {
        FolderLease.key(run.workingDirectory, machine: run.remote?.machineID)
    }

    /// By the clock: at launch, then hourly.
    func applyWorktreeCleanup(now: Date = Date()) {
        guard runsLoaded, gitService != nil else { return }
        if let last = worktreeCleanupAt, now.timeIntervalSince(last) < Self.worktreeCleanupInterval { return }
        worktreeCleanupAt = now
        runWorktreeCleanup(trigger: .automatic, now: now)
    }

    /// "Clean up now" in Settings: the rules that are on, at once, with a fresh report (also of unused folders).
    func cleanUpWorktreesNow() {
        worktreeCleanupAt = Date()
        runWorktreeCleanup(trigger: .manual, now: Date())
    }

    /// A rule changed: it applies at the next look, not an hour later.
    func worktreeCleanupRulesChanged() {
        worktreeCleanupAt = nil
        applyWorktreeCleanup()
    }

    private func runWorktreeCleanup(trigger: WorktreeCleanupReport.Trigger, now: Date) {
        guard runsLoaded, let git = gitService, !worktreeCleanupRunning else { return }
        let terminals = openTerminalFolders?() ?? []
        var candidates: [CleanupCandidate] = []
        var kept: [WorktreeCleanupReport.Entry] = []
        var seen: Set<String> = []
        for run in runs where run.isolation == .worktree && run.statusDetail != "worktreeRemoved" {
            guard let repo = run.repoRoot, let path = run.worktreePath,
                  seen.insert(WorkspacePathPolicy.normalize(path)).inserted else { continue }
            let rules = settings.worktreeCleanupRules(for: repo)
            switch WorktreeCleanup.decide(worktreeFacts(run, terminals: terminals), rules: rules, now: now) {
            case .keep(.unknownChanges):
                candidates.append(CleanupCandidate(id: run.id, repo: repo, path: path, title: run.title, base: run.baseBranch, rules: rules))
            case .keep(let reason) where !reason.isQuiet:
                kept.append(.init(path: path, title: run.title, outcome: .kept, reason: reason.rawValue))
            default:
                continue
            }
        }
        // Unused folders: in Nook's worktree folder (`<root>/<repo>/<name>`), used by no session at all.
        let root = (settings.worktreeRoot as NSString).expandingTildeInPath
        let used = runs.flatMap { [$0.workingDirectory] + ($0.worktreePath.map { [$0] } ?? []) }
        worktreeCleanupRunning = true
        Task { [weak self] in
            var entries = kept
            for candidate in candidates {
                let path = candidate.path
                let facts = await Task.detached(priority: .utility) { () -> WorktreeCleanup.GitFacts?? in
                    // Outer nil: the folder is gone; inner nil: git could not read it.
                    guard FileManager.default.fileExists(atPath: path) else { return nil }
                    return .some(Self.gitFacts(git, path: path, keepWhen: candidate.rules.keepWhen, base: candidate.base))
                }.value
                guard let self else { return }
                // The folder is gone already: nothing to remove, nothing to report.
                guard let found = facts else { continue }
                guard let gitFacts = found else {
                    entries.append(.init(path: path, title: candidate.title, outcome: .failed, reason: tr("ws.cleanup.gitUnreadable")))
                    continue
                }
                if let entry = await self.removeWorktreeByRule(candidate, git: gitFacts) { entries.append(entry) }
            }
            let orphans = await Task.detached(priority: .background) { () -> [WorktreeCleanupReport.Orphan] in
                Self.unusedWorktreeFolders(root: root, used: used, now: now)
                    .map { WorktreeCleanupReport.Orphan(path: $0, bytes: DiskUsage.allocatedSize(of: $0)) }
            }.value
            guard let self else { return }
            let report = WorktreeCleanupReport(trigger: trigger, startedAt: now, finishedAt: Date(), entries: entries, orphans: orphans)
            self.worktreeCleanupReport = report
            report.save()
            self.worktreeCleanupRunning = false
        }
    }

    nonisolated private static func gitFacts(_ git: GitService, path: String, keepWhen: WorktreeCleanup.KeepWhen,
                                             base: String?) -> WorktreeCleanup.GitFacts? {
        guard let changes = git.localChangeCount(path, keepWhen: keepWhen) else { return nil }
        return WorktreeCleanup.GitFacts(localChanges: changes, unpushedCommits: git.unpushedCommitCount(path),
                                        aheadOfBase: base.flatMap { git.divergence(path, base: $0)?.ahead },
                                        branch: git.currentBranch(path))
    }

    nonisolated private static func unusedWorktreeFolders(root: String, used: [String], now: Date) -> [String] {
        let fm = FileManager.default
        var folders: [(path: String, modified: Date)] = []
        let repos = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []
        for repo in repos {
            let names = (try? fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
            for folder in names {
                let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory == true else { continue }
                folders.append((folder.path, values?.contentModificationDate ?? .distantPast))
            }
        }
        return WorktreeCleanup.orphans(candidates: folders, used: used, now: now)
    }

    private func worktreeFacts(_ run: WorkspaceRun, terminals: [String]) -> WorktreeCleanup.Facts {
        let others = runs.filter { $0.id != run.id }.flatMap { [$0.workingDirectory] + ($0.worktreePath.map { [$0] } ?? []) }
        let root = run.worktreePath.map(WorkspacePathPolicy.normalize)
        let terminal = root.map { root in
            terminals.map(WorkspacePathPolicy.normalize).contains { $0 == root || $0.hasPrefix(root + "/") }
        } ?? false
        let symlink = run.worktreePath.map {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSymbolicLink
        } ?? false
        return WorktreeCleanup.Facts(
            worktree: run.worktreePath, repoRoot: run.repoRoot, isRemote: run.isRemote,
            active: run.status.isActive || processes[run.id] != nil, openTerminal: terminal, isSymlink: symlink,
            otherFolders: others,
            pullRequestMerged: PullRequestSync.shared.merged(run.id) || run.prWatch?.state == "merged",
            settled: run.archived || FinishedSessions.shared.contains(FinishedSessions.key(run: run)),
            lastActivity: run.updatedAt, branch: run.branch)
    }

    /// Decides once more with what git said and the sessions as they are now, then removes. The report's line for it;
    /// nil when no rule applies any more.
    private func removeWorktreeByRule(_ candidate: CleanupCandidate, git gitFacts: WorktreeCleanup.GitFacts) async -> WorktreeCleanupReport.Entry? {
        guard let run = run(candidate.id), run.worktreePath == candidate.path else { return nil }
        let path = candidate.path
        var facts = worktreeFacts(run, terminals: openTerminalFolders?() ?? [])
        facts.git = gitFacts
        switch WorktreeCleanup.decide(facts, rules: candidate.rules, now: Date()) {
        case .keep(let reason):
            return reason.isQuiet ? nil : .init(path: path, title: candidate.title, outcome: .kept, reason: reason.rawValue)
        case .remove(let reason):
            let bytes = await Task.detached(priority: .utility) { DiskUsage.allocatedSize(of: path) }.value
            do {
                try await removeWorktree(repo: candidate.repo, path: path, force: candidate.rules.keepWhen.forcesRemoval)
                onAudit?("worktree_cleanup", "\(AgentPathFormat.tilde(path)) · \(reason.rawValue)", "removed")
                append(candidate.id, RunEvent(kind: .system, text: Self.cleanedMessage(reason)))
                return .init(path: path, title: candidate.title, outcome: .removed, reason: reason.rawValue, bytes: bytes)
            } catch {
                onAudit?("worktree_cleanup", "\(AgentPathFormat.tilde(path)) · \(reason.rawValue)", "kept: \(error.localizedDescription)")
                return .init(path: path, title: candidate.title, outcome: .failed, reason: error.localizedDescription)
            }
        }
    }

    /// When the session started or you last wrote to it, whichever is later (for "settle once its pull request merged").
    func lastWrittenAt(_ id: UUID) -> Date? {
        guard let run = run(id) else { return nil }
        let written = events[id]?.last { $0.kind == .user }?.date
        return max(run.createdAt, written ?? .distantPast)
    }

    static func cleanedMessage(_ reason: WorktreeCleanup.RemoveReason) -> String {
        switch reason {
        case .mergedPullRequest: return tr("ws.worktree.cleanedMerged")
        case .settled: return tr("ws.worktree.cleanedSettled")
        case .inactive: return tr("ws.worktree.cleanedInactive")
        case .unchanged: return tr("ws.worktree.cleanedUnchanged")
        case .deletedSession: return tr("ws.worktree.removed")
        }
    }

    /// `Rules.onDeletedSession`: the worktree a deleted session left unused goes too, under the same guards as the
    /// sweep. One that is kept is listed among the unused folders at the next cleanup.
    func cleanUpWorktreeAfterDelete(repo: String, path: String, branch: String?) {
        let rules = settings.worktreeCleanupRules(for: repo)
        guard rules.onDeletedSession, let git = gitService else { return }
        let terminals = openTerminalFolders?() ?? []
        let others = runs.flatMap { [$0.workingDirectory] + ($0.worktreePath.map { [$0] } ?? []) }
        let normalized = WorkspacePathPolicy.normalize(path)
        var facts = WorktreeCleanup.Facts(
            worktree: path, repoRoot: repo, openTerminal: terminals.map(WorkspacePathPolicy.normalize).contains { $0 == normalized || $0.hasPrefix(normalized + "/") },
            otherFolders: others, lastActivity: Date(), branch: branch)
        Task { [weak self] in
            let gitFacts = await Task.detached(priority: .utility) { () -> WorktreeCleanup.GitFacts? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return Self.gitFacts(git, path: path, keepWhen: rules.keepWhen, base: nil)
            }.value
            guard let self, let gitFacts else { return }
            facts.git = gitFacts
            guard case .remove = WorktreeCleanup.decideAfterDelete(facts, rules: rules) else {
                self.onAudit?("worktree_cleanup", "\(AgentPathFormat.tilde(path)) · deletedSession", "kept")
                return
            }
            do {
                try await self.removeWorktree(repo: repo, path: path, force: rules.keepWhen.forcesRemoval)
                self.onAudit?("worktree_cleanup", "\(AgentPathFormat.tilde(path)) · deletedSession", "removed")
                ToastCenter.shared.success(tr("ws.worktree.removed"))
            } catch {
                self.onAudit?("worktree_cleanup", "\(AgentPathFormat.tilde(path)) · deletedSession", "kept: \(error.localizedDescription)")
            }
        }
    }
}

extension WorktreeCleanupReport {
    static func load(_ defaults: UserDefaults = .standard) -> WorktreeCleanupReport? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(WorktreeCleanupReport.self, from: $0) }
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension WorkspaceManager {
    /// At most this often: each sweep lists the temporary folders, scratchpads and DerivedData.
    private static let buildLeftoversInterval: TimeInterval = 6 * 60 * 60

    /// Builds agents left where removing a worktree does not reach (see `BuildLeftovers`), and the installed
    /// dependencies of worktrees nobody used for a week. Every removal lands in the audit log. `force` skips the
    /// interval (the disk runs low); `done` gets the bytes freed.
    func sweepBuildLeftovers(now: Date = Date(), force: Bool = false, done: ((Int64) -> Void)? = nil) {
        guard settings.buildLeftoverCleanup else { done?(0); return }
        if !force, let last = buildLeftoversAt, now.timeIntervalSince(last) < Self.buildLeftoversInterval { return }
        buildLeftoversAt = now
        // Worktrees: Nook's own (`<root>/<repo>/<name>`), the sessions' wherever they are, and Claude Code's in the
        // repositories Nook works in (`<repo>/.claude/worktrees/<name>`).
        let local = runs.filter { !$0.isRemote }
        let sessionWorktrees = local.compactMap(\.worktreePath)
        let containers = [(settings.worktreeRoot, 2)] + Set(local.compactMap(\.repoRoot)).map { ($0 + "/.claude/worktrees", 1) }
        // In use within a week: a session runs or ran there, or a terminal is open there. Everything else is idle.
        let recent = now.addingTimeInterval(-BuildLeftovers.idleAge)
        let busy = local.filter { $0.status.isActive || processes[$0.id] != nil || $0.updatedAt > recent }
            .flatMap { [$0.workingDirectory] + ($0.worktreePath.map { [$0] } ?? []) }
            + (openTerminalFolders?() ?? [])
        let mainCheckouts = Set(local.compactMap(\.repoRoot).map(WorkspacePathPolicy.normalize))
        Task.detached(priority: .background) { [weak self] in
            var worktrees = Set(sessionWorktrees.map { URL(fileURLWithPath: $0) })
            for (container, depth) in containers {
                var level = [URL(fileURLWithPath: (container as NSString).expandingTildeInPath)]
                for _ in 0..<depth {
                    level = level.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                }
                worktrees.formUnion(level)
            }
            let idle = worktrees.filter { BuildLeftovers.isIdle($0.path, busy: busy, mainCheckouts: mainCheckouts) }
            let removed = BuildLeftovers.sweep(.standard(worktrees: Array(worktrees), idleWorktrees: Array(idle)))
            await MainActor.run {
                for item in removed {
                    self?.onAudit?("build_cleanup", "\(AgentPathFormat.tilde(item.leftover.url.path)) · \(item.leftover.kind.rawValue)",
                                   "removed \(DiskUsage.format(item.bytes))")
                }
                done?(removed.reduce(0) { $0 + $1.bytes })
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
        let checkout = worktreeCheckout(git, root: repo)
        Task { [weak self] in
            let result: Result<WorktreeCleanup.Reopen, Error>
            do {
                let plan = try await FolderLease.shared.run(FolderLease.key(repo), priority: .userInitiated) { () throws -> WorktreeCleanup.Reopen in
                    git.pruneWorktrees(repo)
                    let exists = branch.map { git.localBranchExists($0, in: repo) } ?? false
                    let onRemote = !exists && (branch.map { git.remoteBranchExists($0, in: repo) } ?? false)
                    let plan = WorktreeCleanup.reopen(branch: branch, branchExists: exists, remoteBranchExists: onRemote,
                                                      merged: merged, base: base, newBranch: newBranch)
                    var cloned = false
                    switch plan {
                    case .branch(let name): try git.addWorktree(repo: repo, path: path, existingBranch: name)
                    case .remoteBranch(let name): try git.addWorktree(repo: repo, path: path, remoteBranch: name)
                    case .newBranch(let name, let base):
                        cloned = try git.addWorktree(repo: repo, path: path, branch: name, base: base, refreshBase: refreshBase,
                                                     checkoutCache: checkout.cache)
                    case .impossible: throw GitError(gone)
                    }
                    // A submodule that fails to check out leaves the worktree usable; the agent sees the folder as it is.
                    _ = Self.finishWorktree(git, checkout: checkout, root: repo, path: path, cloned: cloned)
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

extension WorkspaceManager {
    /// At most this often: reading the free space is cheap, but nothing fills a disk within minutes.
    private static let diskSpaceInterval: TimeInterval = 5 * 60

    /// When the startup disk runs low (`DiskSpace`): first frees what is safe to free at once (build leftovers and the
    /// cleanup rules you switched on, without waiting for their interval), then says how much is free and what the
    /// worktrees take, once until the disk recovered.
    func watchDiskSpace(now: Date = Date()) {
        if let last = diskSpaceCheckedAt, now.timeIntervalSince(last) < Self.diskSpaceInterval { return }
        diskSpaceCheckedAt = now
        guard let available = DiskSpace.available() else { return }
        let wasLow = diskSpaceLow
        diskSpaceLow = DiskSpace.isLow(available: available, wasLow: wasLow)
        guard diskSpaceLow, !wasLow else { return }
        worktreeCleanupAt = nil
        applyWorktreeCleanup(now: now)
        let root = (settings.worktreeRoot as NSString).expandingTildeInPath
        sweepBuildLeftovers(now: now, force: true) { [weak self] freed in
            Task { [weak self] in
                let worktrees = await Task.detached(priority: .utility) { DiskUsage.allocatedSize(of: root) }.value
                guard let self else { return }
                let free = DiskSpace.available() ?? available
                self.onAudit?("disk_space", "\(DiskUsage.format(free)) free", "freed \(DiskUsage.format(freed))")
                // Freeing lifted it above the limit: nothing to say, and the next drop says it.
                guard free < DiskSpace.lowBytes else { self.diskSpaceLow = false; return }
                self.onLowDiskSpace?(free, freed, worktrees)
            }
        }
    }
}
