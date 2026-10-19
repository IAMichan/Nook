import SwiftUI
import AppKit

/// What the buttons at the bottom of the Agents list open on the right: your pull requests, the usage of every account,
/// and the tools that are not tied to one session: every terminal, the browser, every worktree.
enum AgentsPage {
    static let pullRequests = "pulls"
    static let usage = "usage"
    static let terminals = "terminals"
    static let browser = "browser"
    static let worktrees = "worktrees"
    static let simulator = "simulator"
    /// The pages that are a tool you work in: the panel widens for them and stays open.
    static let tools: Set<String> = [terminals, browser, worktrees, simulator]
}

/// Pull requests and usage as quiet icons under the list, then the tools.
struct AgentsFooter: View {
    let selected: String
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            FooterIcon(label: tr("agents.footer.pullRequests"), active: selected == AgentsPage.pullRequests,
                       action: { open(AgentsPage.pullRequests) }) { PullRequestGlyph() }
            FooterIcon(label: tr("agents.footer.usage"), active: selected == AgentsPage.usage,
                       action: { open(AgentsPage.usage) }) { UsageGlyph() }
            Rectangle().fill(NookTheme.line2).frame(width: 1, height: 16).padding(.horizontal, 4)
            FooterIcon(label: tr("agents.footer.terminals"), active: selected == AgentsPage.terminals,
                       action: { open(AgentsPage.terminals) }) { ToolGlyph(symbol: "terminal") }
            FooterIcon(label: tr("agents.footer.browser"), active: selected == AgentsPage.browser,
                       action: { open(AgentsPage.browser) }) { ToolGlyph(symbol: "safari") }
            FooterIcon(label: tr("agents.footer.worktrees"), active: selected == AgentsPage.worktrees,
                       action: { open(AgentsPage.worktrees) }) { WorktreeGlyph() }
            FooterIcon(label: tr("agents.footer.simulator"), active: selected == AgentsPage.simulator,
                       action: { open(AgentsPage.simulator) }) { ToolGlyph(symbol: "iphone") }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }
}

private struct FooterIcon<Glyph: View>: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @ViewBuilder var glyph: () -> Glyph
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph()
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

/// Two nodes joined by a line, and a third one the line bends to: the pull request mark, drawn in the same line weight
/// as the rest of the list.
private struct PullRequestGlyph: View {
    var body: some View { PullRequestStateGlyph(glyph: .open) }
}

/// The pull request marks GitHub uses, drawn on a 16-point grid so they stay crisp at any size: open (a node, a line,
/// and a second line that bends back with an arrow), draft (the bend replaced by dots), merged (a branch curving back
/// into the main line), closed (the arrow replaced by a cross), a conflict (an exclamation mark beside the line) and a
/// stack (three nodes in a chain).
struct PullRequestStateGlyph: View {
    let glyph: PullRequestBadge.Glyph
    var size: CGFloat = 16
    /// In grid units; a small glyph wants a heavier line to read as the same weight.
    var lineWidth: CGFloat = 1.3
    var nodeRadius: CGFloat = 1.6

