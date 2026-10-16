import SwiftUI
import AppKit

/// Settings › Usage: limits per account, tokens, costs.
extension SettingsView {
    // MARK: Usage

    /// All usage in one place: plan limits per account, tokens and reported costs of agent sessions.
    var usageSection: some View {
        Group {
            Section(tr("settings.agents.subscriptions")) {
                ForEach(app.linkedProfiles.filter { $0.kind != .gemini }) { profile in
                    LabeledContent("\(profile.kind.shortName) · \(AccountLabel.name(profile, app: app))") {
                        Text(app.quota.summary(for: profile)
                             ?? tr(profile.kind == .claude ? "settings.usage.claudeMissing" : (profile.kind == .antigravity ? "ws.usage.quotaUnavailable" : "settings.usage.codexMissing")))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(tr("settings.usage.brain")) {
                    Text(settings.isLocalBrain ? tr("settings.usage.brainLocal") : tr("settings.usage.brainExternal", settings.provider.title))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                UsageView()
                    .environmentObject(app.workspace)
                    .frame(minHeight: 520)
                    .listRowInsets(EdgeInsets())
            }
        }
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
        return StatusRow(title: target.title, detail: stateText(state, target: target), state: rowState) {
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
            status = error.localizedDescription
        }
    }

    func write(_ change: AgentConfigInstaller.Change) {
        pendingChange = nil
        do {
            let backup = try AgentConfigInstaller.apply(change)
            let verb = change.install ? tr("button.link") : tr("button.unlink")
            status = "\(change.target.title): \(verb)." + (backup.map { " Backup: \($0.lastPathComponent)" } ?? "")
                + (change.install && change.target != .claudeStatusLine ? " Restart the agent for changes to take effect." : "")
        } catch {
            status = error.localizedDescription
        }
        refreshAgentStates()
    }
}
