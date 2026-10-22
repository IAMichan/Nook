import SwiftUI
import AppKit

/// Settings › Usage: limits per account, tokens, costs. This file also holds the agent rows of Settings › Agents.
extension SettingsView {
    // MARK: Usage

    /// All usage on its own page: plan limits per account, tokens and reported costs of agent sessions.
    var usageSection: some View {
        UsageView()
            .environmentObject(app.workspace)
    }

    func agentRow(_ target: AgentConfigInstaller.Target) -> some View {
        let state = agentStates[target] ?? .notInstalled
        let rowState: StatusState = {
            switch state {
            case .installed: return .done
            case .outdated: return .warning
            case .unreadable: return .error
            case .notInstalled: return .todo
            }
        }()
        return StatusRow(title: target.title, detail: stateText(state, target: target), state: rowState, agent: target.title) {
            switch state {
            case .notInstalled:
                Button(tr("button.linkEllipsis")) { prepare(target, install: true) }
                    .controlSize(.small)
            case .outdated:
                Button(tr("button.updateEllipsis")) { prepare(target, install: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(tr("button.unlinkEllipsis")) { prepare(target, install: false) }
                    .controlSize(.small)
            case .installed:
                Button(tr("button.unlinkEllipsis")) { prepare(target, install: false) }
                    .controlSize(.small)
            case .unreadable:
                EmptyView()
            }
        }
    }

    func stateText(_ state: AgentConfigInstaller.State, target: AgentConfigInstaller.Target) -> String {
        switch state {
        case .notInstalled: return target.detail
        case .installed: return "\(tr("agents.status.done")) · \(target.displayPath)"
        case .outdated: return "Connected with an older version: update for permissions and prompts in the notch"
        case .unreadable(let message): return message
        }
    }

    func refreshAgentStates() {
        var states: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
        for target in AgentConfigInstaller.Target.allCases {
            states[target] = AgentConfigInstaller.state(of: target)
        }
        agentStates = states
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
