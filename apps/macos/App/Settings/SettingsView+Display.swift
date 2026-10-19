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
            lookSection
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

extension SettingsView {
    // MARK: Nook's look

    /// Presets with a preview of each, then every option on its own.
    var lookSection: some View {
        Section(tr("settings.display.look")) {
            HStack(spacing: 10) {
                NookOrb(mood: .rest, size: 40, glow: false)
                    .frame(width: 60, height: 76)
                ForEach(NookLook.presets) { preset in
                    lookPresetButton(preset.id, preset.look)
                }
            }
            Picker(tr("settings.display.eyes"), selection: $settings.nookLook.eyes) {
                ForEach(NookEyeStyle.allCases) { style in
                    Text(Self.title(for: style)).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Picker(tr("settings.display.mouth"), selection: $settings.nookLook.mouth) {
                ForEach(NookMouthStyle.allCases) { style in
                    Text(Self.title(for: style)).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Toggle(tr("settings.display.gloss"), isOn: $settings.nookLook.gloss)
            Toggle(tr("settings.display.glow"), isOn: $settings.nookLook.glow)
            Toggle(tr("settings.display.cheeks"), isOn: $settings.nookLook.cheeks)
            if settings.nookLook.mouth == .expressive {
                Text(tr("settings.display.mouthHint")).font(.caption).foregroundStyle(.secondary)
            }
            Text(tr("settings.display.lookHint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lookPresetButton(_ id: String, _ look: NookLook) -> some View {
        let selected = settings.nookLook == look
        return Button { settings.nookLook = look } label: {
            VStack(spacing: 6) {
                NookOrb(mood: .rest, size: 34, animated: false, glow: false, look: look)
                    .frame(width: 48, height: 44)
                Text(Self.presetTitle(id)).font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NookTheme.smoke.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func presetTitle(_ id: String) -> String {
        switch id {
        case "minimal": return tr("settings.display.lookPreset.minimal")
        case "playful": return tr("settings.display.lookPreset.playful")
        default: return tr("settings.display.lookPreset.classic")
        }
    }

    private static func title(for style: NookEyeStyle) -> String {
        switch style {
        case .round: return tr("settings.display.eyes.round")
        case .bars: return tr("settings.display.eyes.bars")
        case .dots: return tr("settings.display.eyes.dots")
        }
    }

    private static func title(for style: NookMouthStyle) -> String {
        switch style {
        case .expressive: return tr("settings.display.mouth.expressive")
        case .line: return tr("settings.display.mouth.line")
        case .none: return tr("settings.display.mouth.none")
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
