import SwiftUI
import AppKit

/// Settings › Coding agents: linking each agent and who you are signed in as with it. Settings › Usage: what they used,
/// on a page of its own. How sessions start and where they run are under Sessions and Machines.
extension SettingsView {
    // MARK: Agents

    var agentsSection: some View {
        Group {
            // First which agents are linked to Nook (and show their progress in the notch), then who you are signed in
            // as with each (and the agents that speak ACP).
            Section {
                // The linked ones first; the agents you have not linked are folded away once one is, so the page shows
                // yours rather than every agent there is.
                let linked = AgentConfigInstaller.Target.allCases.filter { target in
                    if case .notInstalled = agentStates[target] ?? .notInstalled { return false }
                    return true
                }
                let others = AgentConfigInstaller.Target.allCases.filter { !linked.contains($0) }
                ForEach(linked) { target in agentRow(target) }
                if linked.isEmpty {
                    ForEach(others) { target in agentRow(target) }
                } else if !others.isEmpty {
                    DisclosureGroup(tr("settings.agents.notLinked", others.count)) {
                        ForEach(others) { target in agentRow(target) }
                    }
                }
                // Antigravity needs its release downloaded before Nook can run it: set up with the other agents.
                LabeledContent("Antigravity") { AntigravitySetupRow(inSettings: true) }
                // How Nook talks to Codex is part of setting Codex up, not of how sessions behave.
                Toggle(tr("settings.ws.codexAppServer"), isOn: $workspace.codexAppServer)
            } header: {
                Text(tr("settings.agents.linkAgents"))
            }
            AccountsSettingsSection()
        }
    }

    // MARK: Usage

    /// Plan limits per account, tokens and costs, and the week recap, which lives here only so the menu bar stays calm.
    var usageSettingsSection: some View {
        Group {
            Section {
                LabeledContent {
                    Button(tr("button.view")) { app.showWeekRecap() }
                } label: {
                    SettingLabel(tr("settings.agents.weekRecap"), hint: tr("settings.agents.weekRecapDetail"))
                }
                Toggle(tr("settings.ws.showCost"), isOn: $workspace.showCost)
            }
            usageSection
        }
    }
}
