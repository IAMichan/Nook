import SwiftUI
import AppKit

/// Settings › General: the languages, how the session list is laid out, and what Nook asks before it acts.
/// How much Nook does on its own and updates are under Maintenance. Settings › Notch & windows: where
/// Nook shows (the notch and the main window) and how it behaves in meetings and while you share your screen. The look is
/// under Appearance; the language dictation is translated to is with dictation.
extension SettingsView {
    // MARK: General

    var generalSection: some View {
        Group {
            Section {
                Picker(selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: {
                    SettingText("settings.overview.appLanguage")
                }
                Picker(selection: $settings.language) {
                    ForEach(AppSettings.languages, id: \.code) { language in
                        Text(language.code == "auto" ? tr("settings.brain.answerLanguage.auto") : language.name).tag(language.code)
                    }
                } label: {
                    SettingText("settings.brain.answerLanguage")
                }
            } header: {
                Text(tr("settings.overview.languageSection"))
            }
            GeneralListAndConfirmations()
        }
    }

    // MARK: Notch and windows

    var notchSection: some View {
        Group {
            // The notch and the main window: everywhere Nook shows, in one group.
            Section(tr("settings.general.where")) {
                SettingToggle(tr("settings.notch.show"), detail: tr("settings.notch.showDetail"), isOn: $settings.showNotch)
                Picker(selection: $settings.placement) {
                    Text(tr("settings.notch.placementNotch")).tag("notch")
                    Text(tr("settings.notch.placementFloating")).tag("floating")
                } label: {
                    SettingText("settings.notch.placement")
                }
                if settings.placement == "floating" {
                    SettingNote(tr("settings.notch.placementHint"))
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
                Toggle(isOn: $settings.hideWhenIdle) { SettingText("settings.notch.hideWhenIdle") }
                Toggle(isOn: Binding(
                    get: { app.viewModel.openOnHover },
                    set: { app.viewModel.openOnHover = $0; refreshTick += 1 }
                )) { SettingText("settings.notch.openOnHover") }
                SettingToggle(tr("settings.window.openAtLaunch"), detail: tr("settings.window.openAtLaunchDetail"),
                              isOn: $settings.openWindowAtLaunch)
            }
            quietSection
        }
    }

    // MARK: Energy

    /// How much Nook does by himself on battery, a hot or busy Mac: one choice, what it means, and what he does right now.
    var energySection: some View {
        Section {
            Picker(selection: $settings.energyMode) {
                ForEach(EnergyMode.allCases) { mode in
                    Text(tr(mode.titleKey)).tag(mode)
                }
            } label: {
                SettingText("settings.energy.mode")
            }
            .pickerStyle(.segmented)
            .help(tr("settings.energy.modeDetail"))
            SettingNote(tr(settings.energyMode.detailKey))
            LabeledContent(tr("settings.energy.now")) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: energySymbol)
                        .foregroundStyle(energy.plan.pace == .full ? NookTheme.mint : NookTheme.amber)
                    Text(energy.statusText).foregroundStyle(NookTheme.textSecondary)
                }
            }
        } header: {
            SettingText("settings.energy.title")
        }
    }

    /// The symbol next to the status line: a bolt at full speed, a leaf while Nook takes it easy, a pause while he waits.
    private var energySymbol: String {
        switch energy.plan.pace {
        case .full: return "bolt.fill"
        case .light: return "leaf.fill"
        case .paused: return "pause.circle.fill"
        }
    }
}

extension NSColor {
    /// 0xRRGGBB in sRGB.
    var nookHex: UInt32 {
        let c = usingColorSpace(.sRGB) ?? self
        let r = UInt32((c.redComponent * 255).rounded())
        let g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

/// The session list's layout and the confirmations on General, with the defaults "Restore defaults" in the bar puts back.
struct GeneralListAndConfirmations: View {
    @ObservedObject private var inbox = InboxStore.shared
    @AppStorage(AppDelegate.confirmQuitKey) private var confirmQuit = true
    @AppStorage(QuitHoldMonitor.enabledKey) private var holdToQuit = false

    var body: some View {
        Section {
            Toggle(isOn: $inbox.groupByProject) { SettingText("settings.ws.inboxProjects") }
            Toggle(tr("settings.ws.inboxWorking"), isOn: $inbox.showWorking)
        } header: {
            SettingText("settings.general.sessionList")
        }
        Section {
            Toggle(isOn: $confirmQuit) { SettingText("settings.ws.confirmQuit") }
            SettingToggle(tr("settings.general.holdToQuit"), detail: tr("settings.general.holdToQuit.detail"), isOn: $holdToQuit)
        } header: {
            SettingText("settings.general.confirmations")
        }
    }

    /// Whether any of General's own settings differs from its default, so "Restore defaults" has something to do.
    @MainActor static var changed: Bool {
        let inbox = InboxStore.shared
        return inbox.groupByProject || !inbox.showWorking
            || UserDefaults.standard.object(forKey: AppDelegate.confirmQuitKey) as? Bool == false
            || UserDefaults.standard.bool(forKey: QuitHoldMonitor.enabledKey)
    }

    /// Puts General's own settings back to how Nook ships. The languages stay: they are yours, not a default.
    @MainActor static func restoreDefaults() {
        InboxStore.shared.groupByProject = false
        InboxStore.shared.showWorking = true
        UserDefaults.standard.removeObject(forKey: AppDelegate.confirmQuitKey)
        UserDefaults.standard.removeObject(forKey: QuitHoldMonitor.enabledKey)
    }
}
