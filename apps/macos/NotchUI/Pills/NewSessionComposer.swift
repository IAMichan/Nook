import SwiftUI
import AppKit

/// Starting a session in the notch: one question, one field, and a few quiet choices underneath.
/// "What should we build in nook?" — type the task, press Return. Agent and account, mode, permissions, effort,
/// where it works (this folder or a new worktree) and the branch it starts from are small menus, already set to
/// your last choices in this folder. Nothing else to fill in: title, branch name and worktree location are derived.
struct NewSessionComposer: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @EnvironmentObject private var settings: WorkspaceSettings
    @ObservedObject private var antigravity = AntigravityInstaller.shared
    /// The panels' icons (terminal, browser, bottom and side panel) at the top right, as in a running session.
    var headerAccessory: AnyView? = nil
    /// Called with the folder the new session will work in, so its panels open there; empty on another machine.
    var onDirectory: (String) -> Void = { _ in }
    /// Called with the new session once it runs.
    let onStarted: (UUID) -> Void

    /// Every choice for the new session. Its `task` stays empty while you type: the words live in `task` below, and
    /// `checkedConfig` puts them in when the session starts.
    @State private var config = NewRunConfig()
    /// The words in the box, held outside the panel's own state: only the field reads them, so a keystroke redraws the
    /// field and not every menu, the heading and the tray of this panel (that cost a frame or more per key).
    @State private var task = NewSessionTask()
    /// Whether the box holds more than whitespace: all the panel itself needs of the words (the start button, the
    /// notice). It changes only when the box becomes empty or not.
    @State private var hasTask = false
    @State private var images: [ImageAttachment] = []
    @State private var project: ProjectInfo?
    @State private var inspecting = false
    @State private var starting = false
    @State private var error: String?
    @State private var allowShared = false
    @State private var showClone = false
    /// A project just made with "New project…": the sheet that offers to publish it.
    @State private var newProjectPlan: PublishPlan?
    /// The last project request from the Agents list this composer applied (`PromptLinkInbox.requestProject`).
    @State private var appliedProjectRequest: UUID?
    @State private var cloneURL = ""
    @State private var cloning = false
    @State private var pendingID = UUID()
    /// On another machine over SSH (see RemoteMachines): which one, and the folder there.
    @State private var remoteMachine: RemoteMachine?
    @State private var remoteFolder = ""
    /// Held, not observed: only its suggestion list watches it (`ComposerSuggestionSlot`), so a key that changes the
    /// list does not redraw this whole panel.
    @State private var composerModel = ComposerModel()
    @ObservedObject private var promptLinks = PromptLinkInbox.shared
    @State private var linkNotice: String?
    /// A pull request link's branch is being checked out (`promptLinks.pendingCheckout`).
    @State private var checkingOut = false
    /// Set once the session started: what is left in the box then is not worth bringing back.
    @State private var started = false
    /// The other models the prompt also goes to, each in a session and worktree of its own (`ModelComparison`).
    @State private var comparing: [ComparisonTarget] = []
    @FocusState private var focused: Bool

    /// The key of the task you were typing in `ComposerDraftStore`, so it also outlives a relaunch.
    static let draftKey = "new-session"

    var body: some View {
        VStack(spacing: 0) {
            if let headerAccessory {
                HStack(spacing: NookTheme.Spacing.md) {
                    Spacer(minLength: 8)
                    headerAccessory
                }
                .frame(height: 30)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { restoreOrPrepare(); app.refreshAgentModels(); applyPromptLink(); applyRequestedProject() }
        .composerFocusOnAppear($focused)
        // Closing the notch (or switching tabs) drops this view; what you typed and chose waits for its return.
        .onDisappear(perform: keepDraft)
        .onChange(of: promptLinks.pending) { _, _ in applyPromptLink() }
        .onChange(of: promptLinks.pendingProject) { _, _ in applyRequestedProject() }
        .onChange(of: workingDirectory, initial: true) { _, directory in onDirectory(directory) }
        // ⌥⌘↩: start it and keep a fresh box here for the next one.
        .keyCommands(["composer.startInBackground": {
            guard canStart, !starting else { return false }
            start(background: true)
            return true
        }], enabled: focused)
    }

    private func setTask(_ text: String) {
        guard text != task.text else { return }
        task.text = text
        let filled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if filled != hasTask { hasTask = filled }
        // Typing again after a start begins the next draft.
        if !text.isEmpty { started = false }
        if !started { ComposerDraftStore.shared.save(sessionID: Self.draftKey, text: text) }
    }

    /// The folder the panels open in: none for a session on another machine.
    private var workingDirectory: String {
        remoteMachine == nil ? config.projectPath : ""
    }

    private var content: some View {
        VStack(spacing: NookTheme.Spacing.xl) {
            Spacer(minLength: 0)
            heading
            if showClone { cloneRow }
            if remoteMachine != nil { remoteRow }
            // A machine that logs in with a password asks for it once, before its first session in this run of Nook.
            if let machine = remoteMachine, !RemotePasswords.shared.isUnlocked(machine) {
                RemotePasswordField(machine: machine) { remoteMachine = $0 }
                    .frame(maxWidth: 640)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
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
    }

    // MARK: Heading

    /// One line while it fits; in a narrow column the folder moves to a line of its own under the question, instead of
    /// the question being squeezed to a word per line beside a long folder name.
    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                headingLead
                projectPicker
            }
            VStack(spacing: NookTheme.Spacing.xxs) {
                headingLead
                projectPicker
            }
        }
        .font(NookTheme.TextStyle.display)
        .multilineTextAlignment(.center)
        .padding(.horizontal, NookTheme.Spacing.lg)
    }

    private var headingLead: some View {
        Text(tr("compose.heading"))
            .foregroundStyle(NookTheme.paper)
    }

    /// The folder (or machine) the session works in, then the question mark, kept together on one line.
    private var projectPicker: some View {
        HStack(spacing: 0) {
            ComposerDropdown(width: 320) {
                Text(projectLabel)
                    .foregroundStyle(NookTheme.paper)
                    .underline(true, pattern: .dot, color: NookTheme.textTertiary)
            } content: {
                let menu = projectMenu
                if !menu.favorites.isEmpty {
                    DropdownHeader(title: tr("ws.new.favorites"))
                    ForEach(menu.favorites, id: \.self) { path in
                        projectRow(path)
                    }
                }
                if !menu.recent.isEmpty {
                    DropdownHeader(title: tr("ws.new.recent"))
                    ForEach(menu.recent, id: \.self) { path in
                        projectRow(path)
                    }
                }
                if !menu.favorites.isEmpty || !menu.recent.isEmpty {
                    DropdownDivider()
                }
                DropdownRow(symbol: "folder.badge.plus", title: tr("ws.new.chooseFolder")) { chooseFolder() }
                // A folder of its own under ~/.nook/scratch, for a question or a try-out that belongs to no project.
                DropdownRow(symbol: "tray", title: tr("ws.new.noProject"), detail: tr("ws.new.noProjectDetail"),
                            chosen: remoteMachine == nil && ScratchProjects.isScratch(config.projectPath)) { chooseNoProject() }
                DropdownRow(symbol: "arrow.down.circle", title: tr("ws.new.clone")) { showClone = true }
                // A new folder with a repository in it, offered to publish on GitHub at once.
                DropdownRow(symbol: "plus.rectangle.on.folder", title: tr("sc.newProject"), detail: tr("sc.newProject.detail")) {
                    chooseNewProject()
                }
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
            .composerTip(project.map { AgentPathFormat.tilde($0.path) } ?? tr("ws.new.pickWorkspace"))
            .sheet(item: $newProjectPlan) { plan in
                PublishRepositorySheet(plan: plan) { _ in newProjectPlan = nil }
                    .environmentObject(workspace)
            }
            Text("?").foregroundStyle(NookTheme.paper)
            if inspecting {
                ProgressView().controlSize(.small).padding(.leading, NookTheme.Spacing.md)
            }
        }
    }

    private func projectRow(_ path: String) -> some View {
        let chosen = project.map { WorkspacePathPolicy.normalize($0.path) == path } ?? false
        return DropdownRow(symbol: "folder", projectIcon: settings.projectIcon(path), title: (path as NSString).lastPathComponent,
                           detail: AgentPathFormat.tilde(path), chosen: chosen, favorite: favoriteBinding(path)) { select(path) }
    }

    private func favoriteBinding(_ path: String) -> Binding<Bool> {
        Binding(get: { settings.isFavoriteProject(path) },
                set: { if $0 != settings.isFavoriteProject(path) { settings.toggleFavoriteProject(path) } })
    }

    private var cloneRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            TextField(tr("ws.new.clonePlaceholder"), text: $cloneURL)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.code)
                .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .frame(height: 30)
                .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
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
            let folder = remoteFolder.isEmpty ? "…" : (remoteFolder as NSString).lastPathComponent
            return remoteMachine.name + ":" + folder
        }
        if let project, ScratchProjects.isScratch(project.path) { return tr("ws.new.noProject") }
        return project?.name ?? tr("compose.pickProject")
    }

    /// The folder on the remote machine, typed: there is no folder panel for another machine.
    private var remoteRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: "server.rack").foregroundStyle(NookTheme.textTertiary)
            // A long machine name gives way, so the field keeps room to type a path.
            Text(tr("ws.remote.folder", remoteMachine?.name ?? "")).foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            TextField("~/code/app", text: $remoteFolder)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.code)
                .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .frame(minWidth: 140)
                .frame(height: 30)
                .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 26) { remoteMachine = nil }
        }
        .font(NookTheme.TextStyle.body)
        .frame(maxWidth: 640)
    }

    // MARK: The box

    /// The same composer a running session answers in, with the choices for the new session inside it.
    private var box: some View {
        // The words are read in `TaskField`, not here: SwiftUI reads a binding's value when it compares the composer it
        // was given with the last one, and a binding made in this `body` would then redraw the whole panel per key.
        TaskField(task: task, set: setTask) { taskBinding in
            composer(taskBinding)
        }
    }

    private func composer(_ taskBinding: Binding<String>) -> some View {
        SessionComposer(
            text: taskBinding,
            prompt: tr("compose.prompt"),
            minHeight: 56,
            lines: 3...8,
            canSend: canStart,
            sending: starting,
            sendLabel: blockingReason ?? tr("ws.new.start"),
            focus: $focused,
            onSend: { start() }
        ) {
            // The same row as in a running session and in the chat: plus menu, the agent and model, then mode and rights.
            ComposerPlusMenu(attach: attachFile) {}
            agentMenu
            ComposerDivider()
            modeMenu
            ComposerDivider()
            permissionMenu
            effortMenu
            ComposerSpeedTier(tiers: speedTiers, chosen: config.speedTier) { config.speedTier = $0 }
            ComposerUltracodeToggle(offered: Ultracode.offered(provider: config.provider, model: config.model),
                                    on: config.ultracode == true) { config.ultracode = $0 }
            ComposerMainThreadToggle(offered: MainThread.offered(provider: config.provider, access: workspace.settings.bridgeAccess),
                                     on: config.mainThread == true) { config.mainThread = $0 ? true : nil }
            usageLimits
        }
        .rich(composerModel, composerConfig)
        .images($images)
        .dictating()
        // One step more or less effort without opening the picker.
        .keyCommands(["effort.increase": { stepEffort(.up) }, "effort.decrease": { stepEffort(.down) }])
    }

    private var composerConfig: ComposerConfig {
        var rich = ComposerConfig()
        rich.fileRoot = config.projectPath.isEmpty ? nil : config.projectPath
        rich.keepsBigPastes = true
        // The session has no id yet: its pasted secrets wait in the composer's own folder. Not for another machine.
        rich.secretScope = remoteMachine == nil ? SecretFiles.composerScope : nil
        return rich
    }

    private func attachFile() {
        guard !config.projectPath.isEmpty,
              let ref = ComposerFilePicker.pick(startingIn: config.projectPath) else { return }
        setTask(ComposerAttachments.appending(ref, to: task.text))
        focused = true
    }

    // MARK: Choices in the box

    /// Agent, account and model in one panel: agents in a rail, their models with a search.
    private var agentMenu: some View {
        let profile = app.profiles.profile(id: config.profileID)
        let name = profile.map { AccountLabel.name($0, app: app) }
        // On Auto the agent is picked from the prompt as the session starts, so the pill shows Auto's own mark and word,
        // not the logo of the agent chosen last.
        let auto = config.model == AutoModel.id && comparing.isEmpty
        return ModelPickerDropdown {
            ComposerPill(symbol: auto ? AutoModel.symbol : nil,
                         agent: auto ? nil : config.provider.displayName,
                         account: auto ? nil : profile.map { AccountTag.of($0, app: app) },
                         text: auto ? tr("auto.model") : comparing.isEmpty
                            ? [config.provider.displayName, name].compactMap { $0 }.joined(separator: " · ")
                                + (config.model.isEmpty ? "" : " · " + app.modelMenuName(config.model, for: config.provider, profileID: config.profileID))
                            : tr("compare.pill", comparing.count + 1),
                         short: auto ? tr("auto.model") : !comparing.isEmpty ? tr("compare.pill", comparing.count + 1)
                            : (config.model.isEmpty ? config.provider.displayName : app.modelMenuName(config.model, for: config.provider, profileID: config.profileID)))
        } content: {
            let providers = app.connectedProviders(in: remoteMachine == nil ? config.projectPath : nil)
            if providers.isEmpty {
                DropdownHeader(title: tr(app.connectedProviders.isEmpty ? "agents.noneConnected" : "sc.agents.allOff"))
            } else {
                AgentModelPicker(providers: providers, provider: config.provider, profileID: config.profileID,
                                 model: config.model, comparing: remoteMachine == nil ? $comparing : nil) { provider, account, model in
                    if provider != config.provider || (account != nil && account != config.profileID) {
                        choose(provider, account: account ?? rememberedProfile(for: provider) ?? config.profileID)
                    }
                    if let model { config.model = model }
                    remember()
                }
            }
        }
        .composerTip(tr("ws.new.accountPinned"))
    }

    private var modeMenu: some View {
        ModeToggle(mode: Binding(get: { config.mode }, set: { config.mode = $0; remember() }))
    }

    private var permissionMenu: some View {
        ComposerDropdown(width: 300, command: "permissionPicker.toggle") {
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
        .composerTip(config.mode == .plan ? tr("ws.new.planReadOnly") : config.permission.help(for: config.provider))
    }

    /// How hard the agent thinks, only for agents that have it; "Default" leaves it to the agent.
    @ViewBuilder
    private var effortMenu: some View {
        let levels = workspace.effortLevels(for: config.provider, profileID: config.profileID,
                                            model: config.model.isEmpty ? nil : config.model)
        if let family = app.modelFamily(config.model, for: config.provider, profileID: config.profileID) {
            levelMenu(family)
        } else if !levels.isEmpty {
            ComposerDivider()
            ComposerDropdown(width: 220, command: "effortPicker.toggle") {
                ComposerPill(symbol: "gauge.with.dots.needle.33percent",
                             text: workspace.effortTitle(config.effort, for: config.provider, profileID: config.profileID))
            } content: {
                DropdownHeader(title: tr("compose.effort"))
                DropdownRow(symbol: "circle.dashed", title: tr(EffortLevels.label(nil)), chosen: config.effort == nil) {
                    config.effort = nil
                    remember()
                }
                ForEach(levels, id: \.self) { level in
                    DropdownRow(symbol: Self.effortSymbol(level, in: levels),
                                title: workspace.effortTitle(level, for: config.provider, profileID: config.profileID),
                                chosen: config.effort == level) {
                        config.effort = level
                        remember()
                    }
                }
            }
            .composerTip(tr("compose.effort.help"))
        }
    }

    /// The subscription limits of the chosen account, beside the effort as in a running session, for every agent that
    /// reports them: you see how much room is left before you start.
    private var usageLimits: some View {
        ComposerUsageRing.forAccount(app.profiles.profile(id: config.profileID), app: app)
    }

    /// For an agent that lists one model per thinking level, the level picks the model of that family.
    private func levelMenu(_ family: ModelVariants.Family) -> some View {
        let levels = family.members.map(\.level)
        let current = family.members.first { $0.id == config.model }?.level ?? ""
        return Group {
            ComposerDivider()
            ComposerDropdown(width: 220, command: "effortPicker.toggle") {
                ComposerPill(symbol: "gauge.with.dots.needle.33percent", text: tr(EffortLevels.label(variant: current)))
            } content: {
                DropdownHeader(title: tr("compose.effort"))
                ForEach(family.members, id: \.self) { member in
                    DropdownRow(symbol: member.level.isEmpty ? "circle.dashed" : Self.effortSymbol(member.level, in: levels),
                                title: tr(EffortLevels.label(variant: member.level)), chosen: member.id == config.model) {
                        config.model = member.id
                        remember()
                    }
                }
            }
            .composerTip(tr("compose.effort.help"))
        }
    }

    /// The gauge fills up with the level.
    private static func effortSymbol(_ level: String, in levels: [String]) -> String {
        EffortSymbol.symbol(level, in: levels)
    }

    /// The faster tiers the chosen agent offers for the chosen model (`SpeedTiers`).
    private var speedTiers: [SpeedTier] {
        SpeedTiers.tiers(for: config.provider, model: config.model,
                         listed: workspace.offeredModels(config.provider, profileID: config.profileID))
    }

    /// `effort.increase` / `effort.decrease`: the next level up or down (`EffortStep`). An agent that lists one model per
    /// level steps through that family's models instead. False when the agent has no levels, so the key goes on.
    private func stepEffort(_ direction: EffortStep.Direction) -> Bool {
        if let family = app.modelFamily(config.model, for: config.provider, profileID: config.profileID) {
            let ids = family.members.map(\.id)
            guard let index = ids.firstIndex(of: config.model) else { return false }
            let next = direction == .up ? min(index + 1, ids.count - 1) : max(index - 1, 0)
            config.model = ids[next]
        } else {
            let levels = workspace.effortLevels(for: config.provider, profileID: config.profileID,
                                                model: config.model.isEmpty ? nil : config.model)
            guard !levels.isEmpty else { return false }
            config.effort = EffortStep.next(current: config.effort, levels: levels, direction: direction)
        }
        remember()
        return true
    }

    // MARK: Below the box

    private var belowBox: some View {
        ComposerTray(edge: .bottom) { belowBoxRow }
    }

    private var belowBoxRow: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let remoteMachine {
                // On another machine: its folder, or a new worktree there (~/.nook/worktrees); git runs there over ssh.
                ComposerPill(symbol: "network", dot: nil, text: tr("ws.remote.via", remoteMachine.host), showsChevron: false)
                    .composerTip(tr("ws.remote.limits"))
                isolationDropdown(worktreeAllowed: true, reason: "")
                Spacer(minLength: 8)
                if config.isolation == .worktree {
                    Image(icon: "arrow.triangle.branch").font(NookTheme.font(10.5)).foregroundStyle(NookTheme.textTertiary)
                    TextField("", text: $config.baseBranch, prompt: Text(tr("ws.remote.baseCurrent")))
                        .textFieldStyle(.plain)
                        .font(NookTheme.TextStyle.detail)
                        .frame(minWidth: 90, maxWidth: 150)
                        .help(tr("ws.remote.baseHelp"))
                }
            } else {
                // A folder that is no git repository has no branch or worktree to choose.
                if project == nil || project?.repoRoot != nil {
                    isolationDropdown(worktreeAllowed: worktreeAllowed, reason: worktreeBlockedReason)
                }

                Spacer(minLength: 8)

                if config.isolation == .worktree, let branches = project?.branches, !branches.isEmpty {
                    ComposerDropdown(width: 280) {
                        // A long branch name is cut short, so the row stays inside a narrow tab.
                        ComposerPill(symbol: "arrow.triangle.branch", dot: nil, text: tr("compose.from", config.baseBranch))
                            .frame(maxWidth: 220)
                    } content: {
                        BranchPicker(branches: sortedBranches(branches), selected: config.baseBranch) { config.baseBranch = $0 }
                    }
                } else if let branch = project?.currentBranch {
                    ComposerPill(symbol: "arrow.triangle.branch", dot: nil, text: branch, showsChevron: false)
                        .frame(maxWidth: 220)
                }
            }
        }
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
        .composerTip(worktreeAllowed ? tr("ws.new.worktreeExplain") : reason)
    }

    /// One line, only when something needs saying: why you cannot start yet, or what went wrong.
    @ViewBuilder
    private var notice: some View {
        if let link = promptLinks.pendingCheckout, let pull = link.pullRequest {
            // A pull request link no session works on: the checkout waits for you, as it runs the project's setup.
            PanelNoticeBar(title: tr("promptLink.pr.title", "\(pull.repository)#\(pull.number)"),
                           detail: tr("promptLink.pr.detail"), symbol: PullRequestIcon.generic, tone: NookTheme.amber) {
                if checkingOut {
                    ProgressView().controlSize(.small)
                } else {
                    NookNoticeActions(primary: NookNoticeAction(tr("promptLink.pr.checkout")) { checkOutLinkedPullRequest(link, pull) },
                                      secondary: NookNoticeAction(tr("button.cancel")) { promptLinks.pendingCheckout = nil })
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
        } else if let error {
            Text(error)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coralSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
        } else if let linkNotice {
            Text(linkNotice)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
        } else if let remoteMachine {
            // On another machine the agent uses that machine's own login; what needs this Mac stays off.
            Text(tr("ws.remote.notice", remoteMachine.name))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
        } else if config.provider == .antigravity, antigravity.installed == nil {
            AntigravitySetupRow().padding(.horizontal, NookTheme.Spacing.md)
        } else if let profile = app.profiles.profile(id: config.profileID), app.history.profileAccounts[profile.id] == nil {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("ws.new.accountNotLoggedIn")).foregroundStyle(NookTheme.amber)
                SmallGhostButton(title: tr("agents.login")) { app.connect(profile) }
            }
            .font(NookTheme.TextStyle.detail)
            .padding(.horizontal, NookTheme.Spacing.md)
        } else if !sharing.isEmpty, config.isolation == .folder {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("ws.new.sharedWarning", sharing.map(\.title).joined(separator: ", ")))
                    .foregroundStyle(NookTheme.amber)
                    .lineLimit(2)
                Toggle(tr("ws.new.sharedAllow"), isOn: $allowShared).toggleStyle(.checkbox)
            }
            .font(NookTheme.TextStyle.detail)
            .padding(.horizontal, NookTheme.Spacing.md)
        } else if let reason = blockingReason, project != nil, hasTask {
            Text(reason)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.horizontal, NookTheme.Spacing.md)
        }
    }

    // MARK: State

    private var projectMenu: (favorites: [String], recent: [String]) {
        // Folders of sessions without a project stay out of Recent; one you turned into a project is a favorite.
        // An archived project stays out (Settings › Projects brings it back), unless it is the one chosen now.
        ProjectSettings.projectMenu(
            favorites: ProjectSettings.withoutArchived(settings.favoriteProjects, overrides: settings.projectOverrides),
            recent: ProjectSettings.withoutArchived(
                [config.projectPath, settings.lastProject] + settings.recentProjects + app.history.sessions.map(\.cwd),
                overrides: settings.projectOverrides)
                .filter { !ScratchProjects.isScratch($0) }
        )
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
        if let problem = shownConfig.problem { return tr("ws.error.config." + problem.rawValue) }
        // On another machine the agent is looked up there, not on this Mac.
        if let machine = remoteMachine {
            return RemotePasswords.shared.isUnlocked(machine) ? nil : tr("remote.password.needed", machine.name)
        }
        if project?.verdict != .ok { return tr("ws.error.config.missingWorkspace") }
        if !settings.isAgentOn(config.provider, for: config.projectPath) { return tr("sc.agents.offHere", config.provider.displayName) }
        if config.provider == .antigravity, antigravity.installed == nil { return tr("ws.antigravity.installFirst") }
        if workspace.executable(config.provider) == nil { return tr("ws.error.noExecutable", config.provider.displayName) }
        if !comparing.isEmpty {
            // Every model works in a worktree of its own.
            if !worktreeBlockedReason.isEmpty { return tr("compare.needsWorktree", worktreeBlockedReason) }
            if let missing = comparisonTargets.first(where: { workspace.executable($0.provider) == nil }) {
                return tr("ws.error.noExecutable", missing.provider.displayName)
            }
            return nil
        }
        if config.isolation == .folder, !allowShared, !sharing.isEmpty { return tr("ws.new.sharedBlocked") }
        return nil
    }

    /// Every model the prompt goes to, the chosen one first.
    private var comparisonTargets: [ComparisonTarget] {
        ModelComparison.targets(primary: ComparisonTarget(provider: config.provider, profileID: config.profileID, model: config.model),
                                extras: comparing)
    }

    private var canStart: Bool { !starting && blockingReason == nil }

    /// The configuration as it will start: with the branch name derived from the task, which only gets filled in at the
    /// moment of starting. Checking `config` itself would see an empty branch name and refuse every new worktree.
    private var checkedConfig: NewRunConfig { configured(task: task.text) }

    /// `checkedConfig` as the panel checks it while you type, without reading the words (see `task`): the check only
    /// asks whether there are any, and a branch name derived from words is always a valid one.
    private var shownConfig: NewRunConfig { configured(task: hasTask ? "task" : "") }

    private func configured(task text: String) -> NewRunConfig {
        var copy = config
        copy.task = text
        copy.branchName = WorktreeNaming.branchName(task: text, id: pendingID)
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
        // What you were writing stays, under the link's text.
        let draft = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
        setTask(draft.isEmpty || draft == link.text ? link.text : link.text + "\n\n" + draft)
        if let path = link.project, FileManager.default.fileExists(atPath: path) { select(path) }
        if let name = link.agent?.lowercased(),
           let provider = RunProvider.allCases.first(where: { $0.rawValue == name || $0.displayName.lowercased() == name }) {
            choose(provider, account: rememberedProfile(for: provider) ?? app.profiles.preferredProfile(provider.kind).id)
            if let model = link.model { config.model = model }
        }
        linkNotice = link.warnings.contains(.strippedHiddenCharacters) ? tr("promptLink.stripped") : tr("promptLink.filled")
    }

    /// "Check out" on a pull request link: the branch in a worktree of its own, the composer on it with the link's words
    /// as the draft (nothing is sent), and the checkout in the action log.
    private func checkOutLinkedPullRequest(_ link: PromptLink, _ pull: PromptLink.PullRequest) {
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

    /// A project's "+" in the Agents list opens the composer on that folder.
    private func applyRequestedProject() {
        guard let request = promptLinks.pendingProject, request.id != appliedProjectRequest else { return }
        appliedProjectRequest = request.id
        showClone = false
        if FileManager.default.fileExists(atPath: request.path) { select(request.path) }
        DispatchQueue.main.async { focused = true }
    }

    /// Back where you left it when the notch closed, else a fresh box with your last choices (and the task you were
    /// typing before Nook quit).
    private func restoreOrPrepare() {
        guard let draft = NewSessionDraft.saved else {
            prepare()
            if task.text.isEmpty, let saved = ComposerDraftStore.shared.draft(for: Self.draftKey) { setTask(saved) }
            return
        }
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
        for (id, text) in draft.excerpts { composerModel.keep(id, text: text) }
        // A project still being inspected when the notch closed is looked at again.
        if project == nil, !config.projectPath.isEmpty, remoteMachine == nil,
           FileManager.default.fileExists(atPath: config.projectPath) {
            select(config.projectPath)
        }
    }

    private func keepDraft() {
        guard !started else { NewSessionDraft.saved = nil; return }
        NewSessionDraft.saved = NewSessionDraft(
            config: configured(task: task.text), images: images, project: project, allowShared: allowShared, showClone: showClone,
            cloneURL: cloneURL, pendingID: pendingID, remoteMachine: remoteMachine, remoteFolder: remoteFolder,
            excerpts: composerModel.excerpts)
    }

    private func prepare() {
        config.worktreeRoot = settings.worktreeRoot
        let menu = projectMenu
        let last = settings.lastProject.isEmpty ? (menu.favorites.first ?? menu.recent.first) : settings.lastProject
        let initial = last.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        applyFolderDefaults(initial)
        if let initial { select(initial) }
    }

    private func choose(_ provider: RunProvider, account: String) {
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
    private func rememberedProfile(for provider: RunProvider) -> String? {
        settings.composerDefaults(for: config.projectPath)
            .profile(for: provider, connected: app.connectedProfiles(for: provider).map(\.id))
    }

    /// Keeps what you just chose for the next new session in this folder, and as the start for folders without choices
    /// of their own. What the project sets for itself (Settings › Workspace, per project) stays out of the global defaults.
    private func remember() {
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
        if !ScratchProjects.isScratch(path) { settings.lastProject = path }
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
        } else if config.isolation == .folder && settings.composerDefaults(for: path).isolation == .worktree {
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
    private func chooseNoProject() {
        do {
            select(try ScratchProjects.create(prompt: task.text))
        } catch let failure {
            error = failure.localizedDescription
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
        settings.rememberProject(url.path)
        select(url.path)
    }

    /// "New project…": a new folder where you choose, with an empty repository, then the offer to publish it on GitHub
    /// (Cancel keeps it on this Mac only).
    private func chooseNewProject() {
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
                select(plan.folder)
                newProjectPlan = plan
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }

    private func clone() {
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
                select(cloned.path)
            } catch let failure {
                error = failure.localizedDescription
            }
            cloning = false
        }
    }

    /// `background` (⌥⌘↩): the session starts without opening, and the box stays for the next one with the same folder,
    /// agent and worktree choices.
    private func start(background: Bool = false) {
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
        Task {
            do {
                let id = try await workspace.start(finalConfig, allowSharedFolder: shared)
                if let remote = finalConfig.remote {
                    UserDefaults.standard.set(remote.directory, forKey: "agents.remoteFolder." + remote.machineID)
                }
                remember()
                started = true
                NewSessionDraft.saved = nil
                ComposerDraftStore.shared.save(sessionID: Self.draftKey, text: "")
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
        let configs = ModelComparison.configs(base: base, targets: targets, ids: targets.map { _ in UUID() },
                                              modelName: comparisonName)
        Task {
            let outcome = await workspace.startComparison(configs, targets: targets)
            starting = false
            if !outcome.started.isEmpty { remember() }
            guard let retry = ModelComparison.retrySelection(after: outcome) else {
                started = true
                NewSessionDraft.saved = nil
                ComposerDraftStore.shared.save(sessionID: Self.draftKey, text: "")
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
            ComposerDraftStore.shared.save(sessionID: Self.draftKey, text: task.text)
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

/// The new-session box as you left it when the notch closed: the task, its pictures and big pastes, and every choice
/// around it. Kept in memory only; the task alone also goes to `ComposerDraftStore` for after a relaunch.
@MainActor
private struct NewSessionDraft {
    static var saved: NewSessionDraft?

    var config: NewRunConfig
    var images: [ImageAttachment]
    var project: ProjectInfo?
    var allowShared: Bool
    var showClone: Bool
    var cloneURL: String
    var pendingID: UUID
    var remoteMachine: RemoteMachine?
    var remoteFolder: String
    var excerpts: [String: String]
}

/// The words typed in the new-session box (`NewSessionComposer.task`): observed by the field alone, so a keystroke does
/// not redraw the panel around it.
@MainActor
@Observable
private final class NewSessionTask {
    var text = ""
}

/// Hands the composer a binding to the box's words, so only this view, not the panel around it, observes them.
private struct TaskField<Content: View>: View {
    let task: NewSessionTask
    let set: (String) -> Void
    @ViewBuilder let content: (Binding<String>) -> Content

    var body: some View {
        content(Binding(get: { task.text }, set: set))
    }
}
