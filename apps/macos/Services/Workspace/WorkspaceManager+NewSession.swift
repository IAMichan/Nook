import Foundation

/// Starting a session: inspecting its project, preparing its folder or worktree, the first turn, and taking over a
/// session that already runs elsewhere; then changing its mode, rights and model.
extension WorkspaceManager {
    // MARK: Inspecting Project

    /// Last inspected metadata for `path`, if already known in this launch.
    func cachedProject(_ path: String) -> ProjectInfo? {
        projectCache[WorkspacePathPolicy.normalize(path)]
    }

    /// Whether `base` in `root` needs a fresh `git fetch` (at most once every two minutes per repository and base branch).
    func shouldRefreshRemoteBase(root: String, base: String, now: Date = Date()) -> Bool {
        let key = WorkspacePathPolicy.normalize(root) + "\n" + base
        if let last = remoteBaseRefreshed[key], now.timeIntervalSince(last) < 120 { return false }
        remoteBaseRefreshed[key] = now
        return true
    }

    private func warmRemoteBase(_ base: String, in root: String) {
        guard base.contains("/"), let git = gitService, shouldRefreshRemoteBase(root: root, base: base) else { return }
        Task.detached(priority: .utility) { git.refreshRemoteBase(base, in: root) }
    }

    /// Information required by "New Session" for a directory. Evaluated off the main thread.
    func inspectProject(_ path: String) async -> ProjectInfo {
        let git = gitService
        let info = await Task.detached(priority: .userInitiated) {
            let normalized = WorkspacePathPolicy.normalize(path)
            var info = ProjectInfo(path: normalized, name: (normalized as NSString).lastPathComponent,
                                   verdict: WorkspacePathPolicy.verdict(for: normalized), repoRoot: nil, currentBranch: nil,
                                   branches: [], defaultBase: nil, hasCommits: false, dirtyFiles: 0, isWorktree: false)
            guard info.verdict == .ok, let git, let root = git.repositoryRoot(for: normalized) else { return info }
            info.repoRoot = root
            let current = git.currentBranch(root)
            info.currentBranch = current
            info.hasCommits = git.hasCommits(root)
            let branchLists = try? git.branches(root)
            if let branchLists { info.branches = branchLists.local + branchLists.remote }
            info.defaultBase = git.worktreeBaseBranch(root, localBranches: branchLists?.local, fallbackBranch: current)
            info.dirtyFiles = git.changedFileCount(root) ?? 0
            if let common = git.commonDirectory(for: root) {
                info.isWorktree = WorkspacePathPolicy.normalize(URL(fileURLWithPath: common).deletingLastPathComponent().path)
                    != WorkspacePathPolicy.normalize(root)
            }
            return info
        }.value
        projectCache[info.path] = info
        if let root = info.repoRoot {
            projectCache[WorkspacePathPolicy.normalize(root)] = info
            if let base = info.defaultBase { warmRemoteBase(base, in: root) }
        }
        return info
    }

    // MARK: New Session

    enum StartError: LocalizedError {
        case config(ConfigProblem)
        case workspace(WorkspacePathPolicy.Verdict)
        case noExecutable(RunProvider)
        case noGit
        case notRepository
        case shared(String)
        case git(String)

        var errorDescription: String? {
            switch self {
            case .config(let problem): return tr("ws.error.config." + problem.rawValue)
            case .workspace(let verdict): return tr("ws.error.path." + String(describing: verdict))
            case .noExecutable(let provider): return tr("ws.error.noExecutable", provider.displayName)
            case .noGit: return tr("ws.error.noGit")
            case .notRepository: return tr("ws.error.notRepository")
            case .shared(let title): return tr("ws.error.shared", title)
            case .git(let message): return message
            }
        }
    }

    /// Validates configuration, opens the session immediately in the workspace, and prepares its folder or worktree
    /// while launching the agent. If worktree or agent startup fails, the session is marked "failed" and can be retried
    /// with "Retry" without duplicating the session.
    @discardableResult
    func start(_ config: NewRunConfig, allowSharedFolder: Bool = false) async throws -> UUID {
        // "Auto": the agent and account that fit the task and limits best (see `autoTarget`).
        var config = config.model == AutoModel.id ? autoTarget(config) : config
        if let problem = config.problem { throw StartError.config(problem) }
        // A main thread knows it from its first message (`MainThread`); an idle start learns it with your first message.
        if let note = MainThread.pending(on: config.mainThread, told: nil),
           !config.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.task = MainThread.attach(note, to: config.task)
        }
        // On another machine: no folder, git or worktree to prepare here.
        if let remote = config.remote { return try await startRemote(config, on: remote) }
        let projectPath = WorkspacePathPolicy.normalize(config.projectPath)
        let verdict = WorkspacePathPolicy.verdict(for: projectPath)
        guard verdict == .ok else { throw StartError.workspace(verdict) }
        guard let executable = executable(config.provider, profileID: config.profileID) else { throw StartError.noExecutable(config.provider) }

