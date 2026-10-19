import SwiftUI
import AppKit

/// Settings › Agents: linking each agent, its accounts and what it used, on one page without tabs.
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
            // Usage is a page of sections of its own: shown on request, so the agents stay at the top.
            Section {
                Button { withAnimation { showUsage.toggle() } } label: {
                    HStack {
                        Text(tr("settings.agents.usage")).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: showUsage ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if showUsage {
                usageSection
            }
            Section {
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
            Section {
                CompanionSettingsRows()
            } header: {
                Text(tr("settings.devices.iphone"))
            }
            RemoteMachinesSection()
        }
    }

    /// A row that takes you to the one place where something lives.
    func settingsLink(_ section: SettingsSection, title: String, detail: String) -> some View {
        Button { app.settingsSection = section } label: {
            HStack(spacing: 12) {
                SettingsTile(section, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
