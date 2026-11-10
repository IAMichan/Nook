import Foundation

/// Source control around a session's worktree: fast checkouts from the cache, submodules, and the main checkout's
/// default branch kept up to date.
extension WorkspaceManager {
    /// What a new worktree of `root` is made with: the checkout cache (fast worktrees on, this Mac) and how its submodules
    /// are checked out. Read on the main actor, used off it.
    struct WorktreeCheckout: Sendable {
        var cache: WorktreeCheckoutCache?
        var submodules: SubmoduleMode
    }

    func worktreeCheckout(_ git: GitService, root: String) -> WorktreeCheckout {
        WorktreeCheckout(cache: settings.fastWorktrees && git.remote == nil ? WorktreeCheckoutCache(git: git) : nil,
                         submodules: settings.sessionDefaults(for: root).submodules)
    }

    /// After a new worktree exists: its submodules, the main checkout's `node_modules` when the lockfiles match (fast
    /// worktrees only), and, when Git checked it out itself, a cached checkout for the next one, in the background.
    /// Returns Git's message when the submodules failed; the worktree is usable either way.
    nonisolated static func finishWorktree(_ git: GitService, checkout: WorktreeCheckout, root: String, path: String,
                                           cloned: Bool) -> String? {
        var problem: String?
        do {
            try git.updateSubmodules(path, mode: checkout.submodules)
        } catch {
            problem = error.localizedDescription
        }
        if let cache = checkout.cache {
            cache.cloneDependencies(from: root, to: path)
            if !cloned { Task.detached(priority: .background) { cache.build(worktree: path, repo: root) } }
        }
        return problem
    }
}

// MARK: Auto-pull

/// When each main checkout was last looked at for auto-pull (normalized path → time), and whether a look is under way.
@MainActor
final class AutoPullClock {
    static let shared = AutoPullClock()
    var checked: [String: Date] = [:]
    var running = false
}

extension WorkspaceManager {
    /// The main checkouts a fast-forward may apply to: those of your sessions on this Mac, your favorite and recent
    /// projects, as long as their project has auto-pull on and is not archived. Paths, not yet resolved to checkouts.
    func autoPullCandidates() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let local = runs.filter { $0.remote == nil }.compactMap { $0.repoRoot ?? $0.projectPath }
        for path in local + settings.favoriteProjects + settings.recentProjects.prefix(12) {
            let clean = WorkspacePathPolicy.normalize(path)
            guard !clean.isEmpty, !ScratchProjects.isScratch(clean), seen.insert(clean).inserted,
                  settings.sessionDefaults(for: clean).autoPull, !settings.isArchivedProject(clean) else { continue }
            result.append(clean)
        }
        return result
    }

    /// Run with the half-minute tick: each checkout with auto-pull on at most every `AutoPull.interval`. Nothing happens
    /// (no git, no network) while no project has it on.
    func autoPullDefaultBranches(now: Date = Date()) {
        let clock = AutoPullClock.shared
        guard runsLoaded, !clock.running, let git = gitService, git.remote == nil else { return }
        let due = autoPullCandidates().filter { path in
            clock.checked[path].map { now.timeIntervalSince($0) >= AutoPull.interval } ?? true
        }
        guard !due.isEmpty else { return }
        for path in due { clock.checked[path] = now }
        // Folders a session works in right now, without a worktree of its own: never moved under an agent.
        let working = Set(runs.filter { $0.status.isActive && $0.isolation == .folder && $0.remote == nil }
            .map { WorkspacePathPolicy.normalize($0.workingDirectory) })
        clock.running = true
        Task { [weak self] in
            let moved = await Task.detached(priority: .utility) { () -> [String] in
                var done: Set<String> = []
                var moved: [String] = []
                for path in due {
                    guard let checkout = git.mainCheckout(of: path) else { continue }
                    let key = WorkspacePathPolicy.normalize(checkout)
                    guard done.insert(key).inserted else { continue }
                    let busy = working.contains { $0 == key || $0.hasPrefix(key + "/") }
                    if (try? git.autoPull(checkout, sessionWorking: busy)) == .fastForward { moved.append(checkout) }
                }
                return moved
            }.value
            clock.running = false
            guard let self else { return }
            for checkout in moved {
                self.onAudit?("auto_pull", checkout, "fast-forwarded")
                self.projectCache[WorkspacePathPolicy.normalize(checkout)] = nil
            }
        }
    }
}

// MARK: Clone and publish

