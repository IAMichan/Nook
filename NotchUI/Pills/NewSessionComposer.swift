import SwiftUI
import AppKit

/// Starting a session in the notch: one question, one field, and a few quiet choices underneath.
/// "What should we build in nook?" — type the task, press Return. Agent and account, mode, permissions,
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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            heading
            if showClone { cloneRow }
            VStack(alignment: .leading, spacing: 8) {
                box
                belowBox
                notice
            }
            .frame(maxWidth: 640)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { prepare(); app.refreshAgentModels() }
    }

    // MARK: Heading

    private var heading: some View {
        HStack(spacing: 0) {
            Text(tr("compose.heading"))
                .foregroundStyle(NookTheme.paper)
            ComposerDropdown(width: 320) {
                Text(project?.name ?? tr("compose.pickProject"))
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
                .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
                .onSubmit(clone)
            SmallGhostButton(title: cloning ? tr("ws.new.cloning") : tr("ws.new.cloneAction"), action: clone)
                .disabled(cloning || !GitService.isCloneURL(cloneURL))
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 26) { showClone = false }
        }
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
            agentMenu
            ComposerDivider()
            modeMenu
            ComposerDivider()
            permissionMenu
        }
        .images($images)
    }

    // MARK: Choices in the box

    /// Agent, account and model in one panel, as T3Code's model picker: agents in a rail, their models with a search.
    private var agentMenu: some View {
        let profile = app.profiles.profile(id: config.profileID)
        let name = profile.map { AccountLabel.name($0, app: app) }
        return ComposerDropdown(width: app.connectedProviders.count > 1 ? 340 : 296) {
            ComposerPill(agent: config.provider.displayName, account: profile.map { AccountKind.of($0, app: app) },
                         text: [config.provider.displayName, name].compactMap { $0 }.joined(separator: " · ")
                            + (config.model.isEmpty ? "" : " · " + app.modelName(config.model, for: config.provider)))
        } content: {
            if app.connectedProviders.isEmpty {
                DropdownHeader(title: tr("agents.noneConnected"))
            } else {
                AgentModelPicker(providers: app.connectedProviders, provider: config.provider, profileID: config.profileID,
                                 model: config.model) { provider, account, model in
                    if provider != config.provider || (account != nil && account != config.profileID) {
                        choose(provider, account: account ?? app.connectedProfiles(for: provider).first?.id ?? config.profileID)
                    }
                    if let model { config.model = model }
                }
            }
        }
        .help(tr("ws.new.accountPinned"))
    }

    private var modeMenu: some View {
        ModeToggle(mode: $config.mode)
    }

    private var permissionMenu: some View {
        ComposerDropdown(width: 300) {
            ComposerPill(symbol: config.permission == .bypass ? "lock.open" : "lock",
                 dot: nil,
                 text: config.mode == .plan ? tr("compose.readOnly") : config.permission.label,
                 tint: config.permission == .bypass && config.mode != .plan ? NookTheme.coralSoft : nil)
        } content: {
            DropdownHeader(title: tr("compose.access"))
            ForEach(config.provider.capabilities.policies) { policy in
                DropdownRow(symbol: policy.symbol, title: policy.label, detail: policy.help(for: config.provider),
                            chosen: config.permission == policy, tint: policy == .bypass ? NookTheme.coralSoft : nil) {
                    config.permission = policy
                }
            }
        }
        .disabled(config.mode == .plan)
        .help(config.mode == .plan ? tr("ws.new.planReadOnly") : config.permission.help(for: config.provider))
    }

    // MARK: Below the box

    private var belowBox: some View {
        HStack(spacing: 6) {
            ComposerDropdown(width: 300) {
                ComposerPill(symbol: config.isolation == .worktree ? "square.stack.3d.up" : "folder", dot: nil,
                     text: config.isolation == .worktree ? tr("compose.newWorktree") : tr("compose.currentCheckout"))
            } content: {
                DropdownHeader(title: tr("compose.whereWorks"))
                DropdownRow(symbol: "folder", title: tr("compose.currentCheckout"), detail: tr("compose.currentCheckoutDetail"),
                            chosen: config.isolation == .folder) {
                    config.isolation = .folder
                }
                DropdownRow(symbol: "square.stack.3d.up", title: tr("compose.newWorktree"), detail: tr("ws.new.worktreeExplain"),
                            chosen: config.isolation == .worktree, disabledReason: worktreeAllowed ? nil : worktreeBlockedReason) {
                    config.isolation = .worktree
                }
            }
            .help(worktreeAllowed ? tr("ws.new.worktreeExplain") : worktreeBlockedReason)

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
        .padding(.horizontal, 6)
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

    private func prepare() {
        // Your default agent, unless it is not connected: then the first one that is.
        let connected = app.connectedProviders
        let provider = connected.contains(settings.defaultProvider) ? settings.defaultProvider : (connected.first ?? settings.defaultProvider)
        config.provider = provider
        config.profileID = (app.connectedProfiles(for: provider).first ?? app.profiles.preferredProfile(provider.kind)).id
        config.model = settings.model(for: provider)
        config.mode = settings.defaultMode
        config.permission = settings.permission(for: provider)
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
            if !provider.capabilities.policies.contains(config.permission) { config.permission = settings.permission(for: provider) }
        }
        config.profileID = account
    }

    private func select(_ path: String) {
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
        // In Plan mode the agent is read-only; the safest permissions go along for when you continue later.
        if request.mode == .plan { request.permission = request.provider.capabilities.policies.first ?? .acceptEdits }
        let finalConfig = request
        let shared = allowShared
        Task {
            do {
                let id = try await workspace.start(finalConfig, allowSharedFolder: shared)
                settings.defaultProvider = config.provider
                settings.setModel(config.model, for: config.provider)
                settings.defaultMode = config.mode
                settings.defaultIsolation = config.isolation
                settings.defaultPermission = config.permission
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
