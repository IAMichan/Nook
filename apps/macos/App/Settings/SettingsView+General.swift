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

    var startSection: some View {
        Group {
            // How far setup is, said once: the count and the guided setup on top, then only the steps still open.
            let openSteps = checklist.filter { !$0.done }
            Section {
                StatusRow(title: tr("settings.overview.readyToUse"),
                          detail: tr("settings.overview.countOf", checklist.filter(\.done).count, checklist.count),
                          state: openSteps.isEmpty ? .done : .todo) {
                    if !openSteps.isEmpty {
                        Button(tr("settings.setup.open")) { app.startOnboarding() }
                            .controlSize(.small)
                    }
                }
            }
            if !openSteps.isEmpty {
                Section(tr("settings.start.todo")) {
                    ForEach(openSteps) { step in
                        StatusRow(title: step.title, detail: step.detail, state: .todo) {
                            Button(step.button) {
                                if let request = step.request {
                                    app.requestPermission { await request(); refreshTick += 1 }
                                } else {
                                    app.settingsSection = step.section
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .onAppear { permissions.watch() }
                .onDisappear { permissions.unwatch() }
            }
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
        let broken = app.connectors.sources.filter { if case .error = $0.status.state { return $0.isActive }; return false }.count
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
