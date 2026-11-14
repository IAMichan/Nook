import SwiftUI

// Subscription limits, counted as Nook's composer counts them: how full a limit is ("38%
// used", a bar that fills), a line on the bar marks where even spending would be by now, color only once it gets full, and the details (reset
// time, pace) one hover or click away instead of in a footnote. Two shapes share these rules: `UsageLimitRows`, one line
// per window for one account (the composer's popover, Settings › Coding agents), and `UsageLimitsModal`, the modal with
// every agent's accounts as one pool per window.

extension QuotaLimit {
    var poolLimit: LimitPool.Limit { .init(label: label, used: percent, resetsAt: resetsAt, duration: duration) }
}

/// How full a limit is colored, as under the composer: calm while there is room, amber from 75 % used, coral from 90 %.
enum UsageTone {
    enum Level { case calm, warning, error }

    static func level(used: Int) -> Level {
        used >= 90 ? .error : (used >= 75 ? .warning : .calm)
    }

    /// A bar's fill; `calm` is what it takes while there is room.
    static func fill(used: Int, calm: Color = NookTheme.textStrong) -> Color {
        switch level(used: used) {
        case .calm: return calm
        case .warning: return NookTheme.amber
        case .error: return NookTheme.coral
        }
    }

    /// A percentage's text.
    static func text(used: Int) -> Color {
        switch level(used: used) {
        case .calm: return NookTheme.textStrong
        case .warning: return NookTheme.amber
        case .error: return NookTheme.coralSoft
        }
    }
}

/// Spending against the window's clock as a small symbol, its meaning in the tooltip.
struct LimitPaceIcon: View {
    let pace: LimitPool.Pace

    private var symbol: String {
        switch pace {
        case .ahead: return "chart.line.uptrend.xyaxis"
        case .on: return "gauge.with.dots.needle.50percent"
        case .under: return "chart.line.downtrend.xyaxis"
        }
    }

    var body: some View {
        Image(icon: symbol)
            .font(NookTheme.font(11, .medium))
            .foregroundStyle(NookTheme.textSecondary)
            .help(tr("limits.pace.\(pace.rawValue)"))
            .accessibilityLabel(tr("limits.pace.\(pace.rawValue)"))
    }
}

// MARK: - One account, one line per window

/// One account's windows, a line each: the window's name on the left, how much is used and when it resets on the right,
/// and under them a thin bar that fills, with a tick where even spending would be by now. The full reset time and the
/// pace are in the line's tooltip. An account that reports no limits shows one "Unavailable" line with the reason in its
/// tooltip.
struct UsageLimitRows: View {
    let limits: [QuotaLimit]
    /// Why there are no limits, shown when `limits` is empty.
    var unavailable: String?
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if limits.isEmpty {
                UsageLimitRow(label: tr("limits.limits"), limit: nil, now: now, help: unavailable ?? "")
            } else {
                // An agent with a quota per model ("Gemini 4 Pro · Week") gets the model as a heading over its windows,
                // so each line names only its window and the lines stay short.
                ForEach(QuotaLimit.grouped(limits), id: \.name) { group in
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        if !group.name.isEmpty {
                            Text(group.name)
                                .font(NookTheme.TextStyle.caption.weight(.semibold))
                                .foregroundStyle(NookTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.limits) { limit in
                            UsageLimitRow(label: group.name.isEmpty ? limit.label : limit.window, limit: limit, now: now,
                                          help: help(limit, used: Self.used(limit)))
                        }
                    }
                }
            }
        }
    }

    /// A window's percentage used, rounded as the pool rounds it, so 38.5 % used reads the same here and in the modal.
    static func used(_ limit: QuotaLimit) -> Int {
        100 - LimitPool.left(limit.percent)
    }

    /// "5 hours: 38% used", "Resets in 2h 14m · 17:30", "Ahead of pace".
    private func help(_ limit: QuotaLimit, used: Int) -> String {
        var lines = [tr("limits.rowUsed", limit.label, used)]
        if let note = limit.note {
            lines.append(note)
        } else if let reset = limit.resetsAt, reset > now {
            lines.append(tr("limits.resetsAt", AgentFormat.compactDuration(reset.timeIntervalSince(now)), AgentFormat.upcoming(reset, now: now)))
        }
        if let elapsed = LimitPool.timeElapsed(limit.poolLimit, now: now) {
            lines.append(tr("limits.windowElapsed", elapsed))
        }
        if let pace = LimitPool.pace(limit.poolLimit, now: now) {
            lines.append(tr("limits.pace.\(pace.rawValue).short"))
        }
        return lines.joined(separator: "\n")
    }
}

