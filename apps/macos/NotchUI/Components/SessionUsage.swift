import SwiftUI

// How full a session's context window is and how much of its account's limits are used, in one place: the session
// panel. Docked beside the conversation it is a card under the panel (`SessionUsageCard`); without the docked panel
// (hidden, a narrow window, the notch, a session without a folder) it is a ring in the header that opens the same
// section (`SessionUsageButton`). The composer keeps only what needs a decision now (`ComposerUsageAlert`): a context
// that is nearly full, or a limit that is nearly or fully used. Every agent gets what it reports: the context for the
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

    /// The short and the long window ("5h 38%", "W 12%"), as the old composer chip showed them.
    var limitLines: [UsageLimits.ChipLine] { UsageLimits.chipLines(limits.map { ($0.duration, $0.percent, $0.window) }) }

    /// The fullest of those lines.
    var fullestLimit: UsageLimits.ChipLine? { limitLines.max { $0.used < $1.used } }

    /// What needs your attention now, the most urgent first: a limit from 90 % (it stops the agent), then a context
    /// past the warning line or set to be summarized before your next message. Nil while all is calm.
    var attention: Attention? {
        if let line = fullestLimit, UsageTone.level(used: line.used) == .error { return .limit(line) }
        if context != nil, contextLevel != .normal || compactFirst == true { return .context }
        return nil
    }

    enum Attention: Equatable {
        case context
        case limit(UsageLimits.ChipLine)
    }

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
/// (hover for the full breakdown), when it summarizes by itself, the choice to summarize first and Summarize now;
/// then the account's windows with their reset and pace, All limits and a refresh. The docked card, the header's
/// popover and the composer's alert all show this.
struct SessionUsageSection: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let source: SessionUsageSource
    /// Closes the popover it is in, before All limits opens the usage modal.
    var close: () -> Void = {}
    private static let shownLimits = 6

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
        let level = snapshot.contextLevel
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            title(tr("usage.session.context"), trailing: "\(TokenTally.format(usage.usedTokens)) / \(TokenTally.format(usage.window))")
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Text(ContextMeter.percentText(usage.fraction))
                        .font(NookTheme.TextStyle.title.monospacedDigit())
                        .foregroundStyle(level == .normal ? NookTheme.paper : snapshot.contextTint)
                    Text(tr("usage.session.windowUsed")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                }
                ContextUsageBar(usage: usage)
            }
            .contentShape(Rectangle())
            // What fills the window, part by part, as the agent reports it.
            .hoverCard(arrowEdge: .leading) {
                ContextUsageCard(usage: usage, pressure: pressure, autoCompactAt: snapshot.autoCompactAt,
                                 onCompact: compact(snapshot), compactFirst: snapshot.compactFirst,
                                 toggleCompactFirst: toggleCompactFirst)
                    .onAppear { if let runID = source.runID { workspace.refreshContextUsage(runID) } }
            }
            .accessibilityElement(children: .combine)
            if ContextMeter.suggestsCompact(pressure) {
                Text(tr("compose.context.nearlyFull"))
                    .font(NookTheme.TextStyle.detail).foregroundStyle(level == .critical ? NookTheme.coral : NookTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let at = snapshot.autoCompactAt {
                Text(tr("compose.context.autoCompact", ContextMeter.tokensText(at)))
                    .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let compactFirst = snapshot.compactFirst {
                Toggle(isOn: Binding(get: { compactFirst }, set: { _ in toggleCompactFirst() })) {
                    Text(tr("compose.context.compactFirst")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.paper)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(tr(compactFirst ? "compose.compactFirst.compactHelp" : "compose.compactFirst.keepHelp",
                         ContextMeter.tokensText(usage.usedTokens)))
            }
            if let onCompact = compact(snapshot) {
                SmallGhostButton(title: tr("compose.context.compact"), action: onCompact)
                    .padding(.leading, -10)
            }
        }
    }

    private func limitsPart(_ snapshot: SessionUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            title(tr("limits.title"), trailing: snapshot.account.isEmpty ? nil : snapshot.account)
            TimelineView(.nookTicks(every: 60)) { context in
                UsageLimitRows(limits: shown(snapshot.limits), now: context.date)
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

/// One bar across: each part of the window in its color (`ContextUsageCard.color`), the buffer dim, the free space empty.
struct ContextUsageBar: View {
    let usage: ContextUsage
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(usage.inWindow.filter { $0.kind != .free }) { category in
                    Rectangle().fill(ContextUsageCard.color(category))
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

/// "62% · 5h 38% · W 12%": the folded card's line, each number in its tone.
struct SessionUsageSummary: View {
    let snapshot: SessionUsageSnapshot

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let context = snapshot.context {
                ProgressRing(fraction: context.fraction, tint: snapshot.contextTint, lineWidth: 2)
                    .frame(width: 12, height: 12)
                Text(ContextMeter.percentText(context.fraction))
                    .foregroundStyle(snapshot.contextLevel == .normal ? NookTheme.textSecondary : snapshot.contextTint)
            }
            ForEach(snapshot.limitLines.indices, id: \.self) { index in
                let line = snapshot.limitLines[index]
                Text(line.short).foregroundStyle(NookTheme.textTertiary)
                    + Text(" \(line.used)%").foregroundStyle(UsageTone.level(used: line.used) == .calm ? NookTheme.textSecondary
                                                             : UsageTone.text(used: line.used))
            }
        }
        .font(NookTheme.TextStyle.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Without the docked panel: a ring in the header

/// Two rings in one: outside the context window, inside the short limit window (or, without a context, the short
/// window outside and the long one inside, as the limits chip had them). Quiet and without a number while all is
/// calm; the number of what needs attention comes beside it in amber or coral.
struct SessionUsageRing: View, Equatable {
    let snapshot: SessionUsageSnapshot
    var hovering = false

    private struct Ring { let fraction: Double; let tint: Color }

    private var rings: [Ring] {
        var rings: [Ring] = []
        if let context = snapshot.context { rings.append(Ring(fraction: context.fraction, tint: snapshot.contextTint)) }
        for line in snapshot.limitLines.prefix(rings.isEmpty ? 2 : 1) {
            rings.append(Ring(fraction: Double(line.used) / 100, tint: UsageTone.fill(used: line.used, calm: NookTheme.textSecondary)))
        }
        return rings
    }

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
            ZStack {
                ForEach(rings.indices, id: \.self) { index in
                    ProgressRing(fraction: rings[index].fraction, tint: rings[index].tint, lineWidth: 1.75)
                        .frame(width: index == 0 ? 15 : 9, height: index == 0 ? 15 : 9)
                }
            }
            .frame(width: 15, height: 15)
            if let number {
                Text(number.0).font(NookTheme.TextStyle.caption.monospacedDigit()).foregroundStyle(number.1)
                    .lineLimit(1).fixedSize()
            }
        }
    }
}

/// The ring in a session's header while the session panel is not docked beside it: click for the usage section in a
/// popover. Nothing when the session reports neither a context nor limits.
struct SessionUsageButton: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let source: SessionUsageSource
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let snapshot = SessionUsageSnapshot.read(source, app: app, workspace: workspace)
        if !snapshot.isEmpty {
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
            .help(snapshot.help)
            .accessibilityLabel(snapshot.help)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SessionUsagePopover(source: source) { open = false }
            }
        }
    }
}

/// The usage section on its own, as a popover from the header's ring or the composer's alert.
struct SessionUsagePopover: View {
    let source: SessionUsageSource
    let close: () -> Void

    var body: some View {
        SessionUsageSection(source: source, close: close)
            .padding(NookTheme.Spacing.lg)
            .frame(width: PanelLayout.sessionPanel, alignment: .leading)
    }
}

// MARK: - The composer: only what needs a decision

/// Beside send, only while something needs a decision: the context past the warning line (or set to be summarized
/// before your next message), or a limit from 90 %. Click for the usage section, with Summarize now. Nothing while
/// all is calm: the numbers are in the session panel.
struct ComposerUsageAlert: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let source: SessionUsageSource
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let snapshot = SessionUsageSnapshot.read(source, app: app, workspace: workspace)
        if let attention = snapshot.attention {
            let (text, tint, fraction) = Self.look(attention, snapshot)
            Button { open.toggle() } label: {
                HStack(spacing: NookTheme.Spacing.xs) {
                    ProgressRing(fraction: fraction, tint: tint, lineWidth: 2.5)
                        .frame(width: 18, height: 18)
                    Text(text)
                        .font(NookTheme.TextStyle.caption.monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, NookTheme.Spacing.sm)
                .frame(height: 28)
                .roundedBackground(hovering || open ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
            }
            .buttonStyle(.nookPlain)
            .composerTip(snapshot.help)
            .accessibilityLabel(snapshot.help)
            .popover(isPresented: $open, arrowEdge: .top) {
                SessionUsagePopover(source: source) { open = false }
            }
        }
    }

    /// "Summarize first · 84%" or "84%" for the context, "5h 94%" or "5h limit reached" for a limit.
    private static func look(_ attention: SessionUsageSnapshot.Attention, _ snapshot: SessionUsageSnapshot) -> (String, Color, Double) {
        switch attention {
        case .limit(let line):
            let text = line.used >= 100 ? tr("usage.alert.limitReached", line.short) : "\(line.short) \(line.used)%"
            return (text, UsageTone.text(used: line.used), Double(line.used) / 100)
        case .context:
            let fraction = snapshot.context?.fraction ?? 0
            let percent = ContextMeter.percentText(fraction)
            let text = snapshot.compactFirst == true ? tr("usage.alert.compactFirst", percent) : percent
            return (text, snapshot.contextTint, fraction)
        }
    }
}
