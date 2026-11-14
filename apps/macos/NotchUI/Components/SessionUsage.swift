import SwiftUI

// How full a session's context window is and how much of its account's limits are used, in one place: the session
// panel. Docked beside the conversation it is a card under the panel (`SessionUsageCard`); without the docked panel
// (hidden, a narrow window, the notch, a session without a folder) it is a ring in the header that opens the same
// section (`SessionUsageButton`). The composer shows none of it. Every agent gets what it reports: the context for the
// agents that report their window, the limits for the accounts that report limits.

/// Whose usage: a session Nook runs (its context, its account's limits) or one it only sees (its account's limits).
struct SessionUsageSource: Equatable {
    var runID: UUID?
    var profileID: String?

    static let none = SessionUsageSource()
}

/// What the usage views draw, read once from the app and the workspace.
struct SessionUsageSnapshot: Equatable {
    var context: ContextUsage?
    var autoCompactAt: Int?
    /// Back at a long session whose prompt cache expired: whether the next message goes after a summary. Nil when that
    /// is not on offer.
    var compactFirst: Bool?
    /// The agent summarizes on `/compact` and is not working.
    var canCompact = false
    var limits: [QuotaLimit] = []
    var account = ""

    var isEmpty: Bool { context == nil && limits.isEmpty }

    /// Measured against the auto-compact point (`ContextMeter.pressure`).
    var pressure: Double {
        guard let context else { return 0 }
        return ContextMeter.pressure(used: context.usedTokens, window: context.window, autoCompactAt: autoCompactAt)
    }

    var contextLevel: ContextMeter.Level { context == nil ? .normal : ContextMeter.level(pressure) }

    /// Each window of its own, shortest first ("5h 38%", "W 12%", a second weekly limit too), at most three.
    var limitLines: [UsageLimits.ChipLine] {
        UsageLimits.ringLines(limits.map { ($0.duration, $0.percent, $0.window, $0.group != nil) })
    }

    /// The fullest of those lines.
    var fullestLimit: UsageLimits.ChipLine? { limitLines.max { $0.used < $1.used } }

    var contextTint: Color {
        switch contextLevel {
        case .critical: return NookTheme.coral
        case .warning: return NookTheme.amber
        case .normal: return compactFirst == true ? NookTheme.amber : NookTheme.textSecondary
        }
    }

