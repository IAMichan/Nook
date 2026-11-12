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
                AntigravityServerRow()
                // How Nook talks to Codex is part of setting Codex up, not of how sessions behave.
                Toggle(isOn: $workspace.codexAppServer) {
                    Label { SettingText("settings.ws.codexAppServer") } icon: { LogoImage.agent(.codex) }
                }
                Toggle(isOn: $workspace.openCodeServer) {
                    Label { SettingText("settings.ws.openCodeServer") } icon: { LogoImage.agent(.opencode) }
                }
            } header: {
                ConnectionListHeader(title: tr("settings.agents.linkAgents"), info: tr("agents.link.info"))
            }
            // The rest is one folded group of the same rows, its summary naming what is inside.
            if !linkedAgents.isEmpty, !unlinkedAgents.isEmpty {
                SettingsFold(tr("settings.agents.notLinkedTitle"),
                             summary: unlinkedAgents.map(\.title).joined(separator: ", ")) {
                    ForEach(unlinkedAgents) { target in agentRow(target) }
                }
            }
            AgentUpdatesSection(workspace: app.workspace)
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

/// Antigravity's ACP server in the same connection row as the agents above it: installed (with its version) or not,
/// the download's progress on its line while it runs, Download or Remove in its "…" menu. Opened, it shows where the
/// download comes from and how it is checked. Removing asks first, as the release has to be downloaded again to use
/// Antigravity.
private struct AntigravityServerRow: View {
    @ObservedObject private var installer = AntigravityInstaller.shared

    var body: some View {
        let installed = installer.installed != nil
        ConnectionRow(title: tr("agents.antigravity.server"),
                      version: installed ? AntigravityRelease.version : nil,
                      status: status(installed: installed),
                      statusText: statusText(installed: installed),
                      detail: detail(installed: installed),
                      removal: installed && !installer.isBusy
                          ? ConnectionRemoval(title: tr("ws.antigravity.remove"), question: tr("confirm.remove", "Antigravity"),
                                              detail: tr("agents.antigravity.removeDetail")) { installer.uninstall() }
                          : nil) {
            AgentLogo(.antigravity, size: 22)
        } menu: {
            if !installed, !installer.isBusy {
                Button(tr("ws.antigravity.install")) { installer.install() }
            }
        } expanded: {
            // Not installed yet: the setup row without its Settings extras (the size, the progress, Install, and where
            // the download comes from); Remove is in the "…" menu. Installed: only where it came from.
            if installed {
                SettingNote(tr("ws.antigravity.note"))
            } else {
                AntigravitySetupRow()
            }
        }
    }

    private func status(installed: Bool) -> ServiceStatus {
        switch installer.phase {
        case .downloading, .verifying, .unpacking, .checking: return .connecting
        case .failed: return .unreachable
        case .idle: return installed ? .connected : .notLinked
        }
    }

    private func statusText(installed: Bool) -> String {
        switch installer.phase {
        case .downloading(let fraction): return tr("agents.antigravity.downloading", Int(fraction * 100))
        case .verifying: return tr("ws.antigravity.verifying")
        case .unpacking: return tr("ws.antigravity.unpacking")
        case .checking: return tr("ws.antigravity.checking")
        case .failed: return tr("agents.antigravity.failed")
        case .idle: return installed ? tr("agents.antigravity.serverReady") : tr("agents.antigravity.serverMissing")
        }
    }

    private func detail(installed: Bool) -> String? {
        if case .failed(let message) = installer.phase { return message }
        guard !installed, !installer.isBusy else { return nil }
        let bytes = Int64(AntigravityRelease.current?.archiveBytes ?? 0)
        return tr("agents.antigravity.size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
}
