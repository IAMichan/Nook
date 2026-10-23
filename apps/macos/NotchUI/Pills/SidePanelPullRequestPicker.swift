import SwiftUI

/// The side panel's Pull request tab before one is open: a search, then the pull requests to open beside the session.
/// First the one for the branch the session's folder is on, then yours, the ones waiting for your review and the
/// watched ones, from every GitHub account (`PullRequestStore`). A click opens it in the tab.
struct SidePanelPullRequestPicker: View {
    let directory: String
    let choose: (PullRequestOpenRequest) -> Void
    @ObservedObject private var store = PullRequestStore.shared
    @StateObject private var git: FolderGitModel
    @State private var query = ""

    init(directory: String, choose: @escaping (PullRequestOpenRequest) -> Void) {
        self.directory = directory
        self.choose = choose
        _git = StateObject(wrappedValue: FolderGitModel(directory: directory))
    }

    /// One group of the list: its heading and its pull requests with the account each is read with.
    private struct PickGroup: Identifiable {
        let id: String
        let title: String
        let items: [PullRequestOpenRequest]
    }

    private var groups: [PickGroup] {
        let branch = git.status?.branch ?? ""
        var seen = Set<String>()
        func take(_ pick: (AccountPullRequests) -> [PullRequestItem]) -> [PullRequestOpenRequest] {
            store.accounts.flatMap { account in pick(account).map { PullRequestOpenRequest(account: account.id, item: $0) } }
                .filter { matches($0.item) && seen.insert($0.item.id.lowercased()).inserted }
        }
        let onBranch = branch.isEmpty ? [] : take { ($0.mine + $0.reviews + $0.watched).filter { $0.headBranch == branch } }
        return [
            PickGroup(id: "branch", title: tr("agents.pr.pick.branch", branch), items: onBranch),
            PickGroup(id: "mine", title: tr("agents.pr.pick.mine"), items: take(\.mine)),
            PickGroup(id: "reviews", title: tr("agents.pr.pick.reviews"), items: take(\.reviews)),
            PickGroup(id: "watched", title: tr("agents.pr.pick.watched"), items: take(\.watched)),
        ].filter { !$0.items.isEmpty }
    }

    private func matches(_ item: PullRequestItem) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }
        let number = text.hasPrefix("#") ? String(text.dropFirst()) : text
        return item.title.lowercased().contains(text) || item.repo.lowercased().contains(text)
            || item.headBranch.lowercased().contains(text) || String(item.number) == number
    }

    var body: some View {
        let groups = groups
        VStack(spacing: 0) {
            NookSearchField(prompt: tr("agents.pr.pick.search"), text: $query, style: .inline)
                .padding(NookTheme.Spacing.sm)
            NookDivider()
            if !GitHubPullRequestList.isAvailable {
                StackedDiffNote(text: tr("agents.pr.pick.unavailable"))
            } else if groups.isEmpty {
                if store.loading && !store.loaded {
                    PatientSpinner()
                } else {
                    StackedDiffNote(text: tr(query.isEmpty ? "agents.pr.pick.none" : "agents.pr.pick.noMatch"))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(groups) { group in
                            NookSectionLabel(group.title, inset: NookTheme.Spacing.sm)
                                .padding(.top, NookTheme.Spacing.md)
                            ForEach(group.items, id: \.item.id) { request in
                                SidePanelPullRequestRow(item: request.item) { choose(request) }
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

/// One pull request to open: its state mark in the state's color, number and title, and its repository under them.
private struct SidePanelPullRequestRow: View {
    let item: PullRequestItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
                PullRequestStateIcon(glyph: item.stateGlyph)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Text("#\(item.number)").font(NookTheme.mono(11, .medium)).foregroundStyle(NookTheme.textTertiary)
                        Text(item.title)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                            .lineLimit(1)
                    }
                    Text(item.headBranch.isEmpty ? item.repo : item.repo + " · " + item.headBranch)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .padding(.vertical, NookTheme.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(hovering ? NookTheme.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.repo + " #\(item.number)")
    }
}
