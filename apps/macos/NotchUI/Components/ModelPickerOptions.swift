import SwiftUI

// What a session is set to beside its model, in the footer of the model picker instead of as pills in the composer:
// Agent or Plan, the reasoning effort, the speed tier, Ultracode, Main thread (sub-threads) and how much access the agent
// has. The composer of a new session and of a running one both hand their values to this one view, so every agent shows
// the same choices (each only where its agent offers them) and the composer keeps its row for the model and the usage.

struct ModelPickerOptions: View {
    /// The reasoning effort: one level per model of a family (an agent that lists a model per level), or levels set on the session.
    struct Effort {
        var family: ModelVariants.Family?
        var model: String
        /// The model the levels belong to, said at the head of the column.
        var modelName: String
        var levels: [String]
        var chosen: String?
        var title: (String?) -> String
        var pickLevel: (String?) -> Void
        var pickModel: (String) -> Void
    }

    /// How much the agent may do. Plan mode makes it read-only.
    struct Access {
        var provider: RunProvider
        var chosen: PermissionPolicy
        var readOnly: Bool
        var pick: (PermissionPolicy) -> Void
    }

    var effort: Effort?
    /// Agent or Plan; nil hides the choice.
    var mode: Binding<ExecutionMode>? = nil
    var access: Access?
    var speedTiers: [SpeedTier] = []
    var speed: String?
    var pickSpeed: (String?) -> Void = { _ in }
    var ultracodeOffered = false
    var ultracode = false
    var setUltracode: (Bool) -> Void = { _ in }
    var mainThreadOffered = false
    var mainThread = false
    var setMainThread: (Bool) -> Void = { _ in }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NookTheme.Spacing.xs) {
                modeChoice
                speedChoice
                subThreads
                Spacer(minLength: NookTheme.Spacing.sm)
                accessMenu
            }
            ChipFlow(spacing: NookTheme.Spacing.xs) {
                modeChoice
                speedChoice
                subThreads
                accessMenu
            }
        }
        .padding(NookTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Ultracode and Main thread are one choice here: working in sub-threads. On, it switches on whatever the agent offers
    /// of the two (Main thread where it may delegate, Ultracode where its model has it).
    private var subThreads: some View {
        ComposerMainThreadToggle(offered: mainThreadOffered || ultracodeOffered,
                                 on: mainThreadOffered ? mainThread : ultracode, divided: false) { on in
            if mainThreadOffered { setMainThread(on) }
            if ultracodeOffered { setUltracode(on) }
        }
    }

    /// Agent and Plan side by side, as one segmented choice. Plan makes the agent read-only (the access menu says so).
    @ViewBuilder
    private var modeChoice: some View {
        if let mode {
            HStack(spacing: 2) {
                ForEach(ExecutionMode.allCases) { option in
                    segment(option.label, symbol: option == .plan ? "list.bullet.clipboard" : "sparkles",
                            on: mode.wrappedValue == option) { mode.wrappedValue = option }
                        .help(option.help)
                }
            }
            .padding(2)
            .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
        }
    }

    /// Standard and the faster tiers side by side, as one segmented choice.
    @ViewBuilder
    private var speedChoice: some View {
        if !speedTiers.isEmpty {
            HStack(spacing: 2) {
                segment(tr("compose.speed.standard"), symbol: "hare", on: speed == nil) { pickSpeed(nil) }
                ForEach(speedTiers, id: \.id) { tier in
                    segment(tier.name, symbol: "bolt.fill", on: speed == tier.id) { pickSpeed(tier.id) }
                }
            }
            .padding(2)
            .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
        }
    }

    private func segment(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(icon: symbol).font(NookTheme.font(12, .medium))
                Text(title).lineLimit(1)
            }
            .font(NookTheme.TextStyle.control)
            .foregroundStyle(on ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 24)
            .roundedBackground(on ? DropdownStyle.chosen : .clear, radius: NookTheme.Radius.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var accessMenu: some View {
        if let access {
            ComposerDropdown(width: 300) {
                ComposerPill(symbol: access.readOnly ? "lock" : access.chosen.symbol,
                             text: access.readOnly ? tr("compose.readOnly") : access.chosen.label,
                             tint: access.chosen == .bypass && !access.readOnly ? NookTheme.coralSoft : nil)
            } content: {
                ModelPickerPermissions(access: access)
            }
            .disabled(access.readOnly)
        }
    }
}

/// The access panel: one icon per policy side by side, and under them the name and what it allows of the one chosen
/// or under the pointer.
private struct ModelPickerPermissions: View {
    let access: ModelPickerOptions.Access
    @State private var hovered: PermissionPolicy?
    @Environment(\.closeDropdown) private var close

    var body: some View {
        let shown = hovered ?? access.chosen
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("compose.access")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
            HStack(spacing: 2) {
                ForEach(access.provider.capabilities.policies) { policy in
                    let on = access.chosen == policy
                    Button {
                        access.pick(policy)
                        close()
                    } label: {
                        Image(icon: policy.symbol)
                            .font(NookTheme.font(14, .medium))
                            .foregroundStyle(on ? NookTheme.paper : policy == .bypass ? NookTheme.coralSoft : NookTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .roundedBackground(on ? DropdownStyle.chosen : .clear, radius: NookTheme.Radius.chip)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? policy : nil }
                    .help(policy.label)
                    .accessibilityLabel(policy.label)
                }
            }
            .padding(2)
            .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
            Text(shown.label).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
            Text(shown.help(for: access.provider))
                .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The reasoning column beside the models in the model picker: its levels one under the other, the chosen one ticked.
struct ModelPickerReasoning: View {
    let effort: ModelPickerOptions.Effort

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("compose.effort")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                Spacer(minLength: 4)
                Text(effort.modelName).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.top, NookTheme.Spacing.md)
            .padding(.bottom, NookTheme.Spacing.xs)
            if let family = effort.family {
                let levels = family.members.map(\.level)
                ForEach(family.members, id: \.self) { member in
                    row(symbol: member.level.isEmpty ? "circle.dashed" : EffortSymbol.symbol(member.level, in: levels),
                        title: tr(EffortLevels.label(variant: member.level)), on: member.id == effort.model) {
                        effort.pickModel(member.id)
                    }
                }
            } else {
                row(symbol: "circle.dashed", title: tr(EffortLevels.label(nil)), on: effort.chosen == nil) { effort.pickLevel(nil) }
                ForEach(effort.levels, id: \.self) { level in
                    row(symbol: EffortSymbol.symbol(level, in: effort.levels), title: effort.title(level),
                        on: effort.chosen == level) { effort.pickLevel(level) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func row(symbol: String, title: String, on: Bool, action: @escaping () -> Void) -> some View {
        DropdownRow(symbol: symbol, title: title, trailing: on ? "✓" : nil, chosen: on, staysOpen: true, action: action)
    }
}
