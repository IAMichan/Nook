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
            Step(title: tr("settings.checklist.screen"), detail: CGPreflightScreenCaptureAccess() ? tr("settings.checklist.screen.granted") : tr("settings.checklist.screen.notGranted"),
                 done: CGPreflightScreenCaptureAccess(), button: tr("button.allow"), section: .privacy,
                 request: { _ = CGRequestScreenCaptureAccess() }),
            Step(title: tr("settings.checklist.calendar"), detail: app.calendar.hasEventAccess ? tr("settings.checklist.calendar.granted") : tr("settings.checklist.calendar.notGranted"),
                 done: app.calendar.hasEventAccess, button: tr("button.allow"), section: .privacy,
                 request: { _ = await app.calendar.requestEvents(); app.connectors.refreshAll() }),
            Step(title: tr("settings.checklist.connectors"), detail: tr("settings.checklist.connectors.detail", app.connectors.active.count),
                 done: app.connectors.active.count >= 3, button: tr("button.view"), section: .connections)
        ]
    }

    var overviewSection: some View {
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
            Section(tr("settings.overview.steps")) {
                ForEach(checklist) { step in
                    StatusRow(title: step.title, detail: step.detail, state: step.done ? .done : .todo) {
                        Button(step.button) {
                            if let request = step.request {
                                app.requestPermission { await request(); refreshTick += 1 }
                            } else {
                                app.settingsSection = step.section
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
            Section {
                ForEach(ShortcutAction.allCases) { action in ShortcutRecorder(action: action) }
                LabeledContent(tr("flow.settings.title")) {
                    Text(tr("shortcut.flowHint", FlowStore.shared.key.symbol)).foregroundStyle(.secondary)
                }
                LabeledContent(tr("settings.overview.openPanel")) {
                    Text(tr("settings.overview.pointToNotch")).foregroundStyle(.secondary)
                }
            } header: {
                Text(tr("settings.overview.howToUse"))
            } footer: {
                Text(tr("settings.overview.howToUseFooter"))
            }
        }
    }

    func shortcutRow(_ title: String, keys: [String]) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { Keycap(label: $0) }
            }
        }
    }
}
