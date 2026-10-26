import SwiftUI
import Charts

/// Usage on the iPhone, as Settings › Usage on the Mac: the plan limits of every account with an even-pace mark, then
/// what the sessions Nook started used over a range, per day and per model.
struct UsageScreen: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var range = "week"

    /// The last answer, whatever its range: the plan limits do not depend on it, so they stay while another range loads.
    private var latest: UsageDigest? { client.usage }
    /// Only the answer for the range on screen: right after switching, the previous range's numbers are not shown as this one's.
    private var usage: UsageDigest? { latest.flatMap { $0.range == range ? $0 : nil } }

    var body: some View {
        ScrollView {
            PanelHeader("Usage")
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !client.can(CompanionFeature.usage) {
                    EmptyState(symbol: "chart.bar", title: "Update Nook on your Mac",
                               message: "Update Nook on your Mac to see your usage here.") {}
                } else if let latest {
                    SectionHeader(title: "Plan limits")
                    if latest.accounts.isEmpty {
                        Text("No agent accounts are connected on your Mac.")
                            .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).card()
                    }
                    ForEach(latest.accounts) { AccountUsageCard(account: $0) }

                    SectionHeader(title: "Sessions in Nook")
                    // Outside the range's figures, so another range can be picked while one loads or after it failed.
                    HStack(spacing: Theme.Spacing.md) {
                        FilterChip(title: "Today", selected: range == "today") { range = "today" }
                        FilterChip(title: "Week", selected: range == "week") { range = "week" }
                        FilterChip(title: "Month", selected: range == "month") { range = "month" }
                    }
                    if let usage {
                        HStack(spacing: Theme.Spacing.md) {
                            StatTile(title: "Sessions", value: usage.sessions.formatted(), symbol: "square.stack.3d.up.fill")
                            StatTile(title: "Tokens", value: Tokens.format(usage.inputTokens + usage.outputTokens + usage.cacheTokens),
                                     symbol: "text.word.spacing")
                            StatTile(title: "Cost", value: usage.cost.map { $0.formatted(.currency(code: "USD")) } ?? "—",
                                     symbol: "dollarsign.circle.fill")
                        }
                        if usage.days.isEmpty {
                            Text("No sessions with token counts in this period.")
                                .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).card()
                        } else {
                            TokensChart(days: usage.days)
                        }
                        if !usage.models.isEmpty {
                            SectionHeader(title: "By model")
                            ModelsCard(models: usage.models)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xxl)
                    }
                    Text("Limits come from the agents themselves. Tokens and costs count the sessions Nook started.")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.xs).padding(.top, Theme.Spacing.md)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .refreshable { await client.loadUsage(range: range) }
        .toolbar(.hidden, for: .navigationBar)
        .screen()
        .task(id: range) {
            while !Task.isCancelled {
                await client.loadUsage(range: range)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

/// One account: its mark and name, then every window it reported.
private struct AccountUsageCard: View {
    let account: UsageDigest.Account

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.lg) {
                AgentIcon(agent: account.agent, size: 34, colored: true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(account.agent).font(Theme.TextStyle.title).foregroundStyle(Theme.text)
                    Text(account.account).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
            }
            if account.limits.isEmpty {
                Text("This agent reports no plan limits.").font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(account.limits) { LimitRow(limit: $0, agent: account.agent) }
            }
        }
        .card()
    }
}

private struct LimitRow: View {
    let limit: UsageDigest.Limit
    let agent: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    Text(limit.label).font(Theme.TextStyle.body).foregroundStyle(Theme.textStrong).lineLimit(1)
                    if let reset = resetText(at: context.date) {
                        Text(reset).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    Text(verbatim: "\(Int(limit.percent.rounded()))%")
                        .font(Theme.TextStyle.strong).monospacedDigit()
                        .foregroundStyle(UsageTone.text(limit.percent))
                }
                UsageBar(fraction: limit.percent / 100, color: UsageTone.fill(limit.percent), pace: limit.pace(at: context.date))
            }
        }
    }

    private func resetText(at now: Date) -> String? {
        if let note = limit.note, !note.isEmpty { return note }
        guard let resetsAt = limit.resetsAt else { return nil }
        let date = Date(timeIntervalSince1970: resetsAt)
        guard date > now else { return nil }
        return String(localized: "Resets \(date.formatted(.relative(presentation: .named)))")
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: symbol).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.rounded(22, .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
        }
        .card(padding: Theme.Spacing.lg)
        .accessibilityElement(children: .combine)
    }
}

/// Tokens per day, stacked per agent in the agent's own color.
private struct TokensChart: View {
    let days: [UsageDigest.Day]

    private var agents: [String] { Array(Set(days.map(\.agent))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Tokens per day").font(Theme.TextStyle.title).foregroundStyle(Theme.text)
            Chart(days) { day in
                BarMark(x: .value("Day", Date(timeIntervalSince1970: day.day), unit: .day),
                        y: .value("Tokens", day.tokens))
                    .foregroundStyle(by: .value("Agent", day.agent))
                    .cornerRadius(4)
            }
            .chartForegroundStyleScale(domain: agents, range: agents.map { AgentIcon.style($0).color })
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let tokens = value.as(Int.self) { Text(Tokens.format(tokens)) } }
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(Theme.textTertiary)
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 180)
        }
        .card()
    }
}

private struct ModelsCard: View {
    let models: [UsageDigest.Model]

    var body: some View {
        RowGroup {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { RowSeparator(inset: Theme.Spacing.xl + 30 + Theme.Spacing.lg) }
                HStack(spacing: Theme.Spacing.lg) {
                    AgentIcon(agent: model.agent, size: 30)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(model.model == "default" ? String(localized: "Default model") : model.model)
                            .font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(model.agent)
                            Text(verbatim: "·")
                            Text("\(model.sessions) sessions")
                        }
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                        Text(Tokens.format(model.tokens)).font(Theme.TextStyle.strong).monospacedDigit().foregroundStyle(Theme.text)
                        if let cost = model.cost {
                            Text(cost, format: .currency(code: "USD")).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
            }
        }
    }
}

// MARK: Shared pieces

/// How full a window is: a calm grey while there is room, amber from 75%, coral from 90% (color means state).
enum UsageTone {
    static func fill(_ percent: Double) -> Color {
        switch percent {
        case ..<75: return Theme.textStrong
        case ..<90: return Theme.amber
        default: return Theme.coral
        }
    }

    static func text(_ percent: Double) -> Color {
        switch percent {
        case ..<75: return Theme.text
        case ..<90: return Theme.amber
        default: return Theme.coral
        }
    }
}

/// A solid bar on a quiet track; with `pace` a white tick marks where usage would be at an even pace through the window.
struct UsageBar: View {
    let fraction: Double
    let color: Color
    var pace: Double? = nil
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(color).frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                if let pace {
                    Capsule().fill(Theme.textTertiary)
                        .frame(width: 2, height: height + 6)
                        .offset(x: proxy.size.width * pace - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

extension UsageDigest.Limit {
    /// How far `now` is into the window (0...1), when its start is known and it has not reset yet.
    func pace(at now: Date = .now) -> Double? {
        guard let duration, duration > 0, let resetsAt else { return nil }
        let remaining = resetsAt - now.timeIntervalSince1970
        guard remaining > 0 else { return nil }
        return min(1, max(0, 1 - remaining / duration))
    }
}

enum Tokens {
    /// 1234567 as "1.2M": token counts at a glance.
    static func format(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