        let id = UUID()
        var workingDirectory = projectPath
        let cached = projectCache[projectPath]
        var repoRoot = cached?.repoRoot
        var branch = cached?.currentBranch
        var worktreePath: String?
        let git = gitService

        if config.isolation == .worktree {
            guard let git else { throw StartError.noGit }
            if repoRoot == nil {
                repoRoot = await Task.detached(priority: .userInitiated) { git.repositoryRoot(for: projectPath) }.value
            }
            guard let root = repoRoot else { throw StartError.notRepository }
            // The project's own branch prefix (Settings › Workspace, per project) wins over the global one.
            let prefix = settings.sessionDefaults(for: root).branchPrefix
            let name = ProjectSettings.branchName(config.branchName, globalPrefix: WorktreeNaming.branchPrefix, projectPrefix: prefix)
            let rootFolder = config.worktreeRoot.isEmpty ? settings.worktreeRoot : config.worktreeRoot
            let repoName = (root as NSString).lastPathComponent
            let reserved = Set(runs.compactMap(\.worktreePath))
            let path = WorktreeNaming.worktreePath(root: (rootFolder as NSString).expandingTildeInPath, repoName: repoName,
                                                   slug: WorktreeNaming.directorySlug(branch: name, prefix: prefix),
                                                   exists: { reserved.contains($0) || FileManager.default.fileExists(atPath: $0) })
            workingDirectory = path
            worktreePath = path
            branch = name
        } else {
            if !allowSharedFolder, let other = activeRuns(sharing: projectPath).first {
                throw StartError.shared(other.title)
            }
        }

