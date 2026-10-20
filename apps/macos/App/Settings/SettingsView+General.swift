import SwiftUI
import AppKit

/// Settings › Overview: what still needs doing, and the shortcuts.
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
            Section {
                StatusRow(title: tr("settings.overview.readyToUse"),
                          detail: tr("settings.overview.countOf", checklist.filter(\.done).count, checklist.count),
                          state: checklist.allSatisfy(\.done) ? .done : .todo) {
                    if !checklist.allSatisfy(\.done) {
                        Button(tr("settings.setup.open")) { app.startOnboarding() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
            let openSteps = checklist.filter { !$0.done }
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
                glanceRow(.privacy, detail: tr("settings.start.permissions", granted, SystemPermission.allCases.count),
                          state: granted == SystemPermission.allCases.count ? .done : .todo)
            }
            Section {
                quickToggle(tr("settings.assistant.thinkAlongToggle"), .assistant, isOn: $settings.autoWatch)
                    .disabled(settings.useLocal)
                quickToggle(tr("settings.assistant.webSearch"), .assistant, isOn: $settings.webSearch)
                quickToggle(tr("flow.settings.enable"), .dictation, isOn: Binding(
                    get: { flowStore.enabled },
                    set: { on in
                        flowStore.enabled = on
                        if on, !FlowDictation.shared.trusted { FlowDictation.shared.askForAccessibility() }
                        FlowDictation.shared.refresh()
                    }
                ))
                quickToggle(tr("settings.voice.speakAnswers"), .dictation, isOn: $settings.speakAnswers)
                quickToggle(tr("settings.voice.agentSound"), .notifications, isOn: $settings.sounds)
            } header: {
                Text(tr("settings.start.quick"))
            } footer: {
                Text(tr("settings.start.quickFooter"))
            }
            Section {
                LabeledContent(tr("settings.overview.openPanel")) {
                    Text(tr("settings.overview.pointToNotch")).foregroundStyle(.secondary)
                }
                Button { app.settingsSection = .shortcuts } label: {
                    HStack {
                        Text(tr("settings.start.allShortcuts")).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text(tr("settings.overview.howToUse"))
            } footer: {
                Text(tr("settings.overview.howToUseFooter"))
            }
        }
    }

    /// One line per part of Nook: its tile, how it is doing, and a button to go there.
    func glanceRow(_ section: SettingsSection, detail: String, state: StatusState) -> some View {
        Button { app.settingsSection = section } label: {
            HStack(spacing: 12) {
                SettingsTile(section, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(state == .warning ? state.color : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: state.symbol).foregroundStyle(state.color)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A switch with, under its name, the section it belongs to.
    func quickToggle(_ title: String, _ section: SettingsSection, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            SettingLabel(title, detail: section.title)
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
