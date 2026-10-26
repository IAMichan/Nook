import SwiftUI
import AppKit

/// Settings › Agents: linking each agent and its accounts, on one page without tabs. What they used has its own page in
/// the sidebar, Settings › Usage.
/// Settings › Workspace: what a new session starts with, and automation.
/// Settings › Devices: the iPhone companion and machines over SSH.
extension SettingsView {
    // MARK: Agents

    var agentsSection: some View {
        Group {
            Section {
                ForEach(AgentConfigInstaller.Target.allCases) { target in
                    agentRow(target)
                }
            } header: {
                Text(tr("settings.agents.linkAgents"))
            }
            // Accounts per agent (personal, work…), and agents that speak ACP.
            AccountsSettingsSection()
            // The week recap lives here only, so the menu bar stays calm.
            Section {
                LabeledContent {
                    Button(tr("button.view")) { app.showWeekRecap() }
                } label: {
                    SettingLabel(tr("settings.agents.weekRecap"), hint: tr("settings.agents.weekRecapDetail"))
                }
            }
        }
    }

    // MARK: Workspace

    var workspaceSection: some View {
        WorkspaceSettingsSection()
    }

    // MARK: Devices

    var devicesSection: some View {
        Group {
            CompanionSettingsRows()
            RemoteMachinesSection()
        }
    }
}
