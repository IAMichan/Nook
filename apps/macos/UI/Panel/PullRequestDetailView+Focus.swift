import SwiftUI

/// A link that points somewhere inside the pull request (`PullRequestFocus`) opens the page there: a comment on the
/// timeline, scrolled to and lit up; a file on the Code tab, unfolded and scrolled to; the checks on the Summary; a commit's
/// changes on the Code tab, or the commits on the timeline.
extension PullRequestDetailView {
    /// The tab a link's focus opens on, from the first frame.
    static func tab(for focus: PullRequestFocus) -> Tab {
        switch focus {
        case .comment: return .timeline
        case .file: return .code
        case .checks: return .summary
        case .commits(let sha): return sha == nil ? .timeline : .code
        }
    }

    /// Goes where the link pointed once the page has what it needs: the overview for the checks, the timeline, commits
    /// and files for the rest. Runs again as those arrive, and does its work once.
    func applyFocus() {
        guard let focus = pendingFocus, settled, let detail else { return }
        switch focus {
        case .checks:
            pendingFocus = nil
            if tab != .summary { switchTo(.summary) }
            // Once the Summary's page is there to scroll.
            DispatchQueue.main.async { revealChecks() }
        case .comment(let ids):
            guard detail.activityLoaded else { return }
            pendingFocus = nil
            if tab != .timeline { switchTo(.timeline) }
            guard let id = ids.first(where: { id in detail.events.contains { $0.id == id } }) else { return }
            focusedEvent = id
            // Once the timeline's page is built (it may appear on this very turn), so it can scroll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollRequest = PullRequestPageScrollRequest(target: id)
            }
        case .file(let anchor):
            guard detail.activityLoaded else { return }
            pendingFocus = nil
            codeCommit = nil
            if tab != .code { switchTo(.code) }
            openFile = anchor.file(in: detail.files.map(\.path))
        case .commits(let sha):
            guard detail.activityLoaded else { return }
            pendingFocus = nil
            if let sha, let commit = detail.commits.first(where: { $0.sha.lowercased().hasPrefix(sha) }) {
                openCommit(commit.sha, detail: detail)
            } else if tab != .timeline {
                switchTo(.timeline)
            }
        }
    }

    /// A new link to a page that is open already: its tab, then the place.
    func takeFocus(_ request: PullRequestFocusRequest?) {
        guard let request else { return }
        pendingFocus = request.focus
        focusedEvent = nil
        let wanted = Self.tab(for: request.focus)
        if tab != wanted { switchTo(wanted) }
        applyFocus()
    }
}
