import SwiftUI
import AppKit

/// Settings › General: the languages, where Nook sits on screen, and how much it does on its own. The look is under
/// Appearance; the language dictation is translated to is with dictation.
extension SettingsView {
    // MARK: General

    var generalSection: some View {
        Group {
            Section {
                Picker(tr("settings.overview.appLanguage"), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Picker(tr("settings.brain.answerLanguage"), selection: $settings.language) {
                    ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: {
                Text(tr("settings.overview.languageSection"))
            }
            Section(tr("settings.notch.title")) {
                Picker(tr("settings.notch.placement"), selection: $settings.placement) {
                    Text(tr("settings.notch.placementNotch")).tag("notch")
                    Text(tr("settings.notch.placementFloating")).tag("floating")
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
                Toggle(tr("settings.notch.hideWhenIdle"), isOn: $settings.hideWhenIdle)
                Toggle(tr("settings.notch.openOnHover"), isOn: Binding(
                    get: { app.viewModel.openOnHover },
                    set: { app.viewModel.openOnHover = $0; refreshTick += 1 }
                ))
            }
            Section(tr("settings.window.title")) {
                SettingToggle(tr("settings.window.openAtLaunch"), detail: tr("settings.window.openAtLaunchDetail"),
                              isOn: $settings.openWindowAtLaunch)
            }
            energySection
            // Rarely needed: folded away at the end, like on every page.
            Section {
                DisclosureGroup(tr("settings.display.advanced")) {
                    Toggle(tr("settings.notch.demoData"), isOn: $app.demoMode)
                }
            }
        }
    }

    // MARK: Energy

    /// How much Nook does by himself on battery, a hot or busy Mac: one choice, what it means, and what he does right now.
    private var energySection: some View {
        Section {
            Picker(selection: $settings.energyMode) {
                ForEach(EnergyMode.allCases) { mode in
                    Text(tr(mode.titleKey)).tag(mode)
                }
            } label: {
                Text(tr("settings.energy.mode"))
            }
            .pickerStyle(.segmented)
            .help(tr("settings.energy.modeDetail"))
            SettingNote(tr(settings.energyMode.detailKey))
            LabeledContent(tr("settings.energy.now")) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(systemName: energySymbol)
                        .foregroundStyle(energy.plan.pace == .full ? NookTheme.mint : NookTheme.amber)
                    Text(energy.statusText).foregroundStyle(NookTheme.textSecondary)
                }
            }
        } header: {
            Text(tr("settings.energy.title"))
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
