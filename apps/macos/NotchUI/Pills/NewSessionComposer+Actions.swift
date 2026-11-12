import SwiftUI
import AppKit

/// What the composer does: drafts, the project and machine it starts in, the agent it starts, and starting it.
extension NewSessionComposer {
    // MARK: Actions

    /// A link only fills the draft (and picks a project, agent or model when they exist here); you read it and press send.
    func applyPromptLink() {
        guard let link = promptLinks.pending else { return }
        promptLinks.pending = nil
        // What you were writing stays, under the link's text.
        // A link for a project fills that project's draft.
        if let path = link.project, FileManager.default.fileExists(atPath: path) { open(path) }
        let draft = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
        setTask(draft.isEmpty || draft == link.text ? link.text : link.text + "\n\n" + draft)
        if let name = link.agent?.lowercased(),
           let provider = RunProvider.allCases.first(where: { $0.rawValue == name || $0.displayName.lowercased() == name }) {
            choose(provider, account: rememberedProfile(for: provider) ?? app.profiles.preferredProfile(provider.kind).id)
            if let model = link.model { config.model = model }
        }
        linkNotice = link.warnings.contains(.strippedHiddenCharacters) ? tr("promptLink.stripped") : tr("promptLink.filled")
    }

    /// "Check out" on a pull request link: the branch in a worktree of its own, the composer on it with the link's words
    /// as the draft (nothing is sent), and the checkout in the action log.
    func checkOutLinkedPullRequest(_ link: PromptLink, _ pull: PromptLink.PullRequest) {
        checkingOut = true
        Task {
            let label = "\(pull.repository)#\(pull.number)"
            do {
                let path = try await app.pullRequestLinkWorktree(pull)
                app.store.audit(tool: "prompt_link_pr_checkout", args: label, result: path)
                promptLinks.pendingCheckout = nil
                var draft = link
                draft.pullRequest = nil
                if !draft.text.isEmpty { promptLinks.pending = draft }
                promptLinks.requestProject(path)
            } catch {
                app.store.audit(tool: "prompt_link_pr_checkout", args: label, result: "error: " + error.localizedDescription)
                ToastCenter.shared.error(error, title: tr("agents.pr.checkout.failed"))
            }
            checkingOut = false
        }
    }

    /// A project's "+" in the Agents list (or an unsent draft's row) opens the composer on that folder's own draft.
    func applyRequestedProject() {
        guard let request = promptLinks.pendingProject, request.id != appliedProjectRequest else { return }
        appliedProjectRequest = request.id
        showClone = false
        if let id = NewSessionDraftKey.machineID(request.path) {
            if let machine = RemoteMachines.load().first(where: { $0.id == id }) { openMachine(machine) }
        } else if FileManager.default.fileExists(atPath: request.path) {
            open(request.path, isolation: request.isolation)
            if let text = request.text, text != task.text {
                if hasTask { ComposerDraftStore.shared.pushToStash(task.text); ToastCenter.shared.success(tr("ws.new.draftStashed")) }
                setTask(text)
            }
        } else if ScratchProjects.isScratch(request.path) {
            // A draft without a project whose empty folder went: a new one, with the words.
            openNoProject(draft: NewSessionDraftKey.folder(request.path))
        }
        DispatchQueue.main.async { focused = true }
    }

    /// Back where you left it when the notch closed, else a fresh box with your last choices (and the task you were
    /// typing before Nook quit). Opened from a session, the box shows that session's project.
    func restoreOrPrepare() {
        if let key = NewSessionDraft.lastKey, let draft = NewSessionDraft.saved[key] {
            load(draft)
        } else {
            prepare()
        }
        // The one shared draft of an earlier Nook goes to the folder it opens on, or to the stash when that has its own.
        let store = ComposerDraftStore.shared
        if let legacy = store.draft(for: NewSessionDraftKey.legacy) {
            store.save(sessionID: NewSessionDraftKey.legacy, text: "")
            if !hasTask { setTask(legacy) } else if legacy != task.text { store.pushToStash(legacy) }
        }
        openOriginProject()
        store.openNewSession = draftKey
    }

    /// ⌘N or New session while a session was open: that session's project (its main checkout, not the agent's worktree).
    /// A project request (a folder's pencil, a link) comes after
    /// and wins.
    private func openOriginProject() {
        guard let origin = app.viewModel.newSessionOrigin else { return }
        app.viewModel.newSessionOrigin = nil
        guard let folder = originFolder(origin) else { return }
        open(folder)
    }

