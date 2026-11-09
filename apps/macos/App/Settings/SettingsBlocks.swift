import SwiftUI
import AppKit

/// Diff preview showing changes to an agent's configuration file before writing.
struct ConfigPreview: View {
    let change: AgentConfigInstaller.Change
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        // The one sheet shape: what happens on top, the lines that change in the middle, Cancel and the step below.
        SetupSheet(title: tr(change.install ? "settings.agents.linkTitle" : "settings.agents.unlinkTitle", change.target.title),
                   subtitle: tr("settings.agents.changeNotice", change.target.displayPath), width: 620) {
            SettingsTile(.agents, size: 40)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if change.preview.isEmpty {
                    Text(tr("settings.agents.noChange")).foregroundStyle(NookTheme.textSecondary)
                }
                ForEach(change.preview) { line in
                    Text(line.text)
                        .foregroundStyle(color(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(NookTheme.mono(11))
            .textSelection(.enabled)
            .padding(NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip).fill(NookTheme.well))
        } footer: {
            Spacer()
            Button(tr("button.cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button(change.install ? tr("button.link") : tr("button.unlink"), action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: return NookTheme.mint
        case .remove: return NookTheme.coral
        case .context: return NookTheme.textSecondary
        }
    }
}

// MARK: Building Blocks

enum StatusState {
    case done, todo, warning, error

    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .todo: return "circle"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .done: return NookTheme.mint
        case .todo: return NookTheme.textTertiary
        case .warning: return NookTheme.amber
        case .error: return NookTheme.coral
        }
    }
}

/// Standardized row with status icon on the left, label and description, and action button on the right.
struct StatusRow<Trailing: View>: View {
    let title: String
    let detail: String
    let state: StatusState
    /// Shows this agent's logo, with the status as a small badge on it, instead of the status icon alone.
    var agent: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            if let agent {
                AgentLogo(agent: agent, size: 22)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: state.symbol)
                            .font(NookTheme.font(10, .semibold))
                            .foregroundStyle(state.color)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
                            .offset(x: 4, y: 4)
                    }
                    .frame(width: 22)
            } else {
                Image(systemName: state.symbol)
                    .font(NookTheme.font(17))
                    .foregroundStyle(state.color)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title)
                // An empty detail leaves the row at one line: what is done needs no explanation.
                if !detail.isEmpty {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(state == .warning || state == .error ? state.color : NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NookTheme.Spacing.md)
            // Every status row's buttons have the same small size, whichever page the row is on.
            trailing()
                .controlSize(.small)
        }
        .padding(.vertical, NookTheme.Spacing.xxs)
    }
}

/// Toggle switch that shows only its title. The explanation is there when you want it, on hover and for VoiceOver,
/// so a page full of switches reads as a calm list instead of a wall of captions.
struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .help(detail)
            .accessibilityHint(detail)
            .settingsAnchor(title)
    }
}

/// A setting's title for rows that hold a button or a picker. With `detail:` a short caption stays under it, for what
/// you need to see (a state, a size, the step to take); with `hint:` only the title shows and the explanation is on
/// hover and for VoiceOver, as with `SettingToggle`.
struct SettingLabel: View {
    let title: String
    let detail: String
    private var showsDetail = true

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    init(_ title: String, hint: String) {
        self.title = title
        self.detail = hint
        self.showsDetail = false
    }

    var body: some View {
        label.settingsAnchor(title)
    }

    @ViewBuilder private var label: some View {
        if showsDetail {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title)
                Text(detail)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(title)
                .help(detail)
                .accessibilityHint(detail)
        }
    }
}

/// A section's title with an optional ⓘ next to it. The explanation of a section lives behind that ⓘ (a click opens it,
/// hovering shows it too) instead of in a footer, so every page reads as titles and controls. Footers stay for what
/// must be seen: a warning, an error, or the one step that unlocks the section.
struct SettingsSectionTitle: View {
    let title: String
    var info: String? = nil

    init(_ title: String, info: String? = nil) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text(title)
            if let info { SettingsInfoButton(text: info) }
        }
        .settingsAnchor(title)
    }
}

/// The small ⓘ that holds an explanation: a click opens it in a popover, hovering shows it as a tooltip.
struct SettingsInfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(tr("settings.info.more"))
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(NookTheme.Spacing.lg)
        }
    }
}

/// A short line under a setting or inside a form: a hint, a warning, or an error. A warning and an error carry their
/// symbol, so they stand out by more than color alone. Every such line in Settings is one of these, so they all read
/// the same.
struct SettingNote: View {
    enum Tone { case info, success, warning, error }

    let text: String
    var tone: Tone = .info

