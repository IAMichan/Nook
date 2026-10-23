import SwiftUI
import Charts

/// What the Usage page counts: what it would cost at API prices, or the tokens themselves.
enum UsageMetric: String, CaseIterable, Identifiable {
    case cost, tokens
    var id: String { rawValue }
}

/// Settings › Usage, the overview: what every agent on this Mac used, read from their own
/// transcripts (also the sessions you run in a terminal), as cost at API prices or as tokens, over the last 24 hours or
/// 7, 30 or 90 days. The same blocks (`UsageOverviewBlocks`) make the Usage page in the Agents tab.
struct UsageInsightsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var history: AgentHistory
    @AppStorage("usage.metric") private var metricRaw = UsageMetric.cost.rawValue
    @AppStorage("usage.window") private var windowRaw = UsageWindow.week.rawValue
    @State private var byDay = false
    @State private var openModel: UsageInsights.ModelTotal?
    @State private var prices = UsagePrices.load()

    private var metric: UsageMetric { UsageMetric(rawValue: metricRaw) ?? .cost }
    private var window: UsageWindow { UsageWindow(rawValue: windowRaw) ?? .week }

    var body: some View {
        let insights = UsageInsights.make(history.ledger, window: window, prices: prices)
        Section {
            HStack(spacing: NookTheme.Spacing.lg) {
                UsageMetricPicker(metricRaw: $metricRaw)
                Spacer(minLength: 0)
                UsageWindowPicker(windowRaw: $windowRaw)
            }
            UsageOverviewBlocks(insights: insights, metric: metric, window: window, loading: history.loading, byDay: $byDay) {
                openModel = $0
            }
        } header: {
            Text(tr("usage.title"))
        } footer: {
            Text(tr("usage.footer"))
        }
        .sheet(item: $openModel) { model in
            UsageModelSheet(model: model, ledger: history.ledger, window: window, metric: metric, prices: $prices) { openModel = nil }
        }
        .onAppear { history.refresh(minimumInterval: 60) }
    }
}

/// Cost or tokens.
struct UsageMetricPicker: View {
    @Binding var metricRaw: String

