import SwiftUI
import AppKit

/// Settings › Overview: what still needs doing and how each part of Nook is doing. Each switch and shortcut lives on its
/// own page only.
extension SettingsView {
    // MARK: Overview

    struct Step: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var done: Bool
        var button: String
        var section: SettingsSection
        /// Permission request run in place; nil means the button navigates to `section`.
        var request: (@MainActor () async -> Void)? = nil
    }

    var checklist: [Step] {
        let _ = refreshTick
        let _ = settings.appLanguage
        return [
            Step(title: tr("settings.checklist.brain"), detail: settings.brainReady ? tr("settings.checklist.brain.ready", settings.activeModelName) : tr("settings.checklist.brain.notReady"),
                 done: settings.brainReady, button: tr("button.choose"), section: .brain),
            Step(title: tr("settings.checklist.screen"), detail: permissions.isGranted(.screen) ? tr("settings.checklist.screen.granted") : tr("settings.checklist.screen.notGranted"),
                 done: permissions.isGranted(.screen), button: tr("button.allow"), section: .privacy,
                 request: { await permissions.request(.screen, app: app) }),
            Step(title: tr("settings.checklist.calendar"), detail: permissions.isGranted(.calendar) ? tr("settings.checklist.calendar.granted") : tr("settings.checklist.calendar.notGranted"),
                 done: permissions.isGranted(.calendar), button: tr("button.allow"), section: .privacy,
                 request: { await permissions.request(.calendar, app: app) }),
            Step(title: tr("settings.checklist.connectors"), detail: tr("settings.checklist.connectors.detail", app.connectors.active.count),
                 done: app.connectors.active.count >= 3, button: tr("button.view"), section: .connections)
        ]
    }

    /// One thing that needs you, wherever it lives in Settings, with the one button that deals with it.
    struct AttentionItem: Identifiable {
        var id: String
        var title: String
        var detail: String
        var state: StatusState
        var button: String
        var action: () -> Void
    }

    /// Everything that needs you, in one list: the setup steps still open, connections that stopped working, agent links
    /// that are out of date, and completing when it is missing something. The Overview shows it, the sidebar counts it.
    var attention: [AttentionItem] {
        var items = checklist.filter { !$0.done }.map { step in
            AttentionItem(id: "step." + step.title, title: step.title, detail: step.detail, state: .todo, button: step.button) {
                if let request = step.request {
                    app.requestPermission { await request(); refreshTick += 1 }
                } else {
                    app.settingsSection = step.section
                }
            }
        }
        items += ConnectionProblems.current(app).map { problem in
            AttentionItem(id: "connection." + problem.id, title: problem.title, detail: problem.detail, state: problem.state,
                          button: tr("settings2.fix")) { app.settingsSection = .connections }
        }
        let outdated = AgentConfigInstaller.Target.allCases.filter {
            if case .outdated? = agentStates[$0] { return true }
            return false
        }
        items += outdated.map { target in
            AttentionItem(id: "agent.\(target)", title: target.title, detail: tr("agents.status.outdated"), state: .warning,
                          button: tr("button.updateEllipsis")) { prepare(target, install: true) }
        }
        if AutocompleteController.shared.needsAttention {
            items.append(AttentionItem(id: "autocomplete", title: SettingsSection.autocomplete.title,
                                       detail: tr("hub.overview.autocomplete"), state: .warning,
                                       button: tr("button.view")) { typingPart = 0; app.settingsSection = .autocomplete })
        }
        return items
    }

    var startSection: some View {
        Group {
            // One list of what needs you, from every page; once it is empty a single calm line says so.
            let items = attention
            Section {
                if items.isEmpty {
                    StatusRow(title: tr("hub.overview.allGood"), detail: tr("hub.overview.allGoodDetail"), state: .done) {
                        EmptyView()
                    }
                }
                ForEach(items) { item in
                    StatusRow(title: item.title, detail: item.detail, state: item.state) {
                        Button(item.button, action: item.action)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text(tr("hub.overview.attention"))
                    Spacer()
                    Button(tr("settings.setup.open")) { app.startOnboarding() }
                        .buttonStyle(.link)
                }
            }
            .onAppear { permissions.watch() }
            .onDisappear { permissions.unwatch() }
            Section(tr("settings.start.glance")) {
                glanceRow(.brain, detail: settings.brainReady ? settings.activeModelName : tr("settings.checklist.brain.notReady"),
                          state: settings.brainReady ? .done : .todo)
                glanceRow(.connections, detail: connectionsGlance.text, state: connectionsGlance.state)
                glanceRow(.agents, detail: tr("settings.start.agentsLinked", linkedAgentCount), state: linkedAgentCount > 0 ? .done : .todo)
                let granted = SystemPermission.allCases.filter { permissions.isGranted($0) }.count
                // Only the recommended permissions make this a to-do; the optional ones (contacts, the microphone…) never do.
                let recommendedGranted = SystemPermission.allCases.allSatisfy { !$0.isRecommended || permissions.isGranted($0) }
                glanceRow(.privacy, detail: tr("settings.start.permissions", granted, SystemPermission.allCases.count),
                          state: recommendedGranted ? .done : .todo)
            }
            UpdateSettingsSection()
        }
    }

    /// One line per part of Nook: its tile, how it is doing, and a way to go there. What works stays quiet; only what
    /// still needs you shows a symbol.
    func glanceRow(_ section: SettingsSection, detail: String, state: StatusState) -> some View {
        SettingsLinkRow(title: section.title, detail: detail, section: section, state: state) {
            app.settingsSection = section
        }
    }

    /// Active sources, and how many need a new sign-in.
    var connectionsGlance: (text: String, state: StatusState) {
        let active = app.connectors.active.count
        let broken = ConnectionProblems.current(app).count
        if broken > 0 { return (tr("settings.start.connectionsBroken", active, broken), .warning) }
        return (tr("settings.checklist.connectors.detail", active), active > 0 ? .done : .todo)
    }

    /// Agents whose link with Nook is in place.
    var linkedAgentCount: Int {
        agentStates.values.filter { state in
            if case .installed = state { return true }
            return false
        }.count
    }
}