    init<S: StringProtocol>(_ text: S, tone: Tone = .info) {
        self.text = String(text)
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
            if let symbol {
                Image(systemName: symbol).accessibilityHidden(true)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(color)
    }

    private var symbol: String? {
        switch tone {
        case .info: return nil
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .info: return NookTheme.textSecondary
        case .success: return NookTheme.mint
        case .warning: return NookTheme.amber
        case .error: return NookTheme.coral
        }
    }
}

/// A row that leads somewhere else (another settings page, a list, a folder): an optional section tile, a title with a
/// line under it, the state when it needs you, and a chevron. A done state stays quiet: only what is left to do shows
/// a symbol, so a page of rows that all work reads calm.
struct SettingsLinkRow: View {
    let title: String
    var detail: String? = nil
    /// The tile of the page the row leads to.
    var section: SettingsSection? = nil
    var state: StatusState? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.lg) {
                if let section {
                    SettingsTile(section, size: 26)
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(title).foregroundStyle(NookTheme.paper)
                    if let detail {
                        Text(detail)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(state == .warning || state == .error ? (state ?? .todo).color : NookTheme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: NookTheme.Spacing.md)
                if let state, state != .done {
                    Image(systemName: state.symbol).foregroundStyle(state.color)
                }
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row in a long list whose buttons show only under the pointer (or while `keepActions`, e.g. during an edit), so the
/// list reads as content instead of a wall of icons. `idle` sits in their place at rest (a pin, a lock), so the row's
/// state stays visible without the buttons.
struct HoverActionsRow<Content: View, Idle: View, Actions: View>: View {
    var keepActions = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var idle: () -> Idle
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        let shown = hovering || keepActions
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            content()
            Spacer(minLength: NookTheme.Spacing.md)
            ZStack(alignment: .trailing) {
                HStack(spacing: NookTheme.Spacing.xs) { idle() }
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(shown ? 0 : 1)
                    .accessibilityHidden(shown)
                HStack(spacing: NookTheme.Spacing.xs) { actions() }
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// "In use" on the row of the model, file or option that is chosen now: the same quiet mint check everywhere, in the
/// place another row has its Use button.
struct InUseLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.mint)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Keycap representation matching keyboard styling.
struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(NookTheme.rounded(12, .medium))
            .foregroundStyle(NookTheme.textStrong)
            .padding(.horizontal, label.count > 1 ? 9 : 0)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                    .fill(NookTheme.smoke)
                    .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).strokeBorder(NookTheme.line2))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            )
    }
}



/// Workspace preferences: default settings for new sessions, worktree location, editor, and terminal.
/// Settings › Sessions (what a new session starts with, where things open, how sessions behave and tidy up, one tab
/// each) and Settings › Automation (scheduled tasks and what agents may use of Nook). The machines sessions run on have
/// a page of their own (`RemoteMachinesSection`).
struct WorkspaceSettingsSection: View {
    /// One page each them: never tabs.
    enum Part {
        /// How a new session starts for all projects, how sessions behave, and how the list tidies itself.
        case sessions
        /// What one project sets for itself (Settings › Code › Projects).
        case projects
        case automation
        /// Where new worktrees go and when Nook removes them (Settings › Code › Worktrees).
        case worktrees
        /// The editor and terminal a session's files open in.
        case openIn
        /// Nook's browser: what it searches with and where an agent's links open.
        case browser
        /// How commit messages and pull requests are written (Settings › Code › Pull requests).
        case commits
    }

    let part: Part
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var ws = WorkspaceSettings.shared
    @ObservedObject private var inbox = InboxStore.shared
    @ObservedObject private var webhook = WebhookListener.shared
    @ObservedObject private var relay = WebhookRelayClient.shared
    @AppStorage(AgentCredits.settingKey) private var stripAgentCredits = false
    @AppStorage(AgentCredits.commitsKey) private var noAgentCredits = false
    @State private var showScheduled = false
    /// The project folder Settings › Projects edits (see `ProjectSettings`); "" until one is chosen, which shows the first.
    /// Kept by Settings, so it stays while you visit other pages.
    @Binding var scope: String

    var body: some View {
        switch part {
        case .sessions:
            defaults
            behavior
            sessionTidying
        case .projects: projects
        case .openIn: openIn
        case .browser: browser
        case .commits: commitStyle
        case .automation:
            // What runs by itself, then what agents may use. The raw traffic log is under Maintenance.
            scheduled
            bridge
        case .worktrees:
            worktreeCreation
            worktreeCleanup
        }
    }

    /// Scheduled tasks: off until you turn it on; the list and editor open in a sheet.
    private var scheduled: some View {
        Section {
            Toggle(tr("sched.settings.enable"), isOn: $ws.scheduledTasksEnabled)
            if ws.scheduledTasksEnabled {
                TextField(tr("sched.settings.port"), value: $ws.scheduledWebhookPort, format: .number.grouping(.never))
                if ws.scheduledWebhookPort != 0, !(1024...65535).contains(ws.scheduledWebhookPort) {
                    SettingNote(tr("sched.settings.portInvalid"), tone: .warning)
                } else if case .listening(let port) = webhook.state {
                    SettingNote(tr("sched.settings.listening", Int(port)), tone: .success)
                } else if case .failed(let message) = webhook.state {
                    SettingNote(tr("sched.webhook.failed", message), tone: .warning)
                }
                Toggle(tr("sched.public.toggle"), isOn: $ws.scheduledWebhooksPublic)
                    .help(tr("sched.public.help"))
                if ws.scheduledWebhooksPublic {
                    SettingNote(tr("sched.public.readable"), tone: .warning)
                    if relay.state == .noRelay { SettingNote(tr("sched.public.noRelay"), tone: .warning) }
                }
                Button(tr("sched.settings.open")) { showScheduled = true }
            }
        } header: {
            SettingsSectionTitle(tr("sched.title"), info: tr("sched.settings.footer"))
        }
        .sheet(isPresented: $showScheduled) {
            ScheduledTasksView { showScheduled = false }
                .environmentObject(app)
        }
    }

