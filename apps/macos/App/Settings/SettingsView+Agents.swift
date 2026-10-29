import SwiftUI
import AppKit

/// Settings › Coding agents: linking each agent, its accounts, and what they used, on one page without tabs.
/// Settings › Workspace: what a new session starts with, automation, and the machines sessions can run on over SSH.
/// The iPhone is linked with everything else you link, under Settings › Accounts & connections.
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
            // What they used: plan limits per account, tokens and costs. The week recap lives here only, so the menu bar
            // stays calm.
            Section {
                LabeledContent {
                    Button(tr("button.view")) { app.showWeekRecap() }
                } label: {
                    SettingLabel(tr("settings.agents.weekRecap"), hint: tr("settings.agents.weekRecapDetail"))
                }
            } header: {
                Text(tr("settings.agents.usage"))
            }
            usageSection
        }
    }

    // MARK: Workspace

    var workspaceSection: some View {
        Group {
            WorkspaceSettingsSection()
            RemoteMachinesSection()
        }
    }
}
