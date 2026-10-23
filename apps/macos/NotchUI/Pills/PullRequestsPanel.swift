import SwiftUI
import AppKit

/// A pull request to open on the Pull requests page, with the account to read it with.
struct PullRequestOpenRequest: Equatable {
    let account: String
    let item: PullRequestItem
}

/// The pull requests of your GitHub accounts: the ones you wrote, the ones waiting for your review, and the others in the
/// organizations and repositories you watch (Settings › Apps & accounts): a
/// search that takes qualifiers (`label:bug`), Sort and Filters beside it (see PullRequestFilterMenu), and flat rows
/// under a heading per group. Open ones by default; the filters also show closed and merged ones. A click opens the pull
/// request in Nook (see PullRequestDetailView), where it can be read in full and merged: beside the list when the page
/// is wide enough, as a side panel, else in its place.
struct PullRequestsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = PullRequestStore.shared
    private var accounts: [AccountPullRequests] { store.accounts }
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    /// The pull requests opened as tabs, and the one shown; nil shows the list alone (the tabs wait for the next click).
    @State private var tabs: [OpenPullRequest] = []
    @State private var activeTab: String?
    private var active: OpenPullRequest? { tabs.first { $0.id == activeTab } }
    /// Search and filters; kept while a pull request is open, so going back shows the same list, and across launches.
    @State private var filter = PullRequestFilter.load()
    @FocusState private var searching: Bool
    /// Groups folded shut, as "account repo" or "account role:review" lines; kept across refreshes and launches.
    @AppStorage("nook.pulls.collapsedRepos") private var collapsedRepos = ""
    @AppStorage("nook.pulls.grouping") private var groupingRaw = PullRequestGrouping.involvement.rawValue
    private var grouping: PullRequestGrouping { PullRequestGrouping(rawValue: groupingRaw) ?? .involvement }
    @AppStorage("nook.pulls.sort") private var sortRaw = PullRequestSort.attention.rawValue
    private var sort: PullRequestSort { PullRequestSort(rawValue: sortRaw) ?? .attention }
    /// The accounts with only the pull requests that match the filter.
    private var shown: [AccountPullRequests] { filter.apply(accounts) }
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

    /// From this width the pull request opens beside the list instead of in its place.
    private static let splitWidth: CGFloat = 860

    var body: some View {
        GeometryReader { geometry in
            let split = geometry.size.width >= Self.splitWidth
            Group {
                if let opened = active, split {
                    HStack(alignment: .top, spacing: 0) {
                        list(selected: opened.item.id)
                            .frame(width: min(max(geometry.size.width * 0.4, 360), 520))
                            .padding(.trailing, NookTheme.Spacing.lg)
                        NookDivider(vertical: true)
                        detail(opened, inline: true)
                            .padding(.leading, NookTheme.Spacing.lg)
                    }
                } else if let opened = active {
                    detail(opened, inline: false)
                } else {
                    list(selected: nil)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onReceive(app.viewModel.$pullRequestToOpen) { take($0) }
        .onChange(of: filter) { _, filter in filter.save() }
    }

    private func detail(_ opened: OpenPullRequest, inline: Bool) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            PullRequestTabStrip(tabs: tabs, active: activeTab, select: { activeTab = $0 }, close: closeTabs)
            PullRequestDetailView(accountID: opened.account, item: opened.item, inline: inline,
                                  stack: PullRequestStack.stack(of: opened.item, in: items(of: opened.account)) ?? [],
                                  onOpenPullRequest: { open(opened.account, $0) }) { activeTab = nil }
                .id(opened.id)
        }
    }

    /// Opens a pull request as a tab (or shows its tab when it is open already); at most eight, the oldest goes first.
    private func open(_ account: String, _ item: PullRequestItem) {
        let tab = OpenPullRequest(account: account, item: item)
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index].item = item
        } else {
            tabs.append(tab)
            if tabs.count > 8 { tabs.removeFirst(tabs.count - 8) }
        }
        activeTab = tab.id
    }

    /// Closes tabs; when the shown one goes, its neighbour on the right (else the left) is shown.
    private func closeTabs(_ ids: Set<String>) {
        let index = tabs.firstIndex { $0.id == activeTab }
        tabs.removeAll { ids.contains($0.id) }
        guard let current = activeTab, ids.contains(current) else { return }
        guard !tabs.isEmpty, let index else { activeTab = nil; return }
        activeTab = tabs[min(index, tabs.count - 1)].id
    }

    /// Every pull request listed under an account, unfiltered, for finding stacks.
    private func items(of account: String) -> [PullRequestItem] {
        guard let found = accounts.first(where: { $0.id == account }) else { return [] }
        return found.reviews + found.mine + found.watched
    }

    /// A pull request link clicked in a chat: it opens here, in full.
    private func take(_ request: PullRequestOpenRequest?) {
        guard let request else { return }
        app.viewModel.pullRequestToOpen = nil
        open(request.account, request.item)
    }

    private func list(selected: String?) -> some View {
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
                searchRow
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
                            if filter.isActive { matchCount }
                            ForEach(shown) { account in
                                // An account without matches stays out of a filtered list, unless it has an error to show.
                                if !filter.isActive || !account.isEmpty || account.error != nil {
                                    accountSection(account, showName: accounts.count > 1, selected: selected)
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

    /// The toolbar: the search (which also takes `label:bug`, `author:ada`, `review:approved` …), then Sort and
    /// Filters. Involvement, which used to be tabs, is a filter there too.
    private var searchRow: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            NookSearchField(prompt: tr("agents.pulls.search"), text: $filter.query, focus: $searching,
                            onEscape: { searching = false })
            // ⌘F jumps to the search field.
            .keyCommand("chat.find") { searching = true }
            .help(tr("agents.pulls.searchHelp"))

            PullRequestSortMenu(sort: Binding(get: { sort }, set: { sortRaw = $0.rawValue }),
                                grouping: Binding(get: { grouping }, set: { groupingRaw = $0.rawValue }))
            PullRequestFilterMenu(filter: $filter, facets: PullRequestFilter.facets(in: accounts, state: filter.state),
                                  accounts: accounts.map { (id: $0.id, name: $0.login.isEmpty ? $0.name : $0.name + " · @" + $0.login) },
                                  watching: !watching.entries.isEmpty)
        }
    }

    /// "12 of 40 shown · Clear", while something narrows the list.
    private var matchCount: some View {
        let all = Set(accounts.flatMap { $0.mine + $0.reviews + $0.watched }.map(\.id)).count
        let shownCount = Set(shown.flatMap { $0.mine + $0.reviews + $0.watched }.map(\.id)).count
        return HStack(spacing: NookTheme.Spacing.sm) {
            Text(tr("agents.pulls.shownOf", shownCount, all)).monospacedDigit()
            Button(tr("agents.pulls.clearFilter")) { filter = PullRequestFilter() }
                .buttonStyle(.plain)
                .foregroundStyle(NookTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, NookTheme.Spacing.xs)
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
    private func accountSection(_ account: AccountPullRequests, showName: Bool, selected: String?) -> some View {
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
                ForEach(account.byRole(sort: sort)) { group in
                    rowGroup(key: account.id + " role:" + group.role.rawValue, symbol: Self.symbol(group.role),
                             title: tr("agents.pulls.group." + group.role.rawValue), rows: group.rows, account: account.id,
                             showRepo: true, selected: selected)
                }
            case .repository:
                // Every pull request of a repository together, whatever brought it into the list; the heading counts
                // the ones waiting for your review.
                ForEach(account.byRepo(sort: sort)) { repo in
                    rowGroup(key: account.id + " " + repo.repo, symbol: "folder", title: repo.repo, rows: repo.rows,
                             account: account.id, showRepo: false, waiting: repo.waiting, selected: selected)
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
        case .mine: return "pencil.line"
        case .watched: return "binoculars"
        }
    }

    /// A group of rows under a heading: a symbol, the name, the count and a line to the edge; a click folds it
    /// shut. The rows stand on the page itself, each with a soft fill under the pointer or while open.
    private func rowGroup(key: String, symbol: String, title: String, rows: [PullRequestRepoGroup.Row], account: String,
                          showRepo: Bool, waiting: Int = 0, selected: String?) -> some View {
        let open = !collapsedRepos.split(separator: "\n").contains(Substring(key))
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            Button {
                withAnimation(NookTheme.reveal) { toggleRepo(key, open: open) }
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(systemName: symbol).font(NookTheme.TextStyle.detail).frame(width: 14)
                    Text(title).font(NookTheme.TextStyle.label).lineLimit(1).truncationMode(.middle)
                    Text("\(rows.count)").font(NookTheme.TextStyle.detail).monospacedDigit().foregroundStyle(NookTheme.textMuted)
                    if waiting > 0 { PullRequestTag(text: tr("agents.pulls.toReview", waiting), color: NookTheme.amber) }
                    NookDivider().frame(minWidth: NookTheme.Spacing.sm)
                    Image(systemName: "chevron.down")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                        .frame(width: 10)
                }
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.xxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr(open ? "agents.pulls.collapseRepo" : "agents.pulls.expandRepo"))
            .accessibilityValue(open ? tr("compose.queue.expanded") : "")
            if open {
                let all = items(of: account)
                ForEach(rows) { row in
                    PullRequestRow(item: row.item, role: row.role, showRepo: showRepo, accountID: account,
                                   selected: selected == row.item.id,
                                   stack: PullRequestStack.position(of: row.item, in: all)) {
                        self.open(account, row.item)
                    }
                }
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

/// One pull request in the list: GitHub's state mark (with a small warning on it for a conflict), then
/// two lines. On top the number, the title, the checks and the review decision, and the lines added and removed at the
/// end; under it the author's picture and login, the repository, up to three labels in their own colors, and when it
/// last changed at the end.
private struct PullRequestRow: View {
    let item: PullRequestItem
    let role: PullRequestRepoGroup.Role
    /// The repository is named on the row unless its group heading already does.
    let showRepo: Bool
    let accountID: String
    /// The pull request open beside the list.
    var selected = false
    /// Where it stands in a stack of pull requests built on each other, if it is in one.
    var stack: (index: Int, count: Int)? = nil
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
            // Shift shows the quick actions; outside the row's own button, so their clicks stay theirs.
            PullRequestQuickActionButtons(item: item, accountID: accountID)
        }
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
            .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
        .onHover { hovering = $0 }
        // Resting on a row reads it ahead, so the click opens it at once.
        .task(id: hovering) {
            guard hovering else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { PullRequestDetailModel.prefetch(accountID: accountID, item: item) }
        }
        .help(tr("agents.pulls.view"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if let url = item.url {
                Button(tr("agents.pulls.open")) { NSWorkspace.shared.open(url) }
                Button(tr("agents.pr.copyLink")) {
                    Pasteboard.copy(url.absoluteString)
                    ToastCenter.shared.success(tr("agents.pr.copiedLink"))
                }
            }
            if !item.headBranch.isEmpty {
                Button(tr("agents.pr.copyBranch")) {
                    Pasteboard.copy(item.headBranch)
                    ToastCenter.shared.success(tr("agents.pr.copiedBranch"))
                }
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            stateMark.padding(.top, 2)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text("#\(item.number)")
                        .font(NookTheme.mono(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize()
                    Text(item.title)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(item.state == .open ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: NookTheme.Spacing.xs) {
                        ciMark
                        reviewMark
                    }
                    .fixedSize()
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if let stack {
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            PullRequestStateGlyph(glyph: .stack, size: 12, lineWidth: 1.5, nodeRadius: 1.8)
                                .frame(width: 12, height: 12)
                            Text("\(stack.index)/\(stack.count)").font(NookTheme.TextStyle.caption).monospacedDigit()
                        }
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize()
                        .help(tr("agents.pulls.stack.position", stack.index, stack.count))
                    }
                    if let additions = item.additions, let deletions = item.deletions {
                        HStack(spacing: NookTheme.Spacing.xs) {
                            Text("+" + additions.formatted()).foregroundStyle(NookTheme.mint)
                            Text("−" + deletions.formatted()).foregroundStyle(NookTheme.coral)
                        }
                        .font(NookTheme.mono(11, .medium))
                        .monospacedDigit()
                        .fixedSize()
                        .help(tr("agents.pulls.linesChanged", additions, deletions))
                    }
                }
                HStack(spacing: NookTheme.Spacing.sm) {
                    if !item.author.isEmpty {
                        HStack(spacing: NookTheme.Spacing.xs) {
                            GitHubAvatar(login: item.author, size: 14)
                            Text(item.author).lineLimit(1)
                        }
                        .help("@" + item.author)
                    }
                    if showRepo {
                        Text(item.repo).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                    }
                    if item.draft, item.state == .open {
                        PullRequestTag(text: tr("agents.pulls.draft").localizedCapitalized, color: NookTheme.textSecondary)
                    }
                    // Grouped by repository, the row says it waits for your review; grouped by role, the heading does.
                    if role == .review, item.state == .open, !showRepo { PullRequestTag(text: tr("agents.pulls.scope.reviews"), color: NookTheme.amber) }
                    labels.layoutPriority(-2)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if let updated = item.updated {
                        Text(AgentFormat.short(Date().timeIntervalSince(updated)))
                            .monospacedDigit()
                            .fixedSize()
                            .help(updated.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
        .contentShape(Rectangle())
    }

    /// GitHub's mark in the state's color; an open pull request that conflicts with its base wears the conflict mark.
    private var stateMark: some View {
        PullRequestStateGlyph(glyph: glyph, size: 16, lineWidth: 1.4, nodeRadius: 1.7)
            .foregroundStyle(tint)
            .frame(width: 16, height: 16)
            .help(tr(stateKey))
    }

    /// The first label, and the next two when there is room; "+2" for the ones left out.
    @ViewBuilder
    private var labels: some View {
        if let first = item.labels.first {
            ViewThatFits(in: .horizontal) {
                ForEach([3, 2, 1], id: \.self) { count in
                    HStack(spacing: NookTheme.Spacing.xs) {
                        let shown = Array(item.labels.prefix(count))
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, name in
                            let rest = item.labels.count - shown.count
                            LabelChip(name: name, color: item.labelColors[name],
                                      suffix: index == shown.count - 1 && rest > 0 ? "+\(rest)" : nil)
                        }
                    }
                    .fixedSize()
                }
                LabelChip(name: first, color: item.labelColors[first]).frame(maxWidth: 120)
            }
        }
    }

    private var glyph: PullRequestBadge.Glyph {
        switch item.state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: return item.conflict ? .conflict : item.draft ? .draft : .open
        }
    }

    private var tint: Color {
        switch item.state {
        case .merged: return NookTheme.violet
        case .closed: return NookTheme.coralSoft
        case .open: return item.conflict ? NookTheme.coral : item.draft ? NookTheme.textTertiary : NookTheme.mint
        }
    }

    private var stateKey: String {
        switch item.state {
        case .merged: return "agents.pulls.state.merged"
        case .closed: return "agents.pulls.state.closed"
        case .open: return item.conflict ? "agents.pulls.state.conflict" : item.draft ? "agents.pulls.draft" : "agents.pulls.state.open"
        }
    }

    /// The checks as GitHub's outlined circles, right behind the title, so you see at a glance whether CI passed.
    @ViewBuilder
    private var ciMark: some View {
        switch item.ci {
        case .passing:
            Image(systemName: "checkmark.circle").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.mint)
                .help(tr("agents.pulls.status.passing"))
        case .failing:
            Image(systemName: "xmark.circle").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.coral)
                .help(tr("agents.pulls.status.failing"))
        // Running checks wait on CI, not on you: no amber.
        case .pending:
            Image(systemName: "smallcircle.filled.circle").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.textSecondary)
                .help(tr("agents.pulls.status.pending"))
        case .unknown:
            EmptyView()
        }
    }
}

extension PullRequestRow {
    /// The review decision next to the checks: approved, changes requested, or waiting for a required review.
    @ViewBuilder
    var reviewMark: some View {
        if item.state == .open {
            switch item.review {
            case .approved:
                Image(systemName: "checkmark.seal.fill").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.mint)
                    .help(tr("agents.pulls.review.approved"))
            case .changesRequested:
                Image(systemName: "exclamationmark.bubble.fill").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.amber)
                    .help(tr("agents.pulls.review.changes"))
            case .required:
                Image(systemName: "eye").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.textTertiary)
                    .help(tr("agents.pulls.review.required"))
            case .none:
                EmptyView()
            }
        }
    }
}

/// A small tinted capsule on a row or a group heading: "Draft", "Reviews", "2 to review".
private struct PullRequestTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(color)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}
