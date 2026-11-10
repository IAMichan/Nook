import Foundation

/// Sessions on another machine (see RemoteMachines): the same agents and turns, started over SSH. Git runs there over
/// ssh too: changes, diffs, commit and push, snapshots per turn, restoring them, and worktrees. Of the workspace bridge
/// the agent gets what cannot touch this Mac (see `RemoteBridge`).
extension WorkspaceManager {
    /// The program that starts this session's agent: its path on this Mac, or on another machine just its name (the
    /// remote login shell finds it).
    func launchExecutable(_ run: WorkspaceRun) -> String? {
        run.remote != nil ? run.provider.kind.command : executable(run.provider, profileID: run.profileID)
    }

    /// Nook's tools for the agent. On another machine they wait until the server is there (`prepareRemoteBridge`): a session
    /// runs without them until then.
    func bridge(for id: UUID) -> BridgeLaunch? {
        guard var launch = bridgeLaunch(), let run = run(id) else { return nil }
        guard let remote = run.remote else {
            launch.token = bridgeToken(id)
            return launch
        }
        guard let home = remoteHomes[remote.machineID] else {
            Task { await prepareRemoteBridge(remote) }
            return nil
        }
        return BridgeLaunch(script: RemoteBridge.scriptPath(home: home),
                            remote: .init(socket: RemoteBridge.socketPath(home: home, run: id), token: bridgeToken(id)))
    }

    /// The token that proves the agent is this session's, for this run of Nook. Kept in memory only: after a restart of
    /// Nook every agent is started again and gets a new one.
    func bridgeToken(_ id: UUID) -> String {
        if let token = bridgeTokens[id] { return token }
        let token = UUID().uuidString + UUID().uuidString
        bridgeTokens[id] = token
        return token
    }

    /// Whether `token` is the one made for the remote session `id`.
    func acceptsRemoteBridge(_ id: UUID, token: String) -> Bool {
        // Only while its agent works: a stopped session's token opens nothing.
        guard let run = run(id), run.isRemote, run.status.isActive else { return false }
        return BridgeIdentity.matches(bridgeTokens[id], token)
    }

    /// Whether `token` is the one made for the session `id` on this Mac. A call that names a session without its token
    /// gets no rights of that session.
    func acceptsLocalBridge(_ id: UUID, token: String) -> Bool {
        guard let run = run(id), !run.isRemote else { return false }
        return BridgeIdentity.matches(bridgeTokens[id], token)
    }

    /// Puts Nook's MCP server on the machine, once per run of Nook.
    func prepareRemoteBridge(_ remote: RemoteTarget) async {
        guard bridgeLaunch() != nil, remoteHomes[remote.machineID] == nil else { return }
        // Another session is installing it: this one starts with the tools too, within what that install may take.
        if remoteBridgeInstalling.contains(remote.machineID) {
            for _ in 0..<260 where remoteBridgeInstalling.contains(remote.machineID) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }
        remoteBridgeInstalling.insert(remote.machineID)
        let home = await Task.detached(priority: .userInitiated) {
            RemoteShell.installBridge(remote, script: WorkspaceBridgeScript.contents)
        }.value
        remoteBridgeInstalling.remove(remote.machineID)
        remoteHomes[remote.machineID] = home
    }

    /// Git for this session's folder: on this Mac, or for a session on another machine over ssh there.
    func sessionGit(for run: WorkspaceRun) -> GitService? {
        guard let remote = run.remote else { return gitService }
        return GitService(executable: "git", remote: remote)
    }

    /// The launch as this session needs it: unchanged here, through ssh for a session on another machine. An ACP agent
    /// you added takes its own variables along; local account folders stay here.
    func placed(_ spec: LaunchSpec, for run: WorkspaceRun) -> LaunchSpec {
        // The arguments the account adds go on every launch of its agent, here or over ssh.
        var spec = spec
        spec.arguments += accountArguments(run.profileID)
        guard let remote = run.remote else { return spec }
        let environment = run.provider == .acp ? (CustomAgents.agent(for: run.profileID)?.environment ?? [:]) : [:]
        let forward = bridge(for: run.id)?.remote.map { RemoteBridge.forward(socket: $0.socket, local: NookPaths.remoteBridgeSocketURL.path) } ?? []
        return RemoteLaunch.wrap(spec, target: remote, environment: environment, forward: forward)
    }

    /// A new session on another machine: in the folder there, or in a new worktree there (~/.nook/worktrees), under that
    /// machine's own login of the agent. Git runs there over ssh, so snapshots and the diff work as for a local session.
    func startRemote(_ config: NewRunConfig, on remote: RemoteTarget) async throws -> UUID {
        await prepareRemoteBridge(remote)
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
        // "Auto": the model is picked for each turn as it starts (see `applyAutoModel`).
        if config.model == AutoModel.id {
            run.autoModel = true
            run.model = ""
        }
        runs.insert(run, at: 0)
        events[id] = []
        selectedRunID = id
        if visibleTask != config.task { displayPrompt[id] = visibleTask }
        append(id, RunEvent(kind: .system, text: tr("ws.remote.started", remote.name, remote.host, directory)))
        RemoteMachines.markUsed(id: remote.machineID)
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
                let submodules = self.settings.sessionDefaults(for: root).submodules
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
                        // Same as on this Mac; a submodule that fails leaves the worktree usable.
                        try? git.updateSubmodules(path, mode: submodules)
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
