import SwiftUI

/// The hover card of a session row's changed files: what the branch changed, file by file with its lines, read from the
/// folder on hover (`FolderGitModel` starts from what it read last, so a second hover shows the list at once).
struct RowChangesCard: View {
    @StateObject private var model: FolderGitModel
    @State private var loaded = false
    /// More than this and the rest is counted under the list: the card stays a glance, the session has the full diff.
    static let limit = 12
    /// The lines the row shows for this session, counted as it edited; git can have nothing left of them (the work went
    /// straight onto the default branch, or the folder is gone), and the card then says so instead of "no changes".
    let countedAdded: Int
    let countedRemoved: Int
    let directory: String
    /// Shows a file's change; gets its path relative to `directory`.
    let onOpen: (String) -> Void

    init(directory: String, countedAdded: Int = 0, countedRemoved: Int = 0, onOpen: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: FolderGitModel.make(directory: directory))
        self.directory = directory
        self.countedAdded = countedAdded
        self.countedRemoved = countedRemoved
        self.onOpen = onOpen
    }

    var body: some View {
        let files = model.changes
        let counted = countedAdded + countedRemoved > 0
        HoverCard(title: files.isEmpty && counted ? tr("agents.panel.changes") : tr("agents.git.changes", files.count)) {
            if files.isEmpty, counted, loaded {
                PullRequestLineCounts(additions: countedAdded, deletions: countedRemoved)
                HoverCardRow(symbol: "checkmark.circle", text: tr("agents.row.changes.counted"))
            } else if files.isEmpty {
                HoverCardRow(symbol: loaded ? "checkmark.circle" : "hourglass",
                             text: loaded ? tr("agents.git.noChanges") : tr("connect.status.loading"))
            } else {
                if model.added + model.removed > 0 {
                    PullRequestLineCounts(additions: model.added, deletions: model.removed)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files.prefix(Self.limit)) { file in
                        // Git names a file from the repository's root, the session's changes from its folder.
                        HoverCardButton(help: tr("agents.row.changes.open"), action: {
                            onOpen(TurnDiff.relative((model.root ?? directory) + "/" + file.path, to: directory))
                        }) {
                            FileChangeRow(file: file)
                        }
                    }
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
/// before sit under their own heading, so the state of a request the chat moved on from stays in view. A stack longer
/// than the card scrolls under its count, so every request in it can be read and opened from here.
struct RowPullRequestCard: View {
    let pullRequests: SessionPullRequests
    /// Opens one of them.
    let onOpen: (URL) -> Void
    /// Taller than this and the list scrolls: about three requests stay in view, the next one peeks in below.
    static let maxListHeight: CGFloat = 560
    @State private var listHeight: CGFloat = 0

    /// Counted over all of them: this is what says how far a stack has landed.
    private var merged: Int { pullRequests.all.filter { $0.state == .merged }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if pullRequests.all.count > 1 {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(tr("agents.row.pr.count", pullRequests.all.count))
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    Spacer(minLength: 0)
                    if merged > 0 {
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            PullRequestStateIcon(glyph: .merged, tinted: false)
                            Text(tr("agents.row.pr.merged", merged)).lineLimit(1)
                        }
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(PullRequestIcon.tint(.merged))
                    }
                }
                .padding(.horizontal, Self.inset)
            }
            let fitted = min(listHeight, Self.maxListHeight)
            ScrollView {
                list
                    .padding(.horizontal, Self.inset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(listHeight > Self.maxListHeight ? .automatic : .hidden)
            .frame(height: fitted)
        }
        .padding(.vertical, Self.inset)
        .frame(width: 320, alignment: .leading)
        .background(DropdownStyle.panel)
    }

    /// The card's padding; the list keeps it inside the scroll view so the scroller sits at the card's edge.
    private static var inset: CGFloat { NookTheme.Spacing.lg + NookTheme.Spacing.xxs }

    private var list: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            // Headings only when the chat has requests of an earlier branch: one branch's list needs none.
            let sections = !pullRequests.earlier.isEmpty
            if !pullRequests.current.isEmpty {
                section(sections ? tr("agents.row.pr.current") : nil, pullRequests.current)
            }
            if !pullRequests.earlier.isEmpty {
                if !pullRequests.current.isEmpty { NookDivider() }
                section(tr("agents.row.pr.earlier"), pullRequests.earlier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String?, _ links: [PullRequestLink]) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let title { NookSectionLabel(title, inset: 0) }
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                if index > 0 { NookDivider() }
                if let url = URL(string: link.url) {
                    HoverCardButton(help: tr("agents.row.pr.open"), action: { onOpen(url) }) {
                        RowPullRequestSummary(link: link)
                    }
                } else {
                    RowPullRequestSummary(link: link)
                }
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
                    Image(icon: "doc.text")
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
                Image(icon: failing > 0 ? "xmark.circle.fill" : running > 0 ? "clock.fill" : "checkmark.circle.fill")
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