/// One line of `UsageLimitRows`: "5 hours        46%  ↻ 3h 36m" over a thin bar.
private struct UsageLimitRow: View {
    let label: String
    /// The window; nil for the "Unavailable" line, which has no bar.
    let limit: QuotaLimit?
    let now: Date
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                Text(label)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NookTheme.Spacing.sm)
                if let limit {
                    let used = UsageLimitRows.used(limit)
                    Text("\(used)%")
                        .font(NookTheme.TextStyle.detail.weight(.semibold).monospacedDigit())
                        .foregroundStyle(UsageTone.text(used: used))
                    if let reset = resetText(limit) ?? limit.note {
                        Text(reset)
                            .font(NookTheme.TextStyle.caption.monospacedDigit())
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else {
                    Text(tr("limits.unavailable"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            if let limit { LimitLineBar(limit: limit, now: now) }
        }
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help.isEmpty ? "\(label): \(tr("limits.unavailable"))" : help)
    }

    /// "↻ 3h 36m", "↻ now", or nil when the window has no reset time (it has not started yet).
    private func resetText(_ limit: QuotaLimit) -> String? {
        guard limit.note == nil, let reset = limit.resetsAt else { return nil }
        return "↻ " + (reset > now ? AgentFormat.compactDuration(reset.timeIntervalSince(now)) : tr("limits.now"))
    }
}

/// A limit's thin bar, as thin as the context's: what was used fills it in its tone, and a short tick stands where even
/// spending would be by now.
private struct LimitLineBar: View {
    let limit: QuotaLimit
    let now: Date
    private static let height: CGFloat = 4
    private static let tick: CGFloat = 10

    var body: some View {
        let used = UsageLimitRows.used(limit)
        let elapsed = LimitPool.timeElapsed(limit.poolLimit, now: now)
        GeometryReader { proxy in
            let width = proxy.size.width
            Bar(fraction: Double(used) / 100, color: UsageTone.fill(used: used, calm: NookTheme.textSecondary),
                height: Self.height, minFill: used > 0 ? Self.height : 0)
                .frame(maxHeight: .infinity)
            if let elapsed, width >= 6 {
                Capsule()
                    .fill(NookTheme.paper)
                    .frame(width: 2, height: Self.tick)
                    .offset(x: LimitSegmentPosition.at(elapsed, width: width) - 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(height: Self.tick)
    }
}

// MARK: - Compact, beside a row

extension QuotaLimit {
    /// One limit per window ("5 hours", "Week"), for a place with room for only a few: a model group's windows when the
    /// model is named (Antigravity's "Gemini 4 Pro · Week"), otherwise the fullest of each window across the groups.
    static func perWindow(_ limits: [QuotaLimit], model: String = "") -> [QuotaLimit] {
        let named = model.isEmpty ? [] : limits.filter { limit in
            limit.group.map { model.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(model) } ?? false
        }
        var result: [QuotaLimit] = []
        for limit in named.isEmpty ? limits : named {
            var item = limit
            item.label = limit.window
            if let index = result.firstIndex(where: { $0.label == item.label }) {
                if item.percent > result[index].percent { result[index] = item }
            } else {
                result.append(item)
            }
        }
        return result
    }
}

/// An account's windows side by side, small enough to sit in a row: per window its name and percentage used above a
/// thin bar, and under it when the window resets. The full reset time and pace are in its tooltip. The usage limit
/// card's header and its accounts to go on with use it; never draw a lone usage bar in a row instead.
struct LimitWindowMeters: View {
    let limits: [QuotaLimit]
    /// What the bar takes while there is room.
    var calm: Color = NookTheme.mint

    static let meterWidth: CGFloat = 78

    var body: some View {
        TimelineView(.nookTicks(every: 30)) { context in
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                if limits.isEmpty {
                    meter(label: tr("limits.limits"), limit: nil, now: context.date)
                } else {
                    ForEach(limits) { meter(label: $0.label, limit: $0, now: context.date) }
                }
            }
        }
    }

    private func meter(label: String, limit: QuotaLimit?, now: Date) -> some View {
        let used = limit.map(UsageLimitRows.used)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                Text(label)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(used.map { "\($0)%" } ?? "–")
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(used.map { UsageTone.text(used: $0) } ?? NookTheme.textTertiary)
            }
            Bar(fraction: Double(used ?? 0) / 100, color: used.map { UsageTone.fill(used: $0, calm: calm) } ?? NookTheme.textTertiary)
                .opacity(used == nil ? 0.5 : 1)
            Text(resetWords(limit, now: now))
                .monospacedDigit()
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
        }
        .font(NookTheme.TextStyle.caption)
        .frame(width: Self.meterWidth, alignment: .leading)
        .help(help(label: label, limit: limit, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help(label: label, limit: limit, now: now))
    }

    /// "↻ 2h 13m", "↻ now", or nothing when the window has no reset time (it has not started yet).
    private func resetWords(_ limit: QuotaLimit?, now: Date) -> String {
        guard let limit, limit.note == nil, let reset = limit.resetsAt else { return " " }
        return "↻ " + (reset > now ? AgentFormat.compactDuration(reset.timeIntervalSince(now)) : tr("limits.now"))
    }

    /// "Week: 62% used", "Resets in 2d 3h · Thu 17:30", the pace.
    private func help(label: String, limit: QuotaLimit?, now: Date) -> String {
        guard let limit else { return tr("ws.limit.usedUnknown") }
        var lines = [tr("limits.rowUsed", label, UsageLimitRows.used(limit))]
        if let note = limit.note {
            lines.append(note)
        } else if let reset = limit.resetsAt, reset > now {
            lines.append(tr("limits.resetsAt", AgentFormat.compactDuration(reset.timeIntervalSince(now)), AgentFormat.upcoming(reset, now: now)))
        }
        if let pace = LimitPool.pace(limit.poolLimit, now: now) {
            lines.append(tr("limits.pace.\(pace.rawValue).short"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Where a share of a bar's width lies, kept 3 pt inside its ends: the even-pace line of the modal's bars and the
/// composer's cards alike.
enum LimitSegmentPosition {
    static func at(_ percent: Int, width: CGFloat) -> CGFloat {
        min(max(3, width * CGFloat(percent) / 100), max(3, width - 3))
    }
}

// MARK: - The modal

/// What the sheet knows about an account beyond its limits.
struct LimitAccountDetails: Equatable {
    var email: String?
    var plan: String?
    /// Banked reset credits (Codex).
    var credits: Int = 0
}

/// One agent's accounts as a pool, with what the sheet shows about each account.
struct UsageLimitSection: Identifiable, Equatable {
    var kind: AgentKind
    var pool: LimitPool
    var details: [String: LimitAccountDetails]
    /// The recent session windows (the 5 hours) of every account of the pool, newest first, with the chats in them.
    var blocks: [UsageBlock] = []
    var id: String { kind.rawValue }
}

extension UsageLimitSection {
    /// Every connected agent with limits, in the order of `AgentKind`, and a notice for each account that reports none.
    /// The agents in `hidden` (the modal's agent filter) are left out.
    @MainActor
    static func make(_ app: AppModel, now: Date, hidden: Set<String> = []) -> (sections: [UsageLimitSection], notices: [String]) {
        let byKind = Dictionary(grouping: app.connectedProfiles.filter { !hidden.contains($0.kind.rawValue) }, by: \.kind)
        let prices = UsagePrices.load()
        var sections: [UsageLimitSection] = []
        var notices: [String] = []
        for kind in AgentKind.allCases {
            guard let profiles = byKind[kind] else { continue }
            var details: [String: LimitAccountDetails] = [:]
            var blocks: [UsageBlock] = []
            let accounts = profiles.map { profile -> LimitPool.Account in
                let account = app.history.profileAccounts[profile.id]
                let plan = account.map(\.plan).flatMap { $0.isEmpty ? nil : $0 } ?? app.quota.codexPlan(for: profile)
                details[profile.id] = LimitAccountDetails(email: account.map(\.name).flatMap { $0.contains("@") ? $0 : nil },
                                                          plan: plan.isEmpty ? nil : plan,
                                                          credits: app.quota.resetCredits(for: profile)?.available ?? 0)
                let limits = app.quota.limits(for: profile)
                if limits.isEmpty {
                    notices.append(tr("limits.notice", "\(kind.name) · \(AccountLabel.name(profile, app: app))", unavailableReason(profile, app: app)))
                }
                // The session window (the 5 hours): when it started, and which chats used it.
                if let session = limits.first(where: { LimitPool.Kind(duration: $0.duration) == .session }), let duration = session.duration {
                    let anchor = session.resetsAt.flatMap { $0 > now ? $0.addingTimeInterval(-duration) : nil }
                    blocks += UsageBlocks.make(app.history.ledger, profile: profile.id, duration: duration, anchor: anchor, now: now,
                                               prices: prices)
                }
                let weights = LimitPool.weights(agent: kind.rawValue, plan: plan)
                return LimitPool.Account(id: profile.id, name: AccountLabel.name(profile, app: app), limits: limits.map(\.poolLimit),
                                         sessionWeight: weights.session, weeklyWeight: weights.weekly)
            }
            if let pool = LimitPool.make(accounts, now: now) {
                blocks.sort { $0.start > $1.start }
                sections.append(UsageLimitSection(kind: kind, pool: pool, details: details, blocks: blocks))
            }
        }
        return (sections, notices)
    }

    /// Why an account shows no limits.
    @MainActor
    static func unavailableReason(_ profile: AgentProfile, app: AppModel) -> String {
        switch profile.kind {
        case .claude: return tr("settings.usage.claudeMissing")
        case .codex: return tr("ws.usage.quotaUnavailable")
        case .gemini: return tr("agents.usage.geminiNoLimits")
        case .opencode, .cursor, .grok, .pi, .acp: return tr("agents.usage.acpNoLimits")
        case .antigravity: return app.antigravityUsage.noLogin ? tr("agents.usage.antigravityNoToken") : tr("ws.usage.quotaUnavailable")
        }
    }

    /// The agent's own page of its plan's usage, where you see and buy more of it; nil when it has none.
    static func usagePage(_ kind: AgentKind) -> URL? {
        switch kind {
        case .claude: return URL(string: "https://claude.ai/settings/usage")
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp: return nil
        }
    }
}

/// The agents the usage modal leaves out (its filter), kept as their raw values, comma separated.
enum UsageHiddenAgents {
    static let storageKey = "usage.modal.hiddenAgents"

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }
}

/// Which part of the usage modal shows: what the agents on this Mac would cost at API prices, their tokens, or the
/// subscription limits. Remembered; "All limits" opens it on Limits.
enum UsageModalTab: String, CaseIterable, Hashable {
    case cost, tokens, limits

    static let storageKey = "usage.modal.tab"
}

/// Usage as a modal: Cost and Tokens show every agent's usage on this Mac (`UsageInsightsPanel`), and
/// Limits shows the usage limits of every connected account: per agent, a card per window with how much of the pool is used
/// in large type and its pace, beside a bar with a segment per account. The one component for every way in: the footer's
/// usage button bottom left, "All limits" under the composer's ring, the command palette and search (over the panel,
/// `UsageModal`) and Settings › Coding agents (as a sheet).
struct UsageLimitsModal: View {
    @EnvironmentObject private var app: AppModel
    let close: () -> Void
    @AppStorage(UsageModalTab.storageKey) private var tabRaw = UsageModalTab.limits.rawValue
    @AppStorage("usage.window") private var windowRaw = UsageWindow.week.rawValue
    @AppStorage(UsageHiddenAgents.storageKey) private var hiddenRaw = ""

    private var tab: UsageModalTab { UsageModalTab(rawValue: tabRaw) ?? .limits }
    private var hidden: Set<String> { UsageHiddenAgents.decode(hiddenRaw) }
    private var window: UsageWindow { UsageWindow(rawValue: windowRaw) ?? .week }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title, then Cost, Tokens and Limits as one segmented control, the range for Cost and
            // Tokens as a second one beside it (on a line of its own when the modal is too narrow), refresh and close.
            ViewThatFits(in: .horizontal) {
                header(range: true)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    header(range: false)
                    if tab != .limits { rangePicker }
                }
            }
            .padding(.horizontal, NookTheme.Spacing.xxl)
            .padding(.vertical, NookTheme.Spacing.lg)
            NookDivider()

            ScrollView(showsIndicators: false) {
                Group {
                    switch tab {
                    case .limits:
                        // Once a minute the reset times count down and the pace line moves on.
                        TimelineView(.nookTicks(every: 60)) { context in
                            let read = UsageLimitSection.make(app, now: context.date, hidden: hidden)
                            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxxl) {
                                UsageLimitPools(sections: read.sections, notices: read.notices, now: context.date)
                                if !app.cliProxy.hubs.isEmpty { hubs(now: context.date) }
                                credits
                            }
                        }
                    case .cost, .tokens:
                        UsageInsightsPanel(history: app.history, metric: tab == .cost ? .cost : .tokens, window: window, hidden: hidden)
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xxl)
                .padding(.vertical, NookTheme.Spacing.xl)
            }
        }
        .frame(maxWidth: 720)
        .frame(minHeight: 320, idealHeight: 560, maxHeight: 760)
        .background(NookTheme.surface)
        .background(tabShortcuts)
        .task { await app.watchQuotas() }
    }

    /// ⌘1, ⌘2 and ⌘3 switch between Cost, Tokens and Limits, in the order of the tabs.
    private var tabShortcuts: some View {
        ZStack {
            ForEach(Array(UsageModalTab.allCases.enumerated()), id: \.element) { index, value in
                Button("") { withAnimation(NookTheme.swap) { tabRaw = value.rawValue } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .buttonStyle(.nookPlain)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The agents that can show anything here: connected ones and the ones with usage on this Mac.
    private var filterableAgents: [AgentKind] {
        let connected = Set(app.connectedProfiles.map(\.kind))
        let used = Set(app.history.ledger.sessionEnds.keys)
        return AgentKind.allCases.filter { connected.contains($0) || used.contains($0.rawValue) || hidden.contains($0.rawValue) }
    }

    /// Which agents the modal shows, for every tab; lit while it hides any.
    private var agentFilter: some View {
        ComposerDropdown(width: 240) {
            PanelHeaderIcon(symbol: "line.3.horizontal.decrease", active: !hidden.isEmpty)
        } content: {
            DropdownHeader(title: tr("usage.filter.agents"))
            ForEach(filterableAgents) { kind in
                let shown = !hidden.contains(kind.rawValue)
                DropdownRow(agent: kind.rawValue, title: kind.name, trailing: shown ? "✓" : nil, chosen: shown, staysOpen: true) {
                    var next = hidden
                    if shown { next.insert(kind.rawValue) } else { next.remove(kind.rawValue) }
                    withAnimation(NookTheme.reveal) { hiddenRaw = UsageHiddenAgents.encode(next) }
                }
            }
            if !hidden.isEmpty {
                DropdownRow(symbol: "eye", title: tr("usage.filter.showAll"), staysOpen: true) {
                    withAnimation(NookTheme.reveal) { hiddenRaw = "" }
                }
            }
        }
        .help(tr("usage.filter.agents"))
        .accessibilityLabel(tr("usage.filter.agents"))
    }

    private func header(range: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            Text(tr("agents.footer.usage"))
                .font(NookTheme.TextStyle.heading)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: NookTheme.Spacing.md)
            NookTabBar<UsageModalTab>(items: [
                .init(value: .cost, title: tr("usage.metric.cost")),
                .init(value: .tokens, title: tr("usage.metric.tokens")),
                .init(value: .limits, title: tr("limits.limits")),
            ], selected: tab, onSelect: { value in withAnimation(NookTheme.swap) { tabRaw = value.rawValue } }, segmented: true)
                .fixedSize()
            if range && tab != .limits { rangePicker }
            agentFilter
            UsageRefreshButton()
            NookIconButton(systemName: "xmark", label: tr("button.close"), size: 30, action: close)
                .keyboardShortcut(.cancelAction)
        }
    }

    /// The range Cost and Tokens count over: 24 hours, 7, 30 or 90 days.
    private var rangePicker: some View {
        NookTabBar<UsageWindow>(items: UsageWindow.allCases.map { .init(value: $0, title: tr("usage.window." + $0.rawValue)) },
                                selected: window, onSelect: { value in withAnimation(NookTheme.swap) { windowRaw = value.rawValue } },
                                segmented: true)
            .fixedSize()
    }

    /// The CLIProxyAPI hubs and the accounts they pool; they are added and removed in Settings.
    private func hubs(now: Date) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            Text(tr("cliproxy.title"))
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
            CLIProxyHubsList(usage: app.cliProxy, editable: false, now: now)
        }
    }

    /// Reset credits are spent after a confirmation, so they stay out of the bar's popovers.
    @ViewBuilder private var credits: some View {
        let holders = app.connectedProfiles.filter { (app.quota.resetCredits(for: $0)?.available ?? 0) > 0 }
        if !holders.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                ForEach(holders) { profile in
                    HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                        AgentLogo(profile.kind, size: 16)
                        ResetCreditRow(profile: profile)
                    }
                }
            }
        }
    }
}

