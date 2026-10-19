import SwiftUI
import Charts

/// Settings › Usage: the plan limits of every connected account, then what the sessions Nook started used, per day and
/// per model. Plain Settings rows in the Nook palette; limits look exactly like in the notch (see UsageTone, UsageBar).
struct UsageView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @AppStorage("ws.usage.range") private var range: UsageRange = .week
    @State private var provider: RunProvider?

    var body: some View {
        let report = UsageReport.make(runs: workspace.runs, filter: UsageReport.Filter(range: range, provider: provider, model: nil, project: nil))
        Group {
            limitsSection
            activitySection(report)
            if !report.rows.isEmpty {
                byModelSection(report)
            }
        }
    }

    // MARK: - Plan limits

    private var limitsSection: some View {
        Section {
            if app.connectedProfiles.isEmpty {
                Text(tr("agents.noneConnected"))
                    .foregroundStyle(.secondary)
            }
            ForEach(app.connectedProfiles) { profile in
                accountRow(profile)
            }
        } header: {
            Text(tr("settings.agents.subscriptions"))
        } footer: {
            Text(tr("ws.usage.quotaNote"))
        }
    }

    /// One account: logo, agent and account name, then each limit it reports, lined up under the name.
    private func accountRow(_ profile: AgentProfile) -> some View {
        let limits = app.quota.limits(for: profile)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AgentLogo(profile.kind, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.kind.shortName)
                    Text(AccountLabel.name(profile, app: app))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Group {
                if limits.isEmpty {
                    Text(fallbackSummary(profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(limits) { limit in
                            limitRow(limit, accent: profile.kind.color)
                        }
                    }
                }
            }
            .padding(.leading, 34)
        }
        .padding(.vertical, 4)
    }

    private func limitRow(_ limit: QuotaLimit, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(limit.label)
                    .font(.callout)
                    .lineLimit(1)
                if let note = limit.note ?? AgentFormat.reset(limit.resetsAt) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(UsageTone.text(limit.percent))
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let pace = limit.elapsed(at: context.date)
                UsageBar(fraction: limit.percent / 100, color: UsageTone.fill(limit.percent, accent: accent), pace: pace)
                    .help(pace.map { tr("agents.usage.pace", Int(($0 * 100).rounded())) } ?? "")
            }
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
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    stat(tr("ws.usage.sessions"), "\(report.sessions)")
                    stat(tr("settings.usage.tokensTitle"), TokenTally.format(report.inputTokens + report.outputTokens))
                    if workspace.settings.showCost {
                        stat(tr("ws.usage.cost"), report.reportedCostUSD.map { AgentPathFormat.cost($0) } ?? "—")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
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
        .padding(.vertical, 4)
        .accessibilityLabel(tr("ws.usage.overTime"))
    }

    // MARK: - Per model

    private func byModelSection(_ report: UsageReport) -> some View {
        Section {
            ForEach(report.rows) { row in
                HStack(spacing: 12) {
                    AgentLogo(row.provider.kind, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.model == "default" ? tr("ws.model.default") : row.model)
                            .lineLimit(1)
                        Text("\(row.provider.displayName) · \(row.sessions) \(tr("ws.usage.sessions").lowercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(TokenTally.format(row.inputTokens + row.outputTokens))
                            .monospacedDigit()
                        if workspace.settings.showCost {
                            Text(costText(row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 2)
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
