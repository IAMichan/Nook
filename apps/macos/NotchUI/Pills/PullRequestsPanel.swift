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
/// is wide enough, as a side panel opens one (half the page, its edge dragged wider or narrower, and a
/// button that makes it fill the page), else in its place.
struct PullRequestsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = PullRequestStore.shared
    private var accounts: [AccountPullRequests] { store.accounts }
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    /// The pull requests opened as tabs, and the one shown; nil shows the list alone (the tabs wait for the next click).
    @State private var tabs: [OpenPullRequest] = []
    @State private var activeTab: String?
    /// Tabs you closed, for ⇧⌘T (`panel.reopenClosed`).
    @State private var closed = ClosedTabs<OpenPullRequest>()
    private var active: OpenPullRequest? { tabs.first { $0.id == activeTab } }
    /// Search and filters; kept while a pull request is open, so going back shows the same list, and across launches.
    @ObservedObject private var filterStore = PullRequestFilterStore.shared
    private var filter: PullRequestFilter {
        get { filterStore.filter }
        nonmutating set { filterStore.filter = newValue }
    }
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
    /// The side panel: half the page at first, as wide as you drag it after (remembered; 0 is "half"),
    /// never narrower than `minimumPanel`, and leaving the list at least `minimumList` and 30% of the page.
    @AppStorage("nook.pulls.panelWidth") private var panelWidth: Double = 0
    private static let minimumPanel: Double = 360
    private static let minimumList: Double = 360
    /// The side panel fills the page, the list out of sight until you restore it or close the panel.
    @State private var maximized = false

    var body: some View {
        GeometryReader { geometry in
            let total = Double(geometry.size.width)
            let split = geometry.size.width >= Self.splitWidth
            let beside = active != nil && split && !maximized
            // The list keeps one place whether or not a pull request is open beside it: in two branches it was made
            // again with each open and close, its rows and avatars with it, scrolled back to the top and refreshed.
            HStack(alignment: .top, spacing: 0) {
                if active == nil || beside {
                    list(selected: beside ? active?.item.id : nil)
                        .frame(maxWidth: .infinity)
                }
                if let opened = active {
                    if beside {
                        detail(opened, split: true)
                            .sidePanel(.trailing, width: panelWidthBinding(total), defaultWidth: (total / 2).rounded(),
                                       minimum: Self.minimumPanel, available: total,
                                       rest: max(Self.minimumList, total * 0.3) + PanelSplit.handle)
                    } else {
                        detail(opened, split: split)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onReceive(app.viewModel.$pullRequestToOpen) { take($0) }
        // ⇧⌘T: the pull request tab closed last opens again; the key goes on when there is none.
        .keyCommands(["panel.reopenClosed": {
            guard let tab = closed.reopen(skipping: { tab in tabs.contains { $0.id == tab.id } }) else { return false }
            open(tab.account, tab.item)
            return true
        }])
        .onChange(of: activeTab) { _, tab in if tab == nil { maximized = false } }
        .onChange(of: accounts) { _, _ in finishTabs() }
    }

    private func panelWidthBinding(_ total: Double) -> Binding<Double> {
        Binding(get: { panelWidth > 0 ? panelWidth : (total / 2).rounded() }, set: { panelWidth = $0 })
    }

    /// The open pull requests as tabs with, beside the list, the buttons that make the panel fill the page and close
    /// it on the same line; under them the one you read. In its place (a narrow page) it has a back arrow instead.
    /// With one pull request open there are no tabs to choose from: the page's own top line (repository and number)
    /// already says which one it is and carries those buttons, so no second line sits above it.
    private func detail(_ opened: OpenPullRequest, split: Bool) -> some View {
        let tabbed = tabs.count > 1
        let toggleMaximized: () -> Void = { withAnimation(NookTheme.reveal) { maximized.toggle() } }
        // Beside the list the tab line closes the panel; without one the page does.
        let close: (() -> Void)? = split && tabbed ? nil : { activeTab = nil }
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if tabbed {
                HStack(spacing: NookTheme.Spacing.xs) {
                    PullRequestTabStrip(tabs: tabs, active: activeTab, select: { activeTab = $0 }, close: closeTabs)
                    if split {
                        ToolbarIconButton(maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                          tr(maximized ? "agents.pulls.panel.restore" : "agents.pulls.panel.maximize"), toggleMaximized)
                        SidePanelCloseButton(help: tr("agents.pr.closePanel")) { activeTab = nil }
                    }
                }
            }
            PullRequestDetailView(accountID: opened.account, item: opened.item, inline: split,
                                  stack: PullRequestStack.stack(of: opened.item, in: items(of: opened.account)) ?? [],
                                  onOpenPullRequest: { open(opened.account, $0) },
                                  onUpdate: { updated in
                                      if let index = tabs.firstIndex(where: { $0.id == opened.id }) { tabs[index].item = updated }
                                  },
                                  onBack: close,
                                  onMaximize: split && !tabbed ? toggleMaximized : nil,
                                  maximized: maximized)
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
        closed.push(tabs.filter { ids.contains($0.id) })
        let index = tabs.firstIndex { $0.id == activeTab }
        tabs.removeAll { ids.contains($0.id) }
        guard let current = activeTab, ids.contains(current) else { return }
        guard !tabs.isEmpty, let index else { activeTab = nil; return }
        activeTab = tabs[min(index, tabs.count - 1)].id
    }

    /// Tabs whose pull request the list now shows merged or closed take that mark, the ones in the background too.
    /// Only that way round: a list read can lag behind the page, which hands its own state back through `onUpdate`.
    private func finishTabs() {
        for index in tabs.indices where tabs[index].item.state == .open {
            let tab = tabs[index]
            guard let listed = items(of: tab.account).first(where: { $0.id == tab.item.id }), listed.state != .open else { continue }
            tabs[index].item.state = listed.state
            tabs[index].item.conflict = false
        }
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
                // Only a refresh you asked for (or a first load) spins; the quiet ones every half minute do not.
                if store.showsProgress {
                    ProgressView().controlSize(.small)
                } else if let read = store.lastRead {
                    PullRequestFreshness(date: read)
                }
                NookIconButton(systemName: "binoculars", label: tr("agents.pulls.watch"), size: 28) { app.openSettings(section: .connections) }
                NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) { Task { await store.refresh(force: true) } }
            }

            if !store.loaded {
                // The very first read, with no list kept from before: a patient spinner, not "No pull requests".
                PatientSpinner()
            } else if !store.available && accounts.isEmpty {
                empty(symbol: "person.crop.circle.badge.plus", title: tr("agents.pulls.notConnected"), detail: tr("agents.pulls.notConnectedDetail"), action: (tr("agents.pulls.connect"), {
                    app.openSettings(section: .connections)
                }))
            } else if accounts.allSatisfy({ $0.isEmpty && $0.error == nil }) {
                empty(symbol: "checkmark.circle", title: tr("agents.pulls.none"), detail: tr("agents.pulls.noneDetail"), action: nil)
            } else {
                // Filtered once per redraw: the empty check, the count and the rows below all read this.
                let shown = self.shown
                searchRow
                if !unreadable.isEmpty { unreadableNote }
                if shown.allSatisfy({ $0.isEmpty && $0.error == nil }) {
                    if filter.isActive {
                        empty(symbol: "line.3.horizontal.decrease.circle", title: tr("agents.pulls.noMatch"), detail: tr("agents.pulls.noMatchDetail"), action: (tr("agents.pulls.clearFilter"), {
                            filter = PullRequestFilter()
                        }))
                    } else {
                        // Only closed or merged pull requests: nothing open, but the State filter shows them.
                        empty(symbol: "checkmark.circle", title: tr("agents.pulls.none"), detail: tr("agents.pulls.noneDetail"), action: nil)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        // Lazy, and flat: the headings and rows of every group are its direct children, so only the
                        // rows in sight are built, however many pull requests you watch.
                        LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            if filter.isActive { matchCount(shown).padding(.bottom, NookTheme.Spacing.sm) }
                            ForEach(shown) { account in
                                // An account without matches stays out of a filtered list, unless it has an error to show.
                                if !filter.isActive || !account.isEmpty || account.error != nil {
                                    accountSection(account, showName: accounts.count > 1, selected: selected)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, NookTheme.Spacing.lg)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The last list shows at once; a stale one refreshes in the background, again every 30 seconds while open,
        // and as soon as you come back to Nook. The slow searches follow at most every three minutes (see PullRequestStore).
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
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
        PullRequestSearchBar(filter: $filterStore.filter, accounts: accounts, prompt: tr("agents.pulls.search"),
                             watching: !watching.entries.isEmpty, focus: $searching, onEscape: { searching = false }) {
            PullRequestSortMenu(sort: Binding(get: { sort }, set: { sortRaw = $0.rawValue }),
                                grouping: Binding(get: { grouping }, set: { groupingRaw = $0.rawValue }))
        }
        // ⌘F jumps to the search field.
        .keyCommand("chat.find") { searching = true }
        .help(tr("agents.pulls.searchHelp"))
    }

    /// "12 of 40 shown · Clear", while something narrows the list.
    private func matchCount(_ shown: [AccountPullRequests]) -> some View {
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

    /// The whole panel when there is nothing to list: the shared empty state, centred in the space below the toolbar.
    private func empty(symbol: String, title: String, detail: String, action: (String, () -> Void)?) -> some View {
        WSEmptyState(symbol: symbol, title: title, message: detail, action: action.map { (title: $0.0, run: $0.1) })
    }

    /// An account's part of the list: its name (with more than one account), an error if reading it failed, then its
    /// groups. No stack of its own: the rows are children of the list's lazy stack, so only the ones in sight are built.
    @ViewBuilder
    private func accountSection(_ account: AccountPullRequests, showName: Bool, selected: String?) -> some View {
        // Where each row stands in a stack, worked out once for the whole account instead of once per row.
        let stacks = PullRequestStack.positions(in: items(of: account.id))
        if showName {
            HStack(spacing: NookTheme.Spacing.sm) {
                if account.login.isEmpty {
                    Image(systemName: "person.crop.circle").font(NookTheme.font(14)).foregroundStyle(NookTheme.textTertiary)
                } else {
                    GitHubAvatar(login: account.login, size: 16)
                }
                Text(account.name).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.textStrong)
                if !account.login.isEmpty, account.login != account.name {
                    Text("@" + account.login).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .padding(.top, NookTheme.Spacing.lg)
        }
        if let error = account.error {
            if account.errorKind == .auth {
                expiredCard.padding(.top, NookTheme.Spacing.sm)
            } else {
                Text(error)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .padding(.top, NookTheme.Spacing.sm)
            }
        }
        switch grouping {
        case .involvement:
            // The ones waiting for you first, then yours, then the rest of what you watch.
            ForEach(account.byRole(sort: sort)) { group in
                rowGroup(key: account.id + " role:" + group.role.rawValue, symbol: Self.symbol(group.role),
                         title: tr("agents.pulls.group." + group.role.rawValue), rows: group.rows, account: account.id,
                         showRepo: true, stacks: stacks, selected: selected)
            }
        case .repository:
            // Every pull request of a repository together, whatever brought it into the list; the heading counts
            // the ones waiting for your review.
            ForEach(account.byRepo(sort: sort)) { repo in
                rowGroup(key: account.id + " " + repo.repo, symbol: "folder", title: repo.repo, rows: repo.rows,
                         account: account.id, showRepo: false, waiting: repo.waiting, stacks: stacks, selected: selected)
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

    /// A group of rows under a heading: a symbol, the name and the count, and a chevron at the end; a click folds it
    /// shut. The rows stand on the page itself, each with a soft fill under the pointer or while open. Heading and rows
    /// are siblings in the list's lazy stack, so a long group is built only as far as you scroll.
    @ViewBuilder
    private func rowGroup(key: String, symbol: String, title: String, rows: [PullRequestRepoGroup.Row], account: String,
                          showRepo: Bool, waiting: Int = 0, stacks: [String: (index: Int, count: Int)],
                          selected: String?) -> some View {
        let open = !collapsedRepos.split(separator: "\n").contains(Substring(key))
        Button {
            withAnimation(NookTheme.reveal) { toggleRepo(key, open: open) }
        } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: symbol).font(NookTheme.TextStyle.detail).frame(width: 14)
                Text(title).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(rows.count)").font(NookTheme.TextStyle.caption).monospacedDigit().foregroundStyle(NookTheme.textMuted)
                if waiting > 0 { PullRequestTag(text: tr("agents.pulls.toReview", waiting), color: NookTheme.amber) }
                Spacer(minLength: NookTheme.Spacing.sm)
                Image(systemName: "chevron.down")
                    .font(NookTheme.font(8.5, .bold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .frame(width: 10)
            }
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.top, NookTheme.Spacing.md)
            .padding(.bottom, NookTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr(open ? "agents.pulls.collapseRepo" : "agents.pulls.expandRepo"))
        .accessibilityValue(open ? tr("compose.queue.expanded") : "")
        if open {
            ForEach(rows) { row in
                PullRequestRow(item: row.item, role: row.role, showRepo: showRepo, accountID: account,
                               selected: selected == row.item.id, stack: stacks[row.item.id]) {
                    self.open(account, row.item)
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