/// `UsageLimitsModal` over the panel, in the notch and the main window alike: the panel dims behind it, and a click
/// beside it or Escape closes it. `AppModel.usageModalOpen` opens it.
struct UsageModal: View {
    let close: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityHidden(true)
                UsageLimitsModal(close: close)
                    .frame(width: min(720, max(0, proxy.size.width - 2 * NookTheme.Spacing.xxl)))
                    .frame(maxHeight: max(0, proxy.size.height - 2 * NookTheme.Spacing.xxl))
                    .fixedSize(horizontal: false, vertical: true)
                    .roundedClip(NookTheme.Radius.sheet)
                    .roundedStroke(NookTheme.line2, radius: NookTheme.Radius.sheet)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Reads the limits of every account now, in the head of the usage limits modal and Settings › Coding agents. Shows a
/// small spinner until Claude Code has answered.
struct UsageRefreshButton: View {
    @EnvironmentObject private var app: AppModel
    @State private var refreshing = false

    var body: some View {
        if refreshing {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 24, height: 24)
                .help(tr("agents.usage.refreshing"))
        } else {
            ToolbarIconButton("arrow.clockwise", tr("agents.usage.refresh")) {
                refreshing = true
                Task {
                    await app.refreshQuotasManually()
                    refreshing = false
                }
            }
        }
    }
}

