import Foundation

/// Each session's git status, diffs, commits and pushes, and the Worktrees list.
extension WorkspaceManager {
    /// Reads the session's git status off the main thread. `quiet` (the refreshes Nook schedules itself as an agent
    /// writes): no spinner, and a result equal to the last one publishes nothing, so a busy session in one window does
    /// not redraw every other window, nor make the panels look up the branch again, while its files stay the same.
    /// One read per session at a time: an ask while it runs is folded into a single read after it.
    func refreshGit(_ id: UUID, quiet: Bool = false) {
        guard let run = run(id), let git = sessionGit(for: run), run.repoRoot != nil else { return }
        if gitRefresh.reading.contains(id) {
            gitRefresh.again[id] = (gitRefresh.again[id] ?? true) && quiet
            if !quiet { showGitLoading(id) }
            return
        }
        gitRefresh.reading.insert(id)
        if !quiet || self.git[id] == nil { showGitLoading(id) }
        let directory = run.workingDirectory
        let base = run.baseBranch
        let cachedPoint = gitRefresh.branchPoints[id].flatMap { Date().timeIntervalSince($0.at) < GitRefreshState.branchPointMaxAge ? $0 : nil }
        let knownBranch = run.branch
        Task.detached(priority: .utility) {
            var status: GitStatus?
            var passed: [String] = []
            var problem: String?
            var divergence: (ahead: Int, behind: Int)?
            var branch: (changes: [GitFileChange], point: GitRefreshState.BranchPoint)?
            if git.remote != nil || FileManager.default.fileExists(atPath: directory) {
                do { status = try git.status(directory) } catch let failure { problem = failure.localizedDescription }
                if let base { divergence = git.divergence(directory, base: base) }
                // What the row counts is what its hover card and the Changes panel show: the branch since it left its
                // base, committed work included (`FolderGitModel`). A session on another machine counts what is not
                // committed, as its review there does.
                if git.remote == nil, let status { branch = Self.branchChanges(git, directory: directory, status: status, cached: cachedPoint) }
                // The session is on another branch than at the last read: the branches it went through in between
                // (an agent that opens several pull requests in one turn) are its earlier branches too.
                if let status, !status.detached, let now = status.branch, let knownBranch, now != knownBranch,
                   let reflog = try? git.run(["log", "-g", "--format=%gs", "-n", "200", "HEAD"], in: directory) {
                    passed = SessionBranches.passed(reflog: reflog.components(separatedBy: "\n"), from: knownBranch, to: now)
                }
            } else {
                problem = tr("ws.error.folderGone", directory)
            }
            let result = (status: status, divergence: divergence, problem: problem)
            let branchResult = branch
            let passedBranches = passed
            await MainActor.run { [weak self] in
                // A session deleted while git was read leaves nothing behind.
                guard let self, self.run(id) != nil else { return }
                self.gitRefresh.reading.remove(id)
                let again = self.gitRefresh.again.removeValue(forKey: id)
                let previous = self.git[id]
                // Still loading when a refresh with the spinner follows straight away.
                var next = GitSnapshot(status: result.status, divergence: result.divergence, error: result.problem,
                                       updated: Date(), loading: again == false)
                // Nothing changed: a quiet read keeps the snapshot's `updated`, so nothing looks at the branch again.
                if quiet, let previous, previous.sameContent(as: next) { next.updated = previous.updated }
                if next != previous { self.git[id] = next }
                if let status = result.status {
                    if let branchResult { self.gitRefresh.branchPoints[id] = branchResult.point }
                    let counted = branchResult?.changes ?? status.files
                    let added = counted.reduce(0) { $0 + ($1.added ?? 0) }
                    let removed = counted.reduce(0) { $0 + ($1.removed ?? 0) }
                    self.update(id, save: false) {
                        $0.changedFiles = counted.count
                        $0.changedLinesAdded = added
                        $0.changedLinesRemoved = removed
                    }
                    // A branch the agent (or you) switched to becomes the session's own.
                    if !status.detached, let branch = status.branch { self.followBranch(id, to: branch, passing: passedBranches) }
                }
                if let again { self.refreshGit(id, quiet: again) }
            }
        }
    }

    /// The branch's changes since where it left its base, else (no base, or git cannot tell) what is not committed.
    nonisolated private static func branchChanges(_ git: GitService, directory: String, status: GitStatus,
                                                  cached: GitRefreshState.BranchPoint?) -> (changes: [GitFileChange], point: GitRefreshState.BranchPoint) {
        let commits = git.headCommits(directory).joined(separator: ",")
        let key = "\(status.branch ?? "")|\(status.upstream ?? "")|\(status.ahead)|\(status.behind)|\(status.detached)|\(commits)"
        let point: GitRefreshState.BranchPoint
        if let cached, cached.key == key {
            point = cached
        } else {
            let comparison = git.branchComparison(directory, status: status, remotes: git.remotes(directory))
            point = GitRefreshState.BranchPoint(key: key, point: comparison.point, at: Date())
        }
        let changes = point.point.flatMap { try? git.changes(directory, since: $0, status: status) } ?? status.files
        return (changes, point)
    }

