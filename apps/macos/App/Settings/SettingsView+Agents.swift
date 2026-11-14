import SwiftUI
import AppKit

/// Settings › Coding agents: every agent in one card, as t3code lists its providers: on the left one row per agent (its
/// logo, name, version, and one line on where it stands), on the right everything of the agent picked (its link with
/// Nook, its version and update, its accounts, and what only it has). Usage & costs is the page's other subject.
extension SettingsView {
    // MARK: Agents

    var agentsSection: some View {
        AgentsSettingsPanel(states: agentStates, workspace: app.workspace) { target in
            agentRow(target)
        }
    }

    // MARK: Usage

    /// Plan limits per account, tokens and costs, and the week recap, which lives here only so the menu bar stays calm.
    var usageSettingsSection: some View {
        Group {
            Section {
                LabeledContent {
                    Button(tr("button.view")) { app.showWeekRecap() }
                } label: {
                    SettingLabel(tr("settings.agents.weekRecap"), hint: tr("settings.agents.weekRecapDetail"))
                }
                Toggle(isOn: $workspace.showCost) { SettingText("settings.ws.showCost") }
            }
            usageSection
        }
    }
}

/// Antigravity's ACP server in the same connection row as the agents above it: installed (with its version) or not,
/// the download's progress on its line while it runs, Download or Remove in its "…" menu. Opened, it shows where the
/// download comes from and how it is checked. Removing asks first, as the release has to be downloaded again to use
/// Antigravity.
private struct AntigravityServerRow: View {
    @ObservedObject private var installer = AntigravityInstaller.shared

    var body: some View {
        let installed = installer.installed != nil
        ConnectionRow(title: tr("agents.antigravity.server"),
                      version: installed ? AntigravityRelease.version : nil,
                      status: status(installed: installed),
                      statusText: statusText(installed: installed),
                      detail: detail(installed: installed),
                      removal: installed && !installer.isBusy
                          ? ConnectionRemoval(title: tr("ws.antigravity.remove"), question: tr("confirm.remove", "Antigravity"),
                                              detail: tr("agents.antigravity.removeDetail")) { installer.uninstall() }
                          : nil) {
            AgentLogo(.antigravity, size: 22)
        } menu: {
            if !installed, !installer.isBusy {
                Button(tr("ws.antigravity.install")) { installer.install() }
            }
        } expanded: {
            // Not installed yet: the setup row without its Settings extras (the size, the progress, Install, and where
            // the download comes from); Remove is in the "…" menu. Installed: only where it came from.
            if installed {
                SettingNote(tr("ws.antigravity.note"))
            } else {
                AntigravitySetupRow()
            }
        }
    }

    private func status(installed: Bool) -> ServiceStatus {
        switch installer.phase {
        case .downloading, .verifying, .unpacking, .checking: return .connecting
        case .failed: return .unreachable
        case .idle: return installed ? .connected : .notLinked
        }
    }

    private func statusText(installed: Bool) -> String {
        switch installer.phase {
        case .downloading(let fraction): return tr("agents.antigravity.downloading", Int(fraction * 100))
        case .verifying: return tr("ws.antigravity.verifying")
        case .unpacking: return tr("ws.antigravity.unpacking")
        case .checking: return tr("ws.antigravity.checking")
        case .failed: return tr("agents.antigravity.failed")
        case .idle: return installed ? tr("agents.antigravity.serverReady") : tr("agents.antigravity.serverMissing")
        }
    }

