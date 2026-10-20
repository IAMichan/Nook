import SwiftUI

/// The usage of every connected account at once, grouped per AI: one section for all Claude accounts, one for
/// Antigravity, and so on. Each account shows the limits its agent reports (5 hours and the week), and what was used in
/// tokens today and this week with a small chart of the last seven days. Agents that report a limit per model
/// (Antigravity) get a compact table with only the busiest models; the rest folds away. Tokens per model and costs live
/// in Settings › Usage.
struct AgentsUsagePanel: View {
    @EnvironmentObject private var app: AppModel
    /// Accounts whose full model list is unfolded.
    @State private var expanded: Set<String> = []

    /// How many models an account shows while folded; a model close to its limit always shows.
    private static let featuredModels = 3

    /// Only accounts that are signed in on an installed agent: no cards for services you did not connect.
    private var profiles: [AgentProfile] { app.connectedProfiles }

    /// The accounts per AI, in the order the AIs first appear in the account list.
    private var groups: [(kind: AgentKind, profiles: [AgentProfile])] {
        var result: [(kind: AgentKind, profiles: [AgentProfile])] = []
        for profile in profiles {
            if let index = result.firstIndex(where: { $0.kind == profile.kind }) {
                result[index].profiles.append(profile)
            } else {
                result.append((profile.kind, [profile]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("agents.footer.usage"))
                    .font(NookTheme.font(14, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Spacer()
            }
            .frame(height: 30)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    if profiles.isEmpty {
                        Text(tr("agents.noneConnected"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    ForEach(groups, id: \.kind) { group in
                        section(group.kind, group.profiles)
                    }
                    if profiles.contains(where: { profile in app.quota.limits(for: profile).contains { $0.group == nil && $0.elapsed() != nil } }) {
                        HStack(spacing: 7) {
                            Capsule().fill(NookTheme.paper).frame(width: 2, height: 11)
                            Text(tr("agents.usage.paceLegend"))
                        }
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                    }
                    Text(tr("agents.usage.note"))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { app.history.refresh() }
        .task { await app.watchQuotas() }
    }

    /// One AI: its logo and name, then all its accounts on one surface, divided by hairlines. With several accounts the
    /// header also counts them and shows the highest limit in use; with one, the account itself already says it all.
    private func section(_ kind: AgentKind, _ profiles: [AgentProfile]) -> some View {
        let peak = profiles.count > 1 ? profiles.flatMap { app.quota.limits(for: $0) }.map(\.percent).max() : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentLogo(agent: kind.name, size: 16)
                Text(kind.name)
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                if profiles.count > 1 {
                    Text(tr("agents.usage.accounts", profiles.count))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: 0)
                if let peak {
                    peakPill(peak, accent: kind.color)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 {
                        Rectangle().fill(NookTheme.line2.opacity(0.5)).frame(height: 1)
                    }
                    account(profile)
                }
            }
            // The same surface the terminals, the browser and the worktrees sit on.
            .cardBackground(NookTheme.field, stroke: NookTheme.line2.opacity(0.6), radius: 12, style: .continuous)
        }
    }

    private func account(_ profile: AgentProfile) -> some View {
        let limits = app.quota.limits(for: profile)
        let usage = app.history.profileUsage[profile.id]
        let account = app.history.profileAccounts[profile.id]
        let accent = profile.kind.color
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                AccountBadge(kind: AccountKind.of(profile, app: app), size: 20, ring: NookTheme.field)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AccountLabel.name(profile, app: app))
                        .font(NookTheme.font(13, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(account.map { $0.plan.isEmpty ? $0.name : "\($0.name) · \($0.plan)" } ?? tr("agents.notLoggedIn"))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if limits.count > 2, let peak = limits.map(\.percent).max() {
                    peakPill(peak, accent: accent)
                }
            }

            if limits.isEmpty {
                Text(profile.kind == .gemini ? tr("agents.usage.geminiNoLimits")
                     : profile.kind == .antigravity && app.antigravityUsage.noLogin ? tr("agents.usage.antigravityNoToken")
                     : tr("ws.usage.quotaUnavailable"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let groups = limitGroups(limits)
                let plain = groups.first { $0.name.isEmpty }?.limits ?? []
                let models = groups.filter { !$0.name.isEmpty }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plain) { limit in
                        limitRow(limit, title: limit.label, accent: accent)
                    }
                    if !models.isEmpty {
                        modelTable(models, profile: profile, accent: accent)
                    }
                }
            }

            Rectangle().fill(NookTheme.line2.opacity(0.35)).frame(height: 1)

            if let usage {
                HStack(alignment: .bottom, spacing: 14) {
                    stat(tr("agents.usage.today"), TokenTally.format(usage.today.total))
                    stat(tr("agents.usage.week"), TokenTally.format(usage.week.total))
                    Spacer(minLength: 0)
                    WeekBars(days: usage.perDay, color: accent)
                }
            } else {
                Text(tr("agents.usage.none"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A limit as its name, reset time and percentage above a solid bar: the bar takes the AI's own color while there
    /// is room, and only turns amber or coral once the limit comes close. A tick on the bar marks where an even pace
    /// would be by now, so a fill past it is running ahead of the window; it moves along every minute.
    private func limitRow(_ limit: QuotaLimit, title: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(NookTheme.font(12.5, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Group {
                    if let note = limit.note {
                        Text(note)
                    } else if let reset = AgentFormat.reset(limit.resetsAt) {
                        Text(reset)
                    }
                }
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(NookTheme.font(16, .bold).monospacedDigit())
                    .foregroundStyle(UsageTone.text(limit.percent))
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let pace = limit.elapsed(at: context.date)
                UsageBar(fraction: limit.percent / 100, color: UsageTone.fill(limit.percent, accent: accent), pace: pace)
                    .help(pace.map { tr("agents.usage.pace", Int(($0 * 100).rounded())) } ?? "")
            }
        }
    }

    /// Limits per model group ("Claude & GPT", "Gemini") in the order they come; plain windows ("5 hours") share one
    /// unnamed group.
    private func limitGroups(_ limits: [QuotaLimit]) -> [(name: String, limits: [QuotaLimit])] {
        var result: [(name: String, limits: [QuotaLimit])] = []
        for limit in limits {
            let name = limit.group ?? ""
            if let index = result.firstIndex(where: { $0.name == name }) {
                result[index].limits.append(limit)
            } else {
                result.append((name, [limit]))
            }
        }
        return result
    }

    /// "peak 82%", tinted like the limit it names.
    private func peakPill(_ peak: Double, accent: Color) -> some View {
        Text(tr("agents.usage.peak", Int(peak.rounded())))
            .font(NookTheme.font(11, .semibold).monospacedDigit())
            .foregroundStyle(UsageTone.text(peak))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(UsageTone.fill(peak, accent: accent).opacity(0.14)))
    }

    /// Limits per model as one table: a row per model, a column per window ("5 hours", "Week"), each cell a slim bar
    /// with its percentage; the reset time is in the cell's tooltip. The busiest models come first and only a few show
    /// until the account is unfolded, so an agent with a long model list stays readable.
    private func modelTable(_ models: [(name: String, limits: [QuotaLimit])], profile: AgentProfile, accent: Color) -> some View {
        let sorted = models.enumerated()
            .sorted { lhs, rhs in
                let a = lhs.element.limits.map(\.percent).max() ?? 0, b = rhs.element.limits.map(\.percent).max() ?? 0
                return a != b ? a > b : lhs.offset < rhs.offset
            }
            .map(\.element)
        let folded = sorted.enumerated()
            .filter { $0.offset < Self.featuredModels || ($0.element.limits.map(\.percent).max() ?? 0) >= 75 }
            .map(\.element)
        let isExpanded = expanded.contains(profile.id)
        let shown = isExpanded ? sorted : folded
        var windows: [String] = []
        for model in sorted {
            for limit in model.limits where !windows.contains(limit.window) { windows.append(limit.window) }
        }
        let hidden = sorted.count - folded.count
        return VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text(tr("agents.usage.model"))
                    ForEach(windows, id: \.self) { Text($0) }
                }
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                ForEach(shown, id: \.name) { model in
                    GridRow {
                        Text(model.name)
                            .font(NookTheme.font(12.5, .medium))
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
                            .help(model.name)
                        ForEach(windows, id: \.self) { window in
                            if let limit = model.limits.first(where: { $0.window == window }) {
                                modelCell(limit, accent: accent)
                            } else {
                                Text("—")
                                    .font(NookTheme.font(12))
                                    .foregroundStyle(NookTheme.textTertiary)
                            }
                        }
                    }
                }
            }
            if hidden > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded { expanded.remove(profile.id) } else { expanded.insert(profile.id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(isExpanded ? tr("agents.usage.fewerModels") : tr("agents.usage.moreModels", hidden))
                        Image(systemName: "chevron.down")
                            .font(NookTheme.font(9, .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(NookTheme.font(11.5, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One window of one model: a slim bar in the limit's tone with the percentage beside it.
    private func modelCell(_ limit: QuotaLimit, accent: Color) -> some View {
        HStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    if limit.percent > 0 {
                        Capsule()
                            .fill(UsageTone.fill(limit.percent, accent: accent))
                            .frame(width: max(5, geo.size.width * CGFloat(min(1, limit.percent / 100))))
                    }
                }
            }
            .frame(minWidth: 34, maxWidth: 90)
            .frame(height: 5)
            Text("\(Int(limit.percent.rounded()))%")
                .font(NookTheme.font(12, .semibold).monospacedDigit())
                .foregroundStyle(UsageTone.text(limit.percent))
                .frame(width: 36, alignment: .trailing)
        }
        .help(limit.note ?? AgentFormat.reset(limit.resetsAt) ?? "")
    }

    /// "Today 1.2M": the label quiet, the number plain, on one line.
    private func stat(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
            Text(value).font(NookTheme.font(12.5, .semibold).monospacedDigit()).foregroundStyle(NookTheme.paper)
        }
        .lineLimit(1)
    }
}

/// How a usage percentage is colored: calm in the AI's own color while there is room, amber when it gets close, coral
/// when it is nearly gone. The number stays plain white until then, so only what needs attention stands out. Shared by
/// the notch and Settings › Usage, so a limit looks the same in both.
enum UsageTone {
    static func fill(_ percent: Double, accent: Color) -> Color {
        switch percent {
        case ..<75: return accent
        case ..<90: return NookTheme.amber
        default: return NookTheme.coral
        }
    }

    static func text(_ percent: Double) -> Color {
        switch percent {
        case ..<75: return NookTheme.paper
        case ..<90: return NookTheme.amber
        default: return NookTheme.coralSoft
        }
    }
}

/// A solid bar on a quiet track. With `pace` (0...1) a white tick, a little taller than the bar, marks where usage would
/// be at an even pace through the window.
struct UsageBar: View {
    let fraction: Double
    let color: Color
    var pace: Double?
    private static let height: CGFloat = 10

    var body: some View {
        let height = Self.height
        return GeometryReader { geo in
            let width = geo.size.width
            let fill = CGFloat(min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: height)
                if fill > 0 {
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(color)
                        .frame(width: max(height, width * fill), height: height)
                }
                if let pace {
                    Capsule()
                        .fill(NookTheme.paper)
                        .frame(width: 2, height: height + 6)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .offset(x: min(width - 2, max(0, width * CGFloat(pace) - 1)))
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: height + 6)
        .accessibilityHidden(true)
    }
}

/// Seven thin bars, one per day, today on the right: how busy an account was this week at a glance.
struct WeekBars: View {
    let days: [(day: Date, tokens: Int)]
    let color: Color

    var body: some View {
        let peak = max(1, days.map(\.tokens).max() ?? 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(days.suffix(7).enumerated()), id: \.offset) { _, day in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(day.tokens > 0 ? color.opacity(0.85) : Color.white.opacity(0.08))
                    .frame(width: 5, height: max(2, 24 * CGFloat(day.tokens) / CGFloat(peak)))
                    .help(AgentFormat.weekdayLetter(day.day) + " · " + TokenTally.format(day.tokens))
            }
        }
        .frame(height: 24, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
