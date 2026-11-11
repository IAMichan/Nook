import SwiftUI

/// The speed tier beside the effort in an agent's composer (`SpeedTiers`): Standard, then the faster tiers the agent
/// offers for the model. Shown only when there are any, so agents without tiers keep their row as it was.
struct ComposerSpeedTier: View {
    let tiers: [SpeedTier]
    let chosen: String?
    let onPick: (String?) -> Void

    var body: some View {
        if !tiers.isEmpty {
            ComposerDivider()
            ComposerDropdown(width: 240) {
                ComposerPill(symbol: chosen == nil ? "hare" : "bolt.fill", text: title(chosen),
                             tint: chosen == nil ? nil : NookTheme.amber)
            } content: {
                DropdownHeader(title: tr("compose.speed"))
                DropdownRow(symbol: "hare", title: tr("compose.speed.standard"), detail: tr("compose.speed.standard.detail"),
                            chosen: chosen == nil) { onPick(nil) }
                ForEach(tiers, id: \.id) { tier in
                    DropdownRow(symbol: "bolt.fill", title: tier.name, detail: tier.detail ?? tr("compose.speed.fast.detail"),
                                chosen: chosen == tier.id) { onPick(tier.id) }
                }
            }
            .composerTip(tr("compose.speed.help"))
        }
    }

    private func title(_ id: String?) -> String {
        guard let id else { return tr("compose.speed.standard") }
        return tiers.first { $0.id == id }?.name ?? SpeedTiers.displayName(id)
    }
}

/// Claude Code's Ultracode beside the effort (`Ultracode`): one click turns it on or off for the next turns. Shown only
/// where the agent and model offer it.
struct ComposerUltracodeToggle: View {
    let offered: Bool
    let on: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        if offered {
            ComposerDivider()
            Button { onToggle(!on) } label: {
                ComposerPill(symbol: "point.3.connected.trianglepath.dotted", text: tr("compose.ultracode"),
                             showsChevron: false, selected: on)
            }
            .buttonStyle(.plain)
            .composerTip(on ? tr("compose.ultracode.on") : tr("compose.ultracode.off"))
            .accessibilityValue(on ? tr("compose.ultracode.stateOn") : tr("compose.ultracode.stateOff"))
        }
    }
}

/// "Main thread" (`MainThread`): the agent hands its work to sub-threads that report back. Every agent that may delegate.
/// On, the pill is filled with a check, so the mode is plain to see; `ComposerMainThreadHint` says what it means.
struct ComposerMainThreadToggle: View {
    let offered: Bool
    let on: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        if offered {
            ComposerDivider()
            Button { onToggle(!on) } label: {
                ComposerPill(symbol: on ? "checkmark" : "arrow.triangle.branch", text: tr("compose.mainThread"),
                             showsChevron: false, selected: on)
            }
            .buttonStyle(.plain)
            .composerTip(on ? tr("compose.mainThread.on") : tr("compose.mainThread.off"))
            .accessibilityValue(on ? tr("compose.mainThread.stateOn") : tr("compose.mainThread.stateOff"))
        }
    }
}

/// One calm line by a composer while Main thread is on (`ComposerMainThreadToggle`): what the session will do and where
/// its sub-threads show up. The same line under a new session's box and a running one's, for every agent that offers it.
struct ComposerMainThreadHint: View {
    let offered: Bool
    let on: Bool

    var body: some View {
        if offered && on {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                Image(icon: "arrow.triangle.branch")
                    .foregroundStyle(NookTheme.iris)
                Text(tr("compose.mainThread.hint"))
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(NookTheme.TextStyle.detail)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The gauge of an effort level fills up with the level (the effort pickers of a new and a running session).
enum EffortSymbol {
    static func symbol(_ level: String, in levels: [String]) -> String {
        let index = levels.firstIndex(of: level) ?? 0
        if index == 0 { return "gauge.with.dots.needle.0percent" }
        if index == levels.count - 1 { return "gauge.with.dots.needle.100percent" }
        return index * 2 < levels.count ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.67percent"
    }
}
