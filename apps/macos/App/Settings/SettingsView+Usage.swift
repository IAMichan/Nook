import SwiftUI
import AppKit

/// The usage part of Settings › Coding agents: limits per account, tokens, costs. This file also holds the agent rows.
extension SettingsView {
    // MARK: Usage

    /// All usage: plan limits per account, tokens and reported costs of agent sessions.
    var usageSection: some View {
        UsageView()
            .environmentObject(app.workspace)
    }

    func agentRow(_ target: AgentConfigInstaller.Target) -> some View {
        let state = agentStates[target] ?? .notInstalled
        let status: ServiceStatus = {
            switch state {
            case .installed: return .connected
            case .outdated: return .expired
            case .unreadable: return .unreachable
            case .notInstalled: return .notLinked
            }
        }()
        let detail: String = {
            switch state {
            case .notInstalled: return target.detail
            case .installed: return target.displayPath
            case .outdated: return tr("agents.status.outdated")
            case .unreadable(let message): return message
            }
        }()
        return ServiceRowShape(title: target.title, detail: detail, status: status,
                               detailIsError: { if case .unreadable = state { return true }; return false }()) {
            AgentTile(agent: target.title)
        } actions: {
            switch state {
            case .notInstalled:
                Button(tr("button.linkEllipsis")) { prepare(target, install: true) }
            case .outdated:
                Button(tr("button.updateEllipsis")) { prepare(target, install: true) }
                    .buttonStyle(.borderedProminent)
                Button(tr("button.unlinkEllipsis")) { prepare(target, install: false) }
            case .installed:
                Button(tr("button.unlinkEllipsis")) { prepare(target, install: false) }
            case .unreadable:
                EmptyView()
            }
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