    func showGitLoading(_ id: UUID) {
        var snapshot = self.git[id] ?? GitSnapshot(status: nil, divergence: nil, error: nil, updated: Date(), loading: false)
        guard !snapshot.loading else { return }
        snapshot.loading = true
        self.git[id] = snapshot
    }

    func scheduleGitRefresh(_ id: UUID, delay: TimeInterval) {
        gitRefresh.refreshes[id]?.cancel()
        gitRefresh.refreshes[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshGit(id, quiet: true)
        }
    }

    func diff(_ id: UUID, file: GitFileChange, options: DiffReadOptions = .standard) async throws -> String {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        return try await Task.detached(priority: .userInitiated) {
            try git.diff(directory, file: file, ignoreWhitespace: options.ignoreWhitespace)
        }.value
    }

    /// What one turn (from `start` to `end`) did to a file: between the snapshots around it when the session has them,
    /// otherwise the file against its last commit.
    func turnDiff(_ id: UUID, path: String, start: Date, end: Date, options: DiffReadOptions = .standard) async throws -> String {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        let around = TurnChanges.checkpoints(run.checkpoints ?? [], start: start, end: end)
        let from = around?.before.ref ?? "HEAD"
        let to = around?.after?.ref
        return try await Task.detached(priority: .userInitiated) {
            try git.diff(directory, path: path, from: from, to: to, ignoreWhitespace: options.ignoreWhitespace)
        }.value
    }

    /// The lines one turn added and removed per file (between the same snapshots as `turnDiff`), keyed by the path
    /// relative to the session's folder. Binary files count as nothing. With a snapshot on both sides of the turn these
    /// are all the files it changed, also by a command or script (`sed`, a formatter) that no edit of the agent shows;
    /// otherwise only `paths`, against the last commit or the files as they are now. When the turn pulled, merged or
    /// rebased, the files Git brought in are left out unless the turn edited, committed or fixed a conflict in them
    /// (`GitService.authoredPaths`); restoring a snapshot still brings back everything.
    func turnLines(_ id: UUID, paths: [String], start: Date, end: Date) async throws -> TurnLines {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        let around = TurnChanges.checkpoints(run.checkpoints ?? [], start: start, end: end)
        let from = around?.before.ref ?? "HEAD"
        let to = around?.after?.ref
        let since = around?.before.date ?? start
        let complete = to != nil
        // A file outside the folder (the agent's own settings, say) would make git refuse the whole list.
        let root = directory.hasSuffix("/") ? directory : directory + "/"
        let inside = complete ? nil : paths.filter { !$0.hasPrefix("/") || $0.hasPrefix(root) }
        let counts = try await Task.detached(priority: .utility) {
            let authored = to.flatMap { git.authoredPaths(directory, from: from, to: $0, since: since) }
            return try git.lineCounts(directory, paths: inside, from: from, to: to, authored: authored)
        }.value
        return TurnLines(counts: counts.mapValues { EditLines(added: $0.added ?? 0, removed: $0.removed ?? 0) }, complete: complete)
    }

