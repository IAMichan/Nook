import AppKit
import Foundation

/// The one git button: the state of the session's branch decides between commit, push, pull
/// request and pull, and the agent writes the commit message and the pull request. It works the same for a session
/// Nook runs and for one it only sees (started in a terminal or the Claude desktop app): both act on the folder.
extension WorkspaceManager {
    /// The folder the button acts on, and who writes the texts.
    struct QuickGitTarget {
        let directory: String
        let git: GitService
        /// The branch the session started from; nil makes it the repository's default branch.
        let baseBranch: String?
        let root: String
        let provider: RunProvider?
        let profileID: String?
        let isRemote: Bool
    }

    /// What the button reports back to the session it acts for.
    struct QuickGitHooks {
        var log: (RunEvent) -> Void = { _ in }
        var committed: () -> Void = {}
        var openedPullRequest: (URL) -> Void = { _ in }
        /// A new branch for a new pull request: what was known about the old branch's pull request no longer applies.
        var switchedBranch: (String) -> Void = { _ in }
    }

    private func quickTarget(_ run: WorkspaceRun) -> QuickGitTarget? {
        guard let git = sessionGit(for: run) else { return nil }
        return QuickGitTarget(directory: run.workingDirectory, git: git, baseBranch: run.baseBranch, root: run.repoRoot ?? run.workingDirectory,
                              provider: run.provider, profileID: run.profileID, isRemote: run.isRemote)
    }

    private func quickTarget(folder root: String) -> QuickGitTarget? {
        guard let git = gitService else { return nil }
        return QuickGitTarget(directory: root, git: git, baseBranch: nil, root: root, provider: nil, profileID: nil, isRemote: false)
    }

    private func quickHooks(_ id: UUID) -> QuickGitHooks {
        QuickGitHooks(log: { [weak self] in self?.append(id, $0) },
                      committed: { [weak self] in self?.markReviewed(id) },
                      openedPullRequest: { [weak self] link in
                          guard let self else { return }
                          self.openPullRequests[id] = link
                          // A GitHub pull request Nook opened for the session is watched from the start.
                          if self.run(id)?.prWatch == nil, PullRequestWatch.canWatch(link) { self.watchPullRequest(id, url: link) }
                      },
                      switchedBranch: { [weak self] branch in
                          guard let self else { return }
                          self.update(id) { $0.branch = branch }
                          self.openPullRequests[id] = nil
                          // The merged pull request's watch makes way for the new one.
                          if self.run(id)?.prWatch != nil { self.watchPullRequest(id, url: nil) }
                          PullRequestSync.shared.forget(id)
                      })
    }

    /// Where the button stands for a session; nil outside a repository.
    func quickGitState(_ id: UUID) async -> GitQuickState? {
        guard let run = run(id), run.repoRoot != nil, let target = quickTarget(run), let status = self.git[id]?.status else { return nil }
        let open = await quickGitState(target, status: status, known: openPullRequests[id]) { [weak self] found in
            if self?.openPullRequests[id] != found { self?.openPullRequests[id] = found }
        }
        return open
    }

    /// Where the button stands for a session Nook only sees, from its repository root and the status read there.
    func quickGitState(folder root: String, status: GitStatus) async -> GitQuickState? {
        guard let target = quickTarget(folder: root) else { return nil }
        return await quickGitState(target, status: status, known: folderPullRequests[root]) { [weak self] found in
            self?.folderPullRequests[root] = found
        }
    }