    /// "Context window 84% · 168k/200k" and "Limits of Work: 5 hours: 38% used · Week: 12% used", one per line.
    var help: String {
        var lines: [String] = []
        if let context {
            lines.append(tr("compose.context.help", ContextMeter.percentText(context.fraction),
                            ContextMeter.tokensText(used: context.usedTokens, window: context.window)))
        }
        if !limits.isEmpty {
            lines.append(tr("compose.limits.help", account, limits.map { tr("limits.rowUsed", $0.label, UsageLimitRows.used($0)) }
                .joined(separator: " · ")))
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func read(_ source: SessionUsageSource, app: AppModel, workspace: WorkspaceManager) -> SessionUsageSnapshot {
        var snapshot = SessionUsageSnapshot()
        let run = source.runID.flatMap { workspace.run($0) }
        if let run {
            if let usage = workspace.contextUsage(run), ContextMeter.worthShowing(used: usage.usedTokens, window: usage.window) {
                snapshot.context = usage
                snapshot.autoCompactAt = workspace.autoCompactAt(run)
                snapshot.compactFirst = workspace.offersCompactFirst(run) ? workspace.compactsFirst(run) : nil
                // Every agent that compacts on `/compact` (Claude Code, Codex, an ACP agent that offers it).
                snapshot.canCompact = !run.status.isActive
                    && AgentCommands.canCompact(run.provider, offered: workspace.acpCommands[run.id] ?? [])
            }
        }
        let profile = run.flatMap { app.profile(for: $0) } ?? source.profileID.flatMap { app.profiles.profile(id: $0) }
        if let profile {
            snapshot.limits = app.quota.limits(for: profile)
            snapshot.account = AccountLabel.name(profile, app: app)
        }
        return snapshot
    }
}

// MARK: - The section

/// The context and the limits of one session: the share of the window used with a bar in the colors of its parts
/// (an accordion under it for the full breakdown), when it summarizes by itself, the choice to summarize first and Summarize now;
/// then the account's windows with their reset and pace, All limits and a refresh. The docked card, the header's
/// popover and the composer's alert all show this.
struct SessionUsageSection: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let source: SessionUsageSource
    /// Closes the popover it is in, before All limits opens the usage modal.
    var close: () -> Void = {}
    private static let shownLimits = 6
    /// Whether the context's breakdown is open, the same in every session and kept across launches.
    @AppStorage("agents.panel.contextBreakdownOpen") private var breakdownOpen = false
    @State private var breakdownHovering = false

    var body: some View {
        let snapshot = SessionUsageSnapshot.read(source, app: app, workspace: workspace)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let context = snapshot.context { contextPart(context, snapshot) }
            if snapshot.context != nil, !snapshot.limits.isEmpty { NookDivider() }
            if !snapshot.limits.isEmpty { limitsPart(snapshot) }
            if snapshot.isEmpty {
                Text(tr("usage.session.none")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ text: String, trailing: String?) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(text).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NookTheme.Spacing.sm)
            if let trailing {
                Text(trailing).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .monospacedDigit().lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func contextPart(_ usage: ContextUsage, _ snapshot: SessionUsageSnapshot) -> some View {
        let pressure = snapshot.pressure
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Text(tr("usage.session.context")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                        .accessibilityAddTraits(.isHeader)
                    // What the window means now (getting long, or when it summarizes by itself) behind an ⓘ, in the
                    // context's tone once it suggests summarizing, instead of a sentence under the bar.
                    if let note = contextNote(snapshot) {
                        SettingsInfoButton(text: note,
                                           tint: ContextMeter.suggestsCompact(pressure) ? snapshot.contextTint : NookTheme.textTertiary)
                    }
                    Spacer(minLength: NookTheme.Spacing.sm)
                    contextNumbers(usage, snapshot)
                }
                ContextUsageBar(usage: usage)
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleBreakdown() }
                    .accessibilityHidden(true)
            }
            // What fills the window, part by part, as the agent reports it: an accordion under the bar.
            breakdownToggle
            if breakdownOpen {
                ContextUsageBreakdown(usage: usage)
                    .transition(.opacity)
                    .onAppear { refreshBreakdown() }
            }
            if let compactFirst = snapshot.compactFirst {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(tr("compose.context.compactFirst")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    Toggle(tr("compose.context.compactFirst"), isOn: Binding(get: { compactFirst }, set: { _ in toggleCompactFirst() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .help(tr(compactFirst ? "compose.compactFirst.compactHelp" : "compose.compactFirst.keepHelp",
                         ContextMeter.tokensText(usage.usedTokens)))
            }
            if let onCompact = compact(snapshot) {
                CompactNowButton(action: onCompact)
            }
        }
    }

    /// "What fills the context ⌄": opens and closes the breakdown under the bar.
    private var breakdownToggle: some View {
        Button(action: toggleBreakdown) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(tr("usage.session.breakdown")).font(NookTheme.TextStyle.detail)
                    .foregroundStyle(breakdownHovering ? NookTheme.paper : NookTheme.textSecondary)
                Image(icon: "chevron.right")
                    .font(NookTheme.font(8, .bold)).foregroundStyle(NookTheme.textTertiary)
                    .rotationEffect(.degrees(breakdownOpen ? 90 : 0))
                Spacer(minLength: 0)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .onHover { breakdownHovering = $0 }
        }
        .buttonStyle(.nookPlain)
    }

    private func toggleBreakdown() {
        withAnimation(NookTheme.Motion.panel) { breakdownOpen.toggle() }
    }

    /// Asks the agent again what fills its window, as the breakdown opens.
    private func refreshBreakdown() {
        if let runID = source.runID { workspace.refreshContextUsage(runID) }
    }

    /// "62%  124k / 200k".
    private func contextNumbers(_ usage: ContextUsage, _ snapshot: SessionUsageSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            Text(ContextMeter.percentText(usage.fraction))
                .font(NookTheme.TextStyle.detail.weight(.semibold).monospacedDigit())
                .foregroundStyle(snapshot.contextLevel == .normal ? NookTheme.textStrong : snapshot.contextTint)
            Text("\(TokenTally.format(usage.usedTokens)) / \(TokenTally.format(usage.window))")
                .font(NookTheme.TextStyle.caption.monospacedDigit()).foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// "This conversation is getting long…" once it suggests summarizing, otherwise when it summarizes by itself.
    private func contextNote(_ snapshot: SessionUsageSnapshot) -> String? {
        if ContextMeter.suggestsCompact(snapshot.pressure) { return tr("compose.context.nearlyFull") }
        return snapshot.autoCompactAt.map { tr("compose.context.autoCompact", ContextMeter.tokensText($0)) }
    }

    private func limitsPart(_ snapshot: SessionUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            title(tr("limits.title"), trailing: snapshot.account.isEmpty ? nil : snapshot.account)
            TimelineView(.nookTicks(every: 60)) { context in
                UsageLimitRows(limits: shown(snapshot.limits), now: context.date)
            }
            if snapshot.limits.count > Self.shownLimits {
                Text(tr("usage.session.moreLimits", snapshot.limits.count - Self.shownLimits))
                    .font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                SmallGhostButton(title: tr("limits.all")) {
                    close()
                    app.openUsageModal(.limits)
                }
                .padding(.leading, -10)
                Spacer(minLength: 0)
                UsageRefreshButton()
            }
        }
    }

    /// The fullest windows when there are many (an agent with a quota per model), in the agent's order.
    private func shown(_ limits: [QuotaLimit]) -> [QuotaLimit] {
        guard limits.count > Self.shownLimits else { return limits }
        let busiest = Set(limits.sorted { $0.percent > $1.percent }.prefix(Self.shownLimits).map(\.id))
        return limits.filter { busiest.contains($0.id) }
    }

    private func compact(_ snapshot: SessionUsageSnapshot) -> (() -> Void)? {
        guard snapshot.canCompact, let runID = source.runID else { return nil }
        return { workspace.send(runID, text: "/compact") }
    }

    private func toggleCompactFirst() {
        if let runID = source.runID { workspace.toggleCompactFirst(runID) }
    }
}

/// Summarize now, across the section: the words, and the command it sends on the right.
private struct CompactNowButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("usage.session.compactNow"))
                    .font(NookTheme.TextStyle.detail.weight(.medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.sm)
                Text("/compact")
                    .font(NookTheme.mono(10))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 28)
            .cardBackground(hovering ? NookTheme.smoke : Color.clear, stroke: NookTheme.line2, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .help(tr("compose.context.compact"))
    }
}

/// One bar across: each part of the window in its color (`ContextUsageBreakdown.color`), the buffer dim, the free space empty.
struct ContextUsageBar: View {
    let usage: ContextUsage
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(usage.inWindow.filter { $0.kind != .free }) { category in
                    Rectangle().fill(ContextUsageBreakdown.color(category))
                        .frame(width: max(1, geometry.size.width * usage.share(category)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(NookTheme.line2)
        .mask { Capsule() }
    }
}

// MARK: - Docked: a card under the session panel

/// The usage section as a card under the docked session panel. Its title line folds it to one line ("Context 62% ·
/// 5h 38% · W 12%") for a short column; right-click hides it, as the panel's rows.
struct SessionUsageCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let source: SessionUsageSource
    /// Docked: a card of its own, as the panel above it.
    var boxed = false
    /// In the branch button's popover: a line between it and the panel's rows above.
    var divided = false
    @AppStorage("agents.panel.usageFolded") private var folded = false
    /// Shared with the session panel's rows (`SessionPanel.optionalRows`), so its menu can turn this back on.
    @AppStorage("agents.panel.hidden") private var hiddenRaw = ""
    @State private var hovering = false

    static let row = "usage"

    var body: some View {
        let snapshot = SessionUsageSnapshot.read(source, app: app, workspace: workspace)
        let hidden = hiddenRaw.split(separator: ",").contains { $0 == Self.row }
        if !snapshot.isEmpty, !hidden {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Button { withAnimation(NookTheme.Motion.panel) { folded.toggle() } } label: {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(tr("usage.session.title")).font(NookTheme.TextStyle.label)
                            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        if folded { SessionUsageSummary(snapshot: snapshot) }
                        Image(icon: folded ? "chevron.down" : "chevron.up")
                            .font(NookTheme.font(8, .bold)).foregroundStyle(NookTheme.textTertiary)
                    }
                    .frame(height: 20)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                }
                .buttonStyle(.nookPlain)
                .help(tr(folded ? "usage.session.unfold" : "usage.session.fold"))
                if !folded { SessionUsageSection(source: source) }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { if divided { NookDivider() } }
            .cardBackground(boxed ? NookTheme.field : Color.clear, stroke: boxed ? NookTheme.border : Color.clear,
                            radius: NookTheme.Radius.conversationCard)
            .contextMenu {
                Button(tr("usage.session.hide")) { hide() }
            }
        }
    }

