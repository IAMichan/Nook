import SwiftUI
import AppKit

/// Diff preview showing changes to an agent's configuration file before writing.
struct ConfigPreview: View {
    let change: AgentConfigInstaller.Change
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(change.install ? "\(change.target.title) \(tr("button.link"))" : "\(change.target.title) \(tr("button.unlink"))")
                .font(NookTheme.TextStyle.strong)
            Text(tr("settings.agents.changeNotice", change.target.displayPath))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
            ScrollView {
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
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip).fill(NookTheme.well))
            HStack {
                Spacer()
                Button(tr("button.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(change.install ? tr("button.link") : tr("button.unlink"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
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

/// Section header: Nook orb for overview, the section's colored tile elsewhere.
struct SettingsHeader: View {
    let section: SettingsSection
    let mood: NookMood

    var body: some View {
        // Title and one line, as a sheet heads itself; only the start page shows Nook. No icon tile: the sidebar already
        // shows where you are.
        HStack(spacing: NookTheme.Spacing.lg) {
            if section == .start {
                NookOrb(mood: mood, size: 28, animated: false)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(section.title).font(NookTheme.TextStyle.display).foregroundStyle(NookTheme.paper)
                Text(section.subtitle).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, NookTheme.Spacing.md)
    }
}

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
        case .todo: return NookTheme.textSecondary.opacity(0.55)
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
        HStack(spacing: 12) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(state == .warning || state == .error ? state.color : NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

/// Toggle switch with concise description below.
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
        Toggle(isOn: $isOn) { SettingLabel(title, detail: detail) }
    }
}

/// A setting's title with a short caption under it: the label of `SettingToggle`, and of rows that hold a button or a
/// picker instead of a switch.
struct SettingLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
struct WorkspaceSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var ws = WorkspaceSettings.shared
    @ObservedObject private var inbox = InboxStore.shared
    @ObservedObject private var webhook = WebhookListener.shared
    @State private var showScheduled = false

    var body: some View {
        Group {
            defaults
            openIn
            behavior
            scheduled
            bridge
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
                Button(tr("sched.settings.open")) { showScheduled = true }
            }
        } header: {
            Text(tr("sched.title"))
        } footer: {
            Text(tr("sched.settings.footer"))
        }
        .sheet(isPresented: $showScheduled) {
            ScheduledTasksView { showScheduled = false }
                .environmentObject(app)
        }
    }

    private var defaults: some View {
        Section {
            Picker(tr("settings.ws.provider"), selection: $ws.defaultProvider) {
                ForEach(RunProvider.allCases.filter { $0 != .acp }) { provider in
                    Label { Text(provider.displayName) } icon: { LogoImage.agent(provider.kind) }.tag(provider)
                }
            }
            // One model per agent: folded away, so the page opens on the choices you make most.
            DisclosureGroup(tr("settings.ws.modelsPerAgent")) {
                ForEach(RunProvider.allCases.filter { $0 != .acp }) { provider in
                    Picker(tr("settings.ws.model", provider.displayName), selection: Binding(
                        get: { ws.model(for: provider) },
                        set: { ws.setModel($0, for: provider) }
                    )) {
                        ForEach(Array(Set(provider.suggestedModels + [ws.model(for: provider)])).sorted(), id: \.self) { model in
                            Text(model.isEmpty ? tr("ws.model.default") : model).tag(model)
                        }
                    }
                }
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
            LabeledContent(tr("settings.ws.worktreeRoot")) {
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
            }
            LabeledContent(tr("settings.ws.branchPrefix")) {
                HStack {
                    TextField(WorktreeNaming.defaultBranchPrefix, text: $ws.branchPrefix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onSubmit { ws.branchPrefix = WorktreeNaming.normalizedBranchPrefix(ws.branchPrefix) }
                    Text(tr("settings.ws.branchPrefix.example", WorktreeNaming.normalizedBranchPrefix(ws.branchPrefix)))
                        .foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
        } header: {
            Text(tr("settings.ws.newSession"))
        } footer: {
            Text(tr("settings.ws.footer"))
        }
    }

    /// Where a session's files, terminal and searches open.
    private var openIn: some View {
        Section(tr("settings.ws.openIn")) {
            Picker(tr("settings.ws.editor"), selection: $ws.editorBundleID) {
                Text(tr("settings.ws.finder")).tag("")
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.editorCandidates)) { Text($0.name).tag($0.bundleID) }
            }
            Picker(tr("settings.ws.terminal"), selection: $ws.terminalBundleID) {
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.terminalCandidates)) { Text($0.name).tag($0.bundleID) }
            }
            BrowserSearchPicker()
        }
    }

    /// How sessions behave and are tidied up, in three short groups: while a session runs, when it stops or Nook
    /// restarts, and how the list keeps itself tidy.
    @ViewBuilder
    private var behavior: some View {
        Section(tr("settings.ws.behavior")) {
            Toggle(tr("settings.ws.autoTitles"), isOn: $ws.autoTitles)
            Toggle(tr("settings.ws.steerByDefault"), isOn: $ws.steerByDefault)
            Toggle(tr("settings.ws.showCost"), isOn: $ws.showCost)
            Toggle(tr("settings.ws.codexAppServer"), isOn: $ws.codexAppServer)
            LabeledContent("Antigravity") { AntigravitySetupRow(inSettings: true) }
        }
        Section {
            Toggle(tr("settings.ws.autoResumeLimited"), isOn: $ws.autoResumeLimited)
            Toggle(tr("settings.ws.continueAfterRelaunch"), isOn: $ws.continueAfterRelaunch)
        }
        Section {
            Toggle(tr("settings.ws.inboxWorking"), isOn: $inbox.showWorking)
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
        }
    }

    /// The workspace bridge: whether agents may use Nook's terminal, browser and pull requests, and linking it to agents
    /// you start yourself in a terminal (sessions Nook starts get it automatically).
    private var bridge: some View {
        Section {
            Toggle(tr("settings.bridge.enabled"), isOn: $ws.agentTools)
            LabeledContent(tr("settings.bridge.outside")) {
                HStack(spacing: 6) {
                    ForEach(RunProvider.allCases.filter { WorkspaceBridgeScript.linkCommand(for: $0) != nil }) { provider in
                        Button(provider.displayName) { link(provider) }
                            .controlSize(.small)
                            .help(WorkspaceBridgeScript.linkCommand(for: provider) ?? "")
                    }
                }
            }
            .disabled(!ws.agentTools)
        } header: {
            Text(tr("settings.bridge.title"))
        } footer: {
            Text(tr("settings.bridge.footer"))
        }
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
/// your reviews. Searched with every connected GitHub account; shown under Settings › Apps & accounts.
struct WatchedPullRequestsSection: View {
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        Section {
            SettingToggle(tr("settings.pulls.myOrganizations"), detail: tr("settings.pulls.myOrganizationsDetail"),
                          isOn: $watching.includeOrganizations)
            ForEach(watching.entries, id: \.self) { entry in
                HStack(spacing: 8) {
                    Image(systemName: PullRequestWatchList.isRepository(entry) ? "book.closed" : "building.2")
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry)
                        Text(tr(PullRequestWatchList.isRepository(entry) ? "settings.pulls.repository" : "settings.pulls.organization"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                    Spacer()
                    Button(role: .destructive) { watching.remove(entry) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(tr("settings.pulls.remove"))
                }
            }
            HStack {
                TextField(tr("settings.pulls.add"), text: $text, prompt: Text(tr("settings.pulls.placeholder")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: text) { _, _ in invalid = false }
                Button(tr("settings.pulls.addButton"), action: add)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || watching.entries.count >= PullRequestWatchList.limit)
            }
            if invalid {
                SettingNote(tr("settings.pulls.invalid"), tone: .warning)
            } else if watching.entries.count >= PullRequestWatchList.limit {
                SettingNote(tr("settings.pulls.full", PullRequestWatchList.limit))
            }
        } header: {
            Text(tr("settings.pulls.title"))
        } footer: {
            Text(tr("settings.pulls.footer"))
        }
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if watching.add(text) { text = "" } else { invalid = true }
    }
}

/// The workspace browser's search engine (see BrowserSearchEngine).
private struct BrowserSearchPicker: View {
    @AppStorage(BrowserSearchEngine.defaultsKey) private var engine = BrowserSearchEngine.duckDuckGo.rawValue

    var body: some View {
        Picker(tr("settings.ws.browserSearch"), selection: $engine) {
            ForEach(BrowserSearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
        }
    }
}
