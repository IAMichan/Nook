import SwiftUI
import AppKit

/// The pull requests of your GitHub accounts: the ones you wrote, the ones waiting for your review, and the others in the
/// organizations and repositories you watch (Settings › Apps & accounts). Open ones by
/// default; the Filters dropdown (see PullRequestFilterMenu) also shows closed and merged ones. A click opens the pull
/// request in Nook (see PullRequestDetailView), where it can be read in full and merged.
struct PullRequestsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = PullRequestStore.shared
    private var accounts: [AccountPullRequests] { store.accounts }
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    /// The pull request shown in full, with the account it is listed under.
    @State private var opened: (account: String, item: PullRequestItem)?
    /// Search and filters; kept while a pull request is open, so going back shows the same list.
    @State private var filter = PullRequestFilter()
    @FocusState private var searching: Bool
    /// Groups folded shut, as "account repo" or "account role:review" lines; kept across refreshes and launches.
    @AppStorage("nook.pulls.collapsedRepos") private var collapsedRepos = ""
    @AppStorage("nook.pulls.grouping") private var groupingRaw = PullRequestGrouping.involvement.rawValue
    private var grouping: PullRequestGrouping { PullRequestGrouping(rawValue: groupingRaw) ?? .involvement }
    /// The accounts with only the pull requests that match the filter.
    private var shown: [AccountPullRequests] { accounts.map(filter.apply) }
    /// Watched entries that no account could search, still in the watch list.
    private var unreadable: [String] {
        let readers = accounts.filter { $0.error == nil }
        guard !readers.isEmpty else { return [] }
        return watching.entries.filter { entry in readers.allSatisfy { $0.unreadable.contains(entry) } }
    }
    /// Open pull requests that wait for your review, each once.
    private var waitingCount: Int {
        Set(accounts.flatMap { $0.reviews.filter { $0.state == .open }.map(\.id) }).count
    }

    var body: some View {
        if let opened {
            PullRequestDetailView(accountID: opened.account, item: opened.item) { self.opened = nil }
                .id(opened.account + " " + opened.item.id)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            PanelListHeader(tr("agents.footer.pullRequests"), count: waitingCount) {
                if store.loading {
                    ProgressView().controlSize(.small)
                } else if let read = store.lastRead {
                    PullRequestFreshness(date: read)
                }
                NookIconButton(systemName: "binoculars", label: tr("agents.pulls.watch"), size: 28) { app.openSettings(section: .connections) }
                NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) { Task { await store.refresh(force: true) } }
            }

            if store.loaded && !store.available && accounts.isEmpty {
                empty(title: tr("agents.pulls.notConnected"), detail: tr("agents.pulls.notConnectedDetail"), action: (tr("agents.pulls.connect"), {
                    app.openSettings(section: .connections)
                }))
            } else if store.loaded && accounts.allSatisfy({ $0.isEmpty && $0.error == nil }) {
                empty(title: tr("agents.pulls.none"), detail: tr("agents.pulls.noneDetail"), action: nil)
            } else {
                filterBar
                if !unreadable.isEmpty { unreadableNote }
                if shown.allSatisfy({ $0.isEmpty && $0.error == nil }) {
                    if filter.isActive {
                        empty(title: tr("agents.pulls.noMatch"), detail: tr("agents.pulls.noMatchDetail"), action: (tr("agents.pulls.clearFilter"), {
                            filter = PullRequestFilter()
                        }))
                    } else {
                        // Only closed or merged pull requests: nothing open, but the State filter shows them.
                        empty(title: tr("agents.pulls.none"), detail: tr("agents.pulls.noneDetail"), action: nil)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                            ForEach(shown) { account in
                                // An account without matches stays out of a filtered list, unless it has an error to show.
                                if !filter.isActive || !account.isEmpty || account.error != nil {
                                    accountSection(account, showName: accounts.count > 1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The last list shows at once; a stale one refreshes in the background, again every 20 seconds while open,
        // and as soon as you come back to Nook.
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            if phase == .done { Task { await store.refresh(force: true) } }
        }
        .onChange(of: watching.entries) { _, _ in Task { await store.refresh(force: true) } }
        .onChange(of: watching.includeOrganizations) { _, _ in Task { await store.refresh(force: true) } }
    }

    // MARK: Search and filters

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            searchRow
            scopeTabs
        }
    }

    /// Which pull requests: all, the ones for your review, yours, or the watched ones. The same choice as Involvement
    /// in the Filters dropdown, one click away.
    private var scopeTabs: some View {
        let scopes = PullRequestFilter.Scope.allCases.filter { $0 != .watched || !watching.entries.isEmpty || filter.scope == .watched }
        return NookTabBar<PullRequestFilter.Scope>(
            items: scopes.map { scope in
                .init(value: scope, title: tr("agents.pulls.scope." + scope.rawValue))
            },
            selected: filter.scope
        ) { scope in
            withAnimation(NookTheme.swap) { filter.scope = scope }
        }
    }

    private var searchRow: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            NookSearchField(prompt: tr("agents.pulls.search"), text: $filter.query, focus: $searching,
                            onEscape: { searching = false })
            .background {
                // ⌘F jumps to the search field.
                Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
            }

            PullRequestFilterMenu(filter: $filter, grouping: Binding(get: { grouping }, set: { groupingRaw = $0.rawValue }),
                                  authors: PullRequestFilter.authors(in: accounts), watching: !watching.entries.isEmpty)
        }
    }

    /// A watched organization or repository GitHub would not search: a typo, or none of your accounts has access.
    private var unreadableNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").font(NookTheme.TextStyle.detail)
            Text(tr("agents.pulls.unreadable", unreadable.joined(separator: ", ")))
                .font(NookTheme.TextStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(NookTheme.coralSoft)
    }

    private func empty(title: String, detail: String, action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(title).font(NookTheme.TextStyle.title).foregroundStyle(NookTheme.paper)
            Text(detail)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                NookPrimaryButton(title: action.0, action: action.1).padding(.top, NookTheme.Spacing.xs)
            }
        }
        .padding(.top, NookTheme.Spacing.md)
    }

    @ViewBuilder
    private func accountSection(_ account: AccountPullRequests, showName: Bool) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if showName {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(systemName: "person.crop.circle").font(NookTheme.font(12))
                    Text(account.name).font(NookTheme.TextStyle.strong)
                    if !account.login.isEmpty { Text("@" + account.login).font(NookTheme.TextStyle.detail) }
                }
                .foregroundStyle(NookTheme.textSecondary)
            }
            if let error = account.error {
                if account.errorKind == .auth {
                    expiredCard
                } else {
                    Text(error)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch grouping {
            case .involvement:
                // The ones waiting for you first, then yours, then the rest of what you watch.
                ForEach(account.byRole) { group in
                    rowGroup(key: account.id + " role:" + group.role.rawValue, symbol: Self.symbol(group.role),
                             title: tr("agents.pulls.group." + group.role.rawValue), rows: group.rows, account: account.id,
                             showRepo: true)
                }
            case .repository:
                // Every pull request of a repository together, whatever brought it into the list.
                ForEach(account.byRepo) { repo in
                    rowGroup(key: account.id + " " + repo.repo, symbol: "folder", title: repo.repo, rows: repo.rows,
                             account: account.id, showRepo: false)
                }
            }
        }
    }

    /// The token was rejected: say so in plain words and offer the fix right here.
    private var expiredCard: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Label(tr("agents.pulls.expired"), systemImage: "exclamationmark.triangle.fill")
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
            Text(tr("agents.pulls.expiredDetail"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NookTheme.Spacing.xs) {
                NookPrimaryButton(title: tr("agents.pulls.useCLI")) { gitHubSignIn.useGitHubCLI() }
                    .disabled(gitHubSignIn.phase == .checkingCLI)
                NookGhostButton(title: tr("agents.pulls.openSettings")) { app.openSettings(section: .connections) }
            }
            .padding(.top, NookTheme.Spacing.xxs)
            if case .failed(let message) = gitHubSignIn.phase {
                Text(message)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NookTheme.Spacing.lg + NookTheme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.coral.opacity(0.08)))
    }

    private static func symbol(_ role: PullRequestRepoGroup.Role) -> String {
        switch role {
        case .review: return "eye"
        case .mine: return "person"
        case .watched: return "binoculars"
        }
    }

    /// A group of rows under a heading that folds it shut: the rows in one quiet card, a line between them.
    private func rowGroup(key: String, symbol: String, title: String, rows: [PullRequestRepoGroup.Row], account: String,
                          showRepo: Bool) -> some View {
        let open = !collapsedRepos.split(separator: "\n").contains(Substring(key))
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.reveal) { toggleRepo(key, open: open) }
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(systemName: "chevron.down")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                        .frame(width: 10)
                    Image(systemName: symbol).font(NookTheme.TextStyle.detail)
                    Text(title).font(NookTheme.TextStyle.label).lineLimit(1).truncationMode(.middle)
                    Text("\(rows.count)").font(NookTheme.TextStyle.detail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.horizontal, NookTheme.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr(open ? "agents.pulls.collapseRepo" : "agents.pulls.expandRepo"))
            .accessibilityValue(open ? tr("compose.queue.expanded") : "")
            if open {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 16 + NookTheme.Spacing.md) }
                        PullRequestRow(item: row.item, role: row.role, showRepo: showRepo, accountID: account) {
                            opened = (account, row.item)
                        }
                    }
                }
                .panelCard()
            }
        }
    }

    private func toggleRepo(_ key: String, open: Bool) {
        var keys = collapsedRepos.split(separator: "\n").map(String.init)
        if open { keys.append(key) } else { keys.removeAll { $0 == key } }
        collapsedRepos = keys.joined(separator: "\n")
    }
}

