import Foundation

/// Sessions on another machine (see RemoteMachines): the same agents and turns, started over SSH. Git runs there over
/// ssh too: changes, diffs, commit and push, snapshots per turn, restoring them, and worktrees. Only the workspace bridge
/// (Nook's terminal, browser and pull requests for the agent) needs this Mac and stays off.
extension WorkspaceManager {
    /// The program that starts this session's agent: its path on this Mac, or on another machine just its name (the
    /// remote login shell finds it).
    func launchExecutable(_ run: WorkspaceRun) -> String? {
        run.remote != nil ? run.provider.kind.command : executable(run.provider)
    }

    /// Nook's terminal, browser and pull requests for the agent: only for sessions on this Mac.
    func bridge(for id: UUID) -> BridgeLaunch? {
        run(id)?.isRemote == true ? nil : bridgeLaunch()
    }

    /// Git for this session's folder: on this Mac, or for a session on another machine over ssh there.
    func sessionGit(for run: WorkspaceRun) -> GitService? {
        guard let remote = run.remote else { return gitService }
        return GitService(executable: "git", remote: remote)
    }

    /// The launch as this session needs it: unchanged here, through ssh for a session on another machine. An ACP agent
    /// you added takes its own variables along; local account folders stay here.
    func placed(_ spec: LaunchSpec, for run: WorkspaceRun) -> LaunchSpec {
        guard let remote = run.remote else { return spec }
        let environment = run.provider == .acp ? (CustomAgents.agent(for: run.profileID)?.environment ?? [:]) : [:]
        return RemoteLaunch.wrap(spec, target: remote, environment: environment)
    }

    /// A new session on another machine: in the folder there, or in a new worktree there (~/.nook/worktrees), under that
    /// machine's own login of the agent. Git runs there over ssh, so snapshots and the diff work as for a local session.
    func startRemote(_ config: NewRunConfig, on remote: RemoteTarget) async throws -> UUID {
        let id = UUID()
        let git = GitService(executable: "git", remote: remote)
        let directory = remote.directory.trimmingCharacters(in: .whitespaces)
        var workingDirectory = directory
        var branch: String?
        var base: String?
        var worktreePath: String?
        let repoRoot = await Task.detached(priority: .userInitiated) { git.repositoryRoot(for: directory) }.value

        if config.isolation == .worktree {
            guard let root = repoRoot else { throw StartError.notRepository }
            let name = config.branchName
            let requested = config.baseBranch
            let path = try await Task.detached(priority: .userInitiated) { () throws -> (path: String, base: String) in
                guard let home = RemoteShell.home(remote) else { throw GitError(tr("ws.remote.noHome")) }
                let base = requested.isEmpty ? (git.currentBranch(root) ?? "HEAD") : requested
                let path = WorktreeNaming.worktreePath(root: RemoteShell.worktreeRoot(home: home), repoName: URL(fileURLWithPath: root).lastPathComponent,
                                                       slug: WorktreeNaming.directorySlug(branch: name),
                                                       exists: { RemoteShell.exists($0, on: remote) })
                try git.addWorktree(repo: root, path: path, branch: name, base: base)
                return (path, base)
            }.value
            workingDirectory = path.path
            worktreePath = path.path
            branch = name
            base = path.base
        } else if repoRoot != nil {
            branch = await Task.detached(priority: .userInitiated) { git.currentBranch(directory) }.value
        }

        let now = Date()
        let title = config.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var run = WorkspaceRun(
            id: id, title: title.isEmpty ? WorktreeNaming.title(from: config.task) : title, task: ContextRefs.visible(config.task),
            provider: config.provider, profileID: config.profileID, model: config.model, mode: config.mode,
            permission: config.permission, isolation: config.isolation, projectPath: repoRoot ?? directory, workingDirectory: workingDirectory,
            repoRoot: repoRoot, branch: branch, baseBranch: base, worktreePath: worktreePath, instructions: config.instructions,
            status: .preparing, statusDetail: nil, providerSessionID: nil, createdAt: now, updatedAt: now, archived: false,
            usage: RunUsage(), turnStartedAt: nil, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil,
            delegation: config.delegation)
        // The agent starts where the session works: the folder, or the new worktree.
        var target = remote
        target.directory = workingDirectory
        run.remote = target
        run.effort = config.effort
        runs.insert(run, at: 0)
        events[id] = []
        selectedRunID = id
        append(id, RunEvent(kind: .system, text: tr("ws.remote.started", remote.name, remote.host, workingDirectory)))
        if let worktreePath {
            append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeCreated", branch ?? "", worktreePath)))
        }
        // The first snapshot, before the agent starts: a new worktree is exactly HEAD, a folder is read as it is.
        if repoRoot != nil {
            let ref = GitService.checkpointRef(session: id, index: 0)
            let folder = workingDirectory
            let fresh = worktreePath != nil
            let made = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    if fresh { try git.checkpointHead(folder, ref: ref) } else { try git.checkpoint(folder, ref: ref) }
                    return true
                } catch {
                    return false
                }
            }.value
            if made { update(id) { $0.checkpoints = [RunCheckpoint(ref: ref, date: Date())] } }
            refreshGit(id)
        }
        let visibleTask = ContextRefs.visible(config.task)
        if visibleTask != config.task { displayPrompt[id] = visibleTask }
        launchTurn(id, prompt: config.task, executable: config.provider.kind.command)
        if title.isEmpty { generateTitle(id) }
        return id
    }
}