    /// How a new session starts in every project; a project changes only what it sets on Settings › Projects.
    @ViewBuilder
    private var defaults: some View {
        Section {
            globalDefaults
        } header: {
            SettingsSectionTitle(tr("settings.ws.newSession"), info: tr("settings.ws.footer"))
        }
        // One model per agent, and which models "Auto" may pick: folded groups of their own, so the page opens on the
        // choices you make most.
        SettingsFold(tr("settings.ws.modelsPerAgent"),
                     summary: app.modelName(ws.model(for: ws.defaultProvider), for: ws.defaultProvider)) {
            ForEach(RunProvider.allCases.filter { $0 != .acp }) { provider in
                Picker(selection: Binding(
                    get: { ws.model(for: provider) },
                    set: { ws.setModel($0, for: provider) }
                )) {
                    ForEach(defaultModelChoices(provider, saved: ws.model(for: provider)), id: \.self) { model in
                        Text(app.modelName(model, for: provider)).tag(model)
                    }
                } label: {
                    AgentName(provider.kind, name: provider.displayName)
                }
            }
            // Off: the model list that came with the app is used, and nothing goes online for it.
            SettingToggle(tr("settings.ws.onlineModels"), detail: onlineModelsDetail, isOn: $ws.onlineModelList)
        }
        autoModelChoice
    }