/// "Updated 20 s ago": how fresh what you see is, ticking along.
struct PullRequestFreshness: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let age = context.date.timeIntervalSince(date)
            Text(age < 10 ? tr("agents.pulls.updatedNow") : tr("agents.pulls.updatedAgo", AgentFormat.short(age)))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .monospacedDigit()
        }
    }
}

/// One pull request in the list: its state as GitHub's mark, the title with the checks at the end, and under it where
/// it lives, its number, who wrote it and when it last changed.
private struct PullRequestRow: View {
    let item: PullRequestItem
    let role: PullRequestRepoGroup.Role
    /// The repository is named on the row unless its group heading already does.
    let showRepo: Bool
    let accountID: String
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                PullRequestStateGlyph(glyph: glyph, size: 16, lineWidth: 1.4, nodeRadius: 1.7)
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                    .help(tr(stateKey))
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(item.title)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(item.state == .open ? NookTheme.paper : NookTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        if item.state == .open { ciMark }
                    }
                    HStack(spacing: NookTheme.Spacing.xs) {
                        if showRepo {
                            Text(item.repo).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                        }
                        Text("#\(item.number)").font(NookTheme.mono(11)).monospacedDigit()
                        if role != .mine, !item.author.isEmpty { Text("· @" + item.author).lineLimit(1) }
                        if item.draft, item.state == .open { tag(tr("agents.pulls.draft").localizedCapitalized, color: NookTheme.textSecondary) }
                        // Grouped by role, the group's heading already says so.
                        if role == .review, item.state == .open, !showRepo { tag(tr("agents.pulls.scope.reviews"), color: NookTheme.amber) }
                        Spacer(minLength: NookTheme.Spacing.sm)
                        if let updated = item.updated {
                            Text(AgentFormat.short(Date().timeIntervalSince(updated))).monospacedDigit().layoutPriority(1)
                        }
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(hovering ? NookTheme.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Resting on a row reads it ahead, so the click opens it at once.
        .task(id: hovering) {
            guard hovering else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { PullRequestDetailModel.prefetch(accountID: accountID, item: item) }
        }
        .help(tr("agents.pulls.view"))
        .contextMenu {
            if let url = item.url {
                Button(tr("agents.pulls.open")) { NSWorkspace.shared.open(url) }
                Button(tr("agents.pr.copyLink")) {
                    Pasteboard.copy(url.absoluteString)
                    ToastCenter.shared.success(tr("agents.pr.copiedLink"))
                }
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(color)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }

    private var glyph: PullRequestBadge.Glyph {
        switch item.state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: return item.draft ? .draft : .open
        }
    }

    private var tint: Color {
        switch item.state {
        case .merged: return NookTheme.violet
        case .closed: return NookTheme.coralSoft
        case .open: return item.draft ? NookTheme.textTertiary : NookTheme.mint
        }
    }

    private var stateKey: String {
        switch item.state {
        case .merged: return "agents.pulls.state.merged"
        case .closed: return "agents.pulls.state.closed"
        case .open: return item.draft ? "agents.pulls.draft" : "agents.pulls.state.open"
        }
    }

    @ViewBuilder
    private var ciMark: some View {
        switch item.ci {
        case .passing:
            Image(systemName: "checkmark.circle.fill").font(NookTheme.font(12)).foregroundStyle(NookTheme.mint)
                .help(tr("agents.pulls.status.passing"))
        case .failing:
            Image(systemName: "xmark.circle.fill").font(NookTheme.font(12)).foregroundStyle(NookTheme.coral)
                .help(tr("agents.pulls.status.failing"))
        // Running checks wait on CI, not on you: no amber.
        case .pending:
            Image(systemName: "clock").font(NookTheme.font(11, .medium)).foregroundStyle(NookTheme.textSecondary)
                .help(tr("agents.pulls.status.pending"))
        case .unknown:
            EmptyView()
        }
    }
}
