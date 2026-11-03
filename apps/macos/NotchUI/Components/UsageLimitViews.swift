import SwiftUI

// Subscription limits, drawn them: everything reads as room left ("62% left", a bar that drains), a
// line on the bar marks where even spending would be by now, color only once little is left, and the details (reset
// time, pace) one hover or click away instead of in a footnote. Two shapes share these rules: `UsageLimitRows`, one line
// per window for one account (the composer's popover, Settings › Coding agents), and `UsageLimitsSheet`, the modal with
// every agent's accounts as one pool per window.

extension QuotaLimit {
    var poolLimit: LimitPool.Limit { .init(label: label, used: percent, resetsAt: resetsAt, duration: duration) }
}

/// How room left is colored: calm while there is room, amber at 20 % left or less, coral at 10 % or less.
enum UsageTone {
    enum Level { case calm, warning, error }

    static func level(left: Int) -> Level {
        left <= 10 ? .error : (left <= 20 ? .warning : .calm)
    }

    /// A bar's fill; `calm` is what it takes while there is room.
    static func fill(left: Int, calm: Color = NookTheme.textStrong) -> Color {
        switch level(left: left) {
        case .calm: return calm
        case .warning: return NookTheme.amber
        case .error: return NookTheme.coral
        }
    }

    /// A percentage's text.
    static func text(left: Int) -> Color {
        switch level(left: left) {
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
        Image(systemName: symbol)
            .font(NookTheme.font(11, .medium))
            .foregroundStyle(NookTheme.textSecondary)
            .help(tr("limits.pace.\(pace.rawValue)"))
            .accessibilityLabel(tr("limits.pace.\(pace.rawValue)"))
    }
}

// MARK: - One account, one line per window

/// One account's windows, a line each: the window's name, a hairline bar of what is left, and the percentage. The reset
/// time and the pace are in the row's tooltip; the row lights up under the pointer. An account that reports no limits
/// shows one "Unavailable" line with the reason in its tooltip.
struct UsageLimitRows: View {
    let limits: [QuotaLimit]
    /// Why there are no limits, shown when `limits` is empty.
    var unavailable: String?
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if limits.isEmpty {
                UsageLimitRow(label: tr("limits.limits"), left: nil, value: tr("limits.unavailable"), help: unavailable ?? "")
            } else {
                ForEach(limits) { limit in
                    let pool = limit.poolLimit
                    let left = LimitPool.left(pool.used)
                    UsageLimitRow(label: limit.label, left: left, value: "\(left)%", help: help(limit, left: left))
                }
            }
        }
    }

    /// "5 hours: 62% left", "Resets in 2h 14m · 17:30", "Ahead of pace".
    private func help(_ limit: QuotaLimit, left: Int) -> String {
        var lines = [tr("limits.rowLeft", limit.label, left)]
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

/// One line of `UsageLimitRows`: label, hairline bar, value.
private struct UsageLimitRow: View {
    let label: String
    /// Left, 0...100; nil for a line without a bar.
    let left: Int?
    let value: String
    let help: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            Text(label)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 96, alignment: .leading)
            if let left {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NookTheme.textSecondary.opacity(0.2))
                        if left > 0 {
                            Capsule()
                                .fill(UsageTone.fill(left: left))
                                .frame(width: max(6, proxy.size.width * CGFloat(left) / 100))
                        }
                    }
                }
                .frame(height: 3)
            } else {
                Spacer(minLength: 0)
            }
            Text(value)
                .font(NookTheme.TextStyle.label.monospacedDigit())
                .foregroundStyle(left.map { UsageTone.text(left: $0) } ?? NookTheme.textSecondary)
                .lineLimit(1)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .font(NookTheme.TextStyle.detail)
        .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
            .fill(hovering ? Color.white.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help.isEmpty ? "\(label): \(value)" : help)
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
    var id: String { kind.rawValue }
}

