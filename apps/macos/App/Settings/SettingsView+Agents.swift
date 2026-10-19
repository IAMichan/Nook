import SwiftUI
import AppKit

/// The tabs of Settings › Agents.
enum AgentSettingsTab: String, CaseIterable, Identifiable {
    case link, accounts, usage, workspace

    var id: String { rawValue }
    var title: String { tr("settings.agents.tab.\(rawValue)") }
}

/// Settings › Agents: linking agents, accounts, usage, workspace defaults.
extension SettingsView {
    // MARK: Agents

    var agentsSection: some View {
        Group {
            Section {
                Picker("", selection: $agentTab) {
                    ForEach(AgentSettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowBackground(Color.clear)
            switch agentTab {
            case .link:
                Section {
                    ForEach(AgentConfigInstaller.Target.allCases) { target in
                        agentRow(target)
                    }
                } header: {
                    Text(tr("settings.agents.linkAgents"))
                } footer: {
                    Text(tr("settings.agents.linkAgentsFooter"))
                }
            case .accounts:
                // Accounts per agent (personal, work…).
                AccountsSettingsSection()
                Section {} footer: {
                    Text(tr("accounts.isolationNote"))
                }
            case .usage:
                usageSection
            case .workspace:
                WorkspaceSettingsSection()
                // Machines sessions can run on over SSH.
                RemoteMachinesSection()
            }
        }
    }
}