    var body: some View {
        Canvas { context, canvas in
            let unit = min(canvas.width, canvas.height) / 16
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            let style = StrokeStyle(lineWidth: lineWidth * unit, lineCap: .round, lineJoin: .round)
            let r = nodeRadius
            var lines = Path()
            var nodes: [CGPoint] = []
            var dots: [CGPoint] = []

            func trunk() {
                lines.move(to: point(4, 3.6 + r)); lines.addLine(to: point(4, 12.4 - r))
                nodes += [point(4, 3.6), point(4, 12.4)]
            }

            switch glyph {
            case .open:
                trunk()
                lines.move(to: point(12, 12.4 - r)); lines.addLine(to: point(12, 7))
                lines.addQuadCurve(to: point(10, 4.8), control: point(12, 4.8))
                lines.addLine(to: point(8.6, 4.8))
                lines.move(to: point(10.2, 3.2)); lines.addLine(to: point(8.6, 4.8)); lines.addLine(to: point(10.2, 6.4))
                nodes.append(point(12, 12.4))
            case .draft:
                trunk()
                lines.move(to: point(12, 12.4 - r)); lines.addLine(to: point(12, 8.6))
                nodes.append(point(12, 12.4))
                dots += [point(12, 6), point(12, 3.4)]
            case .closed:
                trunk()
                lines.move(to: point(12, 12.4 - r)); lines.addLine(to: point(12, 8.2))
                lines.move(to: point(10.2, 2.8)); lines.addLine(to: point(13.8, 6.4))
                lines.move(to: point(13.8, 2.8)); lines.addLine(to: point(10.2, 6.4))
                nodes.append(point(12, 12.4))
            case .conflict:
                trunk()
                lines.move(to: point(12, 2.8)); lines.addLine(to: point(12, 9))
                dots.append(point(12, 12.6))
            case .merged:
                trunk()
                lines.move(to: point(4, 3.6 + r))
                lines.addQuadCurve(to: point(12 - r, 9.6), control: point(4, 9.6))
                nodes.append(point(12, 9.6))
            case .stack:
                nodes += [point(3.6, 12.4), point(8, 8), point(12.4, 3.6)]
                let step = r * 0.7071
                lines.move(to: point(3.6 + step, 12.4 - step)); lines.addLine(to: point(8 - step, 8 + step))
                lines.move(to: point(8 + step, 8 - step)); lines.addLine(to: point(12.4 - step, 3.6 + step))
            }

            context.stroke(lines, with: .foreground, style: style)
            for center in nodes {
                let node = Path(ellipseIn: CGRect(x: center.x - r * unit, y: center.y - r * unit, width: 2 * r * unit, height: 2 * r * unit))
                context.stroke(node, with: .foreground, style: style)
            }
            let dot = lineWidth * 0.75
            for center in dots {
                context.fill(Path(ellipseIn: CGRect(x: center.x - dot * unit, y: center.y - dot * unit, width: 2 * dot * unit, height: 2 * dot * unit)),
                             with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A branch that leaves the line and ends in a folder: a second checkout of the same repository.
private struct WorktreeGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 16
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            let style = StrokeStyle(lineWidth: 1.3 * unit, lineCap: .round, lineJoin: .round)
            var lines = Path()
            lines.move(to: point(4, 5.2)); lines.addLine(to: point(4, 10.8))
            lines.move(to: point(4, 10.4)); lines.addQuadCurve(to: point(6.6, 7.8), control: point(4, 7.8))
            lines.addLine(to: point(8, 7.8))
            var folder = Path()
            folder.move(to: point(8, 10.4)); folder.addLine(to: point(8, 4.6))
            folder.addQuadCurve(to: point(9, 3.6), control: point(8, 3.6))
            folder.addLine(to: point(10.5, 3.6)); folder.addLine(to: point(11.7, 4.9)); folder.addLine(to: point(13.8, 4.9))
            folder.addQuadCurve(to: point(14.8, 5.9), control: point(14.8, 4.9))
            folder.addLine(to: point(14.8, 10.4))
            folder.addQuadCurve(to: point(13.8, 11.4), control: point(14.8, 11.4))
            folder.addLine(to: point(9, 11.4))
            folder.addQuadCurve(to: point(8, 10.4), control: point(8, 11.4))
            folder.closeSubpath()
            context.stroke(lines, with: .foreground, style: style)
            context.stroke(folder, with: .foreground, style: style)
            for center in [point(4, 3.6), point(4, 12.4)] {
                let node = Path(ellipseIn: CGRect(x: center.x - 1.6 * unit, y: center.y - 1.6 * unit, width: 3.2 * unit, height: 3.2 * unit))
                context.stroke(node, with: .foreground, style: style)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// A tool's symbol at the size of the drawn glyphs beside it.
private struct ToolGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .regular))
            .frame(width: 16, height: 16)
    }
}

/// Three bars of different height.
private struct UsageGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 16
            let style = StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round)
            var bars = Path()
            for (x, top) in [(3.5, 9.0), (8.0, 3.0), (12.5, 6.0)] as [(CGFloat, CGFloat)] {
                bars.move(to: CGPoint(x: x * unit, y: 13.5 * unit))
                bars.addLine(to: CGPoint(x: x * unit, y: top * unit))
            }
            context.stroke(bars, with: .foreground, style: style)
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: Pull requests

/// Every open pull request of your GitHub accounts: the ones you wrote, and the ones waiting for your review. A click
/// opens the pull request in Nook (see PullRequestDetailView), where it can be read in full and merged.
struct PullRequestsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = PullRequestStore.shared
    private var accounts: [AccountPullRequests] { store.accounts }
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    /// The pull request shown in full, with the account it is listed under.
    @State private var opened: (account: String, item: PullRequestItem)?