extension UsageLimitSection {
    /// Every connected agent with limits, in the order of `AgentKind`, and a notice for each account that reports none.
    @MainActor
    static func make(_ app: AppModel, now: Date) -> (sections: [UsageLimitSection], notices: [String]) {
        let byKind = Dictionary(grouping: app.connectedProfiles, by: \.kind)
        var sections: [UsageLimitSection] = []
        var notices: [String] = []
        for kind in AgentKind.allCases {
            guard let profiles = byKind[kind] else { continue }
            var details: [String: LimitAccountDetails] = [:]
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
                return LimitPool.Account(id: profile.id, name: AccountLabel.name(profile, app: app), limits: limits.map(\.poolLimit))
            }
            if let pool = LimitPool.make(accounts, now: now) {
                sections.append(UsageLimitSection(kind: kind, pool: pool, details: details))
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
        case .opencode, .cursor, .grok, .acp: return tr("agents.usage.acpNoLimits")
        case .antigravity: return app.antigravityUsage.noLogin ? tr("agents.usage.antigravityNoToken") : tr("ws.usage.quotaUnavailable")
        }
    }
}

/// The usage limits of every connected account, as a modal: per agent, a card per window with what is left of the pool
/// in large type and its pace, beside a bar with a segment per account. Opened from the Usage page, the composer's
/// limits, and Settings › Coding agents.
struct UsageLimitsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("limits.title"))
                    .font(NookTheme.TextStyle.heading)
                    .foregroundStyle(NookTheme.paper)
                Spacer(minLength: NookTheme.Spacing.md)
                UsageRefreshButton()
                Button(tr("button.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, NookTheme.Spacing.xxl)
            .padding(.top, NookTheme.Spacing.xxl)
            .padding(.bottom, NookTheme.Spacing.xl)

            ScrollView(showsIndicators: false) {
                // Once a minute the reset times count down and the pace line moves on.
                TimelineView(.nookTicks(every: 60)) { context in
                    let read = UsageLimitSection.make(app, now: context.date)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxxl) {
                        UsageLimitPools(sections: read.sections, notices: read.notices, now: context.date)
                        credits
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xxl)
                .padding(.bottom, NookTheme.Spacing.xxl)
            }
        }
        .frame(width: 720)
        .frame(minHeight: 320, idealHeight: 560, maxHeight: 760)
        .background(NookTheme.canvas)
        .task { await app.watchQuotas() }
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
                    Image(systemName: "exclamationmark.triangle")
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
                .cardBackground(NookTheme.amber.opacity(0.08), stroke: NookTheme.amber.opacity(0.3), radius: NookTheme.Radius.card, style: .continuous)
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
        }
    }
}

/// One window of the pool: its name, what is left in large type with the pace, and the next refill when the pool has
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
                    Text("\(window.left)%")
                        .font(NookTheme.font(30, .semibold).monospacedDigit())
                        .foregroundStyle(NookTheme.paper)
                    HStack(spacing: NookTheme.Spacing.md) {
                        Text(tr("limits.leftWord"))
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textSecondary)
                        if let pace = window.pace { LimitPaceIcon(pace: pace) }
                    }
                }
                if window.columns.count > 1, let refill = window.nextRefill {
                    Text("↻ +\(refill.restores)%")
                        .font(NookTheme.TextStyle.label.monospacedDigit())
                        .foregroundStyle(NookTheme.paper)
                }
            }
            .frame(width: 176, alignment: .leading)
            LimitPoolBar(window: window, section: section, now: now)
        }
        .padding(NookTheme.Spacing.xl)
        .cardBackground(Color.clear, stroke: NookTheme.line2, radius: NookTheme.Radius.card, style: .continuous)
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

