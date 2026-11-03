import SwiftUI
import Charts

/// Settings › Coding agents: the plan limits of every connected account, then what the sessions Nook started used, per day and
/// per model. Plain Settings rows in the Nook palette; limits look exactly like in the composer (see UsageLimitRows).
struct UsageView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @AppStorage("ws.usage.range") private var range: UsageRange = .week
    @State private var provider: RunProvider?
    @State private var showLimits = false

    var body: some View {
        let report = UsageReport.make(runs: workspace.runs, filter: UsageReport.Filter(range: range, provider: provider, model: nil, project: nil))
        Group {
            // Every agent on this Mac, from their own transcripts: cost, tokens, models and charts.
            UsageInsightsView(history: app.history)
            limitsSection
            activitySection(report)
            if !report.rows.isEmpty {
                byModelSection(report)
            }
        }
        .task { await app.watchQuotas() }
    }

    // MARK: - Plan limits

    private var limitsSection: some View {
        Section {
            if app.connectedProfiles.isEmpty {
                Text(tr("agents.noneConnected"))
                    .foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(app.connectedProfiles) { profile in
                accountRow(profile)
            }
        } header: {
            HStack {
                Text(tr("settings.agents.subscriptions"))
                Spacer()
                SmallGhostButton(title: tr("limits.all")) { showLimits = true }
                    .help(tr("limits.openHelp"))
                    .sheet(isPresented: $showLimits) { UsageLimitsModal { showLimits = false }.frame(width: 720).environmentObject(app) }
                UsageRefreshButton()
            }
        } footer: {
            Text(tr("ws.usage.quotaNote"))
        }
    }

    /// One account: logo, agent and account name, then a line per limit it reports (`UsageLimitRows`). Read again every
    /// minute, so the reset times in the tooltips count down.
    private func accountRow(_ profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.lg) {
                AgentLogo(profile.kind, size: 22)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(profile.kind.shortName)
                    Text(AccountLabel.name(profile, app: app))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Group {
                TimelineView(.nookTicks(every: 60)) { context in
                    UsageLimitRows(limits: app.quota.limits(for: profile), unavailable: fallbackSummary(profile), now: context.date)
                }
                ResetCreditRow(profile: profile)
            }
            // The rows' own inset lines their labels up with the account's name.
            .padding(.leading, 34 - NookTheme.Spacing.md - NookTheme.Spacing.xxs)
        }
        .padding(.vertical, NookTheme.Spacing.xs)
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

    // MARK: - Sessions started in Nook

    private func activitySection(_ report: UsageReport) -> some View {
        Section {
            Picker(tr("ws.usage.range"), selection: $range) {
                ForEach(UsageRange.allCases) { Text(tr("ws.usage.range." + $0.rawValue)).tag($0) }
            }
            Picker(tr("ws.usage.provider"), selection: $provider) {
                Text(tr("ws.usage.allProviders")).tag(RunProvider?.none)
                ForEach(RunProvider.allCases) { provider in
                    Label { Text(provider.displayName) } icon: { LogoImage.agent(provider.kind) }
                        .tag(RunProvider?.some(provider))
                }
            }
            if report.sessions == 0 {
                Text(tr("ws.usage.noData"))
                    .foregroundStyle(NookTheme.textSecondary)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    stat(tr("ws.usage.sessions"), "\(report.sessions)")
                    stat(tr("settings.usage.tokensTitle"), TokenTally.format(report.inputTokens + report.outputTokens))
                    if workspace.settings.showCost {
                        stat(tr("ws.usage.cost"), report.reportedCostUSD.map { AgentPathFormat.cost($0) } ?? "—")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, NookTheme.Spacing.xs)
                if !report.days.isEmpty {
                    chart(report)
                }
            }
        } header: {
            Text(tr("settings.usage.activity"))
        } footer: {
            Text(tr("ws.usage.note.scope"))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            Text(title)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
            Text(value)
                .font(NookTheme.TextStyle.title)
                .monospacedDigit()
        }
    }

    private func chart(_ report: UsageReport) -> some View {
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
                AxisGridLine().foregroundStyle(NookTheme.line2.opacity(0.6))
                AxisValueLabel {
                    if let tokens = value.as(Int.self) { Text(TokenTally.format(tokens)) }
                }
            }
        }
        .frame(height: 140)
        .padding(.vertical, NookTheme.Spacing.xs)
        .accessibilityLabel(tr("ws.usage.overTime"))
    }

    // MARK: - Per model

    private func byModelSection(_ report: UsageReport) -> some View {
        Section {
            ForEach(report.rows) { row in
                HStack(spacing: NookTheme.Spacing.lg) {
                    AgentLogo(row.provider.kind, size: 22)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(row.model == "default" ? tr("ws.model.default") : row.model)
                            .lineLimit(1)
                        Text("\(row.provider.displayName) · \(row.sessions) \(tr("ws.usage.sessions").lowercased())")
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: NookTheme.Spacing.xxs) {
                        Text(TokenTally.format(row.inputTokens + row.outputTokens))
                            .monospacedDigit()
                        if workspace.settings.showCost {
                            Text(costText(row))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, NookTheme.Spacing.xxs)
            }
        } header: {
            Text(tr("ws.usage.byModel"))
        }
    }

    private func costText(_ row: UsageReport.Row) -> String {
        if let cost = row.reportedCostUSD { return AgentPathFormat.cost(cost) }
        return row.provider.capabilities.reportsCost ? tr("ws.unavailable") : tr("ws.usage.notReported")
    }
}
