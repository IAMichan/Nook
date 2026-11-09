import SwiftUI
import AppKit

/// The usage part of Settings › Coding agents: limits per account, tokens, costs. This file also holds the agent link
/// rows and the steps that link or unlink an agent.
extension SettingsView {
    // MARK: Usage

    /// All usage: plan limits per account, tokens and reported costs of agent sessions.
    var usageSection: some View {
        UsageView()
            .environmentObject(app.workspace)
    }

    /// One coding agent's link with Nook (its hooks or plugin in the agent's own config), in the connection row every
    /// list in Settings uses: its logo, Linked, Not linked or Outdated with the file, and a switch that links or
    /// unlinks it. Both ways go through `prepare`, so the exact change is shown to confirm before anything is written;
    /// cancelling leaves the switch where it was, because it only follows the state read from the file.
    func agentRow(_ target: AgentConfigInstaller.Target) -> some View {
        let state = agentStates[target] ?? .notInstalled
        let row: (status: ServiceStatus, text: String, detail: String?, linked: Bool?) = {
            switch state {
            case .installed: return (.connected, tr("agents.link.linked"), target.displayPath, true)
            case .outdated: return (.expired, tr("agents.link.outdated"), target.displayPath, true)
            case .notInstalled: return (.notLinked, tr("agents.link.notLinked"), nil, false)
            // A file Nook cannot read cannot be changed either: no switch, only what went wrong.
            case .unreadable(let message): return (.unreachable, tr("agents.link.unreadable"), message, nil)
            }
        }()
        let isOn: Binding<Bool>? = row.linked.map { linked in
            Binding(get: { linked }, set: { prepare(target, install: $0) })
        }
        return ConnectionRow(title: target.title, status: row.status, statusText: row.text, detail: row.detail,
                             isOn: isOn) {
            AgentLogo(agent: target.title, size: 22)
        } menu: {
            if case .outdated = state {
                Button(tr("agents.link.update")) { prepare(target, install: true) }
            }
        } expanded: {
            // What linking does, then where: the agent's own file, which Nook only changes after showing the change.
            SettingNote(target.detail)
            LabeledContent(tr("agents.link.file")) {
                Text(target.displayPath)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textSecondary)
                    .textSelection(.enabled)
            }
            switch state {
            case .outdated:
                SettingNote(tr("agents.status.outdated"), tone: .warning)
                Button(tr("agents.link.update")) { prepare(target, install: true) }
                    .controlSize(.small)
            case .unreadable(let message):
                SettingNote(message, tone: .error)
            case .installed, .notInstalled:
                EmptyView()
            }
            SettingNote(tr("agents.link.how"))
        }
    }

    /// Read off the main thread: each agent's settings file is read and parsed, while Settings draws its first frame.
    func refreshAgentStates() {
        Task {
            agentStates = await Task.detached(priority: .userInitiated) {
                var states: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
                for target in AgentConfigInstaller.Target.allCases {
                    states[target] = AgentConfigInstaller.state(of: target)
                }
                return states
            }.value
        }
    }

    func prepare(_ target: AgentConfigInstaller.Target, install: Bool) {
        do {
            pendingChange = try AgentConfigInstaller.prepare(target, install: install)
        } catch {
            ToastCenter.shared.error(error, title: tr(install ? "settings.link.failed" : "settings.unlink.failed", target.title))
        }
    }

    func write(_ change: AgentConfigInstaller.Change) {
        pendingChange = nil
        do {
            let backup = try AgentConfigInstaller.apply(change)
            let lines = [backup.map { tr("settings.link.backup", $0.lastPathComponent) },
                         change.install && change.target != .claudeStatusLine ? tr("settings.link.restart") : nil]
            ToastCenter.shared.success(tr(change.install ? "settings.link.done" : "settings.unlink.done", change.target.title),
                                       detail: lines.compactMap { $0 }.joined(separator: " "))
        } catch {
            ToastCenter.shared.error(error, title: tr(change.install ? "settings.link.failed" : "settings.unlink.failed",
                                                      change.target.title))
        }
        refreshAgentStates()
    }
}
