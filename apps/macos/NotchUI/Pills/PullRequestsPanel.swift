import SwiftUI
import AppKit

/// The pull requests of your GitHub accounts: the ones you wrote, and the ones waiting for your review. Open ones by
/// default; the Filters dropdown (see PullRequestFilterMenu) also shows closed and merged ones. A click opens the pull
/// request in Nook (see PullRequestDetailView), where it can be read in full and merged.
struct PullRequestsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = PullRequestStore.shared
    private var accounts: [AccountPullRequests] { store.accounts }
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    /// The pull request shown in full, with the account it is listed under.
    @State private var opened: (account: String, item: PullRequestItem)?
    /// Search and filters; kept while a pull request is open, so going back shows the same list.
    @State private var filter = PullRequestFilter()
    @FocusState private var searching: Bool
    /// The accounts with only the pull requests that match the filter.
    private var shown: [AccountPullRequests] { accounts.map(filter.apply) }

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
                filterBar
                if shown.allSatisfy({ $0.mine.isEmpty && $0.reviews.isEmpty && $0.error == nil }) {
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
                                if !filter.isActive || !account.mine.isEmpty || !account.reviews.isEmpty || account.error != nil {
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

    // MARK: Search and filters

    private var filterBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                TextField(tr("agents.pulls.search"), text: $filter.query)
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.paper)
                    .focused($searching)
                    .onExitCommand { filter.query = ""; searching = false }
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("button.clear"))
                }
            }
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NookTheme.field))
            .background {
                // ⌘F jumps to the search field.
                Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
            }

            PullRequestFilterMenu(filter: $filter, authors: PullRequestFilter.authors(in: accounts))
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
                // Closed and merged ones no longer wait for you: those are the ones you reviewed.
                group(title: tr(filter.state == .open ? "agents.pulls.reviews" : "agents.pulls.forReview", account.reviews.count),
                      items: account.reviews, account: account.id, showAuthor: true)
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
        switch item.state {
        case .merged:
            Image(systemName: "arrow.triangle.merge").font(.system(size: 12, weight: .medium)).foregroundStyle(NookTheme.violet)
                .help(tr("agents.pulls.state.merged"))
        case .closed:
            Image(systemName: "xmark.circle").font(.system(size: 13)).foregroundStyle(NookTheme.coralSoft)
                .help(tr("agents.pulls.state.closed"))
        case .open:
            ciMark
        }
    }

    @ViewBuilder
    private var ciMark: some View {
        switch item.ci {
        case .passing: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.mint)
        case .failing: Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.coral)
        case .pending: Circle().fill(NookTheme.amber).frame(width: 7, height: 7)
        case .unknown: Circle().stroke(NookTheme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }
}
