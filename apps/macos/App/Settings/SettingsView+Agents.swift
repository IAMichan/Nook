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
                // The linked ones first; the agents you have not linked are a folded group of their own under this
                // one once one is, so the page shows yours rather than every agent there is.
                ForEach(linkedAgents) { target in agentRow(target) }
                if linkedAgents.isEmpty {
                    ForEach(unlinkedAgents) { target in agentRow(target) }
                }
                // Antigravity needs its release downloaded before Nook can run it: set up with the other agents.
                LabeledContent("Antigravity") { AntigravitySetupRow(inSettings: true) }
                // How Nook talks to Codex is part of setting Codex up, not of how sessions behave.
                Toggle(isOn: $workspace.codexAppServer) { SettingText("settings.ws.codexAppServer") }
            } header: {
                SettingText("settings.agents.linkAgents")
            }
            if !linkedAgents.isEmpty, !unlinkedAgents.isEmpty {
                SettingsFold(tr("settings.agents.notLinkedTitle"),
                             summary: unlinkedAgents.map(\.title).joined(separator: ", ")) {
                    ForEach(unlinkedAgents) { target in agentRow(target) }
                }
            }
            AccountsSettingsSection()
        }
    }

    /// The agents linked to Nook, and the ones that are not yet.
    var linkedAgents: [AgentConfigInstaller.Target] {
        AgentConfigInstaller.Target.allCases.filter { target in
            if case .notInstalled = agentStates[target] ?? .notInstalled { return false }
            return true
        }
    }

    var unlinkedAgents: [AgentConfigInstaller.Target] {
        let linked = linkedAgents
        return AgentConfigInstaller.Target.allCases.filter { !linked.contains($0) }
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
                Toggle(isOn: $workspace.showCost) { SettingText("settings.ws.showCost") }
            }
            usageSection
        }
    }
}
