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

/// One account's windows, a small card each in the usage modal's layout: the window's name, how much is used with the
/// pace, and a bar that fills with the even-pace line in a slot and the reset time inside it. The full reset time and
/// the pace are in the card's tooltip; the card lights up under the pointer. An account that reports no limits shows
/// one "Unavailable" card with the reason in its tooltip.
struct UsageLimitRows: View {
    let limits: [QuotaLimit]
    /// Why there are no limits, shown when `limits` is empty.
    var unavailable: String?
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if limits.isEmpty {
                UsageLimitRow(label: tr("limits.limits"), limit: nil, now: now, help: unavailable ?? "")
            } else {
                ForEach(limits) { limit in
                    UsageLimitRow(label: limit.label, limit: limit, now: now, help: help(limit, used: Self.used(limit)))
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

/// One card of `UsageLimitRows`, a small `LimitWindowCard`: name and percentage used above, the bar under them.
private struct UsageLimitRow: View {
    let label: String
    /// The window; nil for the "Unavailable" card, which has no bar.
    let limit: QuotaLimit?
    let now: Date
    let help: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Text(label)
                    .font(NookTheme.TextStyle.detail.weight(.medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NookTheme.Spacing.sm)
                if let limit {
                    let used = UsageLimitRows.used(limit)
                    if let pace = LimitPool.pace(limit.poolLimit, now: now) { LimitPaceIcon(pace: pace) }
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                        Text("\(used)%")
                            .font(NookTheme.TextStyle.strong.monospacedDigit())
                            .foregroundStyle(UsageTone.text(used: used))
                        Text(tr("limits.usedWord"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                } else {
                    Text(tr("limits.unavailable"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            if let limit { bar(limit) }
        }
        .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .padding(.vertical, NookTheme.Spacing.md)
        .cardBackground(hovering ? NookTheme.paper.opacity(0.04) : Color.clear, stroke: NookTheme.line2,
                        radius: NookTheme.Radius.control)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help.isEmpty ? "\(label): \(tr("limits.unavailable"))" : help)
    }

    /// As a segment of the modal's pool bar: what was used fills it, the even-pace line sits in a slot cut from it and
    /// the time to the reset is inside it on the right.
    private func bar(_ limit: QuotaLimit) -> some View {
        let used = UsageLimitRows.used(limit)
        let elapsed = LimitPool.timeElapsed(limit.poolLimit, now: now)
        return ZStack(alignment: .trailing) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let at = elapsed.map { LimitSegmentPosition.at($0, width: width) }
                ZStack(alignment: .leading) {
                    Rectangle().fill(NookTheme.wash.opacity(0.05))
                    Rectangle()
                        .fill(UsageTone.fill(used: used).opacity(0.35))
                        .frame(width: width * CGFloat(used) / 100)
                }
                .mask(PaceSlot(at: at))
                if let at, width >= 6 {
                    Capsule()
                        .fill(NookTheme.paper)
                        .frame(width: 2)
                        .padding(.vertical, NookTheme.Spacing.xxs)
                        .offset(x: at - 1)
                }
            }
            if limit.note == nil, let reset = limit.resetsAt {
                LimitResetChip(resetsIn: reset > now ? AgentFormat.compactDuration(reset.timeIntervalSince(now)) : tr("limits.now"),
                               credits: 0)
                    .padding(.trailing, NookTheme.Spacing.xs)
            }
        }
        .frame(height: 20)
        .roundedClip(NookTheme.Radius.chip)
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
    @MainActor
    static func make(_ app: AppModel, now: Date) -> (sections: [UsageLimitSection], notices: [String]) {
        let byKind = Dictionary(grouping: app.connectedProfiles, by: \.kind)
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
                return LimitPool.Account(id: profile.id, name: AccountLabel.name(profile, app: app), limits: limits.map(\.poolLimit))
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

    private var tab: UsageModalTab { UsageModalTab(rawValue: tabRaw) ?? .limits }
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
                            let read = UsageLimitSection.make(app, now: context.date)
                            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxxl) {
                                UsageLimitPools(sections: read.sections, notices: read.notices, now: context.date)
                                credits
                            }
                        }
                    case .cost, .tokens:
                        UsageInsightsPanel(history: app.history, metric: tab == .cost ? .cost : .tokens, window: window)
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xxl)
                .padding(.vertical, NookTheme.Spacing.xl)
            }
        }
        .frame(maxWidth: 720)
        .frame(minHeight: 320, idealHeight: 560, maxHeight: 760)
        .background(NookTheme.surface)
        .task { await app.watchQuotas() }
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
                    Image(icon: "chevron.right")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
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
                        Text(tr("limits.block.empty"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
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

    var body: some View {
        HStack(alignment: .center, spacing: NookTheme.Spacing.xxl) {
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
            .frame(width: 176, alignment: .leading)
            LimitPoolBar(window: window, section: section, now: now)
        }
        .padding(NookTheme.Spacing.xl)
        .cardBackground(Color.clear, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
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
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        if let limit = member.limit, let used = member.used {
            let color = section.kind.color
            let elapsed = LimitPool.timeElapsed(limit, now: now)
            let reset = window.resets.first { $0.accountID == member.accountID }
            let resetsIn = AgentFormat.resetsIn(limit.resetsAt, now: now)
            let credits = section.details[member.accountID]?.credits ?? 0
            Button { open.toggle() } label: {
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
            .onHover { hovering = $0 }
            .help(summary(used: used, elapsed: elapsed, resetsIn: resetsIn, credits: credits))
            .accessibilityLabel(summary(used: used, elapsed: elapsed, resetsIn: resetsIn, credits: credits))
            .popover(isPresented: $open, arrowEdge: .top) {
                LimitSegmentDetails(member: member, window: window, details: section.details[member.accountID], reset: reset, now: now)
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
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let credits = section.details[member.accountID]?.credits ?? 0
        Button { open.toggle() } label: {
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
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 26)
            .roundedBackground(hovering || open ? NookTheme.wash.opacity(0.08) : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .top) {
            LimitSegmentDetails(member: member, window: window, details: section.details[member.accountID],
                                reset: window.resets.first { $0.accountID == member.accountID }, now: now)
        }
    }
}

/// An account's details in one window: who it is, its plan, how much it used, when it resets, where even spending would
/// be and what the reset frees in the pool.
private struct LimitSegmentDetails: View {
    let member: LimitPool.Member
    let window: LimitPool.Window
    let details: LimitAccountDetails?
    let reset: LimitPool.Reset?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md + NookTheme.Spacing.xxs) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(member.name)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
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
