import SwiftUI

/// The session's branches in the tray, oldest first and the current one last, their names in one column so the pull
/// requests line up. A chat with many keeps the newest ones open and folds the older ones behind one row.
struct RunBranchTray: View {
    let rows: [SessionBranches.Row]
    let watches: [PullRequestWatch]
    /// The current branch's pull request can still change (a merged or closed one is only shown).
    let canWatchCurrent: Bool
    let runID: UUID
    let workspace: WorkspaceManager
    @ObservedObject var pullRequestSync: PullRequestSync
    @Binding var showsOlderBranches: Bool

    var body: some View {
        let folded = SessionBranches.folded(rows, open: showsOlderBranches)
        let titles = Dictionary(((pullRequestSync.earlier[runID] ?? []) + (pullRequestSync.links[runID] ?? []))
            .compactMap { link in link.title.map { (link.url, $0) } }, uniquingKeysWith: { _, newer in newer })
        if folded.hidden > 0 || showsOlderBranches && rows.count > SessionBranches.shownWhenFolded {
            Button {
                withAnimation(NookTheme.reveal) { showsOlderBranches.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.xs) {
                    DisclosureChevron(open: showsOlderBranches, size: 8.5, tint: nil, style: .upward)
                    Text(showsOlderBranches ? tr("ws.branches.hideOlder")
                                            : tr("ws.branches.showOlder", folded.hidden, folded.hiddenPullRequests))
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .padding(.leading, NookTheme.Spacing.xs)
            .padding(.vertical, NookTheme.Spacing.xxs)
        }
        ForEach(folded.shown) { row in
            branchRow(row, watch: row.pullRequest.flatMap { url in watches.first { $0.url == url.absoluteString } }, title: row.pullRequest.flatMap { titles[$0.absoluteString] }, canWatchCurrent: canWatchCurrent)
        }
    }

    /// One of the session's branches in the tray: its pull request with state, title and checks (watched from here, one
    /// at a time), or its name and "no pull request" while it has none. `canWatchCurrent`: the current branch's pull
    /// request can still change (a merged or closed one is only shown).
    @ViewBuilder
    private func branchRow(_ row: SessionBranches.Row, watch: PullRequestWatch?, title: String?, canWatchCurrent: Bool) -> some View {
        if let url = row.pullRequest {
            let watched = watch != nil
            PullRequestWatchStrip(url: url, watch: watch, branch: row.branch, isCurrent: row.isCurrent,
                                  title: title, toggle: watched || !row.isCurrent || canWatchCurrent ? {
                if watched { workspace.stopWatchingPullRequest(runID, url: url) } else { workspace.watchPullRequest(runID, url: url) }
            } : nil)
        } else if let branch = row.branch {
            BranchTrayRow(branch: branch, isCurrent: row.isCurrent)
        }
    }
}
