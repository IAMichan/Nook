import SwiftUI
import AppKit

/// Settings › General: language, checklist summary, notch, shortcuts.
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
            Section(tr("settings.overview.languageSection")) {
                Picker(tr("settings.overview.appLanguage"), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }
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
            Section {
                shortcutRow(tr("settings.overview.askTyping"), keys: ["⌥", "⌘", tr("settings.overview.spaceKey")])
                shortcutRow(tr("settings.overview.talkNook"), keys: ["⌥", tr("settings.overview.spaceKey")])
                shortcutRow(tr("settings.overview.lookScreen"), keys: ["⌥", "⌘", "N"])
                LabeledContent(tr("settings.overview.openPanel")) {
                    Text(tr("settings.overview.pointToNotch")).foregroundStyle(.secondary)
                }
            } header: {
                Text(tr("settings.overview.howToUse"))
            } footer: {
                Text(tr("settings.overview.howToUseFooter"))
            }
            Section(tr("settings.notch.title")) {
                Picker(tr("settings.notch.placement"), selection: $settings.placement) {
                    Text(tr("settings.notch.placementNotch")).tag("notch")
                    Text(tr("settings.notch.placementFloating")).tag("floating")
                }
                if settings.placement == "floating" {
                    Text(tr("settings.notch.placementHint")).font(.caption).foregroundStyle(.secondary)
                } else {
                    SettingToggle(tr("settings.notch.allScreens"), detail: tr("settings.notch.allScreensDetail"), isOn: $settings.notchOnAllScreens)
                }
                Picker(tr("settings.notch.screen"), selection: $settings.screenChoice) {
                    Text(tr("settings.notch.auto")).tag("auto")
                    Text(tr("settings.notch.main")).tag("main")
                    Text(tr("settings.notch.mouse")).tag("mouse")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag(name)
                    }
                    // A previously chosen screen that is not connected right now stays selectable.
                    if !["auto", "main", "mouse"].contains(settings.screenChoice),
                       !NSScreen.screens.map(\.localizedName).contains(settings.screenChoice) {
                        Text(settings.screenChoice).tag(settings.screenChoice)
                    }
                }
                .disabled(settings.placement == "notch" && settings.notchOnAllScreens)
                Toggle(tr("settings.notch.hideWhenIdle"), isOn: $settings.hideWhenIdle)
                Toggle(tr("settings.notch.openOnHover"), isOn: Binding(
                    get: { app.viewModel.openOnHover },
                    set: { app.viewModel.openOnHover = $0; refreshTick += 1 }
                ))
                Toggle(tr("settings.notch.demoData"), isOn: $app.demoMode)
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
