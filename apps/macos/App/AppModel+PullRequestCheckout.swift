import Foundation

/// A pull request on your machine, to work on it: in a worktree of its own, in the folder you are in, or on one of your
/// SSH machines. Every session after it runs on the branch; the session itself you start, as always.
extension AppModel {
    /// Finds the folder of a pull request's repository on this Mac: the session's, else a project you worked in.
    private func localFolder(repo: String, preferred: String?) async -> String? {
        let settings = workspace.settings
        let folders = [preferred].compactMap { $0 } + settings.favoriteProjects + settings.recentProjects
        let wanted = repo.lowercased()
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let git = GitService.shared else { return nil }
            var seen = Set<String>()
            for folder in folders where seen.insert(WorkspacePathPolicy.normalize(folder)).inserted && FileManager.default.fileExists(atPath: folder) {
                if SourceForge.repository(remoteURL: git.remoteURL(folder))?.path.lowercased() == wanted { return folder }
            }
            return nil
        }.value
    }

    /// A worktree of its own on the pull request's branch; the new-session composer opens in it.
    func checkOutInWorktree(_ plan: PullRequestCheckoutPlan, preferred: String?) async throws {
        guard let folder = await localFolder(repo: plan.repository, preferred: preferred) else { throw NookError(tr("agents.pr.checkout.noFolder", plan.repository)) }
        guard let git = GitService.shared else { throw NookError(tr("agents.pr.checkout.noGit")) }
        let parent = (workspace.settings.worktreeRoot as NSString).expandingTildeInPath
        let reserved = Set(workspace.runs.compactMap(\.worktreePath))
        let path: String = try await Task.detached(priority: .userInitiated) {
            let root = git.repositoryRoot(for: folder) ?? folder
            let path = WorktreeNaming.worktreePath(root: parent, repoName: URL(fileURLWithPath: root).lastPathComponent, slug: WorktreeNaming.directorySlug(branch: plan.branch, prefix: ""),
                                                   exists: { reserved.contains($0) || FileManager.default.fileExists(atPath: $0) })
            try git.fetchPullRequest(plan, in: root)
            try git.addWorktree(repo: root, path: path, existingBranch: plan.branch)
            return path
        }.value
        openNewSession(in: path)
    }

    /// The pull request's branch in the folder itself. Refuses with changes in it, so nothing of yours gets mixed in.
    func checkOutHere(_ plan: PullRequestCheckoutPlan, preferred: String?) async throws {
        guard let folder = await localFolder(repo: plan.repository, preferred: preferred) else { throw NookError(tr("agents.pr.checkout.noFolder", plan.repository)) }
        guard let git = GitService.shared else { throw NookError(tr("agents.pr.checkout.noGit")) }
        try await Task.detached(priority: .userInitiated) {
            if try !git.status(folder).isClean { throw NookError(tr("agents.pr.checkout.dirty")) }
            try git.fetchPullRequest(plan, in: folder)
            _ = try git.run(["switch", plan.branch], in: folder)
        }.value
        openNewSession(in: folder)
    }

    /// A session on one of your machines, in the folder you last used there, on a branch of its own from the pull request.
    func checkOut(_ plan: PullRequestCheckoutPlan, on machine: RemoteMachine, pull: SessionPullRequestRef) async throws {
        guard RemotePasswords.shared.isUnlocked(machine) else { throw NookError(tr("agents.pr.checkout.locked", machine.name)) }
        let directory = UserDefaults.standard.string(forKey: "agents.remoteFolder." + machine.id) ?? "~"
        let target = RemoteTarget(machine: machine, directory: directory)
        let git = GitService(executable: "git", remote: target)
        let matches = await Task.detached(priority: .userInitiated) {
            SourceForge.repository(remoteURL: git.remoteURL(directory))?.path.lowercased() == plan.repository.lowercased()
        }.value
        guard matches else { throw NookError(tr("agents.pr.checkout.noFolderThere", plan.repository, machine.name)) }
        try await Task.detached(priority: .userInitiated) { _ = try git.run(["fetch", "origin", "+\(plan.ref):\(plan.remoteRef)"], in: directory, timeout: 180) }.value
        var config = sessionConfig(task: SessionPrompts.checkedOut(pull), provider: workspace.settings.defaultProvider, folder: nil, plan: false)
        config.remote = target
        config.isolation = .worktree
        config.branchName = plan.branch
        config.baseBranch = plan.remoteRef
        let id = try await workspace.start(config, allowSharedFolder: true)
        openWorkspace(run: id)
    }

    private func openNewSession(in folder: String) {
        PromptLinkInbox.shared.requestProject(folder)
        openWorkspace(newSession: true)
    }
}
