import SwiftUI
import AppKit

/// Settings › Agents: linking agents, workspace defaults.
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
            WorkspaceSettingsSection()
        }
    }
}