    var body: some View {
        Picker("", selection: $metricRaw) {
            Text(tr("usage.metric.cost")).tag(UsageMetric.cost.rawValue)
            Text(tr("usage.metric.tokens")).tag(UsageMetric.tokens.rawValue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// 24 hours, 7, 30 or 90 days.
struct UsageWindowPicker: View {
    @Binding var windowRaw: String

    var body: some View {
        Picker("", selection: $windowRaw) {
            ForEach(UsageWindow.allCases) { Text(tr("usage.window." + $0.rawValue)).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The Usage page itself, from the large total to the breakdown, wherever it shows (Settings › Usage, Agents › Usage):
/// each agent's share, the chart, the totals, the split by type, and the table per model or per day. `open` opens a
/// model's sheet.
struct UsageOverviewBlocks: View {
    let insights: UsageInsights
    let metric: UsageMetric
    let window: UsageWindow
    var loading = false
    @Binding var byDay: Bool
    let open: (UsageInsights.ModelTotal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
            if insights.tokens.total == 0 {
                Text(loading ? tr("usage.reading") : tr("usage.empty"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.vertical, NookTheme.Spacing.md)
            } else {
                overview(insights)
                UsageAgentChart(insights: insights, metric: metric)
                totals(insights)
                shares(insights)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    HStack {
                        Text(tr("usage.breakdown")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                        Spacer()
                        Picker("", selection: $byDay) {
                            Text(tr("usage.breakdown.model")).tag(false)
                            Text(window.hourly ? tr("usage.breakdown.hour") : tr("usage.breakdown.day")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if byDay { dayTable(insights) } else { modelTable(insights) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Overview

    /// The large total, and per agent its figure and share.
    private func overview(_ insights: UsageInsights) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(metric == .cost ? UsageFormat.usd(insights.cost.total) : UsageFormat.tokens(insights.tokens.total))
                    .font(NookTheme.font(32, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.paper)
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text(metric == .cost ? tr("usage.sessionsEstimate", insights.sessions) : tr("usage.sessions", insights.sessions))
                    if metric == .cost, insights.unpricedTokens > 0 {
                        Image(systemName: "info.circle")
                            .help(tr("usage.unpricedNote", UsageFormat.percent(insights.unpricedShare)))
                    }
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(insights.agents) { total in
                agentRow(total)
            }
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    private func agentRow(_ total: UsageInsights.AgentTotal) -> some View {
        let kind = AgentKind(rawValue: total.agent)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Circle().fill(UsageColors.agent(total.agent)).frame(width: 7, height: 7)
                if let kind { AgentLogo(kind, size: 14) }
                Text(kind?.name ?? total.agent).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
                Text(tr("usage.sessions", total.sessions))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                Spacer(minLength: NookTheme.Spacing.md)
                Text(metric == .cost ? UsageFormat.usd(total.cost) : UsageFormat.tokens(total.tokens.total))
                    .font(NookTheme.TextStyle.strong.monospacedDigit())
                    .foregroundStyle(NookTheme.paper)
            }
            Text(metric == .cost
                 ? tr("usage.shareOfCost", UsageFormat.percent(total.costShare), UsageFormat.tokens(total.tokens.total))
                 : tr("usage.shareOfTokens", UsageFormat.percent(total.tokenShare), UsageFormat.usd(total.cost)))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.leading, 7 + NookTheme.Spacing.md)
        }
    }

    // MARK: Totals

    private func totals(_ insights: UsageInsights) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(tr("usage.totals")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading,
                      spacing: NookTheme.Spacing.lg) {
                UsageMetricTile(label: tr("usage.total.processed"), value: UsageFormat.tokens(insights.tokens.total))
                UsageMetricTile(label: tr("usage.total.cached"), value: UsageFormat.tokens(insights.tokens.cacheRead))
                UsageMetricTile(label: tr("usage.total.uncached"), value: UsageFormat.tokens(insights.tokens.input + insights.tokens.cacheWrite))
                UsageMetricTile(label: tr("usage.total.output"), value: UsageFormat.tokens(insights.tokens.output))
                UsageMetricTile(label: tr("usage.total.savings"), value: UsageFormat.usd(insights.cacheSavings))
            }
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    private func shares(_ insights: UsageInsights) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
            if metric == .tokens {
                UsageShareBar(label: tr("usage.tokensByType"), segments: UsageColors.tokenSegments(insights.tokens), format: { UsageFormat.tokens(Int($0)) })
            } else {
                UsageShareBar(label: tr("usage.costByType"), segments: UsageColors.costSegments(insights.cost), format: UsageFormat.usd)
            }
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    // MARK: Breakdown

    private func modelTable(_ insights: UsageInsights) -> some View {
        let peak = insights.models.map { metric == .cost ? ($0.cost?.total ?? 0) : Double($0.tokens.total) }.max() ?? 0
        return VStack(spacing: 0) {
            UsageTableHeader(columns: [tr("usage.column.model"), tr("usage.column.cost"), tr("usage.column.share"), tr("usage.column.tokens")])
            ForEach(Array(insights.models.enumerated()), id: \.element.id) { index, model in
                let value = metric == .cost ? (model.cost?.total ?? 0) : Double(model.tokens.total)
                UsageModelRow(rank: index + 1, model: model, fraction: peak > 0 ? value / peak : 0,
                              share: metric == .cost ? model.costShare : model.tokenShare) { open(model) }
            }
        }
    }

    private func dayTable(_ insights: UsageInsights) -> some View {
        let agents = insights.agents.map(\.agent)
        return VStack(spacing: 0) {
            UsageTableHeader(columns: [window.hourly ? tr("usage.breakdown.hour") : tr("usage.breakdown.day")]
                             + agents.map { AgentKind(rawValue: $0)?.shortName ?? $0 } + [tr("usage.column.total"), tr("usage.column.tokens")])
            ForEach(insights.columns.reversed(), id: \.self) { column in
                let cells = insights.points.filter { $0.column == column }
                let tokens = cells.map(\.tokens).reduce(0, +)
                if tokens > 0 {
                    HStack(spacing: NookTheme.Spacing.lg) {
                        Text(UsageDates.label(column, hourly: window.hourly))
                            .foregroundStyle(NookTheme.paper)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(agents, id: \.self) { agent in
                            Text(UsageFormat.usd(cells.first { $0.agent == agent }?.cost ?? 0))
                                .foregroundStyle(NookTheme.textSecondary)
                                .frame(width: 72, alignment: .trailing)
                        }
                        Text(UsageFormat.usd(cells.map(\.cost).reduce(0, +)))
                            .foregroundStyle(NookTheme.paper)
                            .frame(width: 72, alignment: .trailing)
                        Text(UsageFormat.tokens(tokens))
                            .foregroundStyle(NookTheme.textSecondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(NookTheme.TextStyle.body.monospacedDigit())
                    .padding(.vertical, NookTheme.Spacing.sm)
                    NookDivider()
                }
            }
        }
    }
}

// MARK: - Pieces

/// The colors of the Usage page: each agent its brand color in the chart and the table; the kinds of token in four
/// quiet tones from the theme.
enum UsageColors {
    static func agent(_ raw: String) -> Color {
        AgentKind(rawValue: raw)?.color ?? NookTheme.textSecondary
    }

    static func tokenSegments(_ tokens: UsageTokens) -> [UsageShareBar.Segment] {
        [
            .init(label: tr("usage.type.cacheRead"), value: Double(tokens.cacheRead), color: NookTheme.blue),
            .init(label: tr("usage.type.input"), value: Double(tokens.input), color: NookTheme.mint),
            .init(label: tr("usage.type.cacheWrite"), value: Double(tokens.cacheWrite), color: NookTheme.violet),
            .init(label: tr("usage.type.output"), value: Double(tokens.output), color: NookTheme.amber),
        ]
    }

    static func costSegments(_ cost: UsageCost) -> [UsageShareBar.Segment] {
        [
            .init(label: tr("usage.type.cacheRead"), value: cost.cacheRead, color: NookTheme.blue),
            .init(label: tr("usage.type.input"), value: cost.input, color: NookTheme.mint),
            .init(label: tr("usage.type.cacheWrite"), value: cost.cacheWrite, color: NookTheme.violet),
            .init(label: tr("usage.type.output"), value: cost.output, color: NookTheme.amber),
        ]
    }
}

enum UsageDates {
    static func label(_ date: Date, hourly: Bool) -> String {
        hourly ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// A label over a large figure.
struct UsageMetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            Text(label).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
            Text(value).font(NookTheme.TextStyle.title.monospacedDigit()).foregroundStyle(NookTheme.paper)
        }
    }
}

/// One thin bar split in parts (a share bar), with a legend: each part's name and figure.
struct UsageShareBar: View {
    struct Segment: Identifiable {
        var label: String
        var value: Double
        var color: Color
        var id: String { label }
    }

    let label: String
    let segments: [Segment]
    let format: (Double) -> String

    var body: some View {
        let visible = segments.filter { $0.value > 0 }
        let total = visible.map(\.value).reduce(0, +)
        if total > 0 {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(label).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                GeometryReader { proxy in
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        ForEach(visible) { segment in
                            Capsule()
                                .fill(segment.color)
                                .frame(width: max(3, (proxy.size.width - CGFloat(visible.count - 1) * 2) * segment.value / total))
                                .help("\(segment.label) · \(format(segment.value)) · \(UsageFormat.percent(segment.value / total))")
                        }
                    }
                }
                .frame(height: 6)
                HStack(spacing: NookTheme.Spacing.lg) {
                    ForEach(visible) { segment in
                        HStack(spacing: NookTheme.Spacing.xs) {
                            RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 3).fill(segment.color).frame(width: 7, height: 7)
                            Text(segment.label).foregroundStyle(NookTheme.textSecondary)
                            Text(format(segment.value)).foregroundStyle(NookTheme.paper).monospacedDigit()
                        }
                    }
                }
                .font(NookTheme.TextStyle.detail)
            }
        }
    }
}

/// The column names over a table, small and grey.
struct UsageTableHeader: View {
    let columns: [String]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.lg) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                    Text(title)
                        .frame(maxWidth: index == 0 ? .infinity : nil, alignment: index == 0 ? .leading : .trailing)
                        .frame(width: index == 0 ? nil : 72, alignment: .trailing)
                }
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.vertical, NookTheme.Spacing.sm)
            NookDivider()
        }
    }
}

/// A model in the breakdown: its rank, logo and id with a thin bar for its size, then cost, share and tokens. A click
/// opens the model.
struct UsageModelRow: View {
    let rank: Int
    let model: UsageInsights.ModelTotal
    let fraction: Double
    let share: Double
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.lg) {
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                        Text("\(rank)").font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary).frame(width: 16, alignment: .leading)
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                            HStack(spacing: NookTheme.Spacing.sm) {
                                if let kind = AgentKind(rawValue: model.agent) { AgentLogo(kind, size: 13) }
                                Text(model.model).foregroundStyle(NookTheme.paper).lineLimit(1).truncationMode(.middle)
                            }
                            if fraction > 0 {
                                GeometryReader { proxy in
                                    Capsule().fill(UsageColors.agent(model.agent))
                                        .frame(width: max(6, min(proxy.size.width, 192) * fraction), height: 2)
                                }
                                .frame(height: 2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if let cost = model.cost {
                            Text(UsageFormat.usd(cost.total)).foregroundStyle(NookTheme.paper)
                        } else {
                            Text(tr("usage.unpriced")).foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                    .frame(width: 72, alignment: .trailing)
                    Text(UsageFormat.percent(share)).foregroundStyle(NookTheme.textSecondary).frame(width: 72, alignment: .trailing)
                    Text(UsageFormat.tokens(model.tokens.total)).foregroundStyle(NookTheme.textSecondary).frame(width: 72, alignment: .trailing)
                }
                .font(NookTheme.TextStyle.body.monospacedDigit())
                .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(hovering ? NookTheme.rowHover : Color.clear))
                NookDivider()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Tokens or cost per hour or day, one smooth band per agent stacked on the next. Pointing at a
/// column shows its figures.
struct UsageAgentChart: View {
    let insights: UsageInsights
    let metric: UsageMetric
    var height: CGFloat = 180
    @State private var selected: Date?

    var body: some View {
        let names = insights.agents.map { AgentKind(rawValue: $0.agent)?.shortName ?? $0.agent }
        let colors = insights.agents.map { UsageColors.agent($0.agent) }
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
            Chart {
                ForEach(insights.points) { point in
                    // No `unit:`: a unit centres each point inside its hour or day, half a column off the axis
                    // labels, which sit on the start of each hour or day.
                    AreaMark(x: .value("Time", point.column),
                             y: .value("Value", value(point)),
                             stacking: .standard)
                        .foregroundStyle(by: .value("Agent", AgentKind(rawValue: point.agent)?.shortName ?? point.agent))
                        .interpolationMethod(.monotone)
                        .opacity(0.85)
                }
                if let selected = selected.flatMap(nearestColumn) {
                    RuleMark(x: .value("Time", selected))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(selected)
                        }
                }
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartLegend(.hidden)
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(NookTheme.line2.opacity(0.6))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(metric == .cost ? UsageFormat.usd(number) : UsageFormat.tokens(Int(number)))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: insights.window.hourly ? 6 : 7)) { _ in
                    AxisValueLabel(format: insights.window.hourly ? Date.FormatStyle.dateTime.hour()
                                                                  : Date.FormatStyle.dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: height)
            .accessibilityLabel(title)
        }
    }

    private var title: String {
        switch (insights.window.hourly, metric) {
        case (true, .cost): return tr("usage.chart.hourlyCost")
        case (true, .tokens): return tr("usage.chart.hourlyTokens")
        case (false, .cost): return tr("usage.chart.dailyCost")
        case (false, .tokens): return tr("usage.chart.dailyTokens")
        }
    }

    private func value(_ point: UsageInsights.Point) -> Double {
        metric == .cost ? point.cost : Double(point.tokens)
    }

    /// The column whose point lies closest to the pointer, so the rule lands on a point of the curve.
    private func nearestColumn(_ date: Date) -> Date? {
        insights.points.map(\.column).min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    /// The column under the pointer: when, the total, and each agent with something in it.
    private func tooltip(_ column: Date) -> some View {
        let cells = insights.points.filter { $0.column == column && value($0) > 0 }
        let total = cells.map(value).reduce(0, +)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            Text(UsageDates.label(column, hourly: insights.window.hourly)).foregroundStyle(NookTheme.textSecondary)
            Text(metric == .cost ? UsageFormat.usd(total) : UsageFormat.tokens(Int(total)))
                .font(NookTheme.TextStyle.strong.monospacedDigit())
                .foregroundStyle(NookTheme.paper)
            ForEach(cells) { cell in
                HStack(spacing: NookTheme.Spacing.xs) {
                    Circle().fill(UsageColors.agent(cell.agent)).frame(width: 6, height: 6)
                    Text(AgentKind(rawValue: cell.agent)?.shortName ?? cell.agent).foregroundStyle(NookTheme.textSecondary)
                    Spacer(minLength: NookTheme.Spacing.md)
                    Text(metric == .cost ? UsageFormat.usd(cell.cost) : UsageFormat.tokens(cell.tokens))
                        .foregroundStyle(NookTheme.paper)
                        .monospacedDigit()
                }
            }
        }
        .font(NookTheme.TextStyle.detail)
        .padding(NookTheme.Spacing.md)
        .frame(minWidth: 150)
        .cardBackground(NookTheme.surface, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.card)
    }
}

/// One model up close: its cost, tokens, cost per million tokens and cache hit rate, its own trend, and its tokens and
/// cost by type. A model without a known price can get one here.
struct UsageModelSheet: View {
    let model: UsageInsights.ModelTotal
    let ledger: UsageLedger
    let window: UsageWindow
    let metric: UsageMetric
    @Binding var prices: PriceTable
    let close: () -> Void
    @State private var input = ""
    @State private var output = ""

    var body: some View {
        let insights = UsageInsights.make(ledger, window: window, prices: prices, agent: model.agent, model: model.model)
        let current = insights.models.first ?? model
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
            HStack(spacing: NookTheme.Spacing.md) {
                if let kind = AgentKind(rawValue: model.agent) { AgentLogo(kind, size: 20) }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(model.model).font(NookTheme.TextStyle.heading).foregroundStyle(NookTheme.paper)
                    Text(AgentKind(rawValue: model.agent)?.name ?? model.agent)
                        .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                }
                Spacer()
                Button(tr("button.close"), action: close).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: NookTheme.Spacing.xxl) {
                UsageMetricTile(label: tr("usage.column.cost"), value: current.cost.map { UsageFormat.usd($0.total) } ?? tr("usage.unpriced"))
                UsageMetricTile(label: tr("usage.column.tokens"), value: UsageFormat.tokens(current.tokens.total))
                if let perMillion = current.costPerMillion {
                    UsageMetricTile(label: tr("usage.perMillion"), value: UsageFormat.usd(perMillion))
                }
                if let hit = current.tokens.cacheHitRate {
                    UsageMetricTile(label: tr("usage.cacheHit"), value: UsageFormat.percent(hit))
                }
            }
            // Unknown cost is not zero: without a price the trend shows tokens.
            UsageAgentChart(insights: insights, metric: current.cost == nil ? .tokens : metric, height: 150)
            HStack(alignment: .top, spacing: NookTheme.Spacing.xxl) {
                UsageShareBar(label: tr("usage.tokensByType"), segments: UsageColors.tokenSegments(current.tokens),
                              format: { UsageFormat.tokens(Int($0)) })
                if let cost = current.cost {
                    UsageShareBar(label: tr("usage.costByType"), segments: UsageColors.costSegments(cost), format: UsageFormat.usd)
                }
            }
            priceEditor(current)
        }
        .padding(NookTheme.Spacing.xxl)
        .frame(width: 620)
        .background(NookTheme.canvas)
        .onAppear {
            let price = ModelRates.price(agent: model.agent, model: model.model, custom: prices)
            input = price?.inputPerMillion.map { String($0) } ?? ""
            output = price?.outputPerMillion.map { String($0) } ?? ""
        }
    }

    /// Your own price per million tokens for this model, used instead of the list price (cached reads at a tenth of input).
    private func priceEditor(_ current: UsageInsights.ModelTotal) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(current.cost == nil ? tr("usage.price.missing", UsageFormat.tokens(current.tokens.total)) : tr("usage.price.title"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
            HStack(spacing: NookTheme.Spacing.md) {
                TextField(tr("usage.price.input"), text: $input).textFieldStyle(.roundedBorder).frame(width: 120)
                TextField(tr("usage.price.output"), text: $output).textFieldStyle(.roundedBorder).frame(width: 120)
                Button(tr("usage.price.save")) {
                    guard let inputRate = Double(input.replacingOccurrences(of: ",", with: ".")),
                          let outputRate = Double(output.replacingOccurrences(of: ",", with: ".")) else { return }
                    prices.setPrice(ModelPrice(input: inputRate, output: outputRate, cacheRead: inputRate * 0.1, cacheWrite: inputRate * 1.25),
                                    provider: model.agent, model: model.model)
                    UsagePrices.save(prices)
                }
                .disabled(Double(input.replacingOccurrences(of: ",", with: ".")) == nil
                          || Double(output.replacingOccurrences(of: ",", with: ".")) == nil)
                if prices.models[PriceTable.key(provider: model.agent, model: model.model)] != nil {
                    Button(tr("usage.price.reset")) {
                        prices.resetPrice(provider: model.agent, model: model.model)
                        UsagePrices.save(prices)
                        let list = ModelRates.price(agent: model.agent, model: model.model)
                        input = list?.inputPerMillion.map { String($0) } ?? ""
                        output = list?.outputPerMillion.map { String($0) } ?? ""
                    }
                }
            }
        }
    }
}

/// Several accounts of one agent as one pool (`LimitPool`): per window the share left, a bar with a segment per account
/// (the part a coming reset gives back hatched), and when that reset lands.
struct UsageLimitPoolView: View {
    let kind: AgentKind
    let pool: LimitPool

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.md) {
                AgentLogo(kind, size: 18)
                Text(tr("usage.pool.title", kind.shortName)).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
            }
            ForEach(pool.windows) { window in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.label).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
                        Spacer()
                        Text(tr("usage.pool.left", Int(window.left.rounded())))
                            .font(NookTheme.TextStyle.strong.monospacedDigit())
                            .foregroundStyle(UsageTone.text(100 - window.left))
                    }
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(window.segments) { segment in
                            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                                segmentBar(segment, restores: segment.resetsAt == window.nextReset && window.nextReset != nil)
                                    .frame(height: 8)
                                segmentLabel(segment)
                            }
                            .help(segmentHelp(segment))
                        }
                    }
                    if let reset = window.nextReset {
                        Text(tr("usage.pool.reset", resettingNames(window), AgentFormat.reset(reset) ?? "", Int(window.restores.rounded())))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
            }
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    /// An account's part of the bar: what is left filled, what its next reset gives back hatched, a gap for a window it
    /// does not report.
    private func segmentBar(_ segment: LimitPool.Segment, restores: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 2).fill(NookTheme.smoke)
                if let left = segment.left {
                    if restores {
                        RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 2)
                            .fill(UsageColors.agent(kind.rawValue).opacity(0.3))
                    }
                    RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 2)
                        .fill(UsageColors.agent(kind.rawValue))
                        .frame(width: proxy.size.width * left / 100)
                }
            }
        }
        .opacity(segment.left == nil ? 0.35 : 1)
    }

    /// Which account a segment is: its name, and what it has left of this window.
    private func segmentLabel(_ segment: LimitPool.Segment) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text(segment.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text(segment.left.map { tr("usage.pool.segmentLeft", Int($0.rounded())) } ?? "–").monospacedDigit()
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textSecondary)
    }

    /// The accounts whose reset is the window's next one, so the reset line says whose limit comes back.
    private func resettingNames(_ window: LimitPool.Window) -> String {
        window.segments.filter { $0.resetsAt == window.nextReset }.map(\.name).joined(separator: ", ")
    }

    private func segmentHelp(_ segment: LimitPool.Segment) -> String {
        guard let left = segment.left else { return tr("usage.pool.notReported", segment.name) }
        let reset = segment.resetsAt.flatMap { AgentFormat.reset($0) } ?? ""
        return tr("usage.pool.segment", segment.name, Int(left.rounded()), reset)
    }
}