/// One account's part of the pool bar. What is left fills it in the agent's color, what the account's next reset gives
/// back is hatched, and the even-pace line sits in a slot cut from the bar. Click for the account's details.
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
        if let limit = member.limit, let left = member.left {
            let color = section.kind.color
            let timeLeft = LimitPool.timeLeft(limit, now: now)
            let reset = window.resets.first { $0.accountID == member.accountID }
            let resetsIn = AgentFormat.resetsIn(limit.resetsAt, now: now)
            let credits = section.details[member.accountID]?.credits ?? 0
            Button { open.toggle() } label: {
                ZStack(alignment: .leading) {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.05))
                            Rectangle()
                                .fill(color.opacity(0.35))
                                .frame(width: width * CGFloat(left) / 100)
                            if left < 100, reset != nil, member.refill > 0 {
                                LimitHatch(color: color)
                                    .opacity(0.2)
                                    .frame(width: width * CGFloat(min(Double(100 - left), member.refill)) / 100)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .mask(PaceSlot(at: timeLeft.map { Self.position($0, width: width) }))
                        if let timeLeft, width >= 6 {
                            Capsule()
                                .fill(NookTheme.paper)
                                .frame(width: 2)
                                .padding(.vertical, NookTheme.Spacing.xxs)
                                .offset(x: Self.position(timeLeft, width: width) - 1)
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
                                Text("\(left)%")
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
                .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                    .stroke(open || hovering ? NookTheme.line2 : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(summary(left: left, timeLeft: timeLeft, resetsIn: resetsIn, credits: credits))
            .accessibilityLabel(summary(left: left, timeLeft: timeLeft, resetsIn: resetsIn, credits: credits))
            .popover(isPresented: $open, arrowEdge: .top) {
                LimitSegmentDetails(member: member, window: window, details: section.details[member.accountID], reset: reset, now: now)
            }
        } else {
            // The account does not report this window: an empty column, so the others stay in place.
            Color.clear.frame(height: wide ? 32 : 20)
        }
    }

    /// Where a share of the bar's width lies, kept 3 pt inside its ends.
    static func position(_ percent: Int, width: CGFloat) -> CGFloat {
        min(max(3, width * CGFloat(percent) / 100), max(3, width - 3))
    }

    private func summary(left: Int, timeLeft: Int?, resetsIn: String?, credits: Int) -> String {
        var parts = [tr("limits.segment", member.name, left)]
        if let resetsIn { parts.append(resetsIn) }
        if let timeLeft { parts.append(tr("limits.windowLeft", timeLeft)) }
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
                    Image(systemName: "ticket")
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 2, style: .continuous).fill(NookTheme.canvas.opacity(0.85)))
    }
}

/// A narrow bar's legend: a row per account with its number, name, what is left and its reset. Click for its details.
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
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 2, style: .continuous).fill(section.kind.color.opacity(0.35)))
                Text(member.name)
                    .font(NookTheme.TextStyle.detail.weight(.medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text("\(member.left ?? 0)%")
                    .font(NookTheme.TextStyle.detail.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NookTheme.paper)
                Spacer(minLength: NookTheme.Spacing.sm)
                HStack(spacing: NookTheme.Spacing.sm) {
                    if let reset = member.limit?.resetsAt {
                        Text("↻ " + (reset > now ? AgentFormat.compactDuration(reset.timeIntervalSince(now)) : tr("limits.now")))
                    }
                    if credits > 0 {
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            Image(systemName: "ticket")
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
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(hovering || open ? Color.white.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .top) {
            LimitSegmentDetails(member: member, window: window, details: section.details[member.accountID],
                                reset: window.resets.first { $0.accountID == member.accountID }, now: now)
        }
    }
}

/// An account's details in one window: who it is, its plan, what is left, when it resets, where even spending would be
/// and what the reset gives back to the pool.
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
                row(tr("limits.row.left"), "\(member.left ?? 0)%")
                if let at = member.limit?.resetsAt {
                    row(tr("limits.row.resets"), at > now
                        ? "\(AgentFormat.upcoming(at, now: now)) · \(tr("limits.in", AgentFormat.compactDuration(at.timeIntervalSince(now))))"
                        : tr("limits.resetsNow"))
                }
                if let limit = member.limit, let timeLeft = LimitPool.timeLeft(limit, now: now) {
                    row(tr("limits.row.evenPace"), tr("limits.row.evenPaceValue", timeLeft))
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
        .buttonStyle(.plain)
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