/// The sheet's content without the app around it: the sections, then the notices of accounts without limits.
struct UsageLimitPools: View {
    let sections: [UsageLimitSection]
    let notices: [String]
    let now: Date
    @StateObject private var focus = LimitDetailsFocus()

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxxl) {
            if sections.isEmpty && notices.isEmpty {
                Text(tr("limits.none"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(sections) { section in
                LimitPoolSectionView(section: section, now: now)
            }
            .environmentObject(focus)
            if !notices.isEmpty {
                HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                    Image(icon: "exclamationmark.triangle")
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.amber)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                        ForEach(notices, id: \.self) { notice in
                            Text(notice).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    Spacer(minLength: 0)
                }
                .padding(NookTheme.Spacing.lg)
                .cardBackground(NookTheme.amber.opacity(0.08), stroke: NookTheme.amber.opacity(0.3), radius: NookTheme.Radius.card)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One agent: its logo and name over a card per window.
private struct LimitPoolSectionView: View {
    let section: UsageLimitSection
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.md) {
                AgentLogo(section.kind, size: 18)
                Text(section.kind.name)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Spacer(minLength: NookTheme.Spacing.md)
                // The agent's own usage page, where the plan's usage is managed and more of it bought.
                if let page = UsageLimitSection.usagePage(section.kind) {
                    SmallGhostButton(title: tr("limits.manage") + " ↗") { NSWorkspace.shared.open(page) }
                        .help(page.host ?? page.absoluteString)
                }
            }
            ForEach(section.pool.windows) { window in
                LimitWindowCard(window: window, section: section, now: now)
            }
            if !section.blocks.isEmpty {
                UsageBlockRows(blocks: section.blocks, names: section.pool.accounts.reduce(into: [:]) { $0[$1.id] = $1.name },
                               now: now)
            }
        }
    }
}

/// The session windows of an agent's accounts, newest first: when each started and ran out, what it used and, opened,
/// which chats used it, so a window that ran out early can be traced back to the chat behind it.
private struct UsageBlockRows: View {
    let blocks: [UsageBlock]
    let names: [String: String]
    let now: Date
    @State private var expanded: Set<String> = []
    @State private var all = false

    var body: some View {
        let shown = all ? blocks : Array(blocks.prefix(4))
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("limits.blocks"))
                .font(NookTheme.TextStyle.detail.weight(.medium))
                .foregroundStyle(NookTheme.textSecondary)
            VStack(spacing: 0) {
                ForEach(shown) { block in
                    row(block)
                }
            }
            .cardBackground(Color.clear, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
            if blocks.count > 4 {
                Button(all ? tr("usage.chats.fewer") : tr("usage.chats.more", blocks.count - 4)) {
                    withAnimation(NookTheme.swap) { all.toggle() }
                }
                .buttonStyle(.nookPlain)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
            }
            Text(tr("limits.blocks.footer"))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ block: UsageBlock) -> some View {
        let open = expanded.contains(block.id)
        return VStack(spacing: 0) {
            Button {
                withAnimation(NookTheme.swap) { if open { expanded.remove(block.id) } else { expanded.insert(block.id) } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                    DisclosureChevron(open: open, size: 10, weight: .semibold)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            Text(tr("limits.block.started", AgentFormat.upcoming(block.start, now: now)))
                                .font(NookTheme.TextStyle.body.weight(.medium))
                                .foregroundStyle(NookTheme.paper)
                            if block.active {
                                NookTag(tr("limits.block.running"))
                            }
                        }
                        Text(detail(block))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: NookTheme.Spacing.md)
                    VStack(alignment: .trailing, spacing: NookTheme.Spacing.xxs) {
                        Text(UsageFormat.usd(block.cost))
                            .font(NookTheme.TextStyle.strong.monospacedDigit())
                            .foregroundStyle(NookTheme.paper)
                        Text(tr("usage.chatCount", block.chats.count))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(block.reported ? tr("limits.block.reported") : tr("limits.block.estimated"))
            if open {
                VStack(spacing: 0) {
                    if block.chats.isEmpty {
                        ListEmptyNote(tr("limits.block.empty"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, NookTheme.Spacing.md)
                    }
                    ForEach(block.chats.prefix(10)) { chat in
                        UsageChatRow(chat: chat, compact: true)
                    }
                }
                .padding(.leading, NookTheme.Spacing.lg + 12 + NookTheme.Spacing.md)
                .padding(.trailing, NookTheme.Spacing.lg)
            }
            NookDivider()
        }
    }

    /// "until 19:32 · Work" — when the window ran or runs out, and the account when the agent has several.
    private func detail(_ block: UsageBlock) -> String {
        var parts = [tr(block.active ? "limits.block.until" : "limits.block.ended", AgentFormat.upcoming(block.end, now: now))]
        if names.count > 1, let name = names[block.profileID] { parts.append(name) }
        parts.append(UsageFormat.tokens(block.tokens.total))
        return parts.joined(separator: " · ")
    }
}

/// One window of the pool: its name, how much is used in large type with the pace, and what the next reset frees when the pool has
/// several accounts, beside the bar.
private struct LimitWindowCard: View {
    let window: LimitPool.Window
    let section: UsageLimitSection
    let now: Date

    /// The narrowest the bar can be beside the summary; narrower, it goes under it, across the whole card.
    private static let barBeside: CGFloat = 280

    var body: some View {
        // Beside each other when the card is wide enough, else the summary over the bar.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: NookTheme.Spacing.xxl) {
                summary.frame(width: 176, alignment: .leading)
                LimitPoolBar(window: window, section: section, now: now)
                    .frame(minWidth: Self.barBeside)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                summary
                LimitPoolBar(window: window, section: section, now: now)
            }
        }
        .padding(NookTheme.Spacing.xl)
        .cardBackground(Color.clear, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(window.label)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Text("\(window.used)%")
                    .font(NookTheme.font(30, .semibold).monospacedDigit())
                    .foregroundStyle(NookTheme.paper)
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr("limits.usedWord"))
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textSecondary)
                    if let pace = window.pace { LimitPaceIcon(pace: pace) }
                }
            }
            if window.columns.count > 1, let refill = window.nextRefill {
                Text(tr("limits.refill", refill.restores))
                    .font(NookTheme.TextStyle.label.monospacedDigit())
                    .foregroundStyle(NookTheme.paper)
            }
        }
    }
}

