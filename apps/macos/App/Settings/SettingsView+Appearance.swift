import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings › Appearance: how Nook looks and sounds. A large live Nook on top that shows each mood, the three styles as
/// cards, then the color (the biggest change after the style), the windows' appearance and theme, the face and finish
/// folded away, and Nook as a buddy.
extension SettingsView {
    // MARK: Appearance

    var appearanceSection: some View {
        Group {
            Section {
                lookPreview
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)

            Section {
                HStack(spacing: NookTheme.Spacing.md) {
                    ForEach(NookLook.presets) { preset in
                        lookPresetCard(preset.id, preset.look)
                    }
                }
                .padding(.vertical, NookTheme.Spacing.xxs)
            } header: {
                Text(tr("settings.appearance.style"))
            } footer: {
                if !NookLook.presets.contains(where: { $0.look == settings.nookLook }) {
                    SettingNote(tr("settings.appearance.styleCustom"))
                }
            }

            Section {
                HStack(spacing: NookTheme.Spacing.xs) {
                    ForEach(Self.accentSwatches, id: \.hex) { swatch in
                        let hex = swatch.hex
                        Button { settings.accentHex = hex } label: {
                            // The chosen color gets a ring a little outside it, so it shows on the white swatch too.
                            Circle().fill(hex == NookTheme.defaultAccentHex ? NookTheme.themeAccent : Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .padding(NookTheme.Spacing.xs)
                                .overlay(Circle().stroke(settings.accentHex == hex ? NookTheme.paper : Color.clear, lineWidth: 1.5))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.nookPlain)
                        .accessibilityLabel(tr(swatch.name))
                        .accessibilityHint(tr("settings.display.accent"))
                        .accessibilityAddTraits(settings.accentHex == hex ? .isSelected : [])
                    }
                    Spacer(minLength: 8)
                    ColorPicker(tr("settings.display.accent"), selection: Binding(
                        get: { Color(hex: settings.accentHex) },
                        set: { settings.accentHex = NSColor($0).nookHex }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            } header: {
                Text(tr("settings.display.color"))
            }

            themeSection

            ColorTokensSettings()

            // The style above sets the face and the finish; changing them one by one is folded away.
            SettingsFold(tr("settings.appearance.fineTune"), summary: tr("settings.appearance.fineTuneSummary"),
                         keys: ["settings.display.eyes", "settings.display.mouth", "settings.display.glow"]) {
                Picker(selection: $settings.nookLook.eyes) {
                    ForEach(NookEyeStyle.allCases) { style in
                        Text(Self.title(for: style)).tag(style)
                    }
                } label: {
                    SettingText("settings.display.eyes")
                }
                .pickerStyle(.segmented)
                Picker(selection: $settings.nookLook.mouth) {
                    ForEach(NookMouthStyle.allCases) { style in
                        Text(Self.title(for: style)).tag(style)
                    }
                } label: {
                    SettingText("settings.display.mouth")
                }
                .pickerStyle(.segmented)
                if settings.nookLook.mouth == .expressive {
                    SettingNote(tr("settings.display.mouthHint"))
                }
                Toggle(tr("settings.display.gloss"), isOn: $settings.nookLook.gloss)
                Toggle(isOn: $settings.nookLook.glow) { SettingText("settings.display.glow") }
                Toggle(tr("settings.display.cheeks"), isOn: $settings.nookLook.cheeks)
            }
            // Putting the look back is "Restore defaults" in the bar over the page, as on General.

            buddySection
        }
    }

    /// The accent colors offered as swatches, each with the name VoiceOver reads. The first is the theme's own (white in
    /// Nook's theme, near black in light), which follows the theme and the appearance.
    static let accentSwatches: [(hex: UInt32, name: String)] = [
        (NookTheme.defaultAccentHex, "settings.accent.white"), (0x8B7BFF, "settings.accent.violet"),
        (0x5AA9FF, "settings.accent.blue"), (0x5ED6A6, "settings.accent.mint"), (0xF2B866, "settings.accent.amber"),
        (0xEF7B73, "settings.accent.coral"), (0xFF7EB6, "settings.accent.pink"),
    ]

    /// Nook large and alive, with the moods underneath to see how each one looks.
    private var lookPreview: some View {
        VStack(spacing: NookTheme.Spacing.lg) {
            NookOrb(mood: lookPreviewMood, size: 88, glow: settings.nookLook.glow, look: settings.nookLook)
                .frame(width: 150, height: 130)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: NookTheme.Spacing.sm)], spacing: NookTheme.Spacing.sm) {
                ForEach(Self.previewMoods, id: \.key) { item in
                    let selected = lookPreviewMood == item.mood
                    Button { lookPreviewMood = item.mood } label: {
                        Text(tr(item.key))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .font(selected ? NookTheme.TextStyle.strong : NookTheme.TextStyle.body)
                            .padding(.horizontal, NookTheme.Spacing.md)
                            .padding(.vertical, NookTheme.Spacing.xs)
                            .foregroundStyle(selected ? NookTheme.onIris : NookTheme.textStrong)
                            .background(NookTheme.shape(NookTheme.Radius.control).fill(selected ? NookTheme.iris : NookTheme.smoke))
                            .contentShape(NookTheme.shape(NookTheme.Radius.control))
                    }
                    .buttonStyle(.nookPlain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NookTheme.Spacing.xl)
        .padding(.horizontal, NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("settings.appearance.preview"))
    }

    private static let previewMoods: [(key: String, mood: NookMood)] = [
        ("settings.appearance.mood.rest", .rest),
        ("settings.appearance.mood.think", .think),
        ("settings.appearance.mood.waiting", .waiting),
        ("settings.appearance.mood.done", .done),
        ("settings.appearance.mood.worry", .worry),
        ("nook.mood.proud", .proud),
        ("nook.mood.curious", .curious),
        ("nook.mood.cozy", .cozy),
        ("nook.mood.focus", .focus),
        ("nook.mood.surprised", .surprised),
        ("nook.mood.caring", .caring),
        ("nook.mood.sleepy", .sleepy),
        ("nook.mood.celebrate", .celebrate),
        ("nook.mood.breathe", .breathe)
    ]

    /// One style as a card: a still Nook in that style, its name, and a ring when chosen.
    private func lookPresetCard(_ id: String, _ look: NookLook) -> some View {
        let selected = settings.nookLook == look
        return Button { withAnimation(NookTheme.reveal) { settings.nookLook = look } } label: {
            VStack(spacing: NookTheme.Spacing.md) {
                NookOrb(mood: .rest, size: 44, animated: false, glow: false, look: look)
                    .frame(width: 60, height: 56)
                Text(Self.presetTitle(id)).font(NookTheme.TextStyle.strong)
                Text(tr("settings.appearance.preset.\(id)"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NookTheme.Spacing.lg)
            .padding(.horizontal, NookTheme.Spacing.md)
            .roundedBackground(selected ? NookTheme.smoke : NookTheme.graphite, radius: NookTheme.Radius.panel)
            .roundedStrokeBorder(selected ? NookTheme.iris : Color.clear, radius: NookTheme.Radius.panel)
            .roundedHitShape(NookTheme.Radius.panel)
        }
        .buttonStyle(.nookPlain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func presetTitle(_ id: String) -> String {
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

    // MARK: Appearance and theme

    /// System, Light or Dark for the windows, then the themes as cards: each with a small preview of its dark and of its
    /// light palette, and a click on one uses it for that appearance. A VS Code theme can be imported as one more.
    var themeSection: some View {
        Section {
            Picker(selection: $settings.appearanceMode) {
                ForEach(NookAppearanceMode.allCases) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            } label: {
                SettingText("theme.appearance")
            }
            .pickerStyle(.segmented)
            Picker(selection: $settings.density) {
                ForEach(NookDensity.allCases) { density in
                    Text(tr("theme.density.\(density.rawValue)")).tag(density)
                }
            } label: {
                SettingText("theme.density")
            }
            .pickerStyle(.segmented)
            SettingNote(tr("theme.densityNote"))
            Picker(selection: $settings.diffColors) {
                ForEach(NookDiffColors.allCases) { colors in
                    Text(tr("theme.diffColors.\(colors.rawValue)")).tag(colors)
                }
            } label: {
                SettingText("theme.diffColors")
            }
            .pickerStyle(.segmented)
            SettingNote(tr("theme.diffColorsNote"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NookTheme.Spacing.md)], spacing: NookTheme.Spacing.md) {
                ForEach(settings.themes) { theme in
                    themeCard(theme)
                }
            }
            .padding(.vertical, NookTheme.Spacing.xxs)
            HStack {
                Button(tr("theme.import")) { importVSCodeTheme() }
                Spacer()
            }
            Toggle(isOn: $settings.renderMath) { SettingText("theme.renderMath") }
            SettingNote(tr("theme.renderMathNote"))
            Toggle(isOn: $settings.richComposer) { SettingText("theme.richComposer") }
            SettingNote(tr("theme.richComposerNote"))
        } header: {
            Text(tr("theme.header"))
        } footer: {
            SettingNote(tr("theme.footer"))
        }
    }

    static func title(for mode: NookAppearanceMode) -> String {
        switch mode {
        case .system: return tr("theme.mode.system")
        case .light: return tr("theme.mode.light")
        case .dark: return tr("theme.mode.dark")
        }
    }

    /// A built-in theme's name in the reader's language; an imported one keeps its own.
    static func title(for theme: NookColorTheme) -> String {
        theme.custom ? theme.name : tr("theme.name.\(theme.id)")
    }

    /// One theme: its name, and a preview per appearance it has; the one in use for dark or light carries a ring.
    private func themeCard(_ theme: NookColorTheme) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(Self.title(for: theme)).font(NookTheme.TextStyle.strong).lineLimit(1)
                Spacer(minLength: 0)
                if theme.custom {
                    ToolbarIconButton("trash", tr("theme.remove"), height: 18, width: 18) {
                        settings.customThemes.removeAll { $0.id == theme.id }
                        if settings.darkThemeID == theme.id { settings.darkThemeID = NookColorTheme.nook.id }
                        if settings.lightThemeID == theme.id { settings.lightThemeID = NookColorTheme.nook.id }
                    }
                }
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                if let dark = theme.dark {
                    themePreview(dark, chosen: settings.darkThemeID == theme.id, label: tr("theme.forDark")) {
                        settings.darkThemeID = theme.id
                    }
                }
                if let light = theme.light {
                    themePreview(light, chosen: settings.lightThemeID == theme.id, label: tr("theme.forLight")) {
                        settings.lightThemeID = theme.id
                    }
                }
            }
        }
        .padding(NookTheme.Spacing.md)
        .roundedBackground(NookTheme.graphite, radius: NookTheme.Radius.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title(for: theme))
    }

    /// A small window in a palette: its canvas, a lifted sidebar, two lines of text and the accent.
    private func themePreview(_ palette: NookPalette, chosen: Bool, label: String, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: 0) {
                Rectangle().fill(Color(hex: palette.surface)).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Color(hex: palette.paper)).frame(width: 28, height: 3)
                    Capsule().fill(Color(hex: palette.textSecondary)).frame(width: 20, height: 3)
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        Circle().fill(Color(hex: palette.accent)).frame(width: 6, height: 6)
                        Circle().fill(Color(hex: palette.mint)).frame(width: 6, height: 6)
                        Circle().fill(Color(hex: palette.coral)).frame(width: 6, height: 6)
                    }
                }
                .padding(5)
                Spacer(minLength: 0)
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Color(hex: palette.canvas))
            .roundedClip(NookTheme.Radius.chip)
            .roundedStrokeBorder(chosen ? NookTheme.iris : NookTheme.line2, radius: NookTheme.Radius.chip, lineWidth: chosen ? 2 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Picks a VS Code color theme file (JSON) and adds it as a theme; it is used at once for the appearance it is made for.
    private func importVSCodeTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        let fallback = url.deletingPathExtension().lastPathComponent
        guard let result = try? VSCodeThemeImport.parse(source, fallbackName: fallback) else {
            ToastCenter.shared.warning(tr("theme.importFailed"))
            return
        }
        let custom = NookCustomTheme(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: result.name, source: source)
        settings.customThemes.append(custom)
        if result.palette.isDark { settings.darkThemeID = custom.id } else { settings.lightThemeID = custom.id }
    }
}

// MARK: Colors

/// Settings › Appearance › Colors: every named color Nook draws with, grouped (surfaces, lines, text, state, changes,
/// chats, code), each with a picker for dark or for light. A color set here lies over the chosen theme and changes every
/// place that uses it; "Reset" brings the theme's own color back. Nothing is set by default.
struct ColorTokensSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var dark = true

    private var themePalette: NookPalette { settings.themeChoice.themePalette(dark: dark, themes: settings.themes) }
    private var overrides: [String: UInt32] { settings.colorOverrides.values(dark: dark) }

    var body: some View {
        Group {
            Section {
                Picker(selection: $dark) {
                    Text(tr("theme.mode.dark")).tag(true)
                    Text(tr("theme.mode.light")).tag(false)
                } label: {
                    SettingText("colors.editFor")
                }
                .pickerStyle(.segmented)
                if !overrides.isEmpty {
                    HStack {
                        Text(tr("colors.changed", overrides.count))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                        Spacer()
                        Button(tr("colors.resetAll")) {
                            var all = settings.colorOverrides
                            if dark { all.dark = [:] } else { all.light = [:] }
                            settings.colorOverrides = all
                        }
                    }
                }
            } header: {
                Text(tr("colors.header"))
            } footer: {
                SettingNote(tr("colors.footer"))
            }
            ForEach(NookColorToken.Group.allCases) { group in
                let tokens = NookColorToken.all.filter { $0.group == group }
                let changed = tokens.filter { overrides[$0.id] != nil }.count
                SettingsFold(tr("colors.group.\(group.rawValue)"),
                             summary: changed > 0 ? tr("colors.changed", changed) : swatchSummary(tokens),
                             keys: tokens.map { "colors.token.\($0.id)" }) {
                    ForEach(tokens) { token in row(token) }
                }
            }
        }
    }

    /// The group's names folded, so a closed group still says what is in it.
    private func swatchSummary(_ tokens: [NookColorToken]) -> String {
        tokens.prefix(4).map { tr("colors.token.\($0.id)") }.joined(separator: ", ") + (tokens.count > 4 ? "…" : "")
    }

    private func row(_ token: NookColorToken) -> some View {
        let themeValue = themePalette[keyPath: token.keyPath]
        let value = overrides[token.id] ?? themeValue
        let changed = overrides[token.id] != nil
        return HStack(spacing: NookTheme.Spacing.md) {
            SettingText("colors.token.\(token.id)")
            Spacer(minLength: NookTheme.Spacing.md)
            if changed {
                ToolbarIconButton("arrow.counterclockwise", tr("colors.reset"), height: 22, width: 22) {
                    set(token, nil, themeValue: themeValue)
                }
            }
            Text(NookColor.string(value))
                .font(NookTheme.mono(11))
                .foregroundStyle(changed ? NookTheme.textStrong : NookTheme.textTertiary)
            ColorPicker(tr("colors.token.\(token.id)"), selection: Binding(
                get: { Color(hex: value) },
                set: { set(token, NSColor($0).nookHex, themeValue: themeValue) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }

    private func set(_ token: NookColorToken, _ hex: UInt32?, themeValue: UInt32) {
        var all = settings.colorOverrides
        all.set(token.id, to: hex, dark: dark, themeValue: themeValue)
        guard all != settings.colorOverrides else { return }
        settings.colorOverrides = all
    }
}
