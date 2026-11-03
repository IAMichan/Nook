import SwiftUI

/// The hover card of a session row's changed files: what the branch changed, file by file with its lines, read from the
/// folder on hover (`FolderGitModel` starts from what it read last, so a second hover shows the list at once).
struct RowChangesCard: View {
    @StateObject private var model: FolderGitModel
    @State private var loaded = false
    /// More than this and the rest is counted under the list: the card stays a glance, the session has the full diff.
    static let limit = 12

    init(directory: String) {
        _model = StateObject(wrappedValue: FolderGitModel.make(directory: directory))
    }

    var body: some View {
        let files = model.changes
        HoverCard(title: tr("agents.git.changes", files.count)) {
            if files.isEmpty {
                HoverCardRow(symbol: loaded ? "checkmark.circle" : "hourglass",
                             text: loaded ? tr("agents.git.noChanges") : tr("connect.status.loading"))
            } else {
                if model.added + model.removed > 0 {
                    PullRequestLineCounts(additions: model.added, deletions: model.removed)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files.prefix(Self.limit)) { FileChangeRow(file: $0) }
                }
                if files.count > Self.limit {
                    Text(tr("agents.row.changes.more", files.count - Self.limit))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
        }
        .frame(width: 320)
        .task {
            await model.refresh()
            loaded = true
        }
    }
}

/// The hover card of a session row's pull request badge: per pull request its title, state, branches, size, checks and
/// who it waits for. A GitHub pull request is read for it (kept for a minute, shared by every row); any other shows what
/// the branch sync knows. With more than one it says how many, and the ones of branches or worktrees the chat worked on
/// before sit under their own heading, so the state of a request the chat moved on from stays in view.
struct RowPullRequestCard: View {
    let pullRequests: SessionPullRequests
    /// More than this and the rest is counted under the list.
    static let limit = 4

    private var shownCurrent: [PullRequestLink] { Array(pullRequests.current.prefix(Self.limit)) }
    private var shownEarlier: [PullRequestLink] { Array(pullRequests.earlier.prefix(max(0, Self.limit - shownCurrent.count))) }
    private var hidden: Int { pullRequests.all.count - shownCurrent.count - shownEarlier.count }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if pullRequests.all.count > 1 {
                Text(tr("agents.row.pr.count", pullRequests.all.count))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
            }
            // Headings only when the chat has requests of an earlier branch: one branch's list needs none.
            let sections = !pullRequests.earlier.isEmpty
            if !shownCurrent.isEmpty {
                section(sections ? tr("agents.row.pr.current") : nil, shownCurrent)
            }
            if !shownEarlier.isEmpty {
                if !shownCurrent.isEmpty { NookDivider() }
                section(tr("agents.row.pr.earlier"), shownEarlier)
            }
            if hidden > 0 {
                Text(tr("agents.row.changes.more", hidden))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .padding(NookTheme.Spacing.lg + NookTheme.Spacing.xxs)
        .frame(width: 320, alignment: .leading)
        .background(DropdownStyle.panel)
    }

    private func section(_ title: String?, _ links: [PullRequestLink]) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let title { NookSectionLabel(title, inset: 0) }
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                if index > 0 { NookDivider() }
                RowPullRequestSummary(link: link)
            }
        }
    }
}

private struct RowPullRequestSummary: View {
    let link: PullRequestLink
    @State private var detail: PullRequestDetail?
    @State private var loading = false

    private var url: URL? { URL(string: link.url) }
    private var title: String { detail?.title ?? link.title ?? "#\(link.number)" }
    private var base: String? { detail?.baseBranch ?? link.baseBranch }
    private var head: String? { detail?.headBranch ?? link.headBranch }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if let url {
                    PullRequestLiveStateBadge(url: url, fallback: PullRequestStatus.glyph(state: link.state, conflicted: link.conflicted))
                } else {
                    PullRequestStateBadge(glyph: PullRequestStatus.glyph(state: link.state, conflicted: link.conflicted), number: link.number)
                }
                Text(link.repository)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.author.isEmpty {
                HoverCardRow(symbol: "person", text: detail.author)
            }
            if let base, let head, !base.isEmpty, !head.isEmpty {
                HoverCardRow(symbol: "arrow.triangle.branch", text: "\(base) ← \(head)")
            }
            if let detail {
                HStack(spacing: NookTheme.Spacing.md) {
                    Image(systemName: "doc.text")
                        .font(NookTheme.font(11, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 16)
                    Text(tr("agents.pr.filesCount", max(detail.changedFiles, detail.files.count)))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                    PullRequestLineCounts(additions: detail.additions, deletions: detail.deletions)
                }
                checks(detail.checks)
                if !detail.requestedReviewers.isEmpty {
                    HoverCardRow(symbol: "eye", text: tr("agents.pr.reviews.waiting", detail.requestedReviewers.joined(separator: ", ")))
                }
            } else if loading {
                HoverCardRow(symbol: "hourglass", text: tr("connect.status.loading"))
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: link.id) { await load() }
    }

    /// "3 passed · 1 failing", with the mark of the worst outcome.
    @ViewBuilder
    private func checks(_ list: [PullRequestCheck]) -> some View {
        let counted = list.filter { $0.outcome != .skipped }
        if counted.isEmpty {
            HoverCardRow(symbol: "checklist", text: tr("agents.pr.checks.none"))
        } else {
            let failing = counted.filter { $0.outcome == .failing }.count
            let running = counted.filter { $0.outcome == .pending }.count
            let passed = counted.filter { $0.outcome == .passing }.count
            let parts = [failing > 0 ? tr("agents.pr.checks.failing", failing) : nil,
                         running > 0 ? tr("agents.pr.checks.running", running) : nil,
                         passed > 0 ? tr("agents.pr.checks.passed", passed) : nil].compactMap { $0 }
            HStack(spacing: NookTheme.Spacing.md) {
                Image(systemName: failing > 0 ? "xmark.circle.fill" : running > 0 ? "clock.fill" : "checkmark.circle.fill")
                    .font(NookTheme.font(11, .medium))
                    .foregroundStyle(failing > 0 ? NookTheme.coral : running > 0 ? NookTheme.amber : NookTheme.mint)
                    .frame(width: 16)
                Text(parts.joined(separator: " · "))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func load() async {
        guard link.host == .github, !link.repository.isEmpty else { return }
        if let cached = RowPullRequestCache.shared.fresh(link.id) {
            detail = cached
            return
        }
        guard let token = GitHubPullRequestDetail.token(accountID: nil) else { return }
        loading = true
        defer { loading = false }
        guard let read = try? await GitHubPullRequestDetail.summary(repo: link.repository, number: link.number, token: token) else { return }
        RowPullRequestCache.shared.store(read, for: link.id)
        PullRequestStatusStore.shared.record(read)
        detail = read
    }
}

/// The pull requests the row cards read, for a minute: sweeping back over a row does not ask GitHub again.
@MainActor
private final class RowPullRequestCache {
    static let shared = RowPullRequestCache()
    private var entries: [String: (detail: PullRequestDetail, at: Date)] = [:]
    private static let maxAge: TimeInterval = 60

    func fresh(_ id: String) -> PullRequestDetail? {
        guard let entry = entries[id], Date().timeIntervalSince(entry.at) < Self.maxAge else { return nil }
        return entry.detail
    }

    func store(_ detail: PullRequestDetail, for id: String) {
        entries[id] = (detail, Date())
        if entries.count > 50, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries[oldest] = nil }
    }
}
