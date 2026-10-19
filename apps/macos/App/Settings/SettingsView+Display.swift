import SwiftUI
import AppKit

/// Settings › General: every language choice together, the look, where Nook sits on screen.
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
                Picker(tr("flow.settings.translate"), selection: $flowStore.translateTo) {
                    Text(tr("flow.settings.asSpoken")).tag("")
                    ForEach(["Nederlands", "English", "Deutsch", "Français", "Español"], id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text(tr("settings.overview.languageSection"))
            } footer: {
                Text(tr("settings.general.languageFooter"))
            }
            Section(tr("settings.display.color")) {
                HStack {
                    ColorPicker(tr("settings.display.accent"), selection: Binding(
                        get: { Color(hex: settings.accentHex) },
                        set: { settings.accentHex = NSColor($0).nookHex }
                    ), supportsOpacity: false)
                    Button(tr("settings.display.accentReset")) { settings.accentHex = NookTheme.defaultAccentHex }
                        .disabled(settings.accentHex == NookTheme.defaultAccentHex)
                }
                HStack(spacing: 10) {
                    ForEach([0xF4F3F7, 0x8B7BFF, 0x5AA9FF, 0x46E0A6, 0xFFB84D, 0xFF6B6B, 0xFF7EB6] as [UInt32], id: \.self) { hex in
                        Button { settings.accentHex = hex } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary.opacity(settings.accentHex == hex ? 0.9 : 0.15), lineWidth: settings.accentHex == hex ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(tr("settings.display.accentHint")).font(.caption).foregroundStyle(.secondary)
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
            }
            Section(tr("settings.display.advanced")) {
                Toggle(tr("settings.notch.demoData"), isOn: $app.demoMode)
            }
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
