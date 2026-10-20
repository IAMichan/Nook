import SwiftUI

/// Settings › Appearance › Wardrobe: a fitting room. Nook stands in front of the mirror in what he wears now; rest
/// the pointer on an item and he tries it on, click it and he keeps it. One item per place (head, eyes, neck).
struct WardrobeSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = NookAppearance.shared
    @State private var slot: NookAccessorySlot = .head
    /// What the pointer rests on, tried on in the mirror; `.some(nil)` is the tile that leaves the place free.
    @State private var trying: NookAccessory?? = nil
    /// Nook's mood in the mirror: pleased for a moment after you dress him.
    @State private var mirrorMood: NookMood = .rest
    @State private var cheerTask: Task<Void, Never>?

    var body: some View {
        Group {
            Section {
                mirror
            } header: {
                Text(tr("wardrobe.title"))
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)

            Section {
                Picker(tr("wardrobe.place"), selection: $slot) {
                    ForEach(NookAccessorySlot.allCases, id: \.self) { place in
                        Text(tr("wardrobe.slot.\(place.rawValue)")).tag(place)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    tile(nil)
                    ForEach(NookAccessory.allCases.filter { $0.slot == slot }) { item in
                        tile(item)
                    }
                }
                .padding(.vertical, 4)
                .onChange(of: slot) { _, _ in trying = nil }
                SettingToggle(tr("wardrobe.automatic"), detail: tr("wardrobe.automaticDetail"), isOn: $settings.nookWardrobe.automatic)
            } footer: {
                Text(tr("wardrobe.footer"))
            }
        }
    }

    // MARK: Mirror

    /// Nook large and alive in a soft spotlight, with what he wears listed beside him.
    private var mirror: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [NookTheme.iris.opacity(0.22), Color.clear], center: .center, startRadius: 0, endRadius: 72))
                    .frame(width: 144, height: 144)
                // The floor he stands on.
                Ellipse()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 66, height: 11)
                    .blur(radius: 4)
                    .offset(y: 54)
                NookOrb(mood: mirrorMood, size: 76, glow: settings.nookLook.glow, look: settings.nookLook, outfit: mirrorOutfit)
                    .offset(y: 8)
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                Text(trying == nil ? tr("wardrobe.mirror.title") : tr("wardrobe.mirror.trying"))
                    .font(.headline)
                if wearing.isEmpty {
                    Text(tr("wardrobe.mirror.nothing"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(wearing) { item in
                            wornRow(item)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button { surprise() } label: {
                        Label(tr("wardrobe.shuffle"), systemImage: "dice")
                    }
                    Button(tr("wardrobe.undress")) { undress() }
                        .disabled(settings.nookWardrobe.chosen.isEmpty)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NookTheme.graphite))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(NookTheme.line2, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("wardrobe.title"))
    }

    /// One thing he wears: its name, whether you chose it or he did, and a way to take your own picks off.
    private func wornRow(_ item: NookAccessory) -> some View {
        let chosen = settings.nookWardrobe.chosen.contains(item)
        return HStack(spacing: 6) {
            Image(systemName: chosen ? "checkmark.circle.fill" : "sparkles")
                .font(.caption)
                .foregroundStyle(chosen ? NookTheme.iris : Color.secondary)
            Text(tr(item.titleKey))
                .font(.callout)
            Text(tr(chosen ? "wardrobe.mirror.chosen" : "wardrobe.mirror.auto"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if chosen {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { settings.nookWardrobe.clear(item.slot) }
                    cheer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("wardrobe.takeOff", tr(item.titleKey)))
            }
        }
    }

    /// What Nook wears now: your choices plus what he picked himself. A chosen hat shows here even while music plays.
    private var wearing: [NookAccessory] {
        var items = appearance.outfit
        for item in settings.nookWardrobe.chosen where !items.contains(item) {
            items.removeAll { $0.slot == item.slot }
            items.append(item)
        }
        return items.sorted { $0.slot.order < $1.slot.order }
    }

    /// What the mirror shows: what he wears, with the item under the pointer tried on.
    private var mirrorOutfit: [NookAccessory] {
        var items = wearing
        if case .some(let candidate) = trying {
            items.removeAll { $0.slot == slot }
            if let candidate { items.append(candidate) }
        }
        return items
    }

    // MARK: Tiles

    private func tile(_ item: NookAccessory?) -> some View {
        let automatic = settings.nookWardrobe.automatic
        let title = item.map { tr($0.titleKey) } ?? tr(automatic ? "wardrobe.item.auto" : "wardrobe.item.none")
        let selected = settings.nookWardrobe.chosen(in: slot) == item
        let picked = item.map { appearance.outfit.contains($0) && !settings.nookWardrobe.chosen.contains($0) } ?? false
        return WardrobeTile(item: item, slot: slot, title: title, selected: selected, picked: picked, automatic: automatic,
                            look: settings.nookLook,
                            onHover: { inside in
                                if inside { trying = .some(item) } else if case .some(let shown) = trying, shown == item { trying = nil }
                            },
                            action: { choose(item) })
    }

    // MARK: Dressing

    private func choose(_ item: NookAccessory?) {
        withAnimation(.easeOut(duration: 0.15)) {
            if let item { settings.nookWardrobe.wear(item) } else { settings.nookWardrobe.clear(slot) }
        }
        trying = nil
        cheer()
    }

    /// A random outfit: nearly always a hat, now and then glasses or a scarf, never the same as now.
    private func surprise() {
        var wardrobe = settings.nookWardrobe
        for place in NookAccessorySlot.allCases {
            let current = wardrobe.chosen(in: place)
            wardrobe.clear(place)
            let chance = place == .head ? 0.9 : 0.45
            let options = NookAccessory.allCases.filter { $0.slot == place && $0 != current }
            if Double.random(in: 0..<1) < chance, let pick = options.randomElement() { wardrobe.wear(pick) }
        }
        if wardrobe.chosen.isEmpty, let hat = NookAccessory.allCases.filter({ $0.slot == .head }).randomElement() {
            wardrobe.wear(hat)
        }
        withAnimation(.easeOut(duration: 0.2)) { settings.nookWardrobe = wardrobe }
        NookPresence.shared.celebrate()
        cheer(.celebrate)
    }

    private func undress() {
        withAnimation(.easeOut(duration: 0.2)) { settings.nookWardrobe.chosen = [] }
        cheer(.surprised)
    }

    /// Nook nods and looks pleased in the mirror for a moment.
    private func cheer(_ mood: NookMood = .proud) {
        NookPresence.shared.nod()
        mirrorMood = mood
        cheerTask?.cancel()
        cheerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            mirrorMood = .rest
        }
    }
}

