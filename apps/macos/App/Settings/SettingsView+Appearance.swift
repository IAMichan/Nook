import SwiftUI
import AppKit

/// Settings › Appearance: how Nook looks. A large live Nook on top that shows each mood, the three styles as cards,
/// then the face, the finish and the color, each option once.
extension SettingsView {
    // MARK: Appearance

    var appearanceSection: some View {
        Group {
            Section {
                lookPreview
            } footer: {
                Text(tr("settings.display.lookHint"))
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)

            Section {
                HStack(spacing: 10) {
                    ForEach(NookLook.presets) { preset in
                        lookPresetCard(preset.id, preset.look)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text(tr("settings.appearance.style"))
            } footer: {
                if !NookLook.presets.contains(where: { $0.look == settings.nookLook }) {
                    Text(tr("settings.appearance.styleCustom"))
                }
            }

            Section {
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
            } header: {
                Text(tr("settings.appearance.face"))
            } footer: {
                if settings.nookLook.mouth == .expressive {
                    Text(tr("settings.display.mouthHint"))
                }
            }

            Section(tr("settings.appearance.finish")) {
                Toggle(tr("settings.display.gloss"), isOn: $settings.nookLook.gloss)
                Toggle(tr("settings.display.glow"), isOn: $settings.nookLook.glow)
                Toggle(tr("settings.display.cheeks"), isOn: $settings.nookLook.cheeks)
            }

            WardrobeSettingsSection()

            Section {
                HStack(spacing: 10) {
                    ForEach([0xF4F3F7, 0x8B7BFF, 0x5AA9FF, 0x46E0A6, 0xFFB84D, 0xFF6B6B, 0xFF7EB6] as [UInt32], id: \.self) { hex in
                        Button { settings.accentHex = hex } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(Color.primary.opacity(settings.accentHex == hex ? 0.9 : 0.15),
                                                         lineWidth: settings.accentHex == hex ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("settings.display.accent"))
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
            } footer: {
                Text(tr("settings.display.accentHint"))
            }

            Section {
                HStack {
                    Spacer()
                    Button(tr("settings.appearance.reset")) {
                        settings.nookLook = .classic
                        settings.accentHex = NookTheme.defaultAccentHex
                        settings.nookWardrobe = .standard
                    }
                    .disabled(settings.nookLook == .classic && settings.accentHex == NookTheme.defaultAccentHex
                              && settings.nookWardrobe == .standard)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    /// Nook large and alive, with the moods underneath to see how each one looks.
    private var lookPreview: some View {
        VStack(spacing: 14) {
            NookOrb(mood: lookPreviewMood, size: 88, glow: settings.nookLook.glow, look: settings.nookLook)
                .frame(width: 150, height: 130)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                ForEach(Self.previewMoods, id: \.key) { item in
                    let selected = lookPreviewMood == item.mood
                    Button { lookPreviewMood = item.mood } label: {
                        Text(tr(item.key))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .foregroundStyle(selected ? NookTheme.onIris : Color.primary)
                            .background(Capsule().fill(selected ? NookTheme.iris : Color.primary.opacity(0.06)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous).fill(NookTheme.graphite))
        .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous).strokeBorder(NookTheme.line2, lineWidth: 0.5))
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
        return Button { withAnimation(.easeOut(duration: 0.15)) { settings.nookLook = look } } label: {
            VStack(spacing: 8) {
                NookOrb(mood: .rest, size: 44, animated: false, glow: false, look: look)
                    .frame(width: 60, height: 56)
                Text(Self.presetTitle(id)).font(.callout.weight(.semibold))
                Text(tr("settings.appearance.preset.\(id)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.smoke.opacity(selected ? 0.9 : 0.5)))
            .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
                .strokeBorder(selected ? NookTheme.iris : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
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
}