    /// One project's own defaults: the project to show, then each row with what it inherits or sets itself.
    @ViewBuilder
    private var projects: some View {
        let choices = ProjectSettings.scopeChoices(favorites: ws.favoriteProjects, recent: ws.recentProjects,
                                                   overrides: ws.projectOverrides)
        let shown = choices.contains(scope) ? scope : (choices.first ?? "")
        Section {
            if shown.isEmpty {
                ListEmptyNote(tr("settings.projects.empty"))
            } else {
                Picker(selection: Binding(get: { shown }, set: { scope = $0 })) {
                    ForEach(choices, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path).help(AgentPathFormat.tilde(path))
                    }
                } label: {
                    SettingText("settings.projects.project")
                }
                projectDefaults(shown)
            }
        } header: {
            SettingsSectionTitle(tr("settings.ws.newSession"), info: tr("settings.scope.footer"))
        }
    }

    @ViewBuilder
    private var globalDefaults: some View {
        Picker(selection: $ws.defaultProvider) {
            ForEach(RunProvider.allCases.filter { $0 != .acp }) { provider in
                Label { Text(provider.displayName) } icon: { LogoImage.agent(provider.kind) }.tag(provider)
            }
        } label: {
            SettingText("settings.ws.provider")
        }
        Picker(tr("settings.ws.mode"), selection: $ws.defaultMode) {
            ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
        }
        Picker(tr("settings.ws.permission"), selection: $ws.defaultPermission) {
            ForEach(PermissionPolicy.allCases) { Text($0.label).tag($0) }
        }
        Picker(tr("settings.ws.isolation"), selection: $ws.defaultIsolation) {
            ForEach(IsolationMode.allCases) { Text($0.label).tag($0) }
        }
    }

    /// One project's defaults: each row shows the value that project starts with, "Inherited" while it follows the value
    /// for all projects, and a reset button once the project sets its own.
    @ViewBuilder
    private func projectDefaults(_ path: String) -> some View {
        let resolved = ws.sessionDefaults(for: path)
        let provider = resolved.provider
        inheritable(.provider, path) {
            Picker(selection: Binding(
                get: { provider }, set: { ws.setOverride(.provider, $0.rawValue, for: path) })) {
                ForEach(RunProvider.allCases.filter { $0 != .acp }) { choice in
                    Label { Text(choice.displayName) } icon: { LogoImage.agent(choice.kind) }.tag(choice)
                }
            } label: {
                SettingText("settings.ws.provider")
            }
        }
        inheritable(.model(provider), path) {
            Picker(selection: Binding(
                get: { resolved.model(for: provider) }, set: { ws.setOverride(.model(provider), $0, for: path) })) {
                ForEach(defaultModelChoices(provider, saved: resolved.model(for: provider)), id: \.self) { model in
                    Text(app.modelName(model, for: provider)).tag(model)
                }
            } label: {
                AgentName(provider.kind, name: tr("settings.ws.model", provider.displayName))
            }
        }
        inheritable(.permission, path) {
            Picker(tr("settings.ws.permission"), selection: Binding(
                get: { resolved.permission }, set: { ws.setOverride(.permission, $0.rawValue, for: path) })) {
                ForEach(PermissionPolicy.allCases) { Text($0.label).tag($0) }
            }
        }
        inheritable(.isolation, path) {
            Picker(tr("settings.ws.isolation"), selection: Binding(
                get: { resolved.isolation }, set: { ws.setOverride(.isolation, $0.rawValue, for: path) })) {
                ForEach(IsolationMode.allCases) { Text($0.label).tag($0) }
            }
        }
        inheritable(.branchPrefix, path) {
            LabeledContent {
                HStack {
                    TextField("", text: Binding(
                        get: { overrideText(.branchPrefix, path) ?? resolved.branchPrefix },
                        set: { ws.setOverride(.branchPrefix, $0, for: path) }), prompt: Text(resolved.branchPrefix))
                        .textFieldStyle(.roundedBorder)
                        // The row already has its label: a titled field in a form would show the prefix a second time.
                        .labelsHidden()
                        .accessibilityLabel(tr("settings.ws.branchPrefix"))
                        .frame(width: 160)
                    Text(tr("settings.ws.branchPrefix.example", resolved.branchPrefix))
                        .foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            } label: {
                SettingText("settings.ws.branchPrefix")
            }
        }
        inheritable(.worktreeCleanup, path) {
            Picker(tr("settings.ws.projectWorktreeCleanup"), selection: Binding(
                get: { resolved.worktreeCleanup }, set: { ws.setOverride(.worktreeCleanup, $0 ? "on" : "off", for: path) })) {
                Text(tr("settings.ws.projectWorktreeCleanup.on")).tag(true)
                Text(tr("settings.ws.projectWorktreeCleanup.off")).tag(false)
            }
        }
        inheritable(.browserSignIns, path) {
            Picker(tr("settings.ws.browserSignIns"), selection: Binding(
                get: { resolved.browserSignIns },
                set: {
                    ws.setOverride(.browserSignIns, $0.stored, for: path)
                    if $0 != .keep { BrowserProfiles.forget(project: path) }
                })) {
                ForEach(BrowserSignInPolicy.allCases) { Text(Self.label($0)).tag($0) }
            }
            .help(tr("settings.ws.browserSignIns.help"))
        }
        inheritable(.titleInstructions, path) {
            TextField(tr("settings.ws.titleInstructions"), text: Binding(
                get: { overrideText(.titleInstructions, path) ?? resolved.titleInstructions },
                set: { ws.setOverride(.titleInstructions, $0, for: path) }),
                      prompt: Text(tr("settings.ws.titleInstructions.placeholder")), axis: .vertical)
                .lineLimit(1...4)
        }
        inheritable(.agentInstructions, path) {
            TextField(tr("settings.ws.agentInstructions"), text: Binding(
                get: { overrideText(.agentInstructions, path) ?? resolved.agentInstructions },
                set: { ws.setOverride(.agentInstructions, $0, for: path) }),
                      prompt: Text(tr("settings.ws.agentInstructions.placeholder")), axis: .vertical)
                .lineLimit(2...8)
                .help(tr("settings.ws.agentInstructions.help"))
        }
    }

    /// A per-project row: its control, then "Inherited" or the button that goes back to the value for all projects.
    private func inheritable<Control: View>(_ key: ProjectSettingKey, _ path: String,
                                            @ViewBuilder _ control: () -> Control) -> some View {
        let own = ws.projectOverrides.isOverridden(key, for: path)
        return HStack(spacing: NookTheme.Spacing.md) {
            control()
            if own {
                ToolbarIconButton("arrow.uturn.backward", tr("settings.scope.reset")) {
                    ws.resetOverride(key, for: path)
                    if key == .browserSignIns { BrowserProfiles.forget(project: path) }
                }
            } else {
                Text(tr("settings.scope.inherited"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textTertiary)
                    .help(tr("settings.scope.inheritedHelp"))
            }
        }
    }

    /// The text a project stored for a key, when it stores one.
    private func overrideText(_ key: ProjectSettingKey, _ path: String) -> String? {
        if case .string(let value)? = ws.projectOverrides.values(for: path)[key.raw] { return value }
        return nil
    }

    /// Where a session's files, terminal and searches open.
    private var openIn: some View {
        Section(tr("settings.ws.openIn")) {
            Picker(selection: $ws.editorBundleID) {
                Text(tr("settings.ws.finder")).tag("")
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.editorCandidates)) { Text($0.name).tag($0.bundleID) }
            } label: {
                SettingText("settings.ws.editor")
            }
            Picker(selection: $ws.terminalBundleID) {
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.terminalCandidates)) { Text($0.name).tag($0.bundleID) }
            } label: {
                SettingText("settings.ws.terminal")
            }
        }
    }

    /// Nook's browser: the search engine of its address bar, and whether an agent's links open there or in your own.
    private var browser: some View {
        Section(tr("settings.browser.title")) {
            BrowserSearchPicker()
            AgentLinkTargetPicker()
            Picker(selection: Binding(
                get: { ws.browserSignInPolicy },
                set: {
                    ws.browserSignInPolicy = $0
                    BrowserProfiles.sweep()
                })) {
                ForEach(BrowserSignInPolicy.allCases) { Text(Self.label($0)).tag($0) }
            } label: {
                SettingText("settings.browser.signIns")
            }
            .help(tr("settings.browser.signIns.detail"))
        }
    }

    /// How a choice for browser sign-ins reads in a picker.
    static func label(_ policy: BrowserSignInPolicy) -> String {
        switch policy {
        case .ask: return tr("settings.browser.signIns.ask")
        case .keep: return tr("settings.browser.signIns.keep")
        case .forget: return tr("settings.browser.signIns.forget")
        }
    }

    /// The models to pick a default from: the composer's menu without older models, with the saved one under its own
    /// name ("opus" stays "opus", so the picker shows it chosen).
    private func defaultModelChoices(_ provider: RunProvider, saved: String) -> [String] {
        [AutoModel.id] + app.workspace.menuModelIDs(for: provider, extra: [saved == AutoModel.id ? "" : saved])
            .filter { !app.workspace.hidesLegacyModel($0, for: provider, chosen: saved) }
            .map { app.workspace.sameModel($0, saved, for: provider) ? saved : $0 }
    }

    /// Which models "Auto" may pick, per agent (see `AutoModel`): a menu of the agent's current models with a tick for
    /// each one allowed and its weight beside it. None ticked means all of them, also the ones that come later.
    private var autoModelChoice: some View {
        SettingsFold(tr("settings.ws.autoModels"), summary: tr("settings.ws.autoModels.summary")) {
            SettingNote(tr("settings.ws.autoModelsDetail"))
            autoAccountChoice
            ForEach(app.connectedProviders.filter { $0 != .acp }) { provider in
                let all = AutoModel.candidates(app.workspace.modelChoices(for: provider), allowed: [],
                                               same: { app.workspace.sameModel($0, $1, for: provider) })
                if !all.isEmpty {
                    let allowed = ws.autoModels(for: provider)
                    let picked = allowed.isEmpty ? all.map(\.id) : all.map(\.id).filter(allowed.contains)
                    LabeledContent {
                        Menu(allowed.isEmpty ? tr("settings.ws.autoModels.all") : tr("settings.ws.autoModels.count", picked.count, all.count)) {
                            ForEach(all, id: \.id) { candidate in
                                Toggle(candidate.name + " · " + tr(AutoModel.tier(of: candidate).key), isOn: Binding(
                                    get: { picked.contains(candidate.id) },
                                    set: { _ in ws.toggleAutoModel(candidate.id, for: provider, all: all.map(\.id)) }))
                            }
                            if !allowed.isEmpty {
                                Divider()
                                Button(tr("settings.ws.autoModels.reset")) { ws.resetAutoModels(for: provider) }
                            }
                        }
                        .fixedSize()
                    } label: {
                        Label { Text(provider.displayName) } icon: { LogoImage.agent(provider.kind) }
                    }
                }
            }
        }
    }

    /// Which agents and accounts "Auto" may use: a switch per agent and, below it, one per account of that agent, so Auto
    /// moves a session between the accounts you allow (for example to the one that has used less of its limits).
    @ViewBuilder
    private var autoAccountChoice: some View {
        SettingNote(tr("settings.ws.autoAccountsDetail"))
        ForEach(app.connectedProviders) { provider in
            Toggle(isOn: Binding(get: { !ws.autoAgentsOff.contains(provider.rawValue) },
                                 set: { ws.setAutoAgent(provider, allowed: $0) })) {
                Label { Text(provider.displayName) } icon: { LogoImage.agent(provider.kind) }
            }
            let accounts = app.connectedProfiles(for: provider)
            if accounts.count > 1 {
                ForEach(accounts) { profile in
                    Toggle(isOn: Binding(get: { !ws.autoAccountsOff.contains(profile.id) },
                                         set: { ws.setAutoAccount(profile.id, allowed: $0) })) {
                        Text(autoAccountName(profile))
                    }
                    .padding(.leading, NookTheme.Spacing.lg)
                    .disabled(ws.autoAgentsOff.contains(provider.rawValue))
                }
            }
        }
    }

    private func autoAccountName(_ profile: AgentProfile) -> String {
        if !profile.label.isEmpty { return profile.label }
        let account = app.history.profileAccounts[profile.id]
        return account.map { $0.organization.isEmpty ? $0.name : $0.organization } ?? tr("agents.personal")
    }

    /// Where the model list comes from, and how old it is.
    private var onlineModelsDetail: String {
        let date = app.workspace.modelManifest?.updatedAt.formatted(date: .abbreviated, time: .omitted)
        return tr("settings.ws.onlineModelsDetail") + (date.map { " " + tr("settings.ws.modelListDate", $0) } ?? "")
    }

    /// How Nook writes commit messages and pull requests.
    private var commitStyle: some View {
        Section {
            Picker(selection: $ws.commitStyle) {
                ForEach(CommitStyle.allCases) { Text(tr("settings.ws.commitStyle." + $0.rawValue)).tag($0) }
            } label: {
                SettingText("settings.ws.commitStyle.row")
            }
            if ws.commitStyle == .custom {
                TextField(tr("settings.ws.commitInstructions"), text: $ws.commitInstructions,
                          prompt: Text(tr("settings.ws.commitInstructions.placeholder")), axis: .vertical)
                    .lineLimit(2...5)
            }
            // Every coding agent Nook starts: its own commits and pull requests, from the next message on.
            SettingToggle(tr("settings.ws.noAgentCredits"), detail: tr("settings.ws.noAgentCredits.detail"),
                          isOn: $noAgentCredits)
            // Only the merge commit Nook asks GitHub for: the branch's commits and your own authorship stay as they are.
            SettingToggle(tr("settings.ws.stripAgentCredits"), detail: tr("settings.ws.stripAgentCredits.detail"),
                          isOn: $stripAgentCredits)
            // Every session, whichever agent opened the pull request: the eye in the tray above the composer follows one by hand.
            SettingToggle(tr("settings.ws.watchNewPullRequests"), detail: tr("settings.ws.watchNewPullRequests.detail"),
                          isOn: $ws.watchNewPullRequests)
        } header: {
            SettingsSectionTitle(tr("settings.ws.commitStyle"), info: tr("settings.ws.commitStyle.footer"))
        }
    }

    /// How sessions behave: while one runs, how the list shows them, and when one stops or Nook restarts. What an
    /// agent costs is shown on Usage, Codex's app-server is set with the agents.
    @ViewBuilder
    private var behavior: some View {
        Section(tr("settings.ws.behavior")) {
            Toggle(isOn: $ws.autoTitles) { SettingText("settings.ws.autoTitles") }
            // Also used by "Regenerate title" in a session's menu; a project can set its own under its defaults.
            TextField(tr("settings.ws.titleInstructions"), text: $ws.titleInstructions,
                      prompt: Text(tr("settings.ws.titleInstructions.placeholder")), axis: .vertical)
                .lineLimit(1...4)
            // Every agent gets these at launch, in every project that does not set its own.
            TextField(tr("settings.ws.agentInstructions"), text: $ws.agentInstructions,
                      prompt: Text(tr("settings.ws.agentInstructions.placeholder")), axis: .vertical)
                .lineLimit(2...8)
                .help(tr("settings.ws.agentInstructions.help"))
            Toggle(tr("settings.ws.steerByDefault"), isOn: $ws.steerByDefault)
            Picker(tr("settings.ws.maxWorking"), selection: $ws.maxWorkingSessions) {
                ForEach(SessionCapacity.choices, id: \.self) { count in
                    Text(count == 0 ? tr("settings.ws.maxWorking.none") : "\(count)").tag(count)
                }
            }
            .help(tr("settings.ws.maxWorking.help"))
            .onChange(of: ws.maxWorkingSessions) { _, _ in app.workspace.startWaitingTurns() }
        }
        // How the session list is laid out and confirming quit are on General its sidebar and confirmations.
        Section {
            Toggle(tr("settings.ws.autoResumeLimited"), isOn: $ws.autoResumeLimited)
            Toggle(tr("settings.ws.continueAfterRelaunch"), isOn: $ws.continueAfterRelaunch)
        } header: {
            SettingText("ws.section.restart")
        }
    }

    /// Where a new worktree goes and what its branch is called.
    private var worktreeCreation: some View {
        Section(tr("settings.worktrees.creation")) {
            LabeledContent {
                HStack {
                    Text(AgentPathFormat.tilde(ws.worktreeRoot)).foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Button(tr("ws.new.change")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { ws.worktreeRoot = url.path }
                    }
                    .controlSize(.small)
                }
            } label: {
                SettingText("settings.ws.worktreeRoot")
            }
            LabeledContent {
                HStack {
                    TextField("", text: $ws.branchPrefix, prompt: Text(WorktreeNaming.defaultBranchPrefix))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(tr("settings.ws.branchPrefix"))
                        .frame(width: 160)
                        .onSubmit { ws.branchPrefix = WorktreeNaming.normalizedBranchPrefix(ws.branchPrefix) }
                    Text(tr("settings.ws.branchPrefix.example", WorktreeNaming.normalizedBranchPrefix(ws.branchPrefix)))
                        .foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            } label: {
                SettingText("settings.ws.branchPrefix")
            }
        }
    }

    /// The session list keeps itself tidy: sessions settle and archive by themselves.
    private var sessionTidying: some View {
        Section {
            Toggle(tr("settings.ws.autoSettle"), isOn: $inbox.autoSettle.enabled)
            if inbox.autoSettle.enabled {
                Toggle(tr("settings.ws.autoSettleMerged"), isOn: $inbox.autoSettle.settleOnMergedPullRequest)
                Stepper(tr("settings.ws.autoSettleDays", inbox.autoSettle.inactivityDays),
                        value: $inbox.autoSettle.inactivityDays, in: 1...30)
            }
            Picker(tr("settings.ws.autoArchive"), selection: $ws.autoArchiveDays) {
                Text(tr("settings.ws.never")).tag(0)
                Text(tr("settings.ws.days", 7)).tag(7)
                Text(tr("settings.ws.days", 30)).tag(30)
                Text(tr("settings.ws.days", 90)).tag(90)
            }
            Toggle(tr("settings.ws.buildLeftovers"), isOn: $ws.buildLeftoverCleanup)
                .help(tr("settings.ws.buildLeftovers.help"))
        } header: {
            SettingsSectionTitle(tr("ws.section.tidy"))
        }
    }

    /// The worktrees keep themselves tidy; one in use or with uncommitted changes always stays.
    @ViewBuilder
    private var worktreeCleanup: some View {
        // Worktrees: every rule off until you switch it on; what the latest cleanup did is under them.
        Section {
            Toggle(tr("settings.ws.worktreeCleanupMerged"), isOn: $ws.worktreeCleanupOnMerge)
            daysPicker(tr("settings.ws.worktreeCleanupSettled"), $ws.worktreeCleanupDays)
            daysPicker(tr("settings.ws.worktreeCleanupInactive"), $ws.worktreeCleanupInactiveDays)
            Toggle(tr("settings.ws.worktreeCleanupUnchanged"), isOn: $ws.worktreeCleanupUnchanged)
            Toggle(tr("settings.ws.worktreeCleanupOnDelete"), isOn: $ws.worktreeCleanupOnDelete)
            Picker(tr("settings.ws.worktreeKeepWhen"), selection: $ws.worktreeKeepWhen) {
                ForEach(WorktreeCleanup.KeepWhen.allCases) { Text(tr("settings.ws.keepWhen." + $0.rawValue)).tag($0) }
            }
            .help(tr("settings.ws.worktreeKeepWhen.help"))
            WorktreeCleanupReportView(workspace: app.workspace)
        } header: {
            SettingsSectionTitle(tr("ws.worktrees.title"), info: tr("settings.ws.worktreeCleanup.footer"))
        }
        .onChange(of: ws.worktreeCleanupRules) { _, _ in app.workspace.worktreeCleanupRulesChanged() }
    }

    private func daysPicker(_ title: String, _ selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            Text(tr("settings.ws.never")).tag(0)
            Text(tr("settings.ws.days", 3)).tag(3)
            Text(tr("settings.ws.days", 7)).tag(7)
            Text(tr("settings.ws.days", 30)).tag(30)
        }
    }

    /// The workspace bridge: whether agents may use Nook's terminal, browser and pull requests, and linking it to agents
    /// you start yourself in a terminal (sessions Nook starts get it automatically).
    private var bridgeButtons: some View {
        ForEach(RunProvider.allCases.filter { WorkspaceBridgeScript.linkCommand(for: $0) != nil }) { provider in
            Button { link(provider) } label: { AgentName(provider.kind, name: provider.displayName) }
                .controlSize(.small)
                .help(WorkspaceBridgeScript.linkCommand(for: provider) ?? "")
        }
    }

    @ViewBuilder private var bridge: some View {
        Section {
            Toggle(tr("settings.bridge.enabled"), isOn: $ws.agentTools)
            LabeledContent(tr("settings.bridge.outside")) {
                // Side by side while they fit; under each other in a narrow window or a longer language.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NookTheme.Spacing.sm) { bridgeButtons }
                    VStack(alignment: .trailing, spacing: NookTheme.Spacing.sm) { bridgeButtons }
                }
            }
            .disabled(!ws.agentTools)
        } header: {
            SettingsSectionTitle(tr("settings.bridge.title"), info: tr("settings.bridge.footer"))
        }
        Section {
            ForEach(RunProvider.allCases) { provider in
                LabeledContent {
                    Menu(accessSummary(provider)) {
                        ForEach(BridgeCapability.allCases) { capability in
                            Toggle(tr("bridge.capability." + capability.rawValue), isOn: accessBinding(capability, provider))
                        }
                    }
                    .fixedSize()
                } label: {
                    AgentName(provider.kind, name: provider.displayName)
                }
            }
        } header: {
            SettingsSectionTitle(tr("settings.bridge.perAgent"), info: tr("settings.bridge.perAgent.info"))
        }
        .disabled(!ws.agentTools)
    }

    /// "All tools", or how many groups are on, for one agent.
    private func accessSummary(_ provider: RunProvider) -> String {
        let on = BridgeCapability.allCases.filter { ws.bridgeAccess.isOn($0, agent: provider.rawValue) }.count
        let all = BridgeCapability.allCases.count
        return on == all ? tr("settings.bridge.access.all") : tr("settings.bridge.access.some", on, all)
    }

    private func accessBinding(_ capability: BridgeCapability, _ provider: RunProvider) -> Binding<Bool> {
        Binding(get: { ws.bridgeAccess.isOn(capability, agent: provider.rawValue) },
                set: { ws.bridgeAccess.set(capability, on: $0, agent: provider.rawValue) })
    }

    /// Registers the bridge with the agent's own configuration, typed in a visible terminal so you see exactly what runs.
    private func link(_ provider: RunProvider) {
        _ = try? WorkspaceBridgeScript.install()
        do {
            guard let command = WorkspaceBridgeScript.linkCommand(for: provider) else { return }
            try app.runVisibly(command,
                               in: FileManager.default.homeDirectoryForCurrentUser.path,
                               name: "nook-bridge-\(provider.rawValue)", title: tr("settings.bridge.terminalTitle", provider.displayName))
        } catch {
            ToastCenter.shared.error(tr("accounts.terminalFailed", error.localizedDescription))
        }
    }
}