    private func detail(installed: Bool) -> String? {
        if case .failed(let message) = installer.phase { return message }
        guard !installed, !installer.isBusy else { return nil }
        let bytes = Int64(AntigravityRelease.current?.archiveBytes ?? 0)
        return tr("agents.antigravity.size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
}

/// One agent in Settings › Coding agents: one Nook can run (`kind`), one it only follows through its settings file
/// (`kind` nil: Copilot CLI, Muse Code, Amp, Hermes), or the ACP agents you add yourself (`.acp`).
struct SettingsAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: AgentKind?
    /// The settings files Nook links it through (Claude Code has two: its hooks and its status line).
    let targets: [AgentConfigInstaller.Target]

    /// The program Nook finds, updates and starts sessions with; nil for an agent it only follows and for the ACP agents.
    var provider: RunProvider? {
        switch kind {
        case .some(.acp), .none: return nil
        case .some(let kind): return RunProvider(rawValue: kind.rawValue)
        }
    }

    /// Every agent, in the order of the list: the ones Nook runs, the ones it follows, then the ACP agents.
    static var all: [SettingsAgent] {
        let runnable = AgentKind.allCases.compactMap { kind -> SettingsAgent? in
            switch kind {
            case .acp: return nil
            case .claude, .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi:
                return SettingsAgent(id: kind.rawValue, name: kind.name, kind: kind,
                                     targets: AgentConfigInstaller.Target.allCases.filter { $0.agentKind == kind })
            }
        }
        let followed = AgentConfigInstaller.Target.allCases.filter { $0.agentKind == nil }.map { target in
            SettingsAgent(id: target.rawValue, name: target.title, kind: nil, targets: [target])
        }
        let added = SettingsAgent(id: AgentKind.acp.rawValue, name: tr("agents.panel.acp"), kind: .acp, targets: [])
        return runnable + followed + [added]
    }
}

extension AgentConfigInstaller.Target {
    /// The agent this settings file belongs to; nil for an agent Nook follows but does not run.
    var agentKind: AgentKind? {
        switch self {
        case .claudeHooks, .claudeStatusLine: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .antigravity: return .antigravity
        case .cursor: return .cursor
        case .openCode: return .opencode
        case .copilot, .muse, .amp, .hermes: return nil
        }
    }
}

/// The card of Settings › Coding agents: the agents on the left, the one picked on the right with its own scroll, so
/// the page stays one screen however many agents and accounts there are. Picking an agent never leaves the page.
struct AgentsSettingsPanel<LinkRow: View>: View {
    /// How each agent's settings file is linked, read by Settings.
    let states: [AgentConfigInstaller.Target: AgentConfigInstaller.State]
    @ObservedObject var workspace: WorkspaceManager
    /// The row that links or unlinks one settings file (with its preview of the change).
    let linkRow: (AgentConfigInstaller.Target) -> LinkRow
    @ObservedObject private var updater = AgentUpdater.shared
    @ObservedObject private var wsSettings = WorkspaceSettings.shared
    @EnvironmentObject private var app: AppModel
    /// The agent picked; nil until you pick one, which shows the first linked agent.
    @State private var selection: String?

    /// The card's height: the list and the agent each scroll inside it.
    private static var height: CGFloat { 540 }
    private static var listWidth: CGFloat { 250 }

    init(states: [AgentConfigInstaller.Target: AgentConfigInstaller.State], workspace: WorkspaceManager,
         @ViewBuilder linkRow: @escaping (AgentConfigInstaller.Target) -> LinkRow) {
        self.states = states
        self.workspace = workspace
        self.linkRow = linkRow
    }