    /// The folder a session at `id` works in on this Mac; nil for a page, a session elsewhere, or one without a project.
    private func originFolder(_ id: String) -> String? {
        let path: String?
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))) {
            guard let run = workspace.run(uuid), run.remote == nil else { return nil }
            path = run.projectPath
        } else if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            path = app.history.sessions.first { $0.id == key }?.cwd
        } else {
            path = app.agentSessions.first { $0.id == id }?.cwd
        }
        guard let path, !path.isEmpty, !ScratchProjects.isScratch(path) else { return nil }
        let folder = WorktreeOrigin.checkoutPath(of: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
              !ScratchProjects.isScratch(folder) else { return nil }
        return folder
    }

    /// Shows a parked draft: its words, pictures and every choice around them.
    private func load(_ draft: NewSessionDraft) {
        started = false
        error = nil
        linkNotice = nil
        config = draft.config
        config.task = ""
        setTask(draft.config.task)
        images = draft.images
        project = draft.project
        allowShared = draft.allowShared
        showClone = draft.showClone
        cloneURL = draft.cloneURL
        pendingID = draft.pendingID
        remoteMachine = draft.remoteMachine
        remoteFolder = draft.remoteFolder
        keepCheckout = draft.keepCheckout
        for (id, text) in draft.excerpts { composerModel.keep(id, text: text) }
        // A project still being inspected when the notch closed is looked at again.
        if project == nil, !config.projectPath.isEmpty, remoteMachine == nil,
           FileManager.default.fileExists(atPath: config.projectPath) {
            select(config.projectPath)
        }
    }

    /// Closing the notch (or switching tabs) parks the box; it comes back on the same draft.
    func keepDraft() {
        park()
        NewSessionDraft.lastKey = draftKey
        if ComposerDraftStore.shared.openNewSession == draftKey { ComposerDraftStore.shared.openNewSession = nil }
    }

    /// Keeps this draft as it is for when its folder opens again. A folder made for "No project" with nothing typed goes.
    private func park() {
        let key = draftKey
        guard !started else { NewSessionDraft.saved[key] = nil; return }
        if remoteMachine == nil, ScratchProjects.isScratch(config.projectPath), !hasTask, images.isEmpty {
            ScratchProjects.discardIfEmpty(config.projectPath)
            NewSessionDraft.saved[key] = nil
            return
        }
        NewSessionDraft.saved[key] = NewSessionDraft(
            config: configured(task: task.text), images: images, project: project, allowShared: allowShared, showClone: showClone,
            cloneURL: cloneURL, pendingID: pendingID, remoteMachine: remoteMachine, remoteFolder: remoteFolder,
            excerpts: composerModel.excerpts, comparing: comparing, keepCheckout: keepCheckout)
    }

    /// Opens `folder`'s own draft: parked as you left it, else its words from `ComposerDraftStore` with the folder's
    /// choices, else an empty box with them. The draft shown before waits under its own folder.
    private func open(_ folder: String, isolation: IsolationMode? = nil) {
        let key = NewSessionDraftKey.folder(folder)
        if key != draftKey {
            park()
            if let draft = NewSessionDraft.saved[key] {
                load(draft)
            } else {
                clearBox()
                select(folder)
                if let words = ComposerDraftStore.shared.draft(for: key) { setTask(words) }
            }
        }
        if let isolation {
            config.isolation = isolation
            keepCheckout = isolation == .folder
        }
    }

    /// A "No project" draft whose empty folder went (Nook removes those): a new folder for it, with its words.
    private func openNoProject(draft key: String) {
        park()
        clearBox()
        let store = ComposerDraftStore.shared
        let words = store.draft(for: key) ?? ""
        do {
            select(try ScratchProjects.create(prompt: words))
            if !words.isEmpty { setTask(words) }
            store.save(sessionID: key, text: "")
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    /// Drops an unsent draft from the list: its words and, when it was parked, everything around them.
    static func discardDraft(_ key: String) {
        NewSessionDraft.discard(key)
        ComposerDraftStore.shared.save(sessionID: key, text: "")
        if case .folder(let path) = NewSessionDraftKey.place(of: key) { ScratchProjects.discardIfEmpty(path) }
    }

    /// The same for a machine over SSH.
    private func openMachine(_ machine: RemoteMachine) {
        let key = NewSessionDraftKey.machine(machine.id)
        guard key != draftKey else { return }
        park()
        if let draft = NewSessionDraft.saved[key] {
            load(draft)
        } else {
            clearBox()
            applyFolderDefaults(nil)
            chooseMachine(machine)
            if let words = ComposerDraftStore.shared.draft(for: key) { setTask(words) }
        }
    }

    /// An empty box with nothing chosen yet, without touching the stored words of the draft shown before.
    private func clearBox() {
        task.text = ""
        hasTask = false
        started = false
        images = []
        comparing = []
        project = nil
        showClone = false
        cloneURL = ""
        remoteMachine = nil
        remoteFolder = ""
        allowShared = false
        keepCheckout = false
        error = nil
        linkNotice = nil
        pendingID = UUID()
        config = NewRunConfig()
        config.worktreeRoot = settings.worktreeRoot
    }

    /// A folder picked in the heading. What you typed goes along to it;
    /// with nothing typed, that folder's own draft opens.
    func pick(_ path: String) {
        guard hasTask || !images.isEmpty else { return open(path) }
        moveDraft { select(path) }
    }

    func pickMachine(_ machine: RemoteMachine) {
        guard hasTask || !images.isEmpty else { return openMachine(machine) }
        moveDraft { chooseMachine(machine) }
    }

    /// Moves the words of this draft to wherever `change` points the box. A draft the new place already had goes to the
    /// stash (⌘S brings it back), so no words are lost.
    private func moveDraft(_ change: () -> Void) {
        let old = draftKey
        change()
        let new = draftKey
        guard new != old else { return }
        let store = ComposerDraftStore.shared
        if let earlier = store.draft(for: new), earlier != task.text {
            store.pushToStash(earlier)
            ToastCenter.shared.success(tr("ws.new.draftStashed"))
        }
        // The new place first: the box clears itself when its own draft disappears from the store (`dropIfDiscarded`).
        if !started { store.save(sessionID: new, text: task.text) }
        store.save(sessionID: old, text: "")
        NewSessionDraft.saved[old] = nil
        NewSessionDraft.saved[new] = nil
    }

    private func prepare() {
        config.worktreeRoot = settings.worktreeRoot
        let menu = projectMenu
        let last = settings.lastProject.isEmpty ? (menu.favorites.first ?? menu.recent.first) : settings.lastProject
        let initial = last.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        applyFolderDefaults(initial)
        if let initial { select(initial) }
        if !hasTask, let words = ComposerDraftStore.shared.draft(for: draftKey) { setTask(words) }
    }

    func choose(_ provider: RunProvider, account: String) {
        if config.provider != provider {
            config.provider = provider
            let defaults = settings.composerDefaults(for: config.projectPath)
            config.model = defaults.model(for: provider)
            config.effort = defaults.effort(for: provider)
            config.speedTier = nil
            config.permission = config.permission.steppedDown(within: provider.capabilities.policies)
        }
        config.profileID = account
    }

    /// The account you last chose for this agent in this folder or else anywhere, while it is still connected, else its
    /// first connected one.
    func rememberedProfile(for provider: RunProvider) -> String? {
        settings.composerDefaults(for: config.projectPath)
            .profile(for: provider, connected: app.connectedProfiles(for: provider).map(\.id))
    }

    /// Keeps what you just chose for the next new session in this folder, and as the start for folders without choices
    /// of their own. What the project sets for itself (Settings › Workspace, per project) stays out of the global defaults.
    func remember() {
        let path = config.projectPath
        if !settings.isOverridden(.provider, for: path) { settings.defaultProvider = config.provider }
        settings.setProfile(config.profileID, for: config.provider)
        if !settings.isOverridden(.model(config.provider), for: path) { settings.setModel(config.model, for: config.provider) }
        settings.defaultMode = config.mode
        if !settings.isOverridden(.permission, for: path) { settings.defaultPermission = config.permission }
        settings.setEffort(config.effort, for: config.provider)
        if !settings.isOverridden(.isolation, for: path) { settings.defaultIsolation = config.isolation }
        // What runs on another machine says nothing about this folder.
        if remoteMachine == nil { settings.rememberFolderChoices(config) }
    }

    /// Sets the choices to what a new session in `folder` starts with. Your agent for it, unless that is not connected:
    /// then your default one, or else the first that is.
    private func applyFolderDefaults(_ folder: String?) {
        let defaults = settings.composerDefaults(for: folder)
        // An agent the project switched off is never the one it starts with.
        let connected = app.connectedProviders(in: folder)
        let provider = [defaults.provider, settings.defaultProvider].first(where: connected.contains)
            ?? connected.first ?? defaults.provider
        config.provider = provider
        config.profileID = defaults.profile(for: provider, connected: app.connectedProfiles(for: provider).map(\.id))
            ?? app.profiles.preferredProfile(provider.kind).id
        config.model = defaults.model(for: provider)
        config.mode = defaults.mode
        config.permission = defaults.permission(for: provider)
        config.effort = defaults.effort(for: provider)
        config.isolation = defaults.isolation
    }

    private func chooseMachine(_ machine: RemoteMachine) {
        remoteMachine = machine
        remoteFolder = UserDefaults.standard.string(forKey: "agents.remoteFolder." + machine.id) ?? "~"
        config.isolation = .folder
        // The branches here mean nothing there: a worktree starts from the branch that folder is on, unless you type one.
        config.baseBranch = ""
        error = nil
    }

    private func select(_ path: String) {
        remoteMachine = nil
        // A folder made for "No project" that nothing started in goes again when you pick another.
        if config.projectPath != path {
            ScratchProjects.discardIfEmpty(config.projectPath)
            applyFolderDefaults(path)
        }
        config.projectPath = path
        // The next new session opens on the project you chose last, also when this one never started; a session
        // without a project leaves that alone.
        // Nor does a session in an agent's worktree: the next one opens on the repository.
        if !ScratchProjects.isScratch(path), WorktreeOrigin.checkoutPath(of: path) == path { settings.lastProject = path }
        error = nil
        if let cached = workspace.cachedProject(path) {
            applyInspectedProject(cached, for: path)
            inspecting = false
        } else {
            inspecting = true
        }
        Task {
            let info = await workspace.inspectProject(path)
            guard config.projectPath == path, remoteMachine == nil else { return }
            applyInspectedProject(info, for: path)
            inspecting = false
        }
    }

    private func applyInspectedProject(_ info: ProjectInfo, for path: String) {
        project = info
        let canWorktree = info.repoRoot != nil && info.hasCommits && workspace.gitAvailable == true
        if !canWorktree {
            config.isolation = .folder
        } else if !keepCheckout, config.isolation == .folder && settings.composerDefaults(for: path).isolation == .worktree {
            config.isolation = .worktree
        }
        if !config.baseBranch.isEmpty, info.branches.contains(config.baseBranch) {
            return
        }
        if let base = info.defaultBase, info.branches.contains(base) {
            config.baseBranch = base
        } else {
            config.baseBranch = info.currentBranch ?? info.branches.first ?? ""
        }
    }

    /// "No project": a new empty folder under ~/.nook/scratch, named after today and what you typed so far; it takes
    /// the prompt's name when the session starts.
    func chooseNoProject() {
        do {
            pick(try ScratchProjects.create(prompt: task.text))
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = tr("ws.new.choosePrompt")
        panel.message = tr("ws.new.chooseMessage")
        if let current = project?.path { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        settings.rememberProject(url.path)
        pick(url.path)
    }

    /// "New project…": a new folder where you choose, with an empty repository, then the offer to publish it on GitHub
    /// (Cancel keeps it on this Mac only).
    func chooseNewProject() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = tr("sc.newProject.defaultName")
        panel.prompt = tr("sc.newProject.create")
        panel.message = tr("sc.newProject.message")
        panel.directoryURL = URL(fileURLWithPath: WorkspaceManager.cloneParent(project: project.map { $0.repoRoot ?? $0.path },
                                                                               hostLayout: false))
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        error = nil
        Task {
            do {
                let plan = try await workspace.createProject(at: url.path)
                settings.rememberProject(plan.folder)
                pick(plan.folder)
                newProjectPlan = plan
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }

    func clone() {
        cloneURL = CloneLayout.repositoryURL(fromPage: cloneURL)
        guard !cloning, GitService.isCloneURL(cloneURL) else { return }
        cloning = true
        error = nil
        let parent = WorkspaceManager.cloneParent(project: project.map { $0.repoRoot ?? $0.path },
                                                  hostLayout: settings.cloneHostLayout)
        Task {
            do {
                let cloned = try await workspace.clone(url: cloneURL, into: parent)
                showClone = false
                cloneURL = ""
                if cloned.usedHTTPS { ToastCenter.shared.success(tr("sc.clone.usedHTTPS")) }
                pick(cloned.path)
            } catch let failure {
                error = failure.localizedDescription
            }
            cloning = false
        }
    }

    /// `background` (⌥⌘↩): the session starts without opening, and the box stays for the next one with the same folder,
    /// agent and worktree choices.
    func start(background: Bool = false) {
        guard canStart else { return }
        if !comparing.isEmpty, remoteMachine == nil { return startComparison(background: background) }
        starting = true
        error = nil
        var request = checkedConfig
        // A folder made for "No project" before the prompt was typed gets the prompt's name now.
        if request.remote == nil, ScratchProjects.isScratch(request.projectPath) {
            request.projectPath = ScratchProjects.rename(request.projectPath, prompt: request.task)
        }
        // References in the text reach the agent as markers plus the context envelope.
        request.task = composerModel.outgoing(request.task).send
        // In Plan mode the agent is read-only; the safest permissions go along for when you continue later.
        if request.mode == .plan { request.permission = request.provider.capabilities.policies.first ?? .acceptEdits }
        let finalConfig = request
        let shared = allowShared
        let key = draftKey
        Task {
            do {
                let id = try await workspace.start(finalConfig, allowSharedFolder: shared)
                if let remote = finalConfig.remote {
                    UserDefaults.standard.set(remote.directory, forKey: "agents.remoteFolder." + remote.machineID)
                }
                remember()
                ComposerDraftStore.shared.save(sessionID: key, text: "")
                started = true
                NewSessionDraft.saved[key] = nil
                setTask("")
                images = []
                pendingID = UUID()
                starting = false
                if background {
                    startedInBackground()
                } else {
                    onStarted(id)
                }
            } catch let failure {
                error = failure.localizedDescription
                starting = false
            }
        }
    }

    /// One prompt to several models: a session per model, each in its own worktree, grouped under the first. When a model
    /// fails, the prompt stays in the box (and in `ComposerDraftStore`) with only the failed models still chosen, and the
    /// box says which ones failed and why.
    private func startComparison(background: Bool = false) {
        starting = true
        error = nil
        var base = checkedConfig
        base.task = composerModel.outgoing(base.task).send
        if base.mode == .plan { base.permission = base.provider.capabilities.policies.first ?? .acceptEdits }
        let targets = comparisonTargets
        let key = draftKey
        let configs = ModelComparison.configs(base: base, targets: targets, ids: targets.map { _ in UUID() },
                                              modelName: comparisonName)
        Task {
            let outcome = await workspace.startComparison(configs, targets: targets)
            starting = false
            if !outcome.started.isEmpty { remember() }
            guard let retry = ModelComparison.retrySelection(after: outcome) else {
                ComposerDraftStore.shared.save(sessionID: key, text: "")
                started = true
                NewSessionDraft.saved[key] = nil
                setTask("")
                images = []
                comparing = []
                pendingID = UUID()
                if background {
                    startedInBackground()
                } else if let leader = outcome.leader {
                    onStarted(leader)
                }
                return
            }
            ComposerDraftStore.shared.save(sessionID: key, text: task.text)
            if retry.primary.provider != config.provider || retry.primary.profileID != config.profileID {
                choose(retry.primary.provider, account: retry.primary.profileID)
            }
            config.model = retry.primary.model
            comparing = retry.extras
            pendingID = UUID()
            error = tr("compare.failed", outcome.failed.map { comparisonName($0.target) + ": " + $0.message }.joined(separator: "\n"))
            if !outcome.started.isEmpty { ToastCenter.shared.success(tr("compare.started", outcome.started.count)) }
        }
    }

    /// After ⌥⌘↩: the session runs in the list, and this box is a fresh draft with the same choices and the keyboard.
    private func startedInBackground() {
        started = false
        ToastCenter.shared.success(tr("ws.new.startedInBackground"))
        focused = true
    }

    /// "Claude Code · Opus": how a model of a comparison is named in its session's title and in an error.
    private func comparisonName(_ target: ComparisonTarget) -> String {
        target.model.isEmpty ? target.provider.displayName
            : target.provider.displayName + " · " + app.modelMenuName(target.model, for: target.provider, profileID: target.profileID)
    }
}