    private func quickGitState(_ target: QuickGitTarget, status: GitStatus, known: URL?,
                               found: @escaping (URL?) -> Void) async -> GitQuickState {
        let git = target.git, directory = target.directory, sessionBase = target.baseBranch
        let facts = await Task.detached(priority: .userInitiated) { () -> (base: String?, remote: Bool, ahead: Int, repo: RemoteRepository?) in
            let remotes = git.remotes(directory)
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            let base = Self.pullRequestBase(sessionBase ?? git.defaultBranch(directory, remote: remote), remote: remote)
            let ahead = base.flatMap { git.commitsAhead(directory, of: git.comparisonBase(directory, base: $0, remote: remote)) } ?? 0
            return (base, !remotes.isEmpty, ahead, SourceForge.repository(remoteURL: git.remoteURL(directory, remote: remote)))
        }.value
        let branch = status.detached ? nil : status.branch
        var open = known
        var landed = false
        if let repo = facts.repo, let branch, let lookup = pullRequestLookup {
            let key = repo.key + " " + branch
            if let last = pullRequestChecked[key], Date().timeIntervalSince(last) < 60 {
                // Asked a moment ago: keep that answer.
            } else {
                pullRequestChecked[key] = Date()
                // Usually the same answer as last time: publishing it again would redraw every view of the workspace.
                let answer = await lookup(repo, branch)
                open = answer.open
                if answer.landed { pullRequestLanded.insert(key) } else { pullRequestLanded.remove(key) }
                found(open)
            }
            landed = open == nil && pullRequestLanded.contains(key)
        }
        return GitQuickState(hasChanges: !status.isClean, branch: branch, isDefaultBranch: branch != nil && branch == facts.base,
                             hasUpstream: status.upstream != nil, hasRemote: facts.remote, ahead: status.ahead, behind: status.behind,
                             aheadOfBase: facts.ahead, hasOpenPullRequest: open != nil, pullRequestLanded: landed)
    }

    /// Carries out the action, step by step; `progress` gets each step's label. Returns the pull request, if one opened.
    @discardableResult
    func performQuickGit(_ id: UUID, _ action: GitQuickAction, progress: @escaping (String) -> Void) async throws -> URL? {
        guard let run = run(id), let target = quickTarget(run) else { throw StartError.noGit }
        guard !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        defer { refreshGit(id) }
        return try await performQuickGit(target, action, hooks: quickHooks(id), progress: progress)
    }

    /// The same for a session Nook only sees, in its repository root.
    @discardableResult
    func performQuickGit(folder root: String, _ action: GitQuickAction, progress: @escaping (String) -> Void) async throws -> URL? {
        guard let target = quickTarget(folder: root) else { throw StartError.noGit }
        let hooks = QuickGitHooks(openedPullRequest: { [weak self] in self?.folderPullRequests[root] = $0 },
                                  switchedBranch: { [weak self] _ in self?.folderPullRequests[root] = nil })
        return try await performQuickGit(target, action, hooks: hooks, progress: progress)
    }

    private func performQuickGit(_ target: QuickGitTarget, _ action: GitQuickAction, hooks: QuickGitHooks,
                                 progress: @escaping (String) -> Void) async throws -> URL? {
        let git = target.git, directory = target.directory
        if action == .pull {
            progress(tr("ws.quick.pulling"))
            try await Task.detached(priority: .userInitiated) { try git.pullFastForward(directory) }.value
            hooks.log(RunEvent(kind: .system, text: tr("ws.event.pulled")))
            return nil
        }
        var message: (subject: String, body: String)?
        if action.commits {
            progress(tr("ws.quick.generatingCommit"))
            let context = try await Task.detached(priority: .userInitiated) { try git.commitContext(directory) }.value
            let branch = await Task.detached { git.currentBranch(directory) }.value
            let style = await commitStyleRules(git, directory: directory, pullRequest: false)
            let answer = await generateText(TextGeneration.commitPrompt(branch: branch, files: context.files, patch: context.patch, style: style),
                                            schema: TextGeneration.commitSchema, prefer: target.provider, profileID: target.profileID,
                                            cwd: target.isRemote ? NSHomeDirectory() : directory)
            message = (TextGeneration.commitSubject((answer?["subject"] as? String) ?? ""), (answer?["body"] as? String) ?? "")
        }
        var cut: String?
        if action.startsBranch {
            progress(tr("ws.quick.branching"))
            let topic: String
            if let message { topic = message.subject } else { topic = await Task.detached { git.recentSubjects(directory).first ?? "" }.value }
            let name = WorktreeNaming.branchName(task: topic, id: UUID(), prefix: settings.sessionDefaults(for: target.root).branchPrefix)
            cut = try await Task.detached(priority: .userInitiated) { try git.startBranch(directory, name: name, remote: Self.remote(git, directory)) }.value
            hooks.log(RunEvent(kind: .system, text: tr("ws.event.branched", name)))
            hooks.switchedBranch(name)
        }
        if let message {
            progress(tr("ws.quick.committing"))
            let sha = try await Task.detached(priority: .userInitiated) { try git.commitAll(directory, subject: message.subject, body: message.body) }.value
            hooks.log(RunEvent(kind: .system, text: tr("ws.event.committed", sha, ToolSummary.oneLine(message.subject, 80))))
            hooks.committed()
        }
        if let cut {
            // Only the new work: the commits of the merged pull request stay out of the new one.
            let sessionBase = target.baseBranch
            await Task.detached(priority: .userInitiated) {
                let remote = Self.remote(git, directory)
                guard let base = Self.pullRequestBase(sessionBase ?? git.defaultBranch(directory, remote: remote), remote: remote) else { return }
                git.moveOntoBase(directory, base: base, remote: remote, cut: cut)
            }.value
        }
        if action.pushes {
            progress(tr("ws.quick.pushing"))
            let pushed = try await Task.detached(priority: .userInitiated) { () throws -> (branch: String, remote: String) in
                guard let branch = git.currentBranch(directory) else { throw StartError.git(tr("ws.error.detached")) }
                let remotes = git.remotes(directory)
                let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
                try git.push(directory, remote: remote, branch: branch)
                return (branch, remote)
            }.value
            hooks.log(RunEvent(kind: .system, text: tr("ws.event.pushed", pushed.branch, pushed.remote)))
        }
        guard action.proposes else { return nil }
        return try await proposePullRequest(target, hooks: hooks, progress: progress)
    }

