import SwiftUI
import Charts

/// Usage on the iPhone, as Settings › Usage on the Mac: the plan limits of every account with an even-pace mark, then
/// what the sessions Nook started used over a range, per day and per model.
struct UsageScreen: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var range = "week"

    private var usage: UsageDigest? { client.usage }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if !client.can(CompanionFeature.usage) {
                    EmptyState(symbol: "chart.bar", title: "Update Nook on your Mac",
                               message: "Update Nook on your Mac to see your usage here.") {}
                } else if let usage {
                    SectionHeader(title: "Plan limits")
                    if usage.accounts.isEmpty {
                        Text("No agent accounts are connected on your Mac.")
                            .font(.callout).foregroundStyle(Theme.textSecondary).card()
                    }
                    ForEach(usage.accounts) { AccountUsageCard(account: $0) }

                    SectionHeader(title: "Sessions in Nook")
                    Picker("Range", selection: $range) {
                        Text("Today").tag("today")
                        Text("Week").tag("week")
                        Text("Month").tag("month")
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: Theme.Spacing.sm) {
                        StatTile(title: "Sessions", value: usage.sessions.formatted(), symbol: "square.stack.3d.up.fill")
                        StatTile(title: "Tokens", value: Tokens.format(usage.inputTokens + usage.outputTokens + usage.cacheTokens),
                                 symbol: "text.word.spacing")
                        StatTile(title: "Cost", value: usage.cost.map { $0.formatted(.currency(code: "USD")) } ?? "—",
                                 symbol: "dollarsign.circle.fill")
                    }
                    if usage.days.isEmpty {
                        Text("No sessions with token counts in this period.")
                            .font(.callout).foregroundStyle(Theme.textSecondary).card()
                    } else {
                        TokensChart(days: usage.days)
                    }
                    if !usage.models.isEmpty {
                        SectionHeader(title: "By model")
                        ModelsCard(models: usage.models)
                    }
                    Text("Limits come from the agents themselves. Tokens and costs count the sessions Nook started.")
                        .font(.caption).foregroundStyle(Theme.textTertiary).padding(.horizontal, Theme.Spacing.xs)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .refreshable { await client.loadUsage(range: range) }
        .navigationTitle("Usage")
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
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                AgentIcon(agent: account.agent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.agent).font(.headline).foregroundStyle(Theme.text)
                    Text(account.account).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
            }
            if account.limits.isEmpty {
                Text("This agent reports no plan limits.").font(.caption).foregroundStyle(Theme.textSecondary)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(limit.label).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                    if let reset = resetText(at: context.date) {
                        Text(reset).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    Text(verbatim: "\(Int(limit.percent.rounded()))%")
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                        .foregroundStyle(UsageTone.text(limit.percent))
                }
                UsageBar(fraction: limit.percent / 100, color: UsageTone.fill(limit.percent, agent: agent), pace: limit.pace(at: context.date))
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
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(Theme.iris)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
        }
        .card(padding: Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

/// Tokens per day, stacked per agent in the agent's own color.
private struct TokensChart: View {
    let days: [UsageDigest.Day]

    private var agents: [String] { Array(Set(days.map(\.agent))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Tokens per day").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
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
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 44) }
                HStack(spacing: Theme.Spacing.md) {
                    AgentIcon(agent: model.agent, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.model == "default" ? String(localized: "Default model") : model.model)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(model.agent)
                            Text(verbatim: "·")
                            Text("\(model.sessions) sessions")
                        }
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Tokens.format(model.tokens)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        if let cost = model.cost {
                            Text(cost, format: .currency(code: "USD")).font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
        .card(padding: Theme.Spacing.md)
    }
}

// MARK: Shared pieces

/// How full a window is, in the colors the notch uses: the agent's own color, amber from 75%, coral from 90%.
enum UsageTone {
    static func fill(_ percent: Double, agent: String) -> Color {
        switch percent {
        case ..<75: return AgentIcon.style(agent).color
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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(color).frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                if let pace {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text)
                        .frame(width: 2, height: 12)
                        .offset(x: proxy.size.width * pace - 1)
                }
            }
        }
        .frame(height: 8)
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
