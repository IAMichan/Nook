import Foundation

/// Sessions on another machine (see RemoteMachines): the same agents and turns, started over SSH. Git runs there over
/// ssh too, so changes, diffs, commit and push work; what needs the folder on this Mac stays off for them: the workspace
/// bridge, checkpoints and worktrees.
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

    /// Finds out whether the remote folder is a repository, and on which branch; from then on its changes show as for a
    /// local session.
    func detectRemoteRepository(_ id: UUID) {
        guard let run = run(id), let remote = run.remote else { return }
        let git = GitService(executable: "git", remote: remote)
        let directory = run.workingDirectory
        Task.detached(priority: .utility) { [weak self] in
            guard let root = git.repositoryRoot(for: directory) else { return }
            let branch = git.currentBranch(directory)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.update(id) {
                    $0.repoRoot = root
                    if $0.branch == nil { $0.branch = branch }
                }
                self.refreshGit(id)
            }
        }
    }

    /// The launch as this session needs it: unchanged here, through ssh for a session on another machine. An ACP agent
    /// you added takes its own variables along; local account folders stay here.
    func placed(_ spec: LaunchSpec, for run: WorkspaceRun) -> LaunchSpec {
        guard let remote = run.remote else { return spec }
        let environment = run.provider == .acp ? (CustomAgents.agent(for: run.profileID)?.environment ?? [:]) : [:]
        return RemoteLaunch.wrap(spec, target: remote, environment: environment)
    }

    /// A new session on another machine: it starts in the folder there, under that machine's own login of the agent.
    func startRemote(_ config: NewRunConfig, on remote: RemoteTarget) -> UUID {
        let id = UUID()
        let now = Date()
        let title = config.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = remote.directory.trimmingCharacters(in: .whitespaces)
        var run = WorkspaceRun(
            id: id, title: title.isEmpty ? WorktreeNaming.title(from: config.task) : title, task: ContextRefs.visible(config.task),
            provider: config.provider, profileID: config.profileID, model: config.model, mode: config.mode,
            permission: config.permission, isolation: .folder, projectPath: directory, workingDirectory: directory,
            repoRoot: nil, branch: nil, baseBranch: nil, worktreePath: nil, instructions: config.instructions,
            status: .preparing, statusDetail: nil, providerSessionID: nil, createdAt: now, updatedAt: now, archived: false,
            usage: RunUsage(), turnStartedAt: nil, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil,
            delegation: config.delegation)
        run.remote = remote
        runs.insert(run, at: 0)
        events[id] = []
        selectedRunID = id
        append(id, RunEvent(kind: .system, text: tr("ws.remote.started", remote.name, remote.host, directory)))
        let visibleTask = ContextRefs.visible(config.task)
        if visibleTask != config.task { displayPrompt[id] = visibleTask }
        launchTurn(id, prompt: config.task, executable: config.provider.kind.command)
        detectRemoteRepository(id)
        if title.isEmpty { generateTitle(id) }
        return id
    }
}
