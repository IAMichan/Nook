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
                .font(.headline)
            Text(tr("settings.agents.changeNotice", change.target.displayPath))
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if change.preview.isEmpty {
                        Text(tr("settings.agents.noChange")).foregroundStyle(.secondary)
                    }
                    ForEach(change.preview) { line in
                        Text(line.text)
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
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
        case .add: return .green
        case .remove: return .red
        case .context: return .secondary
        }
    }
}

// MARK: Building Blocks

/// Section header: Nook orb for overview, the section's colored tile elsewhere.
struct SettingsHeader: View {
    let section: SettingsSection
    let mood: NookMood

    var body: some View {
        HStack(spacing: 14) {
            if section == .general {
                NookOrb(mood: mood, size: 30, animated: false)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NookTheme.iris.opacity(0.14)))
            } else {
                SettingsTile(section, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.title.weight(.semibold))
                Text(section.subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
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
        case .done: return .green
        case .todo: return Color.secondary.opacity(0.55)
        case .warning: return .orange
        case .error: return .red
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
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(state.color)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
                            .offset(x: 4, y: 4)
                    }
                    .frame(width: 22)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(state.color)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(state == .warning || state == .error ? state.color : Color.secondary)
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
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Keycap representation matching keyboard styling.
struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, label.count > 1 ? 9 : 0)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            )
    }
}



/// Workspace preferences: default settings for new sessions, worktree location, editor, and terminal.
struct WorkspaceSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var ws = WorkspaceSettings.shared

    var body: some View {
        Group {
            defaults
            bridge
        }
    }

    private var defaults: some View {
        Section {
            Picker(tr("settings.ws.provider"), selection: $ws.defaultProvider) {
                ForEach(RunProvider.allCases) { provider in
                    Label { Text(provider.displayName) } icon: { LogoImage.agent(provider.kind) }.tag(provider)
                }
            }
            ForEach(RunProvider.allCases) { provider in
                Picker(tr("settings.ws.model", provider.displayName), selection: Binding(
                    get: { ws.model(for: provider) },
                    set: { ws.setModel($0, for: provider) }
                )) {
                    ForEach(Array(Set(provider.suggestedModels + [ws.model(for: provider)])).sorted(), id: \.self) { model in
                        Text(model.isEmpty ? tr("ws.model.default") : model).tag(model)
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
                    Text(AgentPathFormat.tilde(ws.worktreeRoot)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
            Picker(tr("settings.ws.editor"), selection: $ws.editorBundleID) {
                Text(tr("settings.ws.finder")).tag("")
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.editorCandidates)) { Text($0.name).tag($0.bundleID) }
            }
            Picker(tr("settings.ws.terminal"), selection: $ws.terminalBundleID) {
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.terminalCandidates)) { Text($0.name).tag($0.bundleID) }
            }
            Picker(tr("settings.ws.autoArchive"), selection: $ws.autoArchiveDays) {
                Text(tr("settings.ws.never")).tag(0)
                Text(tr("settings.ws.days", 7)).tag(7)
                Text(tr("settings.ws.days", 30)).tag(30)
                Text(tr("settings.ws.days", 90)).tag(90)
            }
            Toggle(tr("settings.ws.showCost"), isOn: $ws.showCost)
            Toggle(tr("settings.ws.codexAppServer"), isOn: $ws.codexAppServer)
            Toggle(tr("settings.ws.autoTitles"), isOn: $ws.autoTitles)
            Toggle(tr("settings.ws.autoResumeLimited"), isOn: $ws.autoResumeLimited)
            LabeledContent("Antigravity") { AntigravitySetupRow(inSettings: true) }
        } header: {
            Text(tr("settings.ws.title"))
        } footer: {
            Text(tr("settings.ws.footer"))
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
        try? WorkspaceBridgeScript.install()
        do {
            guard let command = WorkspaceBridgeScript.linkCommand(for: provider) else { return }
            try app.runVisibly(command,
                               in: FileManager.default.homeDirectoryForCurrentUser.path,
                               name: "nook-bridge-\(provider.rawValue)", title: tr("settings.bridge.terminalTitle", provider.displayName))
        } catch {
            app.viewModel.finish(tr("accounts.terminalFailed", error.localizedDescription))
        }
    }
}
