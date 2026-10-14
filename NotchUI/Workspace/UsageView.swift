import SwiftUI
import Charts

/// Gebruik van de werkruimte: tokens en gemelde kosten per agent en model, door de tijd heen.
/// Alleen wat de agents zelf doorgaven. Wat ze niet melden, staat er als "niet beschikbaar".
struct UsageView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @AppStorage("ws.usage.range") private var range: UsageRange = .week
    @State private var provider: RunProvider?
    @State private var project: String?

    private var report: UsageReport {
        UsageReport.make(runs: workspace.runs, filter: UsageReport.Filter(range: range, provider: provider, model: nil, project: project))
    }

    var body: some View {
        let report = report
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                totals(report)
                chart(report)
                table(report)
                running
                accountQuotas
                notes
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("ws.usage.title")).font(NookTheme.font(17, .semibold))
                Text(tr("ws.usage.subtitle")).font(NookTheme.font(12)).foregroundStyle(WS.secondary)
            }
            Spacer()
            Picker(tr("ws.usage.range"), selection: $range) {
                ForEach(UsageRange.allCases) { Text(tr("ws.usage.range." + $0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            Picker(tr("ws.usage.provider"), selection: $provider) {
                Text(tr("ws.usage.allProviders")).tag(RunProvider?.none)
                ForEach(RunProvider.allCases) { Text($0.displayName).tag(RunProvider?.some($0)) }
            }
            .frame(width: 170)
            Picker(tr("ws.usage.project"), selection: $project) {
                Text(tr("ws.sidebar.allProjects")).tag(String?.none)
                ForEach(Array(Set(workspace.runs.map(\.projectPath))).sorted(), id: \.self) { path in
                    Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                }
            }
            .frame(width: 170)
        }
        .labelsHidden()
    }

    private func totals(_ report: UsageReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
            GridRow {
                metricLabel(tr("ws.usage.sessions"))
                metricLabel(tr("ws.usage.input"))
                metricLabel(tr("ws.usage.output"))
                metricLabel(tr("ws.usage.cacheRead"))
                metricLabel(tr("ws.usage.cost"))
                metricLabel(tr("ws.usage.perSession"))
            }
            GridRow {
                metric("\(report.sessions)", detail: tr("ws.usage.sessionsDetail", report.completed, report.failed, report.running))
                metric(TokenTally.format(report.inputTokens), detail: nil)
                metric(TokenTally.format(report.outputTokens), detail: nil)
                metric(TokenTally.format(report.cacheReadTokens), detail: report.cacheWriteTokens > 0 ? tr("ws.usage.cacheWriteDetail", TokenTally.format(report.cacheWriteTokens)) : nil)
                if workspace.settings.showCost, let cost = report.reportedCostUSD {
                    metric(AgentPathFormat.cost(cost), detail: tr("ws.usage.costCoverage", report.sessionsWithCost, report.sessions))
                } else {
                    metric(tr("ws.unavailable"), detail: workspace.settings.showCost ? tr("ws.usage.noCostReported") : tr("ws.usage.costHidden"), muted: true)
                }
                metric(report.averageTokensPerSession.map { TokenTally.format($0) } ?? tr("ws.unavailable"),
                       detail: tr("ws.usage.tokensCoverage", report.sessionsWithTokens, report.sessions),
                       muted: report.averageTokensPerSession == nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(WS.surface))
    }

    private func metricLabel(_ text: String) -> some View {
        Text(text).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
    }

    private func metric(_ value: String, detail: String?, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(NookTheme.font(16, .semibold))
                .monospacedDigit()
                .foregroundStyle(muted ? WS.tertiary : WS.text)
            Text(detail ?? " ").font(NookTheme.font(10.5)).foregroundStyle(WS.tertiary).lineLimit(1)
        }
    }

    @ViewBuilder
    private func chart(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.usage.overTime"))
            if report.days.isEmpty {
                Text(tr("ws.usage.noData")).font(NookTheme.font(12)).foregroundStyle(WS.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(report.days) { day in
                    BarMark(
                        x: .value(tr("ws.usage.day"), day.day, unit: .day),
                        y: .value("Tokens", day.tokens)
                    )
                    .foregroundStyle(by: .value(tr("ws.usage.provider"), day.provider.displayName))
                    .cornerRadius(2)
                }
                .chartForegroundStyleScale([
                    RunProvider.claude.displayName: RunProvider.claude.color,
                    RunProvider.codex.displayName: RunProvider.codex.color
                ])
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(WS.border)
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) { Text(TokenTally.format(tokens)) }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel(tr("ws.usage.overTime"))
            }
        }
    }

    private func table(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.usage.byModel"))
            if report.rows.isEmpty {
                Text(tr("ws.usage.noData")).font(NookTheme.font(12)).foregroundStyle(WS.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow {
                        ForEach([tr("ws.usage.provider"), tr("ws.inspector.model"), tr("ws.usage.sessions"), tr("ws.usage.input"),
                                 tr("ws.usage.output"), tr("ws.usage.cacheRead"), tr("ws.usage.cost")], id: \.self) { metricLabel($0) }
                    }
                    Divider().gridCellColumns(7)
                    ForEach(report.rows) { row in
                        GridRow {
                            HStack(spacing: 5) {
                                Circle().fill(row.provider.color).frame(width: 6, height: 6)
                                Text(row.provider.displayName)
                            }
                            Text(row.model == "default" ? tr("ws.model.default") : row.model).font(NookTheme.mono(11.5))
                            Text("\(row.sessions)" + (row.sessionsWithoutTokens > 0 ? " (\(tr("ws.usage.withoutTokens", row.sessionsWithoutTokens)))" : ""))
                            Text(TokenTally.format(row.inputTokens)).monospacedDigit()
                            Text(TokenTally.format(row.outputTokens)).monospacedDigit()
                            Text(row.provider.capabilities.reportsCacheTokens ? TokenTally.format(row.cacheReadTokens) : tr("ws.unavailable")).monospacedDigit()
                            Text(costText(row)).foregroundStyle(row.reportedCostUSD == nil ? WS.tertiary : WS.text)
                        }
                        .font(NookTheme.font(12))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(WS.surface))
            }
        }
    }

    private func costText(_ row: UsageReport.Row) -> String {
        guard workspace.settings.showCost else { return "—" }
        if let cost = row.reportedCostUSD { return AgentPathFormat.cost(cost) }
        return row.provider.capabilities.reportsCost ? tr("ws.unavailable") : tr("ws.usage.notReported")
    }

    @ViewBuilder
    private var running: some View {
        let active = workspace.activeRuns
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WSSectionTitle(title: tr("ws.usage.runningNow"))
                ForEach(active) { run in
                    Button { workspace.selectedRunID = run.id } label: {
                        HStack(spacing: 8) {
                            StatusBadge(status: run.status, compact: true)
                            Text(run.title).lineLimit(1)
                            Spacer()
                            Text(run.usage.totalTokens.map { TokenTally.format($0) + " tokens" } ?? tr("ws.usage.firstTurnPending"))
                                .foregroundStyle(WS.secondary)
                        }
                        .font(NookTheme.font(12))
                    }
                    .buttonStyle(.plain)
                }
                Text(tr("ws.usage.runningNote")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
            }
        }
    }

    /// Quota van het account (niet van de sessies hier): alleen wat Claude Code via de statusregel of Codex zelf meldt.
    private var accountQuotas: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.usage.accountQuotas"))
            ForEach(app.profiles.all.filter { $0.kind != .gemini }) { profile in
                HStack(spacing: 8) {
                    Circle().fill(profile.kind.color).frame(width: 6, height: 6)
                    Text("\(profile.kind.shortName) · \(AccountLabel.name(profile, app: app))").font(NookTheme.font(12, .medium))
                    Spacer()
                    Text(quota(profile) ?? tr("ws.usage.quotaUnavailable"))
                        .font(NookTheme.font(12))
                        .foregroundStyle(quota(profile) == nil ? WS.tertiary : WS.secondary)
                }
            }
            Text(tr("ws.usage.quotaNote")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(WS.surface))
    }

    private func quota(_ profile: AgentProfile) -> String? {
        switch profile.kind {
        case .claude: return app.hub.subscriptionUsage(for: profile)?.label
        case .codex:
            guard profile.isDefault, let snapshot = app.codex.snapshot else { return nil }
            let parts = [snapshot.fiveHourLabel, snapshot.weeklyLabel].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .gemini: return nil
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("ws.usage.note.claude")).fixedSize(horizontal: false, vertical: true)
            Text(tr("ws.usage.note.codex")).fixedSize(horizontal: false, vertical: true)
            Text(tr("ws.usage.note.scope")).fixedSize(horizontal: false, vertical: true)
        }
        .font(NookTheme.font(11))
        .foregroundStyle(WS.tertiary)
    }
}