/// The pool's bar: a segment per account side by side. Wide enough, each segment names its account and carries its reset;
/// narrow, the segments show a number and a legend under them names them.
private struct LimitPoolBar: View {
    let window: LimitPool.Window
    let section: UsageLimitSection
    let now: Date
    /// The narrowest a segment can be and still hold its name and reset.
    private static let wideSegment: CGFloat = 132

    var body: some View {
        let showNames = window.columns.count > 1
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(Array(window.columns.enumerated()), id: \.element.id) { index, member in
                    LimitSegment(member: member, window: window, section: section, now: now, index: index + 1, wide: true, showName: showNames)
                        .frame(minWidth: Self.wideSegment, maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    ForEach(Array(window.columns.enumerated()), id: \.element.id) { index, member in
                        LimitSegment(member: member, window: window, section: section, now: now, index: index + 1, wide: false, showName: showNames)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(window.columns.enumerated()), id: \.element.id) { index, member in
                    if member.limit != nil {
                        LimitLegendRow(member: member, window: window, section: section, now: now, index: index + 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One account's part of the pool bar. What was used fills it in the agent's color, hatched where the account's next
/// reset frees only part of it, and the even-pace line sits in a slot cut from the bar. Click for the account's details.
private struct LimitSegment: View {
    let member: LimitPool.Member
    let window: LimitPool.Window
    let section: UsageLimitSection
    let now: Date
    let index: Int
    let wide: Bool
    let showName: Bool
    @EnvironmentObject private var focus: LimitDetailsFocus
    @State private var hovering = false

    private var focusID: String { "\(section.id)|\(window.id)|\(member.accountID)|\(wide ? "bar" : "narrow")" }

    var body: some View {
        let open = focus.open == focusID
        if let limit = member.limit, let used = member.used {
            let color = section.kind.color
            let elapsed = LimitPool.timeElapsed(limit, now: now)
            let reset = window.resets.first { $0.accountID == member.accountID }
            let resetsIn = AgentFormat.resetsIn(limit.resetsAt, now: now)
            let credits = section.details[member.accountID]?.credits ?? 0
            Button { focus.click(focusID) } label: {
                ZStack(alignment: .leading) {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            Rectangle().fill(NookTheme.wash.opacity(0.05))
                            // A reset usually frees all that was used. Only when it frees part of it (a spent week
                            // holds the session window) is that part hatched, so the rest reads as still blocked.
                            // Compared on the unrounded share: `used` is rounded for display, so 8.6 % used shows as
                            // 9 % and would otherwise read as a reset that frees only 8.6 of it.
                            let freed = reset != nil ? min(limit.used, member.refill) : 0
                            let partial = freed > 0 && limit.used - freed >= 0.5
                            let hatched = partial ? min(freed, Double(used)) : 0
                            Rectangle()
                                .fill(color.opacity(0.35))
                                .frame(width: width * CGFloat(Double(used) - hatched) / 100)
                            if partial {
                                LimitHatch(color: color)
                                    .opacity(0.45)
                                    .frame(width: width * CGFloat(hatched) / 100)
                                    .offset(x: width * CGFloat(Double(used) - hatched) / 100)
                            }
                        }
                        .mask(PaceSlot(at: elapsed.map { LimitSegmentPosition.at($0, width: width) }))
                        if let elapsed, width >= 6 {
                            Capsule()
                                .fill(NookTheme.paper)
                                .frame(width: 2)
                                .padding(.vertical, NookTheme.Spacing.xxs)
                                .offset(x: LimitSegmentPosition.at(elapsed, width: width) - 1)
                        }
                    }
                    if wide {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            if showName {
                                Text(member.name)
                                    .font(NookTheme.TextStyle.detail.weight(.medium))
                                    .foregroundStyle(NookTheme.paper)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(used)%")
                                    .font(NookTheme.TextStyle.detail.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(NookTheme.paper)
                                    .fixedSize()
                            }
                            Spacer(minLength: 0)
                            if resetsIn != nil || credits > 0 {
                                LimitResetChip(resetsIn: limit.resetsAt.map { $0 > now ? AgentFormat.compactDuration($0.timeIntervalSince(now)) : tr("limits.now") },
                                               credits: credits)
                                    .layoutPriority(1)
                            }
                        }
                        .padding(.horizontal, NookTheme.Spacing.md)
                    } else {
                        Text("\(index)")
                            .font(NookTheme.TextStyle.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NookTheme.textStrong)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: wide ? 32 : 20)
                .roundedClip(NookTheme.Radius.chip)
                .roundedStroke(open || hovering ? NookTheme.line2 : Color.clear, radius: NookTheme.Radius.chip)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .onHover { inside in
                hovering = inside
                focus.hover(focusID, inside)
            }
            .accessibilityLabel(summary(used: used, elapsed: elapsed, resetsIn: resetsIn, credits: credits))
            .popover(isPresented: focus.binding(focusID), arrowEdge: .top) {
                LimitSegmentDetails(kind: section.kind, member: member, window: window, details: section.details[member.accountID],
                                    reset: reset, now: now)
                    .onHover { focus.hoverDetails($0) }
            }
        } else {
            // The account does not report this window: an empty column, so the others stay in place.
            Color.clear.frame(height: wide ? 32 : 20)
        }
    }

    private func summary(used: Int, elapsed: Int?, resetsIn: String?, credits: Int) -> String {
        var parts = [tr("limits.segment", member.name, used)]
        if let resetsIn { parts.append(resetsIn) }
        if let elapsed { parts.append(tr("limits.windowElapsed", elapsed)) }
        if credits > 0 { parts.append(tr("agents.reset.credits", credits)) }
        return parts.joined(separator: ", ")
    }
}

/// The reset at the end of a wide segment, "↻ 2h 14m", with the banked reset credits after it.
private struct LimitResetChip: View {
    let resetsIn: String?
    let credits: Int

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let resetsIn { Text("↻ \(resetsIn)") }
            if resetsIn != nil && credits > 0 {
                Text("·").foregroundStyle(NookTheme.textSecondary)
            }
            if credits > 0 {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    Image(icon: "ticket")
                    Text("\(credits)")
                }
                .fontWeight(.semibold)
            }
        }
        .font(NookTheme.TextStyle.caption.monospacedDigit())
        .foregroundStyle(NookTheme.paper)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.xxs)
        .roundedBackground(NookTheme.canvas.opacity(0.85), radius: NookTheme.Radius.chip / 2)
    }
}

/// A narrow bar's legend: a row per account with its number, name, how much it used and its reset. Click for its details.
private struct LimitLegendRow: View {
    let member: LimitPool.Member
    let window: LimitPool.Window
    let section: UsageLimitSection
    let now: Date
    let index: Int
    @EnvironmentObject private var focus: LimitDetailsFocus
    @State private var hovering = false

    private var focusID: String { "\(section.id)|\(window.id)|\(member.accountID)|legend" }

    var body: some View {
        let credits = section.details[member.accountID]?.credits ?? 0
        let open = focus.open == focusID
        Button { focus.click(focusID) } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text("\(index)")
                    .font(NookTheme.TextStyle.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NookTheme.textStrong)
                    .frame(width: 16, height: 16)
                    .roundedBackground(section.kind.color.opacity(0.35), radius: NookTheme.Radius.chip / 2)
                Text(member.name)
                    .font(NookTheme.TextStyle.detail.weight(.medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text("\(member.used ?? 0)%")
                    .font(NookTheme.TextStyle.detail.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NookTheme.paper)
                Spacer(minLength: NookTheme.Spacing.sm)
                HStack(spacing: NookTheme.Spacing.sm) {
                    if let reset = member.limit?.resetsAt {
                        Text("↻ " + (reset > now ? AgentFormat.compactDuration(reset.timeIntervalSince(now)) : tr("limits.now")))
                    }
                    if credits > 0 {
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            Image(icon: "ticket")
                            Text("\(credits)")
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(NookTheme.paper)
                    }
                }
                .font(NookTheme.TextStyle.caption.monospacedDigit())
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 26)
            .roundedBackground(hovering || open ? NookTheme.wash.opacity(0.08) : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { inside in
            hovering = inside
            focus.hover(focusID, inside)
        }
        .popover(isPresented: focus.binding(focusID), arrowEdge: .top) {
            LimitSegmentDetails(kind: section.kind, member: member, window: window, details: section.details[member.accountID],
                                reset: window.resets.first { $0.accountID == member.accountID }, now: now)
                .onHover { focus.hoverDetails($0) }
        }
    }
}

/// An account's details in one window: who it is, its plan, how much it used, when it resets, where even spending would
/// be and what the reset frees in the pool.
private struct LimitSegmentDetails: View {
    let kind: AgentKind
    let member: LimitPool.Member
    let window: LimitPool.Window
    let details: LimitAccountDetails?
    let reset: LimitPool.Reset?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md + NookTheme.Spacing.xxs) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    AgentLogo(kind, size: 16)
                    Text(member.name)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                }
                if let email = details?.email {
                    RedactedText(value: email)
                }
            }
            if let plan = details?.plan {
                group { row(tr("limits.row.plan"), plan) }
            }
            group {
                row(tr("limits.row.used"), "\(member.used ?? 0)%")
                if let at = member.limit?.resetsAt {
                    row(tr("limits.row.resets"), at > now
                        ? "\(AgentFormat.upcoming(at, now: now)) · \(tr("limits.in", AgentFormat.compactDuration(at.timeIntervalSince(now))))"
                        : tr("limits.resetsNow"))
                }
                if let limit = member.limit, let elapsed = LimitPool.timeElapsed(limit, now: now) {
                    row(tr("limits.row.evenPace"), tr("limits.row.evenPaceValue", elapsed))
                }
                if let reset, reset.restores > 0, window.columns.count > 1 {
                    row(tr("limits.row.restores"), tr("limits.row.restoresValue", reset.restores))
                }
            }
            if member.limit.flatMap({ LimitPool.timeLeft($0, now: now) }) != nil {
                Text(tr("limits.paceLine"))
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(NookTheme.TextStyle.detail)
        .padding(NookTheme.Spacing.lg)
        .frame(width: 288, alignment: .leading)
    }

    /// A block of rows under a hairline.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            NookDivider()
                .padding(.bottom, NookTheme.Spacing.sm)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.lg) {
            Text(label)
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .foregroundStyle(NookTheme.paper)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An address hidden until clicked, so the sheet can be on screen while you share it.
private struct RedactedText: View {
    let value: String
    @State private var revealed = false

    var body: some View {
        Button { revealed.toggle() } label: {
            Text(value)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .blur(radius: revealed ? 0 : 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .help(revealed ? tr("limits.hide") : tr("limits.reveal"))
        .accessibilityLabel(revealed ? value : tr("limits.reveal"))
    }
}

/// The diagonal lines that mark what a coming reset gives back.
private struct LimitHatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// A mask that keeps the whole bar but a 6 pt slot around the even-pace line.
private struct PaceSlot: View {
    let at: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            if let at {
                Path { path in
                    path.addRect(CGRect(x: -1, y: -1, width: max(0, at - 3) + 1, height: proxy.size.height + 2))
                    path.addRect(CGRect(x: at + 3, y: -1, width: max(0, proxy.size.width - at - 3) + 1, height: proxy.size.height + 2))
                }
                .fill(Color.white)
            } else {
                Rectangle().fill(Color.white)
            }
        }
    }
}

/// Which account's details are open in the limits modal: one at a time, as one popover that moves along the bars.
/// Hovering a segment opens its details after a moment, and moving on to the next segment moves them there at once;
/// leaving the segment and its details closes them again, unless they were opened with a click.
@MainActor
final class LimitDetailsFocus: ObservableObject {
    @Published private(set) var open: String?
    private var pinned = false
    private var overDetails = false
    private var pending: Task<Void, Never>?

    func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.open == id }, set: { [weak self] shown in
            guard let self else { return }
            if shown {
                self.open = id
            } else if self.open == id {
                self.close()
            }
        })
    }

    func hover(_ id: String, _ inside: Bool) {
        guard !pinned else { return }
        pending?.cancel()
        if !inside {
            closeSoon()
        } else if open != nil {
            open = id
        } else {
            pending = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                self?.open = id
            }
        }
    }

    /// A click keeps the details open until you click again or beside them.
    func click(_ id: String) {
        pending?.cancel()
        if open == id && pinned {
            close()
        } else {
            open = id
            pinned = true
        }
    }

    func hoverDetails(_ inside: Bool) {
        overDetails = inside
        guard !pinned else { return }
        pending?.cancel()
        if !inside { closeSoon() }
    }

    private func closeSoon() {
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, !self.overDetails, !self.pinned else { return }
            self.open = nil
        }
    }

    private func close() {
        pending?.cancel()
        open = nil
        pinned = false
        overDetails = false
    }
}