    var body: some View {
        if let opened {
            PullRequestDetailView(accountID: opened.account, item: opened.item) { self.opened = nil }
                .id(opened.account + " " + opened.item.id)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(tr("agents.footer.pullRequests"))
                    .font(NookTheme.font(14, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) { Task { await store.refresh(force: true) } }
            }
            .frame(height: 30)

            if store.loaded && !store.available && accounts.isEmpty {
                empty(title: tr("agents.pulls.notConnected"), detail: tr("agents.pulls.notConnectedDetail"), action: (tr("agents.pulls.connect"), {
                    app.openSettings(section: .connections)
                }))
            } else if store.loaded && accounts.allSatisfy({ $0.mine.isEmpty && $0.reviews.isEmpty && $0.error == nil }) {
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
        // The last list shows at once; a stale one refreshes in the background, and again every minute while open.
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            if phase == .done { Task { await store.refresh(force: true) } }
        }
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
                if account.errorKind == .auth {
                    expiredCard
                } else {
                    Text(error)
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !account.reviews.isEmpty {
                group(title: tr("agents.pulls.reviews", account.reviews.count), items: account.reviews, account: account.id, showAuthor: true)
            }
            if !account.mine.isEmpty {
                group(title: tr("agents.pulls.mine", account.mine.count), items: account.mine, account: account.id, showAuthor: false)
            }
        }
    }

    /// The token was rejected: say so in plain words and offer the fix right here.
    private var expiredCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tr("agents.pulls.expired"), systemImage: "exclamationmark.triangle.fill")
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("agents.pulls.expiredDetail"))
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                NookPrimaryButton(title: tr("agents.pulls.useCLI")) { gitHubSignIn.useGitHubCLI() }
                    .disabled(gitHubSignIn.phase == .checkingCLI)
                NookGhostButton(title: tr("agents.pulls.openSettings")) { app.openSettings(section: .connections) }
            }
            .padding(.top, 2)
            if case .failed(let message) = gitHubSignIn.phase {
                Text(message)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NookTheme.coralSoft.opacity(0.1)))
    }

    private func group(title: String, items: [PullRequestItem], account: String, showAuthor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(NookTheme.font(11.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.bottom, 3)
            ForEach(items) { item in
                PullRequestRow(item: item, showAuthor: showAuthor) { opened = (account, item) }
            }
        }
    }
}

private struct PullRequestRow: View {
    let item: PullRequestItem
    let showAuthor: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
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
                Image(systemName: "chevron.right")
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
        .help(tr("agents.pulls.view"))
        .contextMenu {
            if let url = item.url {
                Button(tr("agents.pulls.open")) { NSWorkspace.shared.open(url) }
            }
        }
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

/// The usage of every connected account at once, grouped per AI: one section for all Claude accounts, one for
/// Antigravity, and so on. Each account shows the limits its agent reports (5 hours and the week), what was used in
/// tokens today and this week with a small chart of the last seven days, and what Nook itself ran with the account.
struct AgentsUsagePanel: View {
    @EnvironmentObject private var app: AppModel

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
                    if profiles.contains(where: { profile in app.quota.limits(for: profile).contains { $0.elapsed() != nil } }) {
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
    }

