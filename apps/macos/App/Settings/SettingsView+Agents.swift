import SwiftUI
import AppKit

/// Settings › Agents: linking each agent and its accounts, on one page without tabs. What they used has its own page,
/// Settings › Usage.
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
            } footer: {
                Text(tr("settings.agents.linkAgentsFooter"))
            }
            // Accounts per agent (personal, work…), and agents that speak ACP.
            AccountsSettingsSection()
            Section {} footer: {
                Text(tr("accounts.isolationNote"))
            }
            // The week recap lives here only, so the menu bar stays calm.
            Section {
                LabeledContent {
                    Button(tr("button.view")) { app.showWeekRecap() }
                } label: {
                    SettingLabel(tr("settings.agents.weekRecap"), detail: tr("settings.agents.weekRecapDetail"))
                }
            }
            Section {
                settingsLink(.usage, title: tr("settings.agents.usage"), detail: tr("settings.agents.usageMoved"))
                settingsLink(.workspace, title: tr("settings.ws.title"), detail: tr("settings.agents.workspaceMoved"))
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

    /// A row that takes you to the one place where something lives.
    func settingsLink(_ section: SettingsSection, title: String, detail: String) -> some View {
        SettingsLinkRow(title: title, detail: detail, section: section) { app.settingsSection = section }
    }
}