    /// The extra rules of the commit style chosen in Settings › Workspace; the repository's own style reads its recent commits.
    private func commitStyleRules(_ git: GitService, directory: String, pullRequest: Bool) async -> [String] {
        let style = settings.commitStyle
        let instructions = settings.commitInstructions
        let subjects = style == .repository
            ? await Task.detached(priority: .userInitiated) { git.recentSubjects(directory) }.value : []
        return pullRequest ? style.pullRequestRules(recentSubjects: subjects, instructions: instructions)
            : style.commitRules(recentSubjects: subjects, instructions: instructions)
    }

    private func proposePullRequest(_ target: QuickGitTarget, hooks: QuickGitHooks, progress: @escaping (String) -> Void) async throws -> URL {
        let git = target.git, directory = target.directory, sessionBase = target.baseBranch, root = target.root
        let found = await Task.detached { (SourceForge.repository(remoteURL: git.remoteURL(directory)), git.currentBranch(directory)) }.value
        guard let repo = found.0 else { throw StartError.git(tr("ws.quick.noForge")) }
        guard let branch = found.1 else { throw StartError.git(tr("ws.error.detached")) }
        progress(tr("ws.quick.generatingPR"))
        let facts = try await Task.detached(priority: .userInitiated) { () -> (base: String?, commits: String, stat: String, patch: String, template: String?) in
            let remotes = git.remotes(directory)
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            guard let base = Self.pullRequestBase(sessionBase ?? git.defaultBranch(directory, remote: remote), remote: remote) else {
                return (nil, "", "", "", nil)
            }
            let context = try git.pullRequestContext(directory, base: git.comparisonBase(directory, base: base, remote: remote))
            return (base, context.commits, context.stat, context.patch, GitService.pullRequestTemplate(root))
        }.value
        guard let base = facts.base, base != branch else { throw StartError.git(tr("ws.quick.onBase", branch)) }
        let style = await commitStyleRules(git, directory: directory, pullRequest: true)
        let answer = await generateText(TextGeneration.pullRequestPrompt(base: base, head: branch, commits: facts.commits, stat: facts.stat,
                                                                        patch: facts.patch, template: facts.template, style: style),
                                        schema: TextGeneration.pullRequestSchema, prefer: target.provider, profileID: target.profileID,
                                        cwd: target.isRemote ? NSHomeDirectory() : directory)
        let title = TextGeneration.pullRequestTitle((answer?["title"] as? String) ?? (facts.commits.split(separator: "\n").first.map {
            String($0.drop { $0 != " " }.dropFirst())
        } ?? ""))
        let body = (answer?["body"] as? String) ?? ""
        progress(tr("ws.quick.creatingPR"))
        do {
            if let create = pullRequestCreate, let link = try await create(repo, title, body, branch, base) {
                hooks.log(RunEvent(kind: .system, text: tr("ws.event.prOpened", link.absoluteString)))
                hooks.openedPullRequest(link)
                return link
            }
        } catch {
            // GitHub refused (no access, a pull request that already exists…): its own page still lets you finish it.
            hooks.log(RunEvent(kind: .error, text: error.localizedDescription))
        }
        // No connected account (or another forge): the forge's own page, with the title and description already filled in.
        guard let compare = SourceForge.newRequestPage(repo: repo, base: base, head: branch, title: title, body: body) else {
            throw StartError.git(tr("ws.quick.noForge"))
        }
        NSWorkspace.shared.open(compare)
        hooks.log(RunEvent(kind: .system, text: tr("ws.event.prCompare", branch)))
        return compare
    }

