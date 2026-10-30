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
        let now = Date()
        let title = config.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTask = ContextRefs.visible(config.task)
        let branch: String? = config.isolation == .worktree ? config.branchName : nil
        let requestedBase = config.baseBranch.trimmingCharacters(in: .whitespaces)
        var run = WorkspaceRun(
            id: id, title: title.isEmpty ? WorktreeNaming.title(from: config.task) : title, task: visibleTask,
            provider: config.provider, profileID: config.profileID, model: config.model, mode: config.mode,
            permission: config.permission, isolation: config.isolation, projectPath: directory, workingDirectory: directory,
            repoRoot: nil, branch: branch, baseBranch: config.isolation == .worktree ? (requestedBase.isEmpty ? nil : requestedBase) : nil,
            worktreePath: nil, instructions: config.instructions,
            status: .preparing, statusDetail: nil, providerSessionID: nil, createdAt: now, updatedAt: now, archived: false,
            usage: RunUsage(), turnStartedAt: now, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil,
            delegation: config.delegation)
        var target = remote
        target.directory = directory
        run.remote = target
        run.effort = config.effort
        runs.insert(run, at: 0)
        events[id] = []
        selectedRunID = id
        if visibleTask != config.task { displayPrompt[id] = visibleTask }
        append(id, RunEvent(kind: .system, text: tr("ws.remote.started", remote.name, remote.host, directory)))
        append(id, RunEvent(kind: .user, text: shownPrompt(id, config.task)))
        if title.isEmpty { generateTitle(id) }

        if config.isolation == .folder {
            launchTurn(id, prompt: config.task, executable: config.provider.kind.command, showPrompt: false)
        }
        let ref = GitService.checkpointRef(session: id, index: claimCheckpointIndex(id))
        prepareTasks[id] = Task { [weak self] in
            let repoRoot = await Task.detached(priority: .userInitiated) { git.repositoryRoot(for: directory) }.value
            guard let self, !Task.isCancelled, self.run(id) != nil else { return }
            if config.isolation == .worktree {
                guard let root = repoRoot else {
                    self.prepareTasks[id] = nil
                    let detail = StartError.notRepository.errorDescription ?? ""
                    self.update(id) { $0.move(to: .failed, detail: detail) }
                    self.append(id, RunEvent(kind: .error, text: detail))
                    return
                }
                let name = config.branchName
                do {
                    let created = try await Task.detached(priority: .userInitiated) { () throws -> (path: String, base: String) in
                        guard let home = RemoteShell.home(remote) else { throw GitError(tr("ws.remote.noHome")) }
                        let base = requestedBase.isEmpty ? (git.currentBranch(root) ?? "HEAD") : requestedBase
                        let path = WorktreeNaming.worktreePath(
                            root: RemoteShell.worktreeRoot(home: home),
                            repoName: URL(fileURLWithPath: root).lastPathComponent,
                            slug: WorktreeNaming.directorySlug(branch: name),
                            exists: { RemoteShell.exists($0, on: remote) })
                        try git.addWorktree(repo: root, path: path, branch: name, base: base)
                        return (path, base)
                    }.value
                    guard !Task.isCancelled, self.run(id)?.status == .preparing else { return }
                    self.prepareTasks[id] = nil
                    var updatedTarget = remote
                    updatedTarget.directory = created.path
                    self.update(id) {
                        $0.projectPath = root
                        $0.repoRoot = root
                        $0.workingDirectory = created.path
                        $0.worktreePath = created.path
                        $0.branch = name
                        $0.baseBranch = created.base
                        $0.remote = updatedTarget
                    }
                    self.append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeCreated", name, created.path)))
                    self.launchTurn(id, prompt: config.task, executable: config.provider.kind.command, showPrompt: false)
                    let folder = created.path
                    let made = (try? await Task.detached(priority: .userInitiated) { try git.checkpointHead(folder, ref: ref) }.value) != nil
                    if made { self.recordInitialCheckpoint(id, RunCheckpoint(ref: ref, date: Date(), conversation: .empty)) }
                    self.refreshGit(id)
                } catch {
                    guard !Task.isCancelled, self.run(id) != nil else { return }
                    self.prepareTasks[id] = nil
                    self.update(id) { $0.move(to: .failed, detail: error.localizedDescription) }
                    self.append(id, RunEvent(kind: .error, text: error.localizedDescription))
                }
            } else {
                self.prepareTasks[id] = nil
                guard let root = repoRoot else { return }
                let remoteBranch = await Task.detached(priority: .userInitiated) { git.currentBranch(directory) }.value
                self.update(id) {
                    $0.projectPath = root
                    $0.repoRoot = root
                    $0.branch = remoteBranch
                }
                let made = (try? await Task.detached(priority: .userInitiated) { try git.checkpoint(directory, ref: ref) }.value) != nil
                if made { self.recordInitialCheckpoint(id, RunCheckpoint(ref: ref, date: Date(), conversation: .empty)) }
                self.refreshGit(id)
            }
        }
        return id
    }
}
