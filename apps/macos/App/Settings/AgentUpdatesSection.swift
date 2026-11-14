import SwiftUI

/// Settings › Agents › Updates: each agent program Nook found, its version, the newest one, and what installed it. Update
/// runs that installer's own update (see `AgentUpdates`) after you confirmed; the row shows its progress. "Update all"
/// updates every agent that has a newer version and a command to get it.
struct AgentUpdatesSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var updater = AgentUpdater.shared
    @ObservedObject private var workspace: WorkspaceManager
    /// Only this agent (Settings › Coding agents shows one agent at a time); nil lists every agent found.
    private let only: RunProvider?

    init(workspace: WorkspaceManager, only: RunProvider? = nil) {
        self.workspace = workspace
        self.only = only
    }

    var body: some View {
        let shown = RunProvider.allCases.filter { updater.entries[$0] != nil && (only == nil || only == $0) }
        let outdated = updater.outdated(installed: workspace.agentVersions).filter { only == nil || only == $0 }
        Section {
            if shown.isEmpty {
                ConnectionListEmpty(title: tr("agentUpdate.empty"), detail: tr("agentUpdate.emptyDetail"))
            }
            ForEach(shown) { provider in
                if let entry = updater.entries[provider] { row(entry) }
            }
        } header: {
            ConnectionListHeader(title: tr("agentUpdate.title"), info: tr("agentUpdate.info"),
                                 add: outdated.isEmpty || only != nil ? nil
                                     : (tr("agentUpdate.all", outdated.count), { app.requestAgentUpdate(outdated) }),
                                 symbol: "arrow.down.circle")
        }
        .onAppear { app.refreshAgentUpdates() }
        .confirmationDialog(question, isPresented: Binding(get: { updater.pending != nil }, set: { if !$0 { updater.pending = nil } }),
                            titleVisibility: .visible) {
            Button(tr("agentUpdate.confirm")) { app.confirmAgentUpdate() }
            Button(tr("button.cancel"), role: .cancel) { updater.pending = nil }
        } message: {
            Text(confirmation)
        }
    }

    private func row(_ entry: AgentUpdater.Entry) -> some View {
        let installed = workspace.agentVersions[entry.provider]
        let outdated = AgentUpdates.isOutdated(installed: installed, latest: entry.latest)
        return ConnectionRow(title: entry.provider.displayName, version: installed,
                             status: status(entry, outdated: outdated), statusText: statusText(entry, outdated: outdated),
                             detail: detail(entry, outdated: outdated)) {
            AgentLogo(entry.provider.kind, size: 22)
        } menu: {
            if entry.command != nil, !entry.phase.isBusy {
                Button(tr("agentUpdate.update")) { app.requestAgentUpdate([entry.provider]) }
            }
            Button(tr("agentUpdate.check")) { app.refreshAgentUpdates(force: true) }
        } expanded: {
            SettingNote(how(entry))
            if let command = entry.command {
                Text(command.display)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textSecondary)
                    .textSelection(.enabled)
                if !entry.phase.isBusy {
                    Button(tr("agentUpdate.update")) { app.requestAgentUpdate([entry.provider]) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func status(_ entry: AgentUpdater.Entry, outdated: Bool) -> ServiceStatus {
        switch entry.phase {
        case .updating: return .connecting
        case .failed: return .unreachable
        case .idle, .updated: return outdated ? .expired : .connected
        }
    }

    private func statusText(_ entry: AgentUpdater.Entry, outdated: Bool) -> String {
        switch entry.phase {
        case .updating: return tr("agentUpdate.updating")
        case .failed: return tr("agentUpdate.failedShort")
        case .idle, .updated:
            if outdated, let latest = entry.latest { return tr("agentUpdate.available", latest) }
            return entry.latest == nil ? tr("agentUpdate.installed") : tr("agentUpdate.upToDate")
        }
    }

    private func detail(_ entry: AgentUpdater.Entry, outdated: Bool) -> String? {
        switch entry.phase {
        case .updating(let line): return line.isEmpty ? nil : line
        case .failed(let message): return message.isEmpty ? nil : message
        case .idle, .updated:
            if outdated, entry.command == nil { return tr("agentUpdate.manual") }
            return entry.owner == .unknown ? nil : tr("agentUpdate.via", entry.owner.name)
        }
    }

    /// Opened: how Nook updates this program, or why it leaves that to you.
    private func how(_ entry: AgentUpdater.Entry) -> String {
        switch entry.owner {
        case .selfUpdate: return tr("agentUpdate.how.self", entry.provider.displayName)
        case .app(let name): return tr("agentUpdate.how.app", name)
        case .unknown: return tr("agentUpdate.how.unknown", entry.executable)
        case .homebrew, .npm, .pnpm, .bun, .volta, .mise: return tr("agentUpdate.how.installer", entry.owner.name)
        }
    }

    private var question: String {
        let names = (updater.pending ?? []).map(\.displayName)
        return names.count == 1 ? tr("agentUpdate.question", names[0]) : tr("agentUpdate.questionAll", names.count)
    }

    /// The commands it runs, and the sessions of those agents that are running now.
    private var confirmation: String {
        let pending = updater.pending ?? []
        let commands = pending.compactMap { updater.entries[$0]?.command?.display }.joined(separator: "\n")
        let running = app.activeSessions(of: pending).count
        return commands + (running > 0 ? "\n\n" + tr("agentUpdate.running", running) : "")
    }
}
