import SwiftUI

/// The side panel's Pull request tab before one is open: a search, then the pull requests to open beside the session.
/// First the one for the branch the session's folder is on, then yours, the ones waiting for your review and the
/// watched ones, from every GitHub account (`PullRequestStore`). A click opens it in the tab.
struct SidePanelPullRequestPicker: View {
    let directory: String
    let choose: (PullRequestOpenRequest) -> Void
    @ObservedObject private var store = PullRequestStore.shared
    @StateObject private var git: FolderGitModel
    /// The same search and Filters as the Pull requests page (open ones by default); a change in one applies to both.
    @ObservedObject private var filterStore = PullRequestFilterStore.shared
    private var filter: PullRequestFilter { filterStore.filter }
    @ObservedObject private var watching = PullRequestWatchSettings.shared

    init(directory: String, choose: @escaping (PullRequestOpenRequest) -> Void) {
        self.directory = directory
        self.choose = choose
        _git = StateObject(wrappedValue: FolderGitModel(directory: directory))
    }

    /// One group of the list: its heading and its pull requests with the account each is read with.
    private struct PickGroup: Identifiable {
        let id: String
        let title: String
        let role: PullRequestRepoGroup.Role
        let items: [PullRequestOpenRequest]
    }

    private var groups: [PickGroup] {
        let branch = git.status?.branch ?? ""
        var seen = Set<String>()
        func take(_ pick: (AccountPullRequests) -> [PullRequestItem]) -> [PullRequestOpenRequest] {
            filter.apply(store.accounts).flatMap { account in pick(account).map { PullRequestOpenRequest(account: account.id, item: $0) } }
                .filter { seen.insert($0.item.id.lowercased()).inserted }
        }
        let onBranch = branch.isEmpty ? [] : take { ($0.mine + $0.reviews + $0.watched).filter { $0.headBranch == branch } }
        return [
            PickGroup(id: "branch", title: tr("agents.pr.pick.branch", branch), role: .mine, items: onBranch),
            PickGroup(id: "mine", title: tr("agents.pr.pick.mine"), role: .mine, items: take(\.mine)),
            PickGroup(id: "reviews", title: tr("agents.pr.pick.reviews"), role: .review, items: take(\.reviews)),
            PickGroup(id: "watched", title: tr("agents.pr.pick.watched"), role: .watched, items: take(\.watched)),
        ].filter { !$0.items.isEmpty }
    }

    /// Every pull request of one account, for where one stands in a stack.
    private func items(of account: String) -> [PullRequestItem] {
        guard let found = store.accounts.first(where: { $0.id == account }) else { return [] }
        return found.reviews + found.mine + found.watched
    }

    var body: some View {
        let groups = groups
        // Where each pull request stands in a stack, per account, worked out once instead of once per row.
        let stacks = Dictionary(store.accounts.map { ($0.id, PullRequestStack.positions(in: items(of: $0.id))) },
                                uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            PullRequestSearchBar(filter: $filterStore.filter, accounts: store.accounts, prompt: tr("agents.pr.pick.search"),
                                 watching: !watching.entries.isEmpty, style: .inline) {
                // As on the Pull requests page: only a refresh you asked for (or a first load) spins.
                if store.showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) {
                        Task { await store.refresh(force: true) }
                    }
                }
            }
                .padding(NookTheme.Spacing.sm)
            NookDivider()
            if !GitHubPullRequestList.isAvailable {
                StackedDiffNote(text: tr("agents.pr.pick.unavailable"))
            } else if groups.isEmpty {
                if store.loading && !store.loaded {
                    PatientSpinner()
                } else {
                    StackedDiffNote(text: tr(!filter.isActive ? "agents.pr.pick.none" : "agents.pr.pick.noMatch"))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(groups) { group in
                            NookSectionLabel(group.title, inset: NookTheme.Spacing.sm)
                                .padding(.top, NookTheme.Spacing.md)
                            ForEach(group.items, id: \.item.id) { request in
                                PullRequestRow(item: request.item, role: group.role, showRepo: true, accountID: request.account,
                                               stack: stacks[request.account]?[request.item.id]) {
                                    choose(request)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .padding(.bottom, NookTheme.Spacing.md)
                }
            }
        }
        .task {
            await git.refresh()
            await store.refresh()
        }
    }
}
