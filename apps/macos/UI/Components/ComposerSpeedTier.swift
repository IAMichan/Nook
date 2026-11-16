import SwiftUI

/// Claude Code's Ultracode beside the effort (`Ultracode`): one click turns it on or off for the next turns. Shown only
/// where the agent and model offer it.
struct ComposerUltracodeToggle: View {
    let offered: Bool
    let on: Bool
    var divided = true
    let onToggle: (Bool) -> Void

    var body: some View {
        if offered {
            if divided { ComposerDivider() }
            Button { onToggle(!on) } label: {
                ComposerPill(symbol: "point.3.connected.trianglepath.dotted", text: tr("compose.ultracode"),
                             showsChevron: false, selected: on)
            }
            .buttonStyle(.nookPlain)
            .composerTip(on ? tr("compose.ultracode.on") : tr("compose.ultracode.off"))
            .accessibilityValue(on ? tr("compose.ultracode.stateOn") : tr("compose.ultracode.stateOff"))
        }
    }
}

/// "Main thread" (`MainThread`): the agent hands its work to sub-threads that report back. Every agent that may delegate.
/// On, the pill is filled with a check, so the mode is plain to see.
struct ComposerMainThreadToggle: View {
    let offered: Bool
    let on: Bool
    var divided = true
    let onToggle: (Bool) -> Void

    var body: some View {
        if offered {
            if divided { ComposerDivider() }
            Button { onToggle(!on) } label: {
                ComposerPill(symbol: on ? "checkmark" : "arrow.triangle.branch", text: tr("compose.mainThread"),
                             showsChevron: false, selected: on)
            }
            .buttonStyle(.nookPlain)
            .composerTip(on ? tr("compose.mainThread.on") : tr("compose.mainThread.off"))
            .accessibilityValue(on ? tr("compose.mainThread.stateOn") : tr("compose.mainThread.stateOff"))
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