/// One item as a tile: Nook wearing it, its name, a check when you chose it and a sparkle when he wears it by himself.
/// Rest the pointer on it and he wakes up and looks at you; the mirror above tries it on.
private struct WardrobeTile: View {
    let item: NookAccessory?
    let slot: NookAccessorySlot
    let title: String
    let selected: Bool
    /// He wears it right now, by his own choice.
    let picked: Bool
    let automatic: Bool
    let look: NookLook
    let onHover: (Bool) -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [NookTheme.iris.opacity(selected ? 0.3 : (hovering ? 0.16 : 0)), Color.clear],
                                             center: .center, startRadius: 0, endRadius: 34))
                    if let item {
                        // Hats stick out above him and a scarf's tails below: keep the whole item in the tile.
                        NookOrb(mood: .rest, size: 36, animated: hovering, glow: false, look: look, outfit: [item])
                            .offset(y: slot == .head ? 9 : (slot == .neck ? -6 : 0))
                    } else {
                        Image(systemName: automatic ? "sparkles" : "circle.slash")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 70, height: 64)
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NookTheme.smoke.opacity(selected ? 0.95 : (hovering ? 0.75 : 0.5))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? NookTheme.iris : Color.primary.opacity(hovering ? 0.2 : 0.1), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NookTheme.iris)
                        .padding(6)
                } else if picked {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(7)
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .help(picked ? tr("wardrobe.mirror.auto") : title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