/// Per agent with two or more accounts that report limits: their pool (`LimitPool`), for Settings › Usage and the Usage
/// page in the Agents tab.
enum UsagePools {
    struct Entry: Identifiable {
        var kind: AgentKind
        var pool: LimitPool
        var id: String { kind.rawValue }
    }

    @MainActor
    static func entries(_ app: AppModel) -> [Entry] {
        let byKind = Dictionary(grouping: app.connectedProfiles, by: \.kind)
        return AgentKind.allCases.compactMap { kind in
            guard let profiles = byKind[kind], profiles.count > 1 else { return nil }
            let accounts = profiles.map { profile in
                LimitPool.Account(id: profile.id, name: AccountLabel.name(profile, app: app),
                                  limits: app.quota.limits(for: profile).map { LimitPool.Limit(label: $0.label, used: $0.percent, resetsAt: $0.resetsAt) })
            }
            return LimitPool.make(accounts).map { Entry(kind: kind, pool: $0) }
        }
    }
}

/// Cost and Tokens on the Usage page in the Agents tab: the same blocks as Settings › Usage, in the panel's own column.
struct UsageInsightsPanel: View {
    @ObservedObject var history: AgentHistory
    let metric: UsageMetric
    let window: UsageWindow
    @State private var byDay = false
    @State private var openModel: UsageInsights.ModelTotal?
    @State private var prices = UsagePrices.load()

    var body: some View {
        let insights = UsageInsights.make(history.ledger, window: window, prices: prices)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            UsageOverviewBlocks(insights: insights, metric: metric, window: window, loading: history.loading, byDay: $byDay) {
                openModel = $0
            }
            Text(tr("usage.footer"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $openModel) { model in
            UsageModelSheet(model: model, ledger: history.ledger, window: window, metric: metric, prices: $prices) { openModel = nil }
        }
        .onAppear { history.refresh(minimumInterval: 60) }
    }
}