        let now = Date()
        let title = config.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTask = ContextRefs.visible(config.task)
        var run = WorkspaceRun(
            id: id,
            title: title.isEmpty ? WorktreeNaming.title(from: config.task) : title,
            task: visibleTask,
            provider: config.provider,
            profileID: config.profileID,
            model: config.model,
            mode: config.mode,
            permission: config.permission,
            isolation: config.isolation,
            projectPath: repoRoot ?? projectPath,
            workingDirectory: workingDirectory,
            repoRoot: repoRoot,
            branch: branch,
            baseBranch: config.isolation == .worktree ? config.baseBranch : nil,
            worktreePath: worktreePath,
            instructions: config.instructions,
            status: .preparing,
            statusDetail: nil,
            providerSessionID: nil,
            createdAt: now,
            updatedAt: now,
            archived: false,
            usage: RunUsage(),
            turnStartedAt: now,
            reviewedAt: nil,
            lastChangeAt: nil,
            changedFiles: nil,
            delegation: config.delegation
        )
        run.effort = config.effort
        run.speedTier = config.speedTier
        run.ultracode = config.ultracode
        run.mainThread = config.mainThread
        run.mainThreadTold = MainThread.toldAtStart(config)
        run.lineage = config.lineage
        // "Auto": the model is picked for each turn as it starts (see `applyAutoModel`).
        if config.model == AutoModel.id {
            run.autoModel = true
            run.model = ""
        }
        // Ready and waiting for your first message: nothing to launch yet (a worktree is still made first).
        let idle = config.startsIdle && config.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if idle, worktreePath == nil {
            run.status = .completed
            run.turnStartedAt = nil
        }
        runs.insert(run, at: 0)
        events[id] = []
        settings.rememberProject(repoRoot ?? projectPath)
        selectedRunID = id
        if let startedBy = config.startedBy, !startedBy.isEmpty { append(id, RunEvent(kind: .system, text: startedBy, tool: "origin")) }
        let shownTask = ContextRefs.timeline(config.task, folder: workingDirectory)
        if shownTask != config.task { displayPrompt[id] = shownTask }
        if let worktreePath, let root = repoRoot {
            append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeCreated", branch ?? "", AgentPathFormat.tilde(worktreePath))))
            if !idle { append(id, RunEvent(kind: .user, text: shownPrompt(id, config.task))) }
            prepareWorktreeAndLaunch(id, root: root, path: worktreePath, branch: branch ?? "", base: config.baseBranch,
                                     prompt: idle ? "" : config.task, executable: executable)
        } else {
            if !idle { launchTurn(id, prompt: config.task, executable: executable) }
            prepareFolderSession(id, directory: workingDirectory, knownRoot: repoRoot, knownBranch: branch)
        }
        if title.isEmpty { generateTitle(id) }
        return id
    }

    /// Creates the session's worktree off the main thread (serialized per repository via `FolderLease`), launches the
    /// agent as soon as the checkout exists, and records the initial snapshot and setup scripts in the background.
    func prepareWorktreeAndLaunch(_ id: UUID, root: String, path: String, branch: String, base: String,
                                  prompt: String, executable: String) {
        guard let git = gitService else { return }
        let refreshBase = shouldRefreshRemoteBase(root: root, base: base)
        let repoKey = FolderLease.key(root)
        let ref = GitService.checkpointRef(session: id, index: claimCheckpointIndex(id))
        let checkout = worktreeCheckout(git, root: root)
        prepareTasks[id]?.cancel()
        prepareTasks[id] = Task { [weak self] in
            let submoduleProblem: String?
            do {
                submoduleProblem = try await FolderLease.shared.run(repoKey, priority: .userInitiated) {
                    let cloned = try git.addWorktree(repo: root, path: path, branch: branch, base: base, refreshBase: refreshBase,
                                                     checkoutCache: checkout.cache)
                    return Self.finishWorktree(git, checkout: checkout, root: root, path: path, cloned: cloned)
                }
            } catch {
                guard let self, !Task.isCancelled, self.run(id) != nil else { return }
                self.prepareTasks[id] = nil
                self.update(id) {
                    $0.worktreePath = nil
                    $0.workingDirectory = root
                    $0.move(to: .failed, detail: error.localizedDescription)
                }
                self.append(id, RunEvent(kind: .error, text: error.localizedDescription))
                return
            }
            guard let self, !Task.isCancelled, self.run(id)?.status == .preparing else { return }
            self.update(id) {
                $0.workingDirectory = path
                $0.worktreePath = path
                $0.branch = branch
            }
            if let submoduleProblem { self.append(id, RunEvent(kind: .error, text: tr("sc.submodules.failed", submoduleProblem))) }
            // The project's setup (nook.json `runOnWorktreeCreate`). One with `"async": false` holds the first turn until
            // it ended; meanwhile the session stays preparing, and stopping it stops the wait.
            let setup = ProjectScripts.setup(await Task.detached(priority: .userInitiated) { ProjectScripts.load(folder: path) }.value)
            guard !Task.isCancelled, self.run(id)?.status == .preparing else { return }
            let holds = setup.holdsAgent && !prompt.isEmpty
            if !holds {
                self.prepareTasks[id] = nil
                self.startFirstTurn(id, prompt: prompt, executable: executable)
            }
            // The first snapshot, before the agent does anything: a new worktree is its branch's HEAD.
            let worktreeKey = FolderLease.key(path)
            let made = (try? await FolderLease.shared.run(worktreeKey, priority: .userInitiated) {
                try git.checkpointHead(path, ref: ref)
            }) != nil
            if made {
                self.recordInitialCheckpoint(id, RunCheckpoint(ref: ref, date: Date(), conversation: .empty))
            }
            guard !Task.isCancelled, self.run(id) != nil else { return }
            let failure = await self.startSetupScripts(id, path: path, scripts: setup.scripts)
            guard holds, !Task.isCancelled, self.run(id)?.status == .preparing else { return }
            self.prepareTasks[id] = nil
            if let failure {
                self.update(id) { $0.move(to: .failed, detail: failure) }
                self.append(id, RunEvent(kind: .error, text: failure))
                return
            }
            self.startFirstTurn(id, prompt: prompt, executable: executable)
        }
    }

    /// The first turn of a session in a new worktree; without a first message, the session waits for yours.
    private func startFirstTurn(_ id: UUID, prompt: String, executable: String) {
        if prompt.isEmpty {
            update(id) {
                $0.status = .completed
                $0.turnStartedAt = nil
            }
        } else {
            launchTurn(id, prompt: prompt, executable: executable, showPrompt: false)
        }
    }

    /// Starts the project's setup scripts in terminals next to the session, and returns once the ones with
    /// `"async": false` ended: nil when they succeeded (or none waits), else what went wrong. While it waits it reads
    /// the script's exit-code file twice a second; nothing runs when no script holds the agent.
    func startSetupScripts(_ id: UUID, path: String, scripts: [ProjectScript]) async -> String? {
        var waiting: [(name: String, status: String, open: @MainActor () -> Bool)] = []
        for script in scripts {
            if script.async {
                _ = runScript?(path, script.command, script.name)
                append(id, RunEvent(kind: .system, text: tr("ws.event.setupScript", script.name)))
                continue
            }
            let status = FileManager.default.temporaryDirectory.appendingPathComponent("nook-setup-\(UUID().uuidString)").path
            guard let open = runScript?(path, ProjectScripts.blockingCommand(script.command, statusFile: status), script.name) else { continue }
            append(id, RunEvent(kind: .system, text: tr("ws.event.setupScriptWaiting", script.name)))
            waiting.append((script.name, status, open))
        }
        var failure: String?
        for item in waiting {
            defer { try? FileManager.default.removeItem(atPath: item.status) }
            while !Task.isCancelled {
                let wasOpen = item.open()
                if let code = ProjectScripts.exitStatus(FileManager.default.contents(atPath: item.status)) {
                    if code != 0, failure == nil { failure = tr("ws.event.setupScriptFailed", item.name, String(code)) }
                    break
                }
                if !wasOpen {
                    failure = failure ?? tr("ws.event.setupScriptClosed", item.name)
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return failure
    }

    /// Resolves git metadata and captures the initial folder snapshot in the background without delaying the first turn.
    func prepareFolderSession(_ id: UUID, directory: String, knownRoot: String?, knownBranch: String?,
                              includeComparisonBase: Bool = false) {
        guard let git = gitService else { return }
        let ref = GitService.checkpointRef(session: id, index: claimCheckpointIndex(id))
        let key = FolderLease.key(directory)
        Task { [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) { () -> (root: String?, branch: String?, base: String?) in
                guard let root = knownRoot ?? git.repositoryRoot(for: directory) else { return (nil, nil, nil) }
                let branch = knownBranch ?? git.currentBranch(directory)
                var base: String?
                if includeComparisonBase, let current = branch {
                    let remotes = git.remotes(directory)
                    let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
                    if let main = git.defaultBranch(directory, remote: remote), main != current {
                        base = git.comparisonBase(directory, base: main, remote: remote)
                    }
                }
                return (root, branch, base)
            }.value
            guard let self, self.run(id) != nil, let root = resolved.root else { return }
            self.update(id) {
                if $0.repoRoot == nil { $0.repoRoot = root }
                if $0.branch == nil, let branch = resolved.branch { $0.branch = branch }
                if $0.baseBranch == nil, let base = resolved.base { $0.baseBranch = base }
            }
            let made = (try? await FolderLease.shared.run(key, priority: .userInitiated) {
                try git.checkpoint(directory, ref: ref)
            }) != nil
            if made {
                self.recordInitialCheckpoint(id, RunCheckpoint(ref: ref, date: Date(), conversation: .empty))
            }
        }
    }

    func claimCheckpointIndex(_ id: UUID) -> Int {
        let next = max(checkpointIndices[id] ?? 0, run(id)?.checkpoints?.count ?? 0)
        checkpointIndices[id] = next + 1
        return next
    }

    func recordInitialCheckpoint(_ id: UUID, _ checkpoint: RunCheckpoint) {
        update(id) {
            let existing = ($0.checkpoints ?? []).filter { $0.ref != checkpoint.ref }
            $0.checkpoints = [checkpoint] + existing
        }
    }

    /// Takes over an existing agent conversation (running in a terminal, or an earlier session) as a Nook session.
    /// Nothing starts yet: the first message resumes the conversation (`--resume`, `exec resume`). `fork` makes that
    /// first turn a copy (Claude Code only), so a conversation that is still running elsewhere is never written to twice.
    /// Already taken over? Returns that session instead of adding a second one.
    @discardableResult
    func adopt(provider: RunProvider, sessionID: String, profileID: String, directory: String, title: String,
               history: [(kind: RunEvent.Kind, text: String)] = [], fork: Bool = false,
               continuesConversation: Bool = true) async throws -> UUID {
        let taken = runs.first { $0.provider == provider && (fork ? $0.copiedFrom == sessionID : $0.isConversation(sessionID)) }
        if let existing = taken {
            if existing.archived { setArchived(existing.id, false) }
            selectedRunID = existing.id
            return existing.id
        }
        let projectPath = WorkspacePathPolicy.normalize(directory)
        let verdict = WorkspacePathPolicy.verdict(for: projectPath)
        guard verdict == .ok else { throw StartError.workspace(verdict) }
        guard executable(provider) != nil else { throw StartError.noExecutable(provider) }

        let cached = projectCache[projectPath]
        let repoRoot = cached?.repoRoot
        let branch = cached?.currentBranch
        let id = UUID()
        let now = Date()
        let clean = InjectedPrompt.title(title)
        // A conversation without a title of its own is named after its first question until an agent writes a better one.
        let opening = history.first { $0.kind == .user }.map { InjectedPrompt.title($0.text) } ?? ""
        let task = clean.isEmpty ? opening : clean
        let permission = settings.sessionDefaults(for: repoRoot ?? projectPath).permission(for: provider)
        let run = WorkspaceRun(
            id: id,
            title: task.isEmpty ? (projectPath as NSString).lastPathComponent : WorktreeNaming.title(from: task),
            task: task,
            provider: provider,
            profileID: profileID,
            model: "",
            mode: .agent,
            permission: permission,
            isolation: .folder,
            projectPath: projectPath,
            workingDirectory: projectPath,
            repoRoot: repoRoot,
            branch: branch,
            baseBranch: nil,
            worktreePath: nil,
            instructions: "",
            status: .completed,
            statusDetail: nil,
            // An agent that cannot load this conversation itself starts a new one from it (see carryOverConversation).
            providerSessionID: continuesConversation ? sessionID : nil,
            createdAt: now,
            updatedAt: now,
            archived: false,
            usage: RunUsage(),
            turnStartedAt: nil,
            reviewedAt: nil,
            lastChangeAt: nil,
            changedFiles: nil
        )
        var adopted = run
        if !continuesConversation { adopted.carriedOverFrom = sessionID }
        if fork { adopted.copiedFrom = sessionID }
        runs.insert(adopted, at: 0)
        events[id] = []
        if fork { forkNext.insert(id) }
        settings.rememberProject(repoRoot ?? projectPath)
        selectedRunID = id
        for entry in history where !entry.text.isEmpty {
            append(id, RunEvent(kind: entry.kind, text: entry.text, state: entry.kind == .assistant ? .done : nil))
        }
        append(id, RunEvent(kind: .system, text: tr(fork ? "ws.event.adoptedFork" : "ws.event.adopted", provider.displayName)))
        scheduleSave()
        // Resolve repository metadata and take the starting snapshot in the background without blocking an immediate reply.
        prepareFolderSession(id, directory: projectPath, knownRoot: repoRoot, knownBranch: branch, includeComparisonBase: true)
        if clean.isEmpty, !opening.isEmpty { generateTitle(id) }
        if !continuesConversation { carryOverConversation(id, prompt: nil) }
        return id
    }

    /// Changes how the next turn runs: mode, permissions, and model. Also while a turn runs (a session Nook took over as
    /// much as one it started): an agent with `liveSettings` takes them over at once (see `applyLive`), Codex and
    /// Antigravity from their next turn. Rights count right away either way: Nook answers what they now cover itself (see `LiveRights`),
    /// the requests already waiting included.
    func configure(_ id: UUID, mode: ExecutionMode? = nil, permission: PermissionPolicy? = nil, model: String? = nil) {
        guard let run = run(id) else { return }
        let before = model == nil ? nil : switchEndpoint(run)
        update(id) {
            if let mode { $0.mode = mode }
            if let permission, run.provider.capabilities.policies.contains(permission) {
                $0.permission = permission
                if permission != run.permission { sessionApprovals[id]?.modeChanged(to: permission) }
            }
            if let model {
                let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
                // "Auto" keeps the model in use until the next turn picks one.
                $0.autoModel = clean == AutoModel.id ? true : nil
                if clean != AutoModel.id { $0.model = clean }
            }
        }
        if let before { noteModelSwitch(id, from: before) }
        if run.status.isActive, let updated = self.run(id) { applyLive(id, from: run, to: updated) }
        if let updated = self.run(id), updated.permission != run.permission || updated.mode != run.mode { allowCovered(id) }
        if !run.status.isActive { refreshWarmSession(id) }
    }

    /// Keeps an idle session's warm connection in step when you change its model, mode, rights or effort before sending.
    func refreshWarmSession(_ id: UUID) {
        guard let run = run(id), !run.status.isActive, processes[id] == nil else { return }
        switch run.provider {
        case .claude:
            guard let idle = claudeIdle[id], idle.key != claudeKey(run) else { return }
            closeClaudeProcess(id)
            prewarm(id)
        case .codex:
            break
        case .pi:
            break
        case .gemini, .opencode, .cursor, .grok, .antigravity, .acp:
            guard let client = acpClients[id], client.isRunning, client.sessionID != nil else { return }
            applyAcpSettings(id, client) {}
        }
    }
}
