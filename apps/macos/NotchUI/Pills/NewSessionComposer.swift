import SwiftUI
import AppKit

/// Starting a session in the notch: one question, one field, and a few quiet choices underneath.
/// "What should we build in nook?" — type the task, press Return. Agent and account, mode, permissions, effort,
/// where it works (this folder or a new worktree) and the branch it starts from are small menus, already set to
/// your last choices. Nothing else to fill in: title, branch name and worktree location are derived.
struct NewSessionComposer: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @EnvironmentObject private var settings: WorkspaceSettings
    @ObservedObject private var antigravity = AntigravityInstaller.shared
    /// Called with the new session once it runs.
    let onStarted: (UUID) -> Void

    @State private var config = NewRunConfig()
    @State private var images: [ImageAttachment] = []
    @State private var project: ProjectInfo?
    @State private var inspecting = false
    @State private var starting = false
    @State private var error: String?
    @State private var allowShared = false
    @State private var showClone = false
    @State private var cloneURL = ""
    @State private var cloning = false
    @State private var pendingID = UUID()
    /// On another machine over SSH (see RemoteMachines): which one, and the folder there.
    @State private var remoteMachine: RemoteMachine?
    @State private var remoteFolder = ""
    @StateObject private var composerModel = ComposerModel()
    @ObservedObject private var promptLinks = PromptLinkInbox.shared
    @State private var linkNotice: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            heading
            if showClone { cloneRow }
            if remoteMachine != nil { remoteRow }
            VStack(alignment: .leading, spacing: 8) {
                // Where it works and the branch it starts from sit in a tray tucked under the box.
                VStack(spacing: 0) {
                    box.zIndex(1)
                    belowBox
                }
                notice
            }
            .frame(maxWidth: 640)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { prepare(); app.refreshAgentModels(); applyPromptLink() }
        .onChange(of: promptLinks.pending) { _, _ in applyPromptLink() }
    }

    // MARK: Heading

    private var heading: some View {
        HStack(spacing: 0) {
            Text(tr("compose.heading"))
                .foregroundStyle(NookTheme.paper)
            ComposerDropdown(width: 320) {
                Text(projectLabel)
                    .foregroundStyle(NookTheme.paper)
                    .underline(true, pattern: .dot, color: NookTheme.textTertiary)
            } content: {
                if !recentProjects.isEmpty {
                    DropdownHeader(title: tr("ws.new.recent"))
                    ForEach(recentProjects, id: \.self) { path in
                        DropdownRow(symbol: "folder", title: URL(fileURLWithPath: path).lastPathComponent, detail: AgentPathFormat.tilde(path),
                                    chosen: project?.path == path) { select(path) }
                    }
                    DropdownDivider()
                }
                DropdownRow(symbol: "folder.badge.plus", title: tr("ws.new.chooseFolder")) { chooseFolder() }
                DropdownRow(symbol: "arrow.down.circle", title: tr("ws.new.clone")) { showClone = true }
                // Another machine over SSH (Settings › Agents › Workspace › Machines).
                let machines = RemoteMachines.load()
                if !machines.isEmpty {
                    DropdownDivider()
                    DropdownHeader(title: tr("ws.remote.header"))
                    ForEach(machines) { machine in
                        DropdownRow(symbol: "server.rack", title: machine.name, detail: machine.host,
                                    chosen: remoteMachine?.id == machine.id) { chooseMachine(machine) }
                    }
                }
            }
            .help(project.map { AgentPathFormat.tilde($0.path) } ?? tr("ws.new.pickWorkspace"))
            Text("?").foregroundStyle(NookTheme.paper)
            if inspecting {
                ProgressView().controlSize(.small).padding(.leading, 8)
            }
        }
        .font(NookTheme.font(22, .regular))
    }

    private var cloneRow: some View {
        HStack(spacing: 8) {
            TextField(tr("ws.new.clonePlaceholder"), text: $cloneURL)
                .textFieldStyle(.plain)
                .font(NookTheme.mono(12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.field))
                .onSubmit(clone)
            SmallGhostButton(title: cloning ? tr("ws.new.cloning") : tr("ws.new.cloneAction"), action: clone)
                .disabled(cloning || !GitService.isCloneURL(cloneURL))
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 26) { showClone = false }
        }
        .frame(maxWidth: 640)
    }

    /// "app", "buildbox:app", or the invitation to pick one.
    private var projectLabel: String {
        if let remoteMachine {
            let folder = remoteFolder.isEmpty ? "…" : URL(fileURLWithPath: remoteFolder).lastPathComponent
            return remoteMachine.name + ":" + folder
        }
        return project?.name ?? tr("compose.pickProject")
    }

    /// The folder on the remote machine, typed: there is no folder panel for another machine.
    private var remoteRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").foregroundStyle(NookTheme.textTertiary)
            Text(tr("ws.remote.folder", remoteMachine?.name ?? "")).foregroundStyle(NookTheme.textSecondary).fixedSize()
            TextField("~/code/app", text: $remoteFolder)
                .textFieldStyle(.plain)
                .font(NookTheme.mono(12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.field))
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 26) { remoteMachine = nil }
        }
        .font(NookTheme.font(12.5))
        .frame(maxWidth: 640)
    }

    // MARK: The box

    /// The same composer a running session answers in, with the choices for the new session inside it.
    private var box: some View {
        SessionComposer(
            text: $config.task,
            prompt: tr("compose.prompt"),
            minHeight: 56,
            lines: 3...8,
            canSend: canStart,
            sending: starting,
            sendLabel: blockingReason ?? tr("ws.new.start"),
            focus: $focused,
            onSend: start
        ) {
            // The same row as in a running session and in the chat: plus menu, the agent and model, then mode and rights.
            ComposerPlusMenu(attach: attachFile) {}
            agentMenu
            ComposerDivider()
            modeMenu
            ComposerDivider()
            permissionMenu
            effortMenu
        }
        .rich(composerModel, composerConfig)
        .images($images)
        .trailing { ComposerMic(text: $config.task) }
    }

    private var composerConfig: ComposerConfig {
        var rich = ComposerConfig()
        rich.tint = config.provider.composerTint
        rich.fileRoot = config.projectPath.isEmpty ? nil : config.projectPath
        rich.keepsBigPastes = true
        return rich
    }

    private func attachFile() {
        guard !config.projectPath.isEmpty,
              let ref = ComposerFilePicker.pick(startingIn: config.projectPath) else { return }
        config.task += (config.task.isEmpty || config.task.hasSuffix(" ") ? "" : " ") + ContextRefs.link(ref) + " "
        focused = true
    }

    // MARK: Choices in the box

    /// Agent, account and model in one panel: agents in a rail, their models with a search.
    private var agentMenu: some View {
        let profile = app.profiles.profile(id: config.profileID)
        let name = profile.map { AccountLabel.name($0, app: app) }
        return ComposerDropdown(width: app.connectedProviders.count > 1 ? 340 : 296) {
            ComposerPill(agent: config.provider.displayName, account: profile.map { AccountKind.of($0, app: app) },
                         text: [config.provider.displayName, name].compactMap { $0 }.joined(separator: " · ")
                            + (config.model.isEmpty ? "" : " · " + app.modelName(config.model, for: config.provider)),
                         short: config.model.isEmpty ? config.provider.displayName : app.modelName(config.model, for: config.provider))
        } content: {
            if app.connectedProviders.isEmpty {
                DropdownHeader(title: tr("agents.noneConnected"))
            } else {
                AgentModelPicker(providers: app.connectedProviders, provider: config.provider, profileID: config.profileID,
                                 model: config.model) { provider, account, model in
                    if provider != config.provider || (account != nil && account != config.profileID) {
                        choose(provider, account: account ?? rememberedProfile(for: provider) ?? config.profileID)
                    }
                    if let model { config.model = model }
                    remember()
                }
            }
        }
        .help(tr("ws.new.accountPinned"))
    }

    private var modeMenu: some View {
        ModeToggle(mode: Binding(get: { config.mode }, set: { config.mode = $0; remember() }))
    }

    private var permissionMenu: some View {
        ComposerDropdown(width: 300) {
            ComposerPill(symbol: config.mode == .plan ? "lock" : config.permission.symbol,
                 dot: nil,
                 text: config.mode == .plan ? tr("compose.readOnly") : config.permission.label,
                 tint: config.permission == .bypass && config.mode != .plan ? NookTheme.coralSoft : nil)
        } content: {
            DropdownHeader(title: tr("compose.access"))
            ForEach(config.provider.capabilities.policies) { policy in
                DropdownRow(symbol: policy.symbol, title: policy.label, detail: policy.help(for: config.provider),
                            chosen: config.permission == policy, tint: policy == .bypass ? NookTheme.coralSoft : nil) {
                    config.permission = policy
                    remember()
                }
            }
        }
        .disabled(config.mode == .plan)
        .help(config.mode == .plan ? tr("ws.new.planReadOnly") : config.permission.help(for: config.provider))
    }

    /// How hard the agent thinks, only for agents that have it; "Default" leaves it to the agent.
    @ViewBuilder
    private var effortMenu: some View {
        let levels = EffortLevels.levels(for: config.provider, model: config.model.isEmpty ? nil : config.model)
        if !levels.isEmpty {
            ComposerDivider()
            ComposerDropdown(width: 220) {
                ComposerPill(symbol: "gauge.with.dots.needle.33percent", text: tr(EffortLevels.label(config.effort)))
            } content: {
                DropdownHeader(title: tr("compose.effort"))
                DropdownRow(symbol: "circle.dashed", title: tr(EffortLevels.label(nil)), chosen: config.effort == nil) {
                    config.effort = nil
                    remember()
                }
                ForEach(levels, id: \.self) { level in
                    DropdownRow(symbol: Self.effortSymbol(level, in: levels), title: tr(EffortLevels.label(level)),
                                chosen: config.effort == level) {
                        config.effort = level
                        remember()
                    }
                }
            }
            .help(tr("compose.effort.help"))
        }
    }

    /// The gauge fills up with the level.
    private static func effortSymbol(_ level: String, in levels: [String]) -> String {
        let index = levels.firstIndex(of: level) ?? 0
        if index == 0 { return "gauge.with.dots.needle.0percent" }
        if index == levels.count - 1 { return "gauge.with.dots.needle.100percent" }
        return index * 2 < levels.count ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.67percent"
    }

    // MARK: Below the box

    private var belowBox: some View {
        HStack(spacing: 6) {
            if let remoteMachine {
                // On another machine: its folder, or a new worktree there (~/.nook/worktrees); git runs there over ssh.
                ComposerPill(symbol: "network", dot: nil, text: tr("ws.remote.via", remoteMachine.host), showsChevron: false)
                    .help(tr("ws.remote.limits"))
                isolationDropdown(worktreeAllowed: true, reason: "")
                Spacer(minLength: 8)
                if config.isolation == .worktree {
                    Image(systemName: "arrow.triangle.branch").font(NookTheme.font(10.5)).foregroundStyle(NookTheme.textTertiary)
                    TextField("", text: $config.baseBranch, prompt: Text(tr("ws.remote.baseCurrent")))
                        .textFieldStyle(.plain)
                        .font(NookTheme.font(12))
                        .frame(width: 150)
                        .help(tr("ws.remote.baseHelp"))
                }
            } else {
                isolationDropdown(worktreeAllowed: worktreeAllowed, reason: worktreeBlockedReason)

                Spacer(minLength: 8)

                if config.isolation == .worktree, let branches = project?.branches, !branches.isEmpty {
                    ComposerDropdown(width: 280) {
                        ComposerPill(symbol: "arrow.triangle.branch", dot: nil, text: tr("compose.from", config.baseBranch))
                    } content: {
                        BranchPicker(branches: sortedBranches(branches), selected: config.baseBranch) { config.baseBranch = $0 }
                    }
                } else if let branch = project?.currentBranch {
                    ComposerPill(symbol: "arrow.triangle.branch", dot: nil, text: branch, showsChevron: false)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, Self.trayTuck + 4)
        .padding(.bottom, 4)
        .background(trayShape.fill(NookTheme.field))
        .overlay(trayShape.stroke(NookTheme.fieldStroke, lineWidth: 1))
        .padding(.top, -Self.trayTuck)
        .padding(.horizontal, 14)
    }

    /// How far the tray runs on under the box, so it reads as coming out from underneath.
    private static let trayTuck: CGFloat = 14

    private var trayShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
    }

    /// Where the agent works: the folder as it is, or a new worktree.
    private func isolationDropdown(worktreeAllowed: Bool, reason: String) -> some View {
        ComposerDropdown(width: 300) {
            ComposerPill(symbol: config.isolation == .worktree ? "square.stack.3d.up" : "folder", dot: nil,
                 text: config.isolation == .worktree ? tr("compose.newWorktree") : tr("compose.currentCheckout"))
        } content: {
            DropdownHeader(title: tr("compose.whereWorks"))
            DropdownRow(symbol: "folder", title: tr("compose.currentCheckout"), detail: tr("compose.currentCheckoutDetail"),
                        chosen: config.isolation == .folder) {
                config.isolation = .folder
                remember()
            }
            DropdownRow(symbol: "square.stack.3d.up", title: tr("compose.newWorktree"), detail: tr("ws.new.worktreeExplain"),
                        chosen: config.isolation == .worktree, disabledReason: worktreeAllowed ? nil : reason) {
                config.isolation = .worktree
                remember()
            }
        }
        .help(worktreeAllowed ? tr("ws.new.worktreeExplain") : reason)
    }

    /// One line, only when something needs saying: why you cannot start yet, or what went wrong.
    @ViewBuilder
    private var notice: some View {
        if let error {
            Text(error)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.coralSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        } else if let linkNotice {
            Text(linkNotice)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        } else if let remoteMachine {
            // On another machine the agent uses that machine's own login; what needs this Mac stays off.
            Text(tr("ws.remote.notice", remoteMachine.name))
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        } else if config.provider == .antigravity, antigravity.installed == nil {
            AntigravitySetupRow().padding(.horizontal, 8)
        } else if let profile = app.profiles.profile(id: config.profileID), app.history.profileAccounts[profile.id] == nil {
            HStack(spacing: 8) {
                Text(tr("ws.new.accountNotLoggedIn")).foregroundStyle(NookTheme.amber)
                SmallGhostButton(title: tr("agents.login")) { app.connect(profile) }
            }
            .font(NookTheme.font(12))
            .padding(.horizontal, 8)
        } else if !sharing.isEmpty, config.isolation == .folder {
            HStack(spacing: 8) {
                Text(tr("ws.new.sharedWarning", sharing.map(\.title).joined(separator: ", ")))
                    .foregroundStyle(NookTheme.amber)
                    .lineLimit(2)
                Toggle(tr("ws.new.sharedAllow"), isOn: $allowShared).toggleStyle(.checkbox)
            }
            .font(NookTheme.font(12))
            .padding(.horizontal, 8)
        } else if let reason = blockingReason, project != nil, !config.task.isEmpty {
            Text(reason)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.horizontal, 8)
        }
    }

    // MARK: State

    private var recentProjects: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in settings.recentProjects + app.history.sessions.map(\.cwd) where !path.isEmpty {
            let normalized = WorkspacePathPolicy.normalize(path)
            guard seen.insert(normalized).inserted, FileManager.default.fileExists(atPath: normalized) else { continue }
            result.append(normalized)
            if result.count == 10 { break }
        }
        return result
    }

    private var worktreeAllowed: Bool {
        guard let project, project.verdict == .ok else { return false }
        return project.repoRoot != nil && project.hasCommits && workspace.gitAvailable == true
    }

    private var worktreeBlockedReason: String {
        if workspace.gitAvailable == false { return tr("ws.error.noGit") }
        guard let project else { return tr("ws.new.pickWorkspace") }
        if project.repoRoot == nil { return tr("ws.new.worktreeNeedsRepo") }
        if !project.hasCommits { return tr("ws.new.worktreeNeedsCommit") }
        return ""
    }

    private var sharing: [WorkspaceRun] {
        guard let project, project.verdict == .ok else { return [] }
        return workspace.activeRuns(sharing: project.repoRoot ?? project.path)
    }

    private var blockingReason: String? {
        if let problem = checkedConfig.problem { return tr("ws.error.config." + problem.rawValue) }
        // On another machine the agent is looked up there, not on this Mac.
        if remoteMachine != nil { return nil }
        if project?.verdict != .ok { return tr("ws.error.config.missingWorkspace") }
        if config.provider == .antigravity, antigravity.installed == nil { return tr("ws.antigravity.installFirst") }
        if workspace.executable(config.provider) == nil { return tr("ws.error.noExecutable", config.provider.displayName) }
        if config.isolation == .folder, !allowShared, !sharing.isEmpty { return tr("ws.new.sharedBlocked") }
        return nil
    }

    private var canStart: Bool { !starting && blockingReason == nil }

    /// The configuration as it will start: with the branch name derived from the task, which only gets filled in at the
    /// moment of starting. Checking `config` itself would see an empty branch name and refuse every new worktree.
    private var checkedConfig: NewRunConfig {
        var copy = config
        copy.branchName = WorktreeNaming.branchName(task: config.task, id: pendingID)
        if let remoteMachine {
            copy.remote = RemoteTarget(machine: remoteMachine, directory: remoteFolder.trimmingCharacters(in: .whitespaces))
            copy.baseBranch = config.baseBranch.trimmingCharacters(in: .whitespaces)
        }
        return copy
    }

    /// The default branch first ("origin/main"), then the rest alphabetically.
    private func sortedBranches(_ branches: [String]) -> [String] {
        let base = project?.defaultBase
        return branches.sorted { a, b in
            if a == base { return true }
            if b == base { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    // MARK: Actions

    /// A link only fills the draft (and picks a project, agent or model when they exist here); you read it and press send.
    private func applyPromptLink() {
        guard let link = promptLinks.pending else { return }
        promptLinks.pending = nil
        config.task = link.text
        if let path = link.project, FileManager.default.fileExists(atPath: path) { select(path) }
        if let name = link.agent?.lowercased(),
           let provider = RunProvider.allCases.first(where: { $0.rawValue == name || $0.displayName.lowercased() == name }) {
            choose(provider, account: rememberedProfile(for: provider) ?? app.profiles.preferredProfile(provider.kind).id)
            if let model = link.model { config.model = model }
        }
        linkNotice = link.warnings.contains(.strippedHiddenCharacters) ? tr("promptLink.stripped") : tr("promptLink.filled")
    }

    private func prepare() {
        // Your default agent, unless it is not connected: then the first one that is.
        let connected = app.connectedProviders
        let provider = connected.contains(settings.defaultProvider) ? settings.defaultProvider : (connected.first ?? settings.defaultProvider)
        config.provider = provider
        config.profileID = rememberedProfile(for: provider) ?? app.profiles.preferredProfile(provider.kind).id
        config.model = settings.model(for: provider)
        config.mode = settings.defaultMode
        config.permission = settings.permission(for: provider)
        config.effort = settings.effort(for: provider)
        config.isolation = settings.defaultIsolation
        config.worktreeRoot = settings.worktreeRoot
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        let initial = settings.lastProject.isEmpty ? recentProjects.first : settings.lastProject
        if let initial, FileManager.default.fileExists(atPath: initial) { select(initial) }
    }

    private func choose(_ provider: RunProvider, account: String) {
        if config.provider != provider {
            config.provider = provider
            config.model = settings.model(for: provider)
            config.effort = settings.effort(for: provider)
            if !provider.capabilities.policies.contains(config.permission) { config.permission = settings.permission(for: provider) }
        }
        config.profileID = account
    }

    /// The account you last chose for this agent while it is still connected, else its first connected one.
    private func rememberedProfile(for provider: RunProvider) -> String? {
        let connected = app.connectedProfiles(for: provider)
        if let saved = settings.profile(for: provider), connected.contains(where: { $0.id == saved }) { return saved }
        return connected.first?.id
    }

    /// Keeps what you just chose for the next new session, so it does not fall back to the defaults.
    private func remember() {
        settings.defaultProvider = config.provider
        settings.setProfile(config.profileID, for: config.provider)
        settings.setModel(config.model, for: config.provider)
        settings.defaultMode = config.mode
        settings.defaultPermission = config.permission
        settings.setEffort(config.effort, for: config.provider)
        settings.defaultIsolation = config.isolation
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
        config.projectPath = path
        inspecting = true
        error = nil
        Task {
            let info = await workspace.inspectProject(path)
            project = info
            inspecting = false
            let canWorktree = info.repoRoot != nil && info.hasCommits && workspace.gitAvailable == true
            if !canWorktree {
                config.isolation = .folder
            } else if config.isolation == .folder && settings.defaultIsolation == .worktree {
                config.isolation = .worktree
            }
            if let base = info.defaultBase, info.branches.contains(base) {
                config.baseBranch = base
            } else {
                config.baseBranch = info.currentBranch ?? info.branches.first ?? ""
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = tr("ws.new.choosePrompt")
        panel.message = tr("ws.new.chooseMessage")
        if let current = project?.path { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        select(url.path)
    }

    private func clone() {
        guard !cloning, GitService.isCloneURL(cloneURL) else { return }
        cloning = true
        error = nil
        let parent: String
        if let project {
            parent = URL(fileURLWithPath: project.repoRoot ?? project.path).deletingLastPathComponent().path
        } else {
            parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
        }
        Task {
            do {
                let path = try await workspace.clone(url: cloneURL, into: parent)
                showClone = false
                cloneURL = ""
                select(path)
            } catch let failure {
                error = failure.localizedDescription
            }
            cloning = false
        }
    }

    private func start() {
        guard canStart else { return }
        starting = true
        error = nil
        var request = checkedConfig
        // References in the text reach the agent as markers plus the context envelope.
        request.task = composerModel.outgoing(request.task).send
        // In Plan mode the agent is read-only; the safest permissions go along for when you continue later.
        if request.mode == .plan { request.permission = request.provider.capabilities.policies.first ?? .acceptEdits }
        let finalConfig = request
        let shared = allowShared
        Task {
            do {
                let id = try await workspace.start(finalConfig, allowSharedFolder: shared)
                if let remote = finalConfig.remote {
                    UserDefaults.standard.set(remote.directory, forKey: "agents.remoteFolder." + remote.machineID)
                }
                remember()
                config.task = ""
                pendingID = UUID()
                starting = false
                onStarted(id)
            } catch let failure {
                error = failure.localizedDescription
                starting = false
            }
        }
    }
}