    /// One AI: its logo and name with the number of accounts and the highest limit in use, then all its accounts in
    /// one card, divided by hairlines.
    private func section(_ kind: AgentKind, _ profiles: [AgentProfile]) -> some View {
        let peak = profiles.flatMap { app.quota.limits(for: $0) }.map(\.percent).max()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentLogo(agent: kind.name, size: 16)
                Text(kind.name)
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(profiles.count == 1 ? tr("agents.usage.oneAccount") : tr("agents.usage.accounts", profiles.count))
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.textTertiary)
                Spacer(minLength: 0)
                if let peak {
                    Text(tr("agents.usage.peak", Int(peak.rounded())))
                        .font(NookTheme.font(11, .semibold).monospacedDigit())
                        .foregroundStyle(UsageTone.text(peak))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(UsageTone.fill(peak, accent: kind.color).opacity(0.14)))
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                    }
                    account(profile)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: 0x111114))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
        }
    }

    private func account(_ profile: AgentProfile) -> some View {
        let limits = app.quota.limits(for: profile)
        let usage = app.history.profileUsage[profile.id]
        let account = app.history.profileAccounts[profile.id]
        let accent = profile.kind.color
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                AccountBadge(kind: AccountKind.of(profile, app: app), size: 20, ring: Color(hex: 0x111114))
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
            }

            if limits.isEmpty {
                Text(profile.kind == .gemini ? tr("agents.usage.geminiNoLimits")
                     : profile.kind == .antigravity && app.antigravityUsage.noLogin ? tr("agents.usage.antigravityNoToken")
                     : tr("ws.usage.quotaUnavailable"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(limitGroups(limits), id: \.name) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if !group.name.isEmpty {
                                Text(group.name)
                                    .font(NookTheme.font(11, .semibold))
                                    .foregroundStyle(NookTheme.paper.opacity(0.75))
                            }
                            ForEach(group.limits) { limit in
                                limitRow(limit, title: group.name.isEmpty ? limit.label : limit.window, accent: accent)
                            }
                        }
                    }
                }
            }

            if let usage {
                HStack(alignment: .bottom, spacing: 18) {
                    stat(tr("agents.usage.today"), TokenTally.format(usage.today.total))
                    stat(tr("agents.usage.week"), TokenTally.format(usage.week.total))
                    stat(tr("agents.usage.sessions"), "\(usage.sessionsWeek)")
                    Spacer(minLength: 0)
                    WeekBars(days: usage.perDay, color: accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.025)))
            } else {
                Text(tr("agents.usage.none"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
            }

            let nook = nookUsage(profile)
            if nook.turns > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold))
                    Text(tr("agents.usage.inNook", nook.turns, TokenTally.format(nook.tokens)))
                    if let cost = nook.cost, cost > 0, WorkspaceSettings.shared.showCost {
                        Text("· " + AgentPathFormat.cost(cost))
                    }
                }
                .font(NookTheme.font(11))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
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

    /// What sessions Nook ran with this account did in the last seven days: turns, tokens and the cost the agent reported.
    private func nookUsage(_ profile: AgentProfile) -> (turns: Int, tokens: Int, cost: Double?) {
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        var turns = 0, tokens = 0
        var cost: Double?
        for run in app.workspace.runs where run.profileID == profile.id && run.provider.kind == profile.kind && run.updatedAt > since {
            turns += run.usage.turns
            tokens += run.usage.totalTokens ?? 0
            if let reported = run.usage.reportedCostUSD { cost = (cost ?? 0) + reported }
        }
        return (turns, tokens, cost)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(NookTheme.font(10.5)).foregroundStyle(NookTheme.textTertiary)
            Text(value).font(NookTheme.font(13, .semibold).monospacedDigit()).foregroundStyle(NookTheme.paper)
        }
    }
}

/// How a usage percentage is colored: calm in the AI's own color while there is room, amber when it gets close, coral
/// when it is nearly gone. The number stays plain white until then, so only what needs attention stands out.
private enum UsageTone {
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
private struct UsageBar: View {
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
