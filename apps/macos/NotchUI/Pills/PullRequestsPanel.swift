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
    /// Repository groups folded shut, as "account repo" lines; kept across refreshes and launches.
    @AppStorage("nook.pulls.collapsedRepos") private var collapsedRepos = ""
    /// The accounts with only the pull requests that match the filter.
    private var shown: [AccountPullRequests] { accounts.map(filter.apply) }
    /// Watched entries that no account could search, still in the watch list.
    private var unreadable: [String] {
        let readers = accounts.filter { $0.error == nil }
        guard !readers.isEmpty else { return [] }
        return watching.entries.filter { entry in readers.allSatisfy { $0.unreadable.contains(entry) } }
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
            PanelListHeader(tr("agents.footer.pullRequests")) {
                if store.loading { ProgressView().controlSize(.small) }
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
                        VStack(alignment: .leading, spacing: 18) {
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
        // The last list shows at once; a stale one refreshes in the background, and again every half minute while open.
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            if phase == .done { Task { await store.refresh(force: true) } }
        }
        .onChange(of: watching.entries) { _, _ in Task { await store.refresh(force: true) } }
        .onChange(of: watching.includeOrganizations) { _, _ in Task { await store.refresh(force: true) } }
    }

    // MARK: Search and filters

    private var filterBar: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            NookSearchField(prompt: tr("agents.pulls.search"), text: $filter.query, focus: $searching,
                            onEscape: { searching = false })
            .background {
                // ⌘F jumps to the search field.
                Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
            }

            PullRequestFilterMenu(filter: $filter, authors: PullRequestFilter.authors(in: accounts), watching: !watching.entries.isEmpty)
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
            // Every pull request of a repository together, whatever brought it into the list.
            ForEach(account.byRepo) { repo in
                repoGroup(repo, account: account.id)
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

    private func repoGroup(_ group: PullRequestRepoGroup, account: String) -> some View {
        let key = account + " " + group.repo
        let open = !collapsedRepos.split(separator: "\n").contains(Substring(key))
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            Button {
                withAnimation(NookTheme.reveal) { toggleRepo(key, open: open) }
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(systemName: "chevron.down")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                        .frame(width: 10)
                    Image(systemName: "folder").font(NookTheme.TextStyle.detail)
                    Text(group.repo).font(NookTheme.TextStyle.label).lineLimit(1).truncationMode(.middle)
                    Text("\(group.rows.count)").font(NookTheme.TextStyle.detail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.horizontal, NookTheme.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr(open ? "agents.pulls.collapseRepo" : "agents.pulls.expandRepo"))
            .accessibilityValue(open ? tr("compose.queue.expanded") : "")
            .padding(.bottom, NookTheme.Spacing.xs)
            if open {
                ForEach(group.rows) { row in
                    PullRequestRow(item: row.item, role: row.role) { opened = (account, row.item) }
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

private struct PullRequestRow: View {
    let item: PullRequestItem
    let role: PullRequestRepoGroup.Role
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 10) {
                ci.frame(width: 16)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(item.title)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    HStack(spacing: NookTheme.Spacing.sm) {
                        // The repository is the group's heading, so the number is enough here.
                        Text("#\(item.number)")
                        if role != .mine, !item.author.isEmpty { Text("· @" + item.author) }
                        if item.draft { Text("· " + tr("agents.pulls.draft")) }
                        if role == .review, item.state == .open {
                            Text("· " + tr("agents.pulls.scope.reviews")).foregroundStyle(NookTheme.amber)
                        }
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let updated = item.updated {
                    Text(AgentFormat.short(Date().timeIntervalSince(updated)))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(hovering ? NookTheme.rowHover : Color.clear))
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
        switch item.state {
        case .merged:
            Image(systemName: "arrow.triangle.merge").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.violet)
                .help(tr("agents.pulls.state.merged"))
        case .closed:
            Image(systemName: "xmark.circle").font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.coralSoft)
                .help(tr("agents.pulls.state.closed"))
        case .open:
            ciMark
        }
    }

    @ViewBuilder
    private var ciMark: some View {
        switch item.ci {
        case .passing: Image(systemName: "checkmark.circle.fill").font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.mint)
        case .failing: Image(systemName: "xmark.circle.fill").font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.coral)
        // Running checks wait on CI, not on you: no amber.
        case .pending: Circle().fill(NookTheme.textSecondary).frame(width: 7, height: 7)
        case .unknown: Circle().stroke(NookTheme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }
}