/// The organizations and repositories whose open pull requests show under Agents › Pull requests, beside your own and
/// your reviews. Searched with every connected GitHub account; shown under Settings › Pull requests. Each one is a
/// connection row with Stop watching last in its "…" menu, and "+ Watch organization" in the header opens a small
/// dialog to type one.
struct WatchedPullRequestsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    @State private var adding = false

    /// Pull requests are searched with your GitHub accounts: without one, the page says so first.
    private var gitHubLinked: Bool {
        (app.connectors.source(id: "github") as? any CloudConnectorConfig)?.isConfigured ?? false
    }

    private var full: Bool { watching.entries.count >= PullRequestWatchList.limit }

    /// The header's button and the empty list's: none once the list is full.
    private var addAction: (title: String, action: () -> Void)? {
        full ? nil : (tr("watch.add"), { adding = true })
    }

    var body: some View {
        if !gitHubLinked {
            Section {
                LabeledContent {
                    Button(tr("settings.pulls.connectGitHub")) { app.openConnections(.add(nil)) }
                } label: {
                    SettingLabel(tr("settings.pulls.needsGitHub"), hint: tr("settings.pulls.needsGitHubDetail"))
                }
            }
        }
        Section {
            SettingToggle(tr("settings.pulls.myOrganizations"), detail: tr("settings.pulls.myOrganizationsDetail"),
                          isOn: $watching.includeOrganizations)
            if watching.entries.isEmpty {
                ConnectionListEmpty(title: tr("watch.empty.title"), detail: tr("watch.empty.detail"), add: addAction)
            }
            ForEach(watching.entries, id: \.self) { entry in
                let repository = PullRequestWatchList.isRepository(entry)
                ConnectionRow(
                    title: entry,
                    status: .connected,
                    statusText: tr(repository ? "settings.pulls.repository" : "settings.pulls.organization"),
                    removal: ConnectionRemoval(title: tr("settings.pulls.remove"), question: tr("confirm.stopWatching", entry),
                                               detail: tr("watch.stopDetail")) {
                        watching.remove(entry)
                        ToastCenter.shared.success(tr("connection.removed", entry))
                    }
                ) {
                    Image(systemName: repository ? "book.closed" : "building.2")
                        .font(NookTheme.font(16))
                        .foregroundStyle(NookTheme.textSecondary)
                } menu: {
                    Button(tr("watch.openOnGitHub")) {
                        if let url = URL(string: "https://github.com/" + entry) { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if full {
                SettingNote(tr("settings.pulls.full", PullRequestWatchList.limit))
            }
        } header: {
            ConnectionListHeader(title: tr("settings.pulls.title"), info: tr("settings.pulls.footer"), add: addAction)
                // On the header, the one view that is always there, so the sheet is attached once and not to every row.
                .sheet(isPresented: $adding) { AddSheet() }
        }
    }

    /// Typing an organization or repository to watch, with Cancel and Watch on the right.
    private struct AddSheet: View {
        @Environment(\.dismiss) private var dismiss
        @ObservedObject private var watching = PullRequestWatchSettings.shared
        @State private var text = ""
        @State private var invalid = false

        private var canAdd: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

        var body: some View {
            SetupSheet(title: tr("watch.addTitle"), subtitle: tr("settings.pulls.footer"), width: 460) {
                ServiceTile(domain: "github.com", fallback: "building.2", size: 48)
            } content: {
                Text(tr("watch.name")).font(NookTheme.TextStyle.strong)
                TextField("", text: $text, prompt: Text(tr("settings.pulls.placeholder")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: text) { _, _ in invalid = false }
                if invalid {
                    SettingNote(tr("settings.pulls.invalid"), tone: .warning)
                }
            } footer: {
                Spacer()
                Button(tr("button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(tr("settings.pulls.addButton"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdd)
            }
        }

        /// Several entries may be typed at once (separated by commas or spaces); the toast names the ones that were new.
        private func add() {
            guard canAdd else { return }
            let before = watching.entries
            guard watching.add(text) else {
                invalid = true
                return
            }
            let added = watching.entries.filter { !before.contains($0) }
            ToastCenter.shared.success(tr("connection.added", added.joined(separator: ", ")))
            dismiss()
        }
    }
}

/// Where a link in an agent's conversation opens (see AgentLinkTarget).
private struct AgentLinkTargetPicker: View {
    @AppStorage(AgentLinkTarget.defaultsKey) private var target = AgentLinkTarget.app.rawValue

    var body: some View {
        Picker(selection: $target) {
            ForEach(AgentLinkTarget.allCases) { Text($0.name).tag($0.rawValue) }
        } label: {
            SettingText("settings.ws.linkTarget")
        }
    }
}

/// The workspace browser's search engine (see BrowserSearchEngine).
private struct BrowserSearchPicker: View {
    @AppStorage(BrowserSearchEngine.defaultsKey) private var engine = BrowserSearchEngine.duckDuckGo.rawValue

    var body: some View {
        Picker(selection: $engine) {
            ForEach(BrowserSearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
        } label: {
            SettingText("settings.ws.browserSearch")
        }
    }
}