    private func hide() {
        var rows = Set(hiddenRaw.split(separator: ",").map(String.init))
        rows.insert(Self.row)
        hiddenRaw = rows.sorted().joined(separator: ",")
    }
}

/// "Context 62% · 5h 38% · W 12%": the folded card's line, each number in its tone.
struct SessionUsageSummary: View {
    let snapshot: SessionUsageSnapshot

    private var items: [(label: String, value: String, tint: Color)] {
        var items: [(label: String, value: String, tint: Color)] = []
        if let context = snapshot.context {
            items.append((tr("usage.session.context"), ContextMeter.percentText(context.fraction),
                          snapshot.contextLevel == .normal ? NookTheme.textSecondary : snapshot.contextTint))
        }
        for line in snapshot.limitLines {
            items.append((line.short, "\(line.used)%", UsageTone.level(used: line.used) == .calm ? NookTheme.textSecondary
                                                         : UsageTone.text(used: line.used)))
        }
        return items
    }

    var body: some View {
        let parts = items
        HStack(spacing: NookTheme.Spacing.sm) {
            ForEach(parts.indices, id: \.self) { index in
                if index > 0 { Text("·").foregroundStyle(NookTheme.textTertiary) }
                Text(parts[index].label).foregroundStyle(NookTheme.textTertiary)
                    + Text(" \(parts[index].value)").foregroundStyle(parts[index].tint)
            }
        }
        .font(NookTheme.TextStyle.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Without the docked panel: a ring in the header

/// One ring of the header's nest: what it measures ("Context", "5h", "W"), how full, in which tone.
struct SessionUsageRingItem: Equatable {
    var label: String
    var fraction: Double
    var tint: Color
    var used: String
}

extension SessionUsageSnapshot {
    /// The rings from outside in: the context window, then each limit window from short to long.
    var rings: [SessionUsageRingItem] {
        var rings: [SessionUsageRingItem] = []
        if let context {
            rings.append(SessionUsageRingItem(label: tr("usage.session.context"), fraction: context.fraction,
                                              tint: contextTint, used: ContextMeter.percentText(context.fraction)))
        }
        for line in limitLines {
            rings.append(SessionUsageRingItem(label: line.short, fraction: Double(line.used) / 100,
                                              tint: UsageTone.fill(used: line.used, calm: NookTheme.textSecondary),
                                              used: "\(line.used)%"))
        }
        return rings
    }

    /// "Rings, outside in: Context, 5h, W", for the header's tooltip.
    var ringOrder: String? {
        let rings = rings
        guard rings.count > 1 else { return nil }
        return tr("usage.ring.order", rings.map(\.label).joined(separator: ", "))
    }
}

/// Rings nested in one another, the first outside. With `highlight` only that ring is drawn in its tone and the others
/// as bare tracks: the legend's mark for "this one".
struct NestedUsageRings: View {
    let rings: [SessionUsageRingItem]
    var size: CGFloat = 18
    var lineWidth: CGFloat = 1.25
    var gap: CGFloat = 0.75
    var highlight: Int?

    var body: some View {
        let step = 2 * (lineWidth + gap)
        ZStack {
            ForEach(rings.indices, id: \.self) { index in
                let diameter = max(lineWidth * 2, size - CGFloat(index) * step)
                ProgressRing(fraction: highlight.map { $0 == index ? 1 : 0 } ?? rings[index].fraction,
                             tint: highlight == nil ? rings[index].tint : NookTheme.textStrong, lineWidth: lineWidth)
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The context window outside, the limit windows nested inside it from short to long (5 hours, the week, a second
/// weekly limit). Quiet and without a number while all is calm; the number of what needs attention comes beside it in
/// amber or coral. The tooltip names the rings from outside in; the popover's legend marks each one.
struct SessionUsageRing: View, Equatable {
    let snapshot: SessionUsageSnapshot
    var hovering = false

    /// "84%" for a context past the warning line, "5h 78%" for a limit from 75 %; nil while calm.
    private var number: (String, Color)? {
        let limit = snapshot.fullestLimit.flatMap { UsageTone.level(used: $0.used) == .calm ? nil : $0 }
        let context = snapshot.context.flatMap { snapshot.contextLevel == .normal && snapshot.compactFirst != true ? nil : $0 }
        if let limit, UsageTone.level(used: limit.used) == .error || context == nil {
            return ("\(limit.short) \(limit.used)%", UsageTone.text(used: limit.used))
        }
        if let context { return (ContextMeter.percentText(context.fraction), snapshot.contextTint) }
        return nil
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            NestedUsageRings(rings: snapshot.rings)
            if let number {
                Text(number.0).font(NookTheme.TextStyle.caption.monospacedDigit()).foregroundStyle(number.1)
                    .lineLimit(1).fixedSize()
            }
        }
    }
}

/// Which ring is which, at the top of the header's popover: per ring a small nest with only that ring lit, its name and
/// how full it is ("◎ Context 42%  ◎ 5h 38%  ◎ W 12%").
struct SessionUsageRingLegend: View {
    let snapshot: SessionUsageSnapshot

    var body: some View {
        let rings = snapshot.rings
        if rings.count > 1 {
            HStack(spacing: NookTheme.Spacing.md) {
                ForEach(rings.indices, id: \.self) { index in
                    HStack(spacing: NookTheme.Spacing.xs) {
                        NestedUsageRings(rings: rings, size: 12, lineWidth: 1, gap: 0.5, highlight: index)
                        Text(rings[index].label).foregroundStyle(NookTheme.textTertiary)
                            + Text(" \(rings[index].used)").foregroundStyle(rings[index].tint)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(NookTheme.TextStyle.caption.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// The ring in a session's header while the session panel is not docked beside it: click for the usage section in a
/// popover. Nothing when the session reports neither a context nor limits.
struct SessionUsageButton: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let source: SessionUsageSource

    /// Reads the usage on every change of the workspace or the app model (both publish often while an agent works); the
    /// button itself, its help and its ring are drawn again only when what they show changed.
    var body: some View {
        let snapshot = SessionUsageSnapshot.read(source, app: app, workspace: workspace)
        if !snapshot.isEmpty {
            SessionUsageButtonLabel(source: source, snapshot: snapshot).equatable()
        }
    }
}

/// `SessionUsageButton` for one reading of the usage.
private struct SessionUsageButtonLabel: View, Equatable {
    let source: SessionUsageSource
    let snapshot: SessionUsageSnapshot
    @State private var open = false
    @State private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source && lhs.snapshot == rhs.snapshot }

    var body: some View {
        // The usage, then which ring is which: made once for the tooltip and the label.
        let help = [snapshot.help, snapshot.ringOrder].compactMap { $0 }.joined(separator: "\n")
        Button { open.toggle() } label: {
            SessionUsageRing(snapshot: snapshot).equatable()
                .padding(.horizontal, NookTheme.Spacing.sm)
                .frame(height: ToolbarGroup.itemHeight)
                .roundedBackground(hovering || open ? NookTheme.smoke : Color.clear, radius: ToolbarGroup.itemRadius)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
        .buttonStyle(.nookPlain)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SessionUsagePopover(source: source, legend: true) { open = false }
        }
    }
}

/// The usage section on its own, as a popover from the header's ring or the composer's alert. From the ring it opens
/// with the legend that says which ring is which.
struct SessionUsagePopover: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let source: SessionUsageSource
    var legend = false
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if legend {
                SessionUsageRingLegend(snapshot: SessionUsageSnapshot.read(source, app: app, workspace: workspace))
            }
            SessionUsageSection(source: source, close: close)
        }
        .padding(NookTheme.Spacing.lg)
        .frame(width: PanelLayout.sessionPanel, alignment: .leading)
    }
}