    var body: some View {
        let agents = SettingsAgent.all
        let picked = agents.first { $0.id == selection }
            ?? agents.first { agent in agent.targets.contains { isLinked(states[$0]) } }
            ?? agents[0]
        Section {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(agents) { agent in
                            listRow(agent, selected: agent == picked)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(width: Self.listWidth)
                NookDivider(vertical: true)
                Form {
                    detail(picked)
                }
                .formStyle(SettingsFormStyle())
                .font(NookTheme.TextStyle.body)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity)
                .id(picked.id)
            }
            .frame(height: Self.height)
            .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.panel)
            .roundedStrokeBorder(NookTheme.separator, radius: NookTheme.Radius.panel)
            .roundedClip(NookTheme.Radius.panel)
        } header: {
            SettingsSectionTitle(tr("agents.panel.title"), info: tr("agents.link.info"))
        }
        .settingsBareSection()
    }

    // MARK: The list

    private func listRow(_ agent: SettingsAgent, selected: Bool) -> some View {
        let place = standing(agent)
        return Button {
            selection = agent.id
        } label: {
            HStack(spacing: NookTheme.Spacing.md) {
                logo(agent, size: 24)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Text(agent.name)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        if let version = version(agent) {
                            Text(version)
                                .font(NookTheme.mono(10.5))
                                .foregroundStyle(NookTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Circle().fill(place.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(place.text)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverRowFill(selected: selected, radius: nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: The agent picked

    @ViewBuilder
    private func detail(_ agent: SettingsAgent) -> some View {
        let place = standing(agent)
        Section {
            HStack(spacing: NookTheme.Spacing.lg) {
                logo(agent, size: 32)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(agent.name)
                        .font(NookTheme.TextStyle.heading)
                        .foregroundStyle(NookTheme.paper)
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Circle().fill(place.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(place.text)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if let version = version(agent) {
                    Text(version)
                        .font(NookTheme.mono(11))
                        .foregroundStyle(NookTheme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .settingsBareSection()
        if !agent.targets.isEmpty {
            Section {
                ForEach(agent.targets) { target in linkRow(target) }
            } header: {
                SettingsSectionTitle(tr("agents.panel.link"), info: tr("agents.panel.linkInfo"))
            }
        }
        ownSection(agent)
        if let provider = agent.provider {
            AgentUpdatesSection(workspace: workspace, only: provider)
        }
        switch agent.kind {
        case .some(.acp), .none:
            EmptyView()
        case .some(let kind):
            AccountsSettingsSection(only: kind)
        }
    }

    /// What only this agent has: how Nook talks to Codex and OpenCode, Antigravity's server, the ACP agents you added,
    /// and for an agent Nook only follows, what that means.
    @ViewBuilder
    private func ownSection(_ agent: SettingsAgent) -> some View {
        switch agent.kind {
        case .some(.codex):
            Section {
                Toggle(isOn: $wsSettings.codexAppServer) { SettingText("settings.ws.codexAppServer") }
            } header: {
                SettingsSectionTitle(tr("agents.panel.connection"))
            }
        case .some(.opencode):
            Section {
                Toggle(isOn: $wsSettings.openCodeServer) { SettingText("settings.ws.openCodeServer") }
            } header: {
                SettingsSectionTitle(tr("agents.panel.connection"))
            }
        case .some(.antigravity):
            Section {
                AntigravityServerRow()
            } header: {
                SettingsSectionTitle(tr("agents.panel.connection"))
            }
        case .some(.acp):
            AcpAgentsSection()
        case .some(.claude), .some(.gemini), .some(.cursor), .some(.grok), .some(.pi):
            EmptyView()
        case .none:
            Section {
                SettingNote(tr("agents.panel.followOnly", agent.name))
            }
        }
    }

    // MARK: Parts

    @ViewBuilder
    private func logo(_ agent: SettingsAgent, size: CGFloat) -> some View {
        if let kind = agent.kind {
            AgentLogo(kind, size: size)
        } else {
            AgentLogo(agent: agent.name, size: size)
        }
    }

    private func version(_ agent: SettingsAgent) -> String? {
        agent.provider.flatMap { workspace.agentVersions[$0] }
    }

    private func isLinked(_ state: AgentConfigInstaller.State?) -> Bool {
        switch state {
        case .some(.installed), .some(.outdated): return true
        case .some(.notInstalled), .some(.unreadable), .none: return false
        }
    }

    private func isOutdatedLink(_ state: AgentConfigInstaller.State?) -> Bool {
        if case .some(.outdated) = state { return true }
        return false
    }

    /// Where the agent stands, in a word and a color: an update waiting, a link to renew, linked, found, or not yet.
    private func standing(_ agent: SettingsAgent) -> (text: String, color: Color) {
        if let provider = agent.provider, let entry = updater.entries[provider], let latest = entry.latest,
           AgentUpdates.isOutdated(installed: workspace.agentVersions[provider], latest: latest) {
            return (tr("agentUpdate.available", latest), NookTheme.amber)
        }
        if agent.targets.contains(where: { isOutdatedLink(states[$0]) }) {
            return (tr("agents.link.outdated"), NookTheme.amber)
        }
        if agent.targets.contains(where: { isLinked(states[$0]) }) {
            return (tr("agents.link.linked"), NookTheme.mint)
        }
        if let kind = agent.kind, agent.targets.isEmpty {
            // Nothing to link (Grok, Pi, the ACP agents): found on this Mac or not, and how many you added.
            switch kind {
            case .acp:
                return (tr("agents.panel.acpSub"), NookTheme.textTertiary)
            case .claude, .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi:
                return agent.provider.flatMap({ updater.entries[$0] }) != nil
                    ? (tr("agentUpdate.installed"), NookTheme.mint)
                    : (tr("agents.panel.notFound"), NookTheme.textTertiary)
            }
        }
        return (tr("agents.link.notLinked"), NookTheme.textTertiary)
    }
}
