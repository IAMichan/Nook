import SwiftUI
import Charts

/// Settings › Agents › Usage: subscription limits, tokens, costs, activity chart, and model breakdown.
struct UsageView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("ws.usage.range") private var range: UsageRange = .week
    @State private var provider: RunProvider?
    @State private var project: String?

    private var report: UsageReport {
        UsageReport.make(runs: workspace.runs, filter: UsageReport.Filter(range: range, provider: provider, model: nil, project: project))
    }

    var body: some View {
        let report = report
        Group {
            subscriptionsSection
            activitySection(report)
            chartSection(report)
            byModelSection(report)
            runningSection
        }
    }

    // MARK: - Subscriptions

    private var subscriptionsSection: some View {
        Section {
            // Every connected account, Gemini CLI included (it reports no limits: its tokens instead).
            ForEach(app.connectedProfiles) { profile in
                accountCard(profile)
            }
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(NookTheme.iris.opacity(0.18))
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NookTheme.iris)
                }
                .frame(width: 22, height: 22)
                Text(tr("settings.usage.brain"))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(settings.isLocalBrain ? tr("settings.usage.brainLocal") : tr("settings.usage.brainExternal", settings.provider.title))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 2)
        } header: {
            Text(tr("settings.agents.subscriptions"))
        } footer: {
            Text(tr("ws.usage.quotaNote"))
        }
    }

    /// One account: its logo and name, the fullest window as a badge, then every window as a bar, grouped per model.
    private func accountCard(_ profile: AgentProfile) -> some View {
        let limits = app.quota.limits(for: profile)
        let highest = limits.map(\.percent).max()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentLogo(profile.kind, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.kind.shortName)
                        .font(.subheadline.weight(.semibold))
                    Text(AccountLabel.name(profile, app: app))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let highest {
                    Text("\(Int(highest.rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Self.color(percent: highest))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Self.color(percent: highest).opacity(0.14)))
                }
            }
            if limits.isEmpty {
                Label(fallbackSummary(profile), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let groups = Self.grouped(limits)
                LazyVGrid(columns: groups.count > 1 ? [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)] : [GridItem(.flexible())],
                          alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if !group.name.isEmpty {
                                Text(group.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            ForEach(group.limits) { limit in
                                limitRow(limit)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func limitRow(_ limit: QuotaLimit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(limit.window)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let note = limit.note ?? AgentFormat.reset(limit.resetsAt) {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Self.color(percent: limit.percent))
            }
            meter(limit.percent / 100, color: Self.color(percent: limit.percent))
        }
    }

    /// A rounded bar, filled to `fraction`.
    private func meter(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 6)
    }

    /// The windows of one model ("Gemini 4 Pro"); plain windows ("5 hours") form one unnamed group.
    private struct LimitGroup: Identifiable {
        var name: String
        var limits: [QuotaLimit]
        var id: String { name }
    }

    /// Windows per model group, in the order they came.
    private static func grouped(_ limits: [QuotaLimit]) -> [LimitGroup] {
        var result: [LimitGroup] = []
        for limit in limits {
            let name = limit.group ?? ""
            if let index = result.firstIndex(where: { $0.name == name }) {
                result[index].limits.append(limit)
            } else {
                result.append(LimitGroup(name: name, limits: [limit]))
            }
        }
        return result
    }

    private static func color(percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// Without limits: today's and this week's tokens from the agent's conversations, or why nothing is known.
    private func fallbackSummary(_ profile: AgentProfile) -> String {
        if profile.kind == .gemini, let usage = app.history.profileUsage[profile.id] {
            return tr("settings.usage.tokens", TokenTally.format(usage.today.total), TokenTally.format(usage.week.total))
        }
        switch profile.kind {
        case .claude: return tr("settings.usage.claudeMissing")
        case .codex: return tr("settings.usage.codexMissing")
        case .gemini: return tr("agents.usage.geminiNoLimits")
        case .opencode, .cursor, .grok, .acp: return tr("agents.usage.acpNoLimits")
        case .antigravity: return app.antigravityUsage.noLogin ? tr("agents.usage.antigravitySignIn") : tr("ws.usage.quotaUnavailable")
        }
    }

    // MARK: - Activity & Totals

    private func activitySection(_ report: UsageReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Period range selector
                Picker(tr("ws.usage.range"), selection: $range) {
                    ForEach(UsageRange.allCases) { Text(tr("ws.usage.range." + $0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Filter pickers
                HStack(spacing: 12) {
                    Picker(selection: $provider) {
                        Text(tr("ws.usage.allProviders")).tag(RunProvider?.none)
                        ForEach(RunProvider.allCases) { provider in
                            Label { Text(provider.displayName) } icon: { LogoImage.agent(provider.kind) }
                                .tag(RunProvider?.some(provider))
                        }
                    } label: {
                        Text(tr("ws.usage.provider"))
                    }
                    .pickerStyle(.menu)

                    Picker(selection: $project) {
                        Text(tr("ws.sidebar.allProjects")).tag(String?.none)
                        ForEach(Array(Set(workspace.runs.map(\.projectPath))).sorted(), id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                        }
                    } label: {
                        Text(tr("ws.usage.project"))
                    }
                    .pickerStyle(.menu)
                }

                Divider()

                // 3x2 metric cards
                totalsGrid(report)
            }
            .padding(.vertical, 4)
        } header: {
            Text(tr("ws.usage.title"))
        }
    }

    private func totalsGrid(_ report: UsageReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                metricCell(
                    title: tr("ws.usage.sessions"),
                    value: "\(report.sessions)",
                    detail: tr("ws.usage.sessionsDetail", report.completed, report.failed, report.running)
                )
                metricCell(
                    title: tr("ws.usage.input"),
                    value: TokenTally.format(report.inputTokens),
                    detail: nil
                )
                metricCell(
                    title: tr("ws.usage.output"),
                    value: TokenTally.format(report.outputTokens),
                    detail: nil
                )
            }
            GridRow {
                metricCell(
                    title: tr("ws.usage.cacheRead"),
                    value: TokenTally.format(report.cacheReadTokens),
                    detail: report.cacheWriteTokens > 0 ? tr("ws.usage.cacheWriteDetail", TokenTally.format(report.cacheWriteTokens)) : nil
                )
                metricCell(
                    title: tr("ws.usage.cost"),
                    value: workspace.settings.showCost && report.reportedCostUSD != nil ? AgentPathFormat.cost(report.reportedCostUSD!) : tr("ws.unavailable"),
                    detail: workspace.settings.showCost
                        ? (report.reportedCostUSD != nil ? tr("ws.usage.costCoverage", report.sessionsWithCost, report.sessions) : tr("ws.usage.noCostReported"))
                        : tr("ws.usage.costHidden"),
                    muted: !workspace.settings.showCost || report.reportedCostUSD == nil
                )
                metricCell(
                    title: tr("ws.usage.perSession"),
                    value: report.averageTokensPerSession.map { TokenTally.format($0) } ?? tr("ws.unavailable"),
                    detail: tr("ws.usage.tokensCoverage", report.sessionsWithTokens, report.sessions),
                    muted: report.averageTokensPerSession == nil
                )
            }
        }
    }

    private func metricCell(title: String, value: String, detail: String?, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(muted ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(" ")
                    .font(.system(size: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Chart

    private func chartSection(_ report: UsageReport) -> some View {
        Section {
            if report.days.isEmpty {
                Text(tr("ws.usage.noData"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
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
                    RunProvider.codex.displayName: RunProvider.codex.color,
                    RunProvider.gemini.displayName: RunProvider.gemini.color,
                    RunProvider.opencode.displayName: RunProvider.opencode.color,
                    RunProvider.cursor.displayName: RunProvider.cursor.color,
                    RunProvider.grok.displayName: RunProvider.grok.color
                ])
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) { Text(TokenTally.format(tokens)) }
                        }
                    }
                }
                .frame(height: 160)
                .padding(.vertical, 4)
                .accessibilityLabel(tr("ws.usage.overTime"))
            }
        } header: {
            Text(tr("ws.usage.overTime"))
        }
    }

    // MARK: - By Model

    private func byModelSection(_ report: UsageReport) -> some View {
        Section {
            if report.rows.isEmpty {
                Text(tr("ws.usage.noData"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(report.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    AgentLogo(row.provider.kind, size: 14)
                                    Text(row.provider.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(row.model == "default" ? tr("ws.model.default") : row.model)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(row.sessions) \(tr("ws.usage.sessions").lowercased())" + (row.sessionsWithoutTokens > 0 ? " (\(tr("ws.usage.withoutTokens", row.sessionsWithoutTokens)))" : ""))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(tr("ws.usage.inOut", TokenTally.format(row.inputTokens), TokenTally.format(row.outputTokens)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if workspace.settings.showCost {
                                        Text(costText(row))
                                            .font(.subheadline.weight(.medium).monospacedDigit())
                                            .foregroundStyle(row.reportedCostUSD == nil ? Color.secondary : Color.primary)
                                    }
                                }
                                if row.provider.capabilities.reportsCacheTokens && row.cacheReadTokens > 0 {
                                    Text(tr("ws.usage.cache", TokenTally.format(row.cacheReadTokens)))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        meter(share(of: row, in: report), color: row.provider.color)
                    }
                    .padding(.vertical, 3)
                }
            }
        } header: {
            Text(tr("ws.usage.byModel"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("ws.usage.note.claude"))
                Text(tr("ws.usage.note.codex"))
                Text(tr("ws.usage.note.scope"))
            }
        }
    }

    /// The row's tokens relative to the busiest row, for the bar under it.
    private func share(of row: UsageReport.Row, in report: UsageReport) -> Double {
        func tokens(_ row: UsageReport.Row) -> Int { row.inputTokens + row.outputTokens + row.cacheReadTokens }
        guard let busiest = report.rows.map(tokens).max(), busiest > 0 else { return 0 }
        return Double(tokens(row)) / Double(busiest)
    }

    private func costText(_ row: UsageReport.Row) -> String {
        guard workspace.settings.showCost else { return "—" }
        if let cost = row.reportedCostUSD { return AgentPathFormat.cost(cost) }
        return row.provider.capabilities.reportsCost ? tr("ws.unavailable") : tr("ws.usage.notReported")
    }

    // MARK: - Running Now

    @ViewBuilder
    private var runningSection: some View {
        let active = workspace.activeRuns
        if !active.isEmpty {
            Section {
                ForEach(active) { run in
                    Button {
                        workspace.selectedRunID = run.id
                    } label: {
                        HStack(spacing: 8) {
                            StatusBadge(status: run.status, compact: true)
                            Text(run.title).lineLimit(1)
                            Spacer()
                            Text(run.usage.totalTokens.map { TokenTally.format($0) + " tokens" } ?? tr("ws.usage.firstTurnPending"))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(tr("ws.usage.runningNow"))
            } footer: {
                Text(tr("ws.usage.runningNote"))
            }
        }
    }
}