    /// The branch a pull request of this session merges into: the one it started from, else (a chat taken over from a
    /// terminal has none) the repository's default branch.
    func pullRequestBaseBranch(_ id: UUID) async -> String? {
        guard let run = run(id), let git = sessionGit(for: run) else { return nil }
        let directory = run.workingDirectory
        let sessionBase = run.baseBranch
        return await Task.detached(priority: .userInitiated) {
            let remotes = git.remotes(directory)
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            // The remote may have renamed its default branch since the last fetch; offline, the local answer stands.
            if sessionBase == nil { _ = try? git.run(["remote", "set-head", remote, "--auto"], in: directory, timeout: 15) }
            return Self.pullRequestBase(sessionBase ?? git.defaultBranch(directory, remote: remote), remote: remote)
        }.value
    }

    /// The same for a repository Nook only sees, by its root.
    func pullRequestBaseBranch(folder root: String) async -> String? {
        guard let git = gitService else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let remotes = git.remotes(root)
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            _ = try? git.run(["remote", "set-head", remote, "--auto"], in: root, timeout: 15)
            return Self.pullRequestBase(git.defaultBranch(root, remote: remote), remote: remote)
        }.value
    }

    /// Git in the repository of a session Nook only sees (one from a terminal or the Claude desktop app), by its root:
    /// the same commit and pull request as for a session Nook runs.
    func folderStatus(_ root: String) async -> GitStatus? {
        guard let git = gitService else { return nil }
        return await Task.detached(priority: .userInitiated) { try? git.status(root) }.value
    }

    func commit(folder root: String, message: String, paths: [String]) async throws -> String {
        guard let git = gitService else { throw StartError.noGit }
        return try await Task.detached(priority: .userInitiated) { try git.commit(root, message: message, paths: paths) }.value
    }

    func remoteRepository(folder root: String) async -> RemoteRepository? {
        guard let git = gitService else { return nil }
        return await Task.detached { SourceForge.repository(remoteURL: git.remoteURL(root)) }.value
    }

    func currentBranch(folder root: String) async -> String? {
        guard let git = gitService else { return nil }
        return await Task.detached { git.currentBranch(root) }.value
    }

    /// The remote the button pushes to: origin, else the first one.
    nonisolated static func remote(_ git: GitService, _ directory: String) -> String {
        let remotes = git.remotes(directory)
        return remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
    }

    /// The branch a pull request merges into, without the remote's name ("origin/main" → "main").
    nonisolated static func pullRequestBase(_ base: String?, remote: String) -> String? {
        guard var base, !base.isEmpty else { return nil }
        for prefix in ["origin/", remote + "/"] where base.hasPrefix(prefix) { base = String(base.dropFirst(prefix.count)) }
        return base.isEmpty ? nil : base
    }

    nonisolated static func compareURL(repo: String, base: String, head: String, title: String, body: String) -> URL? {
        guard let plain = GitHubRemote.compareURL(repo: repo, base: base, head: head),
              var components = URLComponents(url: plain, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "title", value: title),
                                                                  URLQueryItem(name: "body", value: String(body.prefix(6_000)))]
        return components.url
    }
}
