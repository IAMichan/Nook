import SwiftUI
import AppKit

/// Settings › Coding agents: linking each agent, its accounts, and what they used, on one page without tabs.
/// Settings › Workspace: what a new session starts with, automation, and the machines sessions can run on over SSH.
/// The iPhone is linked with everything else you link, under Settings › Accounts & connections.
extension SettingsView {
    // MARK: Agents

    var agentsSection: some View {
        Group {
            // First who you are signed in as with each agent (and the agents that speak ACP), then which agents show
            // their progress in the notch, then what they used.
            AccountsSettingsSection()
            Section {
                ForEach(AgentConfigInstaller.Target.allCases) { target in
                    agentRow(target)
                }
            } header: {
                Text(tr("settings.agents.linkAgents"))
            }
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
        WorkspaceSettingsSection()
    }
}