    func commit(_ id: UUID, message: String, paths: [String]) async throws -> String {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        guard !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        let directory = run.workingDirectory
        let sha = try await Task.detached(priority: .userInitiated) { try git.commit(directory, message: message, paths: paths) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.event.committed", sha, ToolSummary.oneLine(message, 80))))
        markReviewed(id)
        refreshGit(id)
        return sha
    }

    func push(_ id: UUID) async throws {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        guard let branch = await Task.detached(operation: { git.currentBranch(directory) }).value else {
            throw StartError.git(tr("ws.error.detached"))
        }
        let remote = await Task.detached(operation: { git.remotes(directory).contains("origin") ? "origin" : (git.remotes(directory).first ?? "origin") }).value
        try await Task.detached(priority: .userInitiated) { try git.push(directory, remote: remote, branch: branch) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.event.pushed", branch, remote)))
        refreshGit(id)
    }

    /// owner/repo from remote URL if it is a GitHub repository.
    func githubRepository(_ id: UUID) async -> String? {
        guard let run = run(id), let git = sessionGit(for: run) else { return nil }
        let directory = run.workingDirectory
        let url = await Task.detached(operation: { git.remoteURL(directory) }).value
        return url.flatMap(GitHubRemote.repository(from:))
    }

    /// The forge of the session's folder (GitHub, GitLab, Bitbucket…), from its remote; nil without a recognisable remote.
    func remoteRepository(_ id: UUID) async -> RemoteRepository? {
        guard let run = run(id), let git = sessionGit(for: run) else { return nil }
        let directory = run.workingDirectory
        let url = await Task.detached(operation: { git.remoteURL(directory) }).value
        return SourceForge.repository(remoteURL: url)
    }

    func currentBranch(_ id: UUID) async -> String? {
        guard let run = run(id), let git = sessionGit(for: run) else { return nil }
        let directory = run.workingDirectory
        return await Task.detached(operation: { git.currentBranch(directory) }).value
    }

    /// Deletes a session's worktree. Never while the session is running; uncommitted changes require `force`.
    func removeWorktree(_ id: UUID, force: Bool) async throws {
        guard let run = run(id), let worktree = run.worktreePath, let repo = run.repoRoot, let git = sessionGit(for: run) else { return }
        guard processes[id] == nil, !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        let others = runs.filter { $0.id != id && $0.status.isActive && $0.workingDirectory == worktree }
        guard others.isEmpty else { throw StartError.git(tr("ws.error.busy")) }
        let local = !run.isRemote
        try await FolderLease.shared.run(FolderLease.key(worktree, machine: run.remote?.machineID), priority: .userInitiated) {
            if local { WorktreeArchive.save(worktree: worktree) }
            try git.removeWorktree(repo: repo, path: worktree, force: force)
        }
        append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeRemoved", AgentPathFormat.tilde(worktree))))
        update(id) { $0.statusDetail = "worktreeRemoved" }
        self.git[id] = nil
        refreshWorktrees()
    }

    /// The session's files are there to snapshot: its worktree, or its folder.
    func canSnapshot(_ run: WorkspaceRun) -> Bool {
        // On another machine git there answers for itself (a folder that is gone fails the snapshot, nothing more).
        if run.isRemote { return true }
        return run.isolation == .worktree ? worktreeExists(run) : FileManager.default.fileExists(atPath: run.workingDirectory)
    }

    func worktreeExists(_ run: WorkspaceRun) -> Bool {
        guard let path = run.worktreePath else { return false }
        if run.isRemote { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    /// All worktrees across repositories containing sessions, with linked sessions and change statuses.
    /// One refresh at a time: it reads every worktree (Git and its size on disk), which takes minutes with a hundred of
    /// them, and the list asks again each time it appears. A request during a refresh runs once after it, not alongside.
    /// Sizes come from `DiskUsage.cachedAllocatedSize` unless `force` (the list's refresh button) measures them again.
    func refreshWorktrees(force: Bool = false) {
        guard let git = gitService else { return }
        // Nobody looks at the rows: the list refreshes when it opens.
        guard worktreesListShown > 0 else { return }
        guard !worktreesLoading else {
            gitRefresh.worktreesPending = true
            if force { gitRefresh.worktreesForced = true }
            return
        }
        let sizeAge = force ? 0 : DiskUsage.cachedSizeAge
        let roots = Set(runs.compactMap(\.repoRoot))
        let snapshot = runs
        let listOpen = worktreesListOpen
        worktreesLoading = true
        Task.detached(priority: .utility) {
            // Resolving each root to its main checkout runs Git once per root: off the main thread, or every refresh
            // froze the app for seconds with many sessions.
            let repos = Array(Set(roots.map { git.mainCheckout(of: $0) ?? $0 })).sorted()
            var rows: [WorktreeRow] = []
            var seenPaths = Set<String>()
            // Closed meanwhile: the rest is for no one. The list keeps the rows it had; opening it again refreshes in full.
            var stopped = false
            repositories: for repo in repos where FileManager.default.fileExists(atPath: repo) {
                guard listOpen.isOpen else { stopped = true; break }
                guard let list = try? git.worktrees(repo) else { continue }
                for worktree in list {
                    guard listOpen.isOpen else { stopped = true; break repositories }
                    autoreleasepool {
                        let path = WorkspacePathPolicy.normalize(worktree.path)
                        guard seenPaths.insert(path).inserted else { return }
                        let linked = snapshot.filter { WorkspacePathPolicy.normalize($0.workingDirectory) == path }
                        // Only show root workspace if a session is actively using it.
                        if worktree.isMain && linked.isEmpty { return }
                        var row = WorktreeRow(repoRoot: repo, worktree: worktree, runIDs: linked.map(\.id))
                        if FileManager.default.fileExists(atPath: worktree.path) {
                            row.changedFiles = git.changedFileCount(worktree.path)
                            if !worktree.isMain { row.bytes = DiskUsage.cachedAllocatedSize(of: worktree.path, maxAge: sizeAge) { listOpen.isOpen } }
                            let base = linked.compactMap(\.baseBranch).first
                            row.baseBranch = base
                            if let base, let divergence = git.divergence(worktree.path, base: base) {
                                row.ahead = divergence.ahead
                                row.behind = divergence.behind
                            }
                        }
                        rows.append(row)
                    }
                }
            }
            await MainActor.run { [weak self, rows, stopped] in
                guard let self else { return }
                if !stopped { self.worktreeRows = rows }
                self.worktreesLoading = false
                if self.gitRefresh.worktreesPending {
                    let forced = self.gitRefresh.worktreesForced
                    self.gitRefresh.worktreesPending = false
                    self.gitRefresh.worktreesForced = false
                    self.refreshWorktrees(force: forced)
                }
            }
        }
    }

    /// A Worktrees list opened (`true`) or closed. Opening refreshes its rows; with every list closed, a refresh under way
    /// stops at the next worktree and later changes wait for the next opening.
    func worktreesShown(_ shown: Bool) {
        worktreesListShown = max(0, worktreesListShown + (shown ? 1 : -1))
        worktreesListOpen.isOpen = worktreesListShown > 0
        if shown { refreshWorktrees() }
    }

    /// The worktree deleting this session would leave unused (`WorktreeCleanup`), offered to remove along with it.
    func orphanedWorktree(_ id: UUID) -> (repo: String, path: String)? {
        guard let run = run(id), !run.isRemote, let repo = run.repoRoot else { return nil }
        let others = runs.filter { $0.id != id }.flatMap { [$0.workingDirectory] + ($0.worktreePath.map { [$0] } ?? []) }
        guard let path = WorktreeCleanup.orphaned(worktree: run.worktreePath, otherFolders: others),
              WorkspacePathPolicy.normalize(path) != WorkspacePathPolicy.normalize(repo) else { return nil }
        return (repo, path)
    }

    /// Deletes a session and then its worktree. Git refuses a worktree with changes that were never committed; that is
    /// reported and the worktree stays, so nothing you did not commit is lost.
    func deleteWithWorktree(_ id: UUID) {
        guard let worktree = orphanedWorktree(id) else { delete(id); return }
        guard run(id)?.status.isActive == false else { return }
        delete(id, cleanUpWorktree: false)
        // `delete` leaves a session whose process is still there; its worktree stays with it.
        guard run(id) == nil else { return }
        Task {
            do {
                try await removeWorktree(repo: worktree.repo, path: worktree.path, force: false)
                ToastCenter.shared.success(tr("ws.worktree.removed"))
            } catch {
                ToastCenter.shared.error(error, title: tr("ws.worktree.removeFailed"))
            }
        }
    }

    /// Removes a worktree that is not linked to any active session (from the overview).
    func removeWorktree(repo: String, path: String, force: Bool) async throws {
        guard let git = gitService else { throw StartError.noGit }
        let target = WorkspacePathPolicy.normalize(path)
        guard !runs.contains(where: { $0.status.isActive && WorkspacePathPolicy.normalize($0.workingDirectory) == target }) else {
            throw StartError.git(tr("ws.error.busy"))
        }
        try await FolderLease.shared.run(FolderLease.key(path), priority: .userInitiated) {
            WorktreeArchive.save(worktree: path)
            try git.removeWorktree(repo: repo, path: path, force: force)
        }
        for run in runs where WorkspacePathPolicy.normalize(run.workingDirectory) == target {
            append(run.id, RunEvent(kind: .system, text: tr("ws.event.worktreeRemoved", AgentPathFormat.tilde(path))))
            update(run.id) { $0.statusDetail = "worktreeRemoved" }
        }
        refreshWorktrees()
    }
}

/// What `WorkspaceManager+Git` keeps between reads.
struct GitRefreshState {
    /// A scheduled refresh per session (`scheduleGitRefresh`).
    var refreshes: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose `git status` is being read: a refresh asked for meanwhile runs once after it, not alongside it.
    var reading: Set<UUID> = []
    /// Of those, the ones asked again while reading, and whether that ask showed the spinner.
    var again: [UUID: Bool] = [:]
    /// Where each session's branch is counted from (`GitService.branchComparison`), kept while its branch, upstream and
    /// commits stay the same (for at most `branchPointMaxAge`), so a refresh as the agent writes adds two diffs, not ten
    /// git processes.
    var branchPoints: [UUID: BranchPoint] = [:]
    struct BranchPoint: Sendable {
        var key: String
        var point: String?
        var at: Date
    }
    static let branchPointMaxAge: TimeInterval = 60
    /// Another refresh was asked for while one ran; it runs once that one is done (`refreshWorktrees`).
    var worktreesPending = false
    /// The pending refresh measures every worktree's size again (the list's refresh button), not from the cache.
    var worktreesForced = false

    /// A deleted session's reads and what they kept.
    mutating func forget(_ id: UUID) {
        refreshes.removeValue(forKey: id)?.cancel()
        reading.remove(id)
        again[id] = nil
        branchPoints[id] = nil
    }
}