extension WorkspaceManager {
    /// Clones a repository (into `<host>/<owner>/<repo>` with that layout on), then selects it as the active project.
    /// An SSH address that SSH refuses is cloned over HTTPS; the result says so.
    func clone(url: String, into parent: String) async throws -> GitService.CloneResult {
        guard let git = gitService else { throw StartError.noGit }
        let layout = settings.cloneHostLayout
        let result = try await Task.detached(priority: .userInitiated) {
            try git.clone(url: url, into: parent, hostLayout: layout)
        }.value
        settings.rememberProject(result.path)
        return result
    }

    /// The folder a clone goes under: the root of the host layout the current project lives in, else (with the layout
    /// on) ~/Developer, else the folder next to the current project.
    nonisolated static func cloneParent(project: String?, hostLayout: Bool) -> String {
        let developer = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
        if hostLayout { return project.flatMap(CloneLayout.layoutRoot(of:)) ?? developer }
        guard let project else { return developer }
        return URL(fileURLWithPath: project).deletingLastPathComponent().path
    }

    /// "New project…": makes the folder (it must not exist yet, or be empty) with an empty repository in it, and returns
    /// what publishing it would do.
    func createProject(at path: String) async throws -> PublishPlan {
        guard let git = gitService, git.remote == nil else { throw StartError.noGit }
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                guard ((try? fm.contentsOfDirectory(atPath: path)) ?? ["?"]).isEmpty else {
                    throw GitError(tr("sc.newProject.exists", path))
                }
            } else {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            try git.run(["init", "--quiet"], in: path)
        }.value
        guard let plan = await publishPlan(folder: path) else { throw GitError(tr("sc.newProject.exists", path)) }
        return plan
    }

    /// What publishing a folder would do, for the confirmation: nil when it cannot be published (it has a remote, or
    /// lives on another machine).
    func publishPlan(folder: String) async -> PublishPlan? {
        guard let git = gitService, git.remote == nil else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> PublishPlan? in
            // A session's worktree publishes its repository: the main checkout and the branch it is on.
            let root = git.repositoryRoot(for: folder).map { git.mainCheckout(of: $0) ?? $0 }
            let remotes = root.map { git.remotes($0) } ?? []
            guard RepositoryPublish.canPublish(isRepository: root != nil, remotes: remotes) else { return nil }
            let path = root ?? folder
            return PublishPlan(folder: path, name: RepositoryPublish.suggestedName(URL(fileURLWithPath: path).lastPathComponent),
                               needsRepository: root == nil, needsFirstCommit: !git.hasCommits(path))
        }.value
    }

    /// Publishes a local project: a new GitHub repository (private unless you said otherwise), `origin` pointing at it,
    /// and the current branch pushed. Only after your confirmation; the action log gets what was made.
    func publishRepository(_ plan: PublishPlan, name: String, owner: String?, isPrivate: Bool) async throws -> URL {
        guard let git = gitService, git.remote == nil else { throw StartError.noGit }
        let folder = plan.folder
        let branch = try await Task.detached(priority: .userInitiated) { try git.preparePublish(folder) }.value
        let made: GitHubRepositoryCreate.Made
        do {
            made = try await GitHubRepositoryCreate.create(name: name, owner: owner, isPrivate: isPrivate)
        } catch {
            onAudit?("publish_repository", "\(folder) → \(name)", "failed: \(error.localizedDescription)")
            throw error
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try git.publish(folder, remoteURL: made.cloneURL, branch: branch, token: made.token)
            }.value
        } catch {
            onAudit?("publish_repository", "\(folder) → \(made.fullName)", "created, push failed: \(error.localizedDescription)")
            throw error
        }
        onAudit?("publish_repository", "\(folder) → \(made.fullName) (\(isPrivate ? "private" : "public"))",
                 "created and pushed \(branch)")
        projectCache[WorkspacePathPolicy.normalize(folder)] = nil
        for run in runs where run.repoRoot.map(WorkspacePathPolicy.normalize) == WorkspacePathPolicy.normalize(folder)
            || WorkspacePathPolicy.normalize(run.projectPath) == WorkspacePathPolicy.normalize(folder) {
            refreshGit(run.id)
        }
        return made.page
    }
}

/// What Publish will do to a folder, shown before it does it.
struct PublishPlan: Equatable, Sendable, Identifiable {
    var folder: String
    /// The suggested repository name.
    var name: String
    /// The folder is no repository yet: `git init` first.
    var needsRepository: Bool
    /// Nothing is committed yet: every file goes into a first commit.
    var needsFirstCommit: Bool

    var id: String { folder }
}
