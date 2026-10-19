import AppKit
import Foundation

/// The one git button: the state of the session's branch decides between commit, push, pull
/// request and pull, and the agent writes the commit message and the pull request.
extension WorkspaceManager {
    /// Where the button stands for a session; nil outside a repository.
    func quickGitState(_ id: UUID) async -> GitQuickState? {
        guard let run = run(id), run.repoRoot != nil, let git = gitService, let status = self.git[id]?.status else { return nil }
        let directory = run.workingDirectory
        let sessionBase = run.baseBranch
        let facts = await Task.detached(priority: .userInitiated) { () -> (base: String?, remote: Bool, ahead: Int, repo: RemoteRepository?) in
            let remotes = git.remotes(directory)
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            let base = Self.pullRequestBase(sessionBase ?? git.defaultBranch(directory, remote: remote), remote: remote)
            let ahead = base.flatMap { git.commitsAhead(directory, of: git.comparisonBase(directory, base: $0, remote: remote)) } ?? 0
            return (base, !remotes.isEmpty, ahead, SourceForge.repository(remoteURL: git.remoteURL(directory, remote: remote)))
        }.value
        let branch = status.detached ? nil : status.branch
        if let repo = facts.repo, let branch, let lookup = pullRequestLookup {
            let key = repo.key + " " + branch
            if let last = pullRequestChecked[key], Date().timeIntervalSince(last) < 60 {
                // Asked a moment ago: keep that answer.
            } else {
                pullRequestChecked[key] = Date()
                openPullRequests[id] = await lookup(repo, branch)
            }
        }
        return GitQuickState(hasChanges: !status.isClean, branch: branch, isDefaultBranch: branch != nil && branch == facts.base,
                             hasUpstream: status.upstream != nil, hasRemote: facts.remote, ahead: status.ahead, behind: status.behind,
                             aheadOfBase: facts.ahead, hasOpenPullRequest: openPullRequests[id] != nil)
    }

    /// Carries out the action, step by step; `progress` gets each step's label. Returns the pull request, if one opened.
    @discardableResult
    func performQuickGit(_ id: UUID, _ action: GitQuickAction, progress: @escaping (String) -> Void) async throws -> URL? {
        guard let run = run(id), let git = gitService else { throw StartError.noGit }
        guard !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        let directory = run.workingDirectory
        defer { refreshGit(id) }

        if action == .pull {
            progress(tr("ws.quick.pulling"))
            try await Task.detached(priority: .userInitiated) { try git.pullFastForward(directory) }.value
            append(id, RunEvent(kind: .system, text: tr("ws.event.pulled")))
            return nil
        }
        if action.commits {
            progress(tr("ws.quick.generatingCommit"))
            let context = try await Task.detached(priority: .userInitiated) { try git.commitContext(directory) }.value
            let branch = await currentBranch(id)
            let answer = await generateText(TextGeneration.commitPrompt(branch: branch, files: context.files, patch: context.patch),
                                            schema: TextGeneration.commitSchema, prefer: run.provider, profileID: run.profileID, cwd: directory)
            let subject = TextGeneration.commitSubject((answer?["subject"] as? String) ?? "")
            let body = (answer?["body"] as? String) ?? ""
            progress(tr("ws.quick.committing"))
            let sha = try await Task.detached(priority: .userInitiated) { try git.commitAll(directory, subject: subject, body: body) }.value
            append(id, RunEvent(kind: .system, text: tr("ws.event.committed", sha, ToolSummary.oneLine(subject, 80))))
            markReviewed(id)
        }
        if action.pushes {
            progress(tr("ws.quick.pushing"))
            try await push(id)
        }
        guard action.proposes else { return nil }
        return try await proposePullRequest(id, progress: progress)
    }

    private func proposePullRequest(_ id: UUID, progress: @escaping (String) -> Void) async throws -> URL {
        guard let run = run(id), let git = gitService else { throw StartError.noGit }
        let directory = run.workingDirectory
        guard let repo = await remoteRepository(id) else { throw StartError.git(tr("ws.quick.noForge")) }
        guard let branch = await currentBranch(id) else { throw StartError.git(tr("ws.error.detached")) }
        let sessionBase = run.baseBranch
        let root = run.repoRoot ?? directory
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
        let answer = await generateText(TextGeneration.pullRequestPrompt(base: base, head: branch, commits: facts.commits, stat: facts.stat,
                                                                        patch: facts.patch, template: facts.template),
                                        schema: TextGeneration.pullRequestSchema, prefer: run.provider, profileID: run.profileID, cwd: directory)
        let title = TextGeneration.pullRequestTitle((answer?["title"] as? String) ?? (facts.commits.split(separator: "\n").first.map {
            String($0.drop { $0 != " " }.dropFirst())
        } ?? ""))
        let body = (answer?["body"] as? String) ?? ""
        progress(tr("ws.quick.creatingPR"))
        do {
            if let create = pullRequestCreate, let link = try await create(repo, title, body, branch, base) {
                openPullRequests[id] = link
                append(id, RunEvent(kind: .system, text: tr("ws.event.prOpened", link.absoluteString)))
                return link
            }
        } catch {
            // GitHub refused (no access, a pull request that already exists…): its own page still lets you finish it.
            append(id, RunEvent(kind: .error, text: error.localizedDescription))
        }
        // No connected account (or another forge): the forge's own page, with the title and description already filled in.
        guard let compare = SourceForge.newRequestPage(repo: repo, base: base, head: branch, title: title, body: body) else {
            throw StartError.git(tr("ws.quick.noForge"))
        }
        NSWorkspace.shared.open(compare)
        append(id, RunEvent(kind: .system, text: tr("ws.event.prCompare", branch)))
        return compare
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
