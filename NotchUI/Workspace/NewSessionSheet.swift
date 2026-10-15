import SwiftUI
import AppKit

/// "New session": choose folder, enter task prompt, select agent, account, and isolation, then launch.
struct NewSessionSheet: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @EnvironmentObject private var settings: WorkspaceSettings
    let onStarted: (UUID) -> Void
    /// Closes the sheet (it is presented as a native AppKit sheet, see `WorkspaceWindowController.presentSheet`).
    let close: () -> Void
    /// Shown inside the notch: no own title bar (the notch shows it) and it fills the space it gets.
    var embedded = false

    @State private var config = NewRunConfig()
    @State private var project: ProjectInfo?
    @State private var inspecting = false
    @State private var branchEdited = false
    @State private var customModel = false
    @State private var showInstructions = false
    @State private var allowShared = false
    @State private var starting = false
    @State private var stage = ""
    @State private var error: String?
    @State private var cloneURL = ""
    @State private var showClone = false
    @State private var cloning = false
    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack {
                    Text(tr("ws.new.title")).font(NookTheme.font(16, .semibold))
                    Spacer()
                    Text(tr("ws.new.shortcut")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    workspaceSection
                    taskSection
                    agentSection
                    isolationSection
                    instructionsSection
                }
                .padding(embedded ? 4 : 20)
                .frame(maxWidth: embedded ? 720 : CGFloat.infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            Divider().opacity(embedded ? 0.4 : 1)
            footer
        }
        .frame(width: embedded ? nil : 660, height: embedded ? nil : 720)
        .frame(maxWidth: embedded ? CGFloat.infinity : nil, maxHeight: embedded ? CGFloat.infinity : nil, alignment: .topLeading)
        .background(embedded ? Color.clear : WS.background)
        .onAppear(perform: prepare)
        .onChange(of: config.provider) { _, provider in providerChanged(provider) }
        .onChange(of: config.task) { _, task in
            if !branchEdited { config.branchName = WorktreeNaming.branchName(task: task.isEmpty ? "sessie" : task, id: pendingID) }
        }
    }

    /// Stable ID for this sheet so suggested branch name does not recalculate on every keystroke.
    @State private var pendingID = UUID()

    // MARK: Working directory

    private var recentProjects: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let candidates = settings.recentProjects + app.history.sessions.map(\.cwd)
        for path in candidates where !path.isEmpty {
            let normalized = WorkspacePathPolicy.normalize(path)
            guard seen.insert(normalized).inserted, FileManager.default.fileExists(atPath: normalized) else { continue }
            result.append(normalized)
            if result.count == 10 { break }
        }
        return result
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.new.workspace"))
            HStack(spacing: 8) {
                Menu {
                    if !recentProjects.isEmpty {
                        Section(tr("ws.new.recent")) {
                            ForEach(recentProjects, id: \.self) { path in
                                Button(AgentPathFormat.tilde(path)) { select(path) }
                            }
                        }
                    }
                    Divider()
                    Button(tr("ws.new.chooseFolder")) { chooseFolder() }
                    Button(tr("ws.new.clone")) { showClone = true }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(project.map { AgentPathFormat.tilde($0.path) } ?? tr("ws.new.pickWorkspace"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .menuStyle(.button)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(tr("ws.new.chooseFolder")) { chooseFolder() }
            }
            if showClone {
                HStack(spacing: 8) {
                    TextField(tr("ws.new.clonePlaceholder"), text: $cloneURL)
                        .textFieldStyle(.roundedBorder)
                        .font(NookTheme.mono(12))
                    Button(cloning ? tr("ws.new.cloning") : tr("ws.new.cloneAction")) { clone() }
                        .disabled(cloning || !GitService.isCloneURL(cloneURL))
                }
                Text(tr("ws.new.cloneHint", AgentPathFormat.tilde(cloneParent)))
                    .font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
            }
            projectSummary
        }
    }

    @ViewBuilder
    private var projectSummary: some View {
        if inspecting {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(tr("ws.new.inspecting")).font(NookTheme.font(12)) }
                .foregroundStyle(WS.secondary)
        } else if let project {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: project.verdict == .ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(project.verdict == .ok ? NookTheme.mint : NookTheme.coral)
                    Text(project.name).font(NookTheme.font(13, .semibold))
                    if project.verdict != .ok {
                        Text(tr("ws.error.path." + String(describing: project.verdict))).font(NookTheme.font(12)).foregroundStyle(NookTheme.coralSoft)
                    }
                }
                if project.verdict == .ok {
                    if project.repoRoot != nil {
                        HStack(spacing: 10) {
                            Label(project.currentBranch ?? tr("ws.new.detached"), systemImage: "arrow.triangle.branch")
                            Label(project.dirtyFiles == 0 ? tr("ws.new.clean") : tr("ws.new.dirty", project.dirtyFiles),
                                  systemImage: project.dirtyFiles == 0 ? "checkmark" : "pencil.circle")
                                .foregroundStyle(project.dirtyFiles == 0 ? WS.secondary : NookTheme.amber)
                            if project.isWorktree { Label(tr("ws.new.isWorktree"), systemImage: "square.stack.3d.up") }
                        }
                        .font(NookTheme.font(12))
                        .foregroundStyle(WS.secondary)
                    } else {
                        Text(workspace.gitAvailable == false ? tr("ws.error.noGit") : tr("ws.new.notRepo"))
                            .font(NookTheme.font(12)).foregroundStyle(WS.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(WS.surface))
        }
    }

    // MARK: Task prompt

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.new.task"))
            ZStack(alignment: .topLeading) {
                if config.task.isEmpty {
                    Text(tr("ws.new.taskPlaceholder"))
                        .font(NookTheme.font(13))
                        .foregroundStyle(WS.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $config.task)
                    .font(NookTheme.font(13))
                    .scrollContentBackground(.hidden)
                    .focused($taskFocused)
                    .frame(height: 110)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(WS.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(taskFocused ? NookTheme.iris.opacity(0.5) : WS.border, lineWidth: 1))
            TextField(tr("ws.new.namePlaceholder", WorktreeNaming.title(from: config.task)), text: $config.title)
                .textFieldStyle(.roundedBorder)
                .help(tr("ws.new.nameHelp"))
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        let caps = config.provider.capabilities
        let installed = app.history.executables[config.provider.kind] != nil
        let accounts = app.profiles.profiles(for: config.provider.kind)
        let selected = app.profiles.profile(id: config.profileID)
        let loggedIn = selected.map { app.history.profileAccounts[$0.id] != nil } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            WSSectionTitle(title: tr("ws.new.agent"))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label(tr("ws.new.provider"))
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $config.provider) {
                            ForEach(RunProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                        if !installed {
                            Text(tr("ws.new.notInstalled", config.provider.displayName))
                                .font(NookTheme.font(11.5)).foregroundStyle(NookTheme.amber)
                        }
                        Text(tr("ws.new.geminiNote")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                    }
                }
                GridRow {
                    label(tr("ws.new.account"))
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $config.profileID) {
                            ForEach(accounts) { profile in
                                Text(AccountLabel.line(profile, app: app) + (app.profiles.isPreferred(profile) ? " ★" : ""))
                                    .tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 360)
                        if selected != nil && !loggedIn {
                            HStack(spacing: 6) {
                                Text(tr("ws.new.accountNotLoggedIn")).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.amber)
                                Button(tr("agents.login")) { if let selected { app.connect(selected) } }
                                    .controlSize(.small)
                            }
                        } else {
                            Text(tr("ws.new.accountPinned")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                        }
                    }
                }
                GridRow {
                    label(tr("ws.new.model"))
                    HStack(spacing: 8) {
                        if customModel {
                            TextField(tr("ws.new.modelCustom"), text: $config.model)
                                .textFieldStyle(.roundedBorder)
                                .font(NookTheme.mono(12))
                                .frame(width: 220)
                        } else {
                            Picker("", selection: $config.model) {
                                ForEach(config.provider.suggestedModels, id: \.self) { model in
                                    Text(model.isEmpty ? tr("ws.model.default") : model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        Toggle(tr("ws.new.modelOther"), isOn: $customModel)
                            .toggleStyle(.checkbox)
                    }
                }
                GridRow {
                    label(tr("ws.new.mode"))
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $config.mode) {
                            ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                        Text(config.mode.help).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                    }
                }
                GridRow {
                    label(tr("ws.new.permissions"))
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $config.permission) {
                            ForEach(caps.policies) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        .disabled(config.mode == .plan)
                        Text(config.mode == .plan ? tr("ws.new.planReadOnly") : config.permission.help(for: config.provider))
                            .font(NookTheme.font(11))
                            .foregroundStyle(config.permission == .bypass && config.mode != .plan ? NookTheme.coralSoft : WS.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !caps.approvals {
                            Text(tr("ws.new.noApprovals", config.provider.displayName))
                                .font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Isolation

    private var worktreeAllowed: Bool {
        guard let project, project.verdict == .ok else { return false }
        return project.repoRoot != nil && project.hasCommits && workspace.gitAvailable == true
    }

    private var isolationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            WSSectionTitle(title: tr("ws.new.isolation"))
            Picker("", selection: $config.isolation) {
                Text(IsolationMode.folder.label).tag(IsolationMode.folder)
                Text(IsolationMode.worktree.label).tag(IsolationMode.worktree)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .disabled(!worktreeAllowed)

            if !worktreeAllowed, project != nil {
                Text(worktreeBlockedReason).font(NookTheme.font(11.5)).foregroundStyle(WS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if config.isolation == .worktree {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        label(tr("ws.new.base"))
                        Picker("", selection: $config.baseBranch) {
                            ForEach(project?.branches ?? [], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    GridRow {
                        label(tr("ws.new.branch"))
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("nook/…", text: Binding(get: { config.branchName }, set: {
                                config.branchName = $0
                                branchEdited = true
                            }))
                            .textFieldStyle(.roundedBorder)
                            .font(NookTheme.mono(12))
                            .frame(width: 320)
                            if !WorktreeNaming.isPlausibleBranchName(config.branchName) {
                                Text(tr("ws.error.config.invalidBranchName")).font(NookTheme.font(11)).foregroundStyle(NookTheme.coralSoft)
                            }
                        }
                    }
                    GridRow {
                        label(tr("ws.new.location"))
                        HStack(spacing: 6) {
                            Text(AgentPathFormat.tilde(config.worktreeRoot.isEmpty ? settings.worktreeRoot : config.worktreeRoot))
                                .font(NookTheme.mono(11.5))
                                .foregroundStyle(WS.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(tr("ws.new.change")) { chooseWorktreeRoot() }.controlSize(.small)
                        }
                    }
                }
                if let project, project.dirtyFiles > 0 {
                    Label(tr("ws.new.dirtyNotIncluded", project.dirtyFiles), systemImage: "exclamationmark.triangle")
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(tr("ws.new.worktreeExplain"))
                    .font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let project, project.verdict == .ok {
                let sharing = workspace.activeRuns(sharing: project.repoRoot ?? project.path)
                if !sharing.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(tr("ws.new.sharedWarning", sharing.map(\.title).joined(separator: ", ")), systemImage: "exclamationmark.triangle.fill")
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(tr("ws.new.sharedAllow"), isOn: $allowShared).toggleStyle(.checkbox).font(NookTheme.font(12))
                    }
                } else {
                    Text(tr("ws.new.folderExplain")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var worktreeBlockedReason: String {
        if workspace.gitAvailable == false { return tr("ws.error.noGit") }
        guard let project else { return "" }
        if project.repoRoot == nil { return tr("ws.new.worktreeNeedsRepo") }
        if !project.hasCommits { return tr("ws.new.worktreeNeedsCommit") }
        return ""
    }

    private var instructionsSection: some View {
        DisclosureGroup(isExpanded: $showInstructions) {
            TextEditor(text: $config.instructions)
                .font(NookTheme.font(12.5))
                .scrollContentBackground(.hidden)
                .frame(height: 80)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(WS.surface))
                .padding(.top, 6)
            Text(tr("ws.new.instructionsHint")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
        } label: {
            Text(tr("ws.new.instructions")).font(NookTheme.font(12.5, .semibold))
        }
    }

    // MARK: Bottom bar

    private var footer: some View {
        HStack(spacing: 10) {
            if starting {
                ProgressView().controlSize(.small)
                Text(stage).font(NookTheme.font(12)).foregroundStyle(WS.secondary)
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(NookTheme.coral)
                Text(error).font(NookTheme.font(12)).foregroundStyle(NookTheme.coralSoft)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } else if let reason = blockingReason {
                Text(reason).font(NookTheme.font(12)).foregroundStyle(WS.tertiary)
            }
            Spacer()
            Button(tr("button.cancel")) { close() }
                .keyboardShortcut(.cancelAction)
                .disabled(starting)
            Button(tr("ws.new.start")) { start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(starting || blockingReason != nil)
        }
        .padding(.horizontal, embedded ? 4 : 20)
        .padding(.vertical, 12)
    }

    private var blockingReason: String? {
        if let problem = config.problem { return tr("ws.error.config." + problem.rawValue) }
        if project?.verdict != .ok { return tr("ws.error.config.missingWorkspace") }
        if app.history.executables[config.provider.kind] == nil { return tr("ws.error.noExecutable", config.provider.displayName) }
        if let project, config.isolation == .folder, !allowShared, !workspace.activeRuns(sharing: project.repoRoot ?? project.path).isEmpty {
            return tr("ws.new.sharedBlocked")
        }
        return nil
    }

    private func label(_ text: String) -> some View {
        Text(text).font(NookTheme.font(12.5)).foregroundStyle(WS.secondary).frame(width: 96, alignment: .leading)
    }

    // MARK: Actions

    private func prepare() {
        config.provider = settings.defaultProvider
        config.profileID = app.profiles.preferredProfile(settings.defaultProvider.kind).id
        config.model = settings.model(for: settings.defaultProvider)
        customModel = !config.provider.suggestedModels.contains(config.model)
        config.mode = settings.defaultMode
        config.permission = settings.permission(for: settings.defaultProvider)
        config.isolation = settings.defaultIsolation
        config.worktreeRoot = settings.worktreeRoot
        config.branchName = WorktreeNaming.branchName(task: "sessie", id: pendingID)
        taskFocused = true
        let initial = settings.lastProject.isEmpty ? recentProjects.first : settings.lastProject
        if let initial, FileManager.default.fileExists(atPath: initial) { select(initial) }
    }

    private func providerChanged(_ provider: RunProvider) {
        config.profileID = app.profiles.preferredProfile(provider.kind).id
        config.model = settings.model(for: provider)
        customModel = !provider.suggestedModels.contains(config.model)
        if !provider.capabilities.policies.contains(config.permission) { config.permission = settings.permission(for: provider) }
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
            if !canWorktree { config.isolation = .folder } else if config.isolation == .folder && settings.defaultIsolation == .worktree {
                config.isolation = .worktree
            }
            let localBranches = info.branches
            if let base = info.defaultBase, localBranches.contains(base) {
                config.baseBranch = base
            } else {
                config.baseBranch = info.currentBranch ?? localBranches.first ?? ""
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

    private func chooseWorktreeRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("ws.new.choosePrompt")
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        config.worktreeRoot = url.path
    }

    private var cloneParent: String {
        if let project { return URL(fileURLWithPath: project.repoRoot ?? project.path).deletingLastPathComponent().path }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
    }

    private func clone() {
        cloning = true
        error = nil
        let parent = cloneParent
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
        guard !starting, blockingReason == nil else { return }
        starting = true
        error = nil
        stage = config.isolation == .worktree ? tr("ws.new.stageWorktree") : tr("ws.new.stageAgent")
        var request = config
        // In Plan mode, the agent is read-only; safest available permissions are passed along for when you proceed later.
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
                onStarted(id)
                close()
            } catch let failure {
                // Nothing was created (except as indicated by error): retrying will not create duplicate sessions.
                error = failure.localizedDescription
                starting = false
            }
        }
    }
}
