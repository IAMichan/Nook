import SwiftUI
import AppKit

/// What the three buttons at the bottom of the Agents list open on the right: your pull requests, or the usage of every
/// account. The settings button opens Settings › Agents.
enum AgentsPage {
    static let pullRequests = "pulls"
    static let usage = "usage"
}

/// Settings, pull requests and usage as quiet icons under the list.
struct AgentsFooter: View {
    @EnvironmentObject private var app: AppModel
    let selected: String
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            icon("gearshape", label: tr("agents.footer.settings"), active: false) { app.openSettings(section: .agents) }
            icon("arrow.triangle.pull", label: tr("agents.footer.pullRequests"), active: selected == AgentsPage.pullRequests) {
                open(AgentsPage.pullRequests)
            }
            icon("chart.bar", label: tr("agents.footer.usage"), active: selected == AgentsPage.usage) { open(AgentsPage.usage) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
    }

    private func icon(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        FooterIcon(symbol: symbol, label: label, active: active, action: action)
    }
}

private struct FooterIcon: View {
    let symbol: String
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textTertiary)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Color(hex: 0x17171A) : (hovering ? Color(hex: 0x111113) : Color.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Pull requests

/// Every open pull request of your GitHub accounts: the ones you wrote, and the ones waiting for your review. A click
/// opens the pull request on GitHub.
struct PullRequestsPanel: View {
    @EnvironmentObject private var app: AppModel
    @State private var accounts: [AccountPullRequests] = []
    @State private var loading = true
    @State private var loadedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(tr("agents.footer.pullRequests"))
                    .font(NookTheme.font(14, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) { Task { await reload() } }
            }
            .frame(height: 30)

            if !GitHubPullRequestList.isAvailable {
                empty(title: tr("agents.pulls.notConnected"), detail: tr("agents.pulls.notConnectedDetail"), action: (tr("agents.pulls.connect"), {
                    app.openSettings(section: .connections)
                }))
            } else if loadedOnce && accounts.allSatisfy({ $0.mine.isEmpty && $0.reviews.isEmpty && $0.error == nil }) {
                empty(title: tr("agents.pulls.none"), detail: tr("agents.pulls.noneDetail"), action: nil)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(accounts) { account in
                            accountSection(account, showName: accounts.count > 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(nanoseconds: 90_000_000_000)
            }
        }
    }

    private func reload() async {
        guard GitHubPullRequestList.isAvailable else {
            loading = false
            loadedOnce = true
            return
        }
        loading = true
        let fresh = await GitHubPullRequestList.load()
        accounts = fresh
        loading = false
        loadedOnce = true
    }

    private func empty(title: String, detail: String, action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(NookTheme.font(15, .semibold)).foregroundStyle(NookTheme.paper)
            Text(detail)
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                NookPrimaryButton(title: action.0, action: action.1).padding(.top, 4)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func accountSection(_ account: AccountPullRequests, showName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showName {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle").font(.system(size: 12))
                    Text(account.name).font(NookTheme.font(12.5, .semibold))
                    if !account.login.isEmpty { Text("@" + account.login).font(NookTheme.font(12)) }
                }
                .foregroundStyle(NookTheme.textSecondary)
            }
            if let error = account.error {
                Text(error)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !account.reviews.isEmpty {
                group(title: tr("agents.pulls.reviews", account.reviews.count), items: account.reviews, showAuthor: true)
            }
            if !account.mine.isEmpty {
                group(title: tr("agents.pulls.mine", account.mine.count), items: account.mine, showAuthor: false)
            }
        }
    }

    private func group(title: String, items: [PullRequestItem], showAuthor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(NookTheme.font(11.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.bottom, 3)
            ForEach(items) { item in
                PullRequestRow(item: item, showAuthor: showAuthor)
            }
        }
    }
}

private struct PullRequestRow: View {
    let item: PullRequestItem
    let showAuthor: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = item.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ci.frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NookTheme.font(13.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.id)
                        if showAuthor, !item.author.isEmpty { Text("· @" + item.author) }
                        if item.draft { Text("· " + tr("agents.pulls.draft")) }
                    }
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let updated = item.updated {
                    Text(AgentFormat.short(Date().timeIntervalSince(updated)))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color(hex: 0x111113) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("agents.pulls.open"))
    }

    @ViewBuilder
    private var ci: some View {
        switch item.ci {
        case .passing: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.mint)
        case .failing: Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.coral)
        case .pending: Circle().fill(NookTheme.amber).frame(width: 7, height: 7)
        case .unknown: Circle().stroke(NookTheme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }
}

// MARK: Usage

/// The usage of every account at once: the limits that agents report (5 hours and the week) and what was used in
/// tokens today and this week, per agent and account.
struct AgentsUsagePanel: View {
    @EnvironmentObject private var app: AppModel

    private var profiles: [AgentProfile] { app.profiles.all }

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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profiles) { profile in
                        card(profile)
                    }
                    Text(tr("agents.usage.note"))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { app.history.refresh() }
    }

    private func card(_ profile: AgentProfile) -> some View {
        let limits = app.quota.limits(for: profile)
        let usage = app.history.profileUsage[profile.id]
        let account = app.history.profileAccounts[profile.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentMark(agent: profile.kind.name, account: AccountKind.of(profile, app: app), size: 22, ring: Color(hex: 0x121214))
                    .padding(.trailing, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(profile.kind.name) · \(AccountLabel.name(profile, app: app))")
                        .font(NookTheme.font(13.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                    Text(account.map { $0.plan.isEmpty ? $0.name : "\($0.name) · \($0.plan)" } ?? tr("agents.notLoggedIn"))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if limits.isEmpty {
                Text(profile.kind == .gemini ? tr("agents.usage.geminiNoLimits") : tr("ws.usage.quotaUnavailable"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
            } else {
                ForEach(limits) { limit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(limit.label).foregroundStyle(NookTheme.textSecondary)
                            Spacer()
                            Text("\(Int(limit.percent.rounded()))%").foregroundStyle(AgentFormat.color(percent: limit.percent))
                            if let reset = AgentFormat.reset(limit.resetsAt) {
                                Text(reset).foregroundStyle(NookTheme.textTertiary)
                            }
                        }
                        .font(NookTheme.font(12))
                        Bar(fraction: limit.percent / 100, color: AgentFormat.color(percent: limit.percent))
                    }
                }
            }
            if usage == nil {
                Text(tr("agents.usage.none"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
            } else if let usage {
                HStack(spacing: 16) {
                    stat(tr("agents.usage.today"), TokenTally.format(usage.today.total))
                    stat(tr("agents.usage.week"), TokenTally.format(usage.week.total))
                    stat(tr("agents.usage.sessions"), "\(usage.sessionsWeek)")
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x121214)))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary)
            Text(value).font(NookTheme.font(13, .medium)).foregroundStyle(NookTheme.paper)
        }
    }
}
