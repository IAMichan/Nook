import AppKit
import SwiftUI

/// A line comment written on the Code tab, waiting for the review it will go out with. Kept per pull request while Nook
/// runs, so leaving the page does not lose it.
struct PullRequestPendingComment: Identifiable, Equatable, Sendable {
    let review: ReviewComment
    /// GitHub's line and side: the new file's line, or the old file's for a removed line.
    let line: Int
    let side: String
    /// The first line and its side, for a comment on several lines.
    var startLine: Int? = nil
    var startSide: String? = nil

    var id: UUID { review.id }
    var action: PullRequestAction.LineComment {
        PullRequestAction.LineComment(path: review.path, line: line, side: side, body: review.text, startLine: startLine, startSide: startSide)
    }

    /// From the rows of a diff: GitHub places a comment on the new file's line, or the old file's for a removed line.
    static func make(_ row: UnifiedDiff.Row, from first: UnifiedDiff.Row?, text: String, path: String, scope: String) -> PullRequestPendingComment? {
        guard let line = row.new ?? row.old else { return nil }
        let review = ReviewComment(path: path, line: row.new, code: row.raw, text: text, scope: scope)
        return PullRequestPendingComment(review: review, line: line, side: row.new == nil ? "LEFT" : "RIGHT", startLine: first.flatMap { $0.new ?? $0.old },
                                         startSide: first.map { $0.new == nil ? "LEFT" : "RIGHT" })
    }
}

/// The Code tab: every changed file in one scroll in reading order, or the files of one commit picked from the menu. Line
/// comments are written here and go out together with the review, so the whole change is what they are on. The
/// conversations already on a line stand under it; the ones on a line a push moved stand under the file. A file you mark
/// viewed folds, and its mark lapses when a push changes it.
struct PullRequestCodeTab: View {
    let detail: PullRequestDetail
    let accountID: String
    @ObservedObject var actions: PullRequestActionState
    @Binding var viewed: PullRequestViewedFiles
    /// The sha of the commit shown; nil for the whole change.
    @Binding var commit: String?
    /// A file to unfold and scroll to, from the Guide.
    let focus: String?
    let now: Date
    let onScroll: (PullRequestPageScroll) -> Void
    @State private var expanded: Set<String> = []
    @State private var showsTree = true
    @State private var commitFiles: [String: [PullRequestFile]] = [:]
    @State private var commitError: String?
    /// Opened once per head: later polls leave what you folded alone.
    @State private var openedFor: String?

    private var key: String { PullRequestViewedFiles.key(repo: detail.repo, number: detail.number) }
    private var files: [PullRequestFile] {
        if let commit { return commitFiles[commit] ?? [] }
        let byPath = Dictionary(detail.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return PullRequestFileOrder.ordered(detail.files.map(\.path)).compactMap { byPath[$0] }
    }

    var body: some View {
        let files = files
        let stacked = files.map(Self.stacked)
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    scopeMenu
                    pendingBar
                    Spacer(minLength: NookTheme.Spacing.sm)
                    StackedDiffToolbar(files: stacked, expanded: $expanded, showsTree: $showsTree, hidesWhitespace: false)
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        scopeMenu
                        Spacer(minLength: NookTheme.Spacing.sm)
                        pendingBar
                    }
                    StackedDiffToolbar(files: stacked, expanded: $expanded, showsTree: $showsTree, hidesWhitespace: false)
                }
            }
            .padding(.vertical, NookTheme.Spacing.xs)
            .pullRequestPageColumn()
            NookDivider()
            if let commitError, commit != nil {
                StackedDiffNote(text: commitError)
            } else if commit != nil, commit.flatMap({ commitFiles[$0] }) == nil {
                PatientSpinner()
            } else if files.isEmpty {
                ListEmptyNote(tr("agents.pr.files.none"))
            } else {
                StackedDiffList(files: stacked, scope: "pull \(detail.id) \(commit ?? detail.headSHA)", expanded: $expanded, showsTree: showsTree,
                                focus: focus, headerAccessory: viewedMark, onScroll: onScroll, diff: { file, _ in
                    files.first { $0.path == file.path }?.patch ?? ""
                }) { file, text in
                    body(of: file, text: text)
                }
            }
        }
        .task(id: commit) { await readCommit() }
        .onChange(of: detail.headSHA, initial: true) { _, head in unfold(head) }
    }

    /// The diff with what is said about it: pending comments and conversations under their line, the rest under the file.
    @ViewBuilder
    private func body(of file: StackedDiffFile, text: String) -> some View {
        let lines = UnifiedDiff.rows(text).compactMap(\.new)
        let threads = commit == nil ? PullRequestConversation.items(detail.events).filter { $0.root.isOn(path: file.path) } : []
        let onLine = threads.filter { item in Self.line(item).map(lines.contains) ?? false }
        let moved = threads.filter { item in !onLine.contains(item) }
        VStack(alignment: .leading, spacing: 0) {
            DiffText(text: text, comments: commit == nil ? actions.lineComments.filter { $0.review.path == file.path }.map(\.review) : [],
                     onRemoveComment: commit == nil ? { id in actions.lineComments.removeAll { $0.id == id } } : nil,
                     stacked: true, path: file.path, scope: "pull \(detail.id)",
                     onRowComment: commit == nil && detail.isOpen && detail.features.lineComments ? { row, first, comment in
                         if let pending = PullRequestPendingComment.make(row, from: first, text: comment, path: file.path, scope: "pull \(detail.id)") {
                             actions.lineComments.append(pending)
                         }
                     } : nil,
                     annotationLines: Set(onLine.compactMap(Self.line)),
                     annotationVersion: onLine.map { "\($0.id) \($0.events.count) \($0.root.resolved)" }.joined(separator: ","),
                     annotation: { line in
                         AnyView(ForEach(onLine.filter { Self.line($0) == line }) { item in
                             PullRequestConversationRow(item: item, now: now).padding(NookTheme.Spacing.sm)
                         })
                     })
            ForEach(moved) { item in
                PullRequestConversationRow(item: item, now: now).padding(NookTheme.Spacing.sm)
            }
        }
    }

    private static func line(_ item: PullRequestConversationItem) -> Int? {
        if case .lineComment(_, let line) = item.root.kind, !item.root.outdated { return line }
        return nil
    }

    private static func stacked(_ file: PullRequestFile) -> StackedDiffFile {
        let kind: ChangedFilesTree.FileStat.Kind
        switch file.status {
        case "added": kind = .added
        case "removed": kind = .deleted
        case "renamed", "copied": kind = .renamed(from: file.previousPath ?? "")
        default: kind = .modified
        }
        return StackedDiffFile(path: file.path, previousPath: file.previousPath, kind: kind, additions: file.additions, deletions: file.deletions)
    }

    /// The whole change or one commit, newest commit first.
    private var scopeMenu: some View {
        Menu {
            Button(tr("agents.pr.code.allCommits")) { commit = nil }
            if !detail.commits.isEmpty, detail.features.commitView {
                Divider()
                ForEach(detail.commits.reversed()) { item in
                    Button(item.shortSHA + "  " + item.subject) { commit = item.sha }
                }
            }
        } label: {
            Text(commit.flatMap { sha in detail.commits.first { $0.sha == sha }?.subject } ?? tr("agents.pr.code.allCommits"))
                .font(NookTheme.TextStyle.label)
                .lineLimit(1)
        }
        .menuStyle(.nookBorderlessButton)
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: commit == nil, vertical: false)
        .help(commit == nil ? tr("agents.pr.code.scope") : tr("agents.pr.code.wholeChangeOnly"))
        .accessibilityLabel(tr("agents.pr.code.scope"))
    }

    /// "2 comments · Finish review", while comments wait for their review.
    @ViewBuilder
    private var pendingBar: some View {
        if !actions.lineComments.isEmpty {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("agents.pr.code.pending", actions.lineComments.count))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.amber)
                    .monospacedDigit()
                    .lineLimit(1)
                SmallGhostButton(title: tr("agents.pr.code.finishReview")) {
                    actions.open(.write, detail: detail)
                    actions.asReview = true
                }
            }
            .fixedSize()
        }
    }

    private func viewedMark(_ file: StackedDiffFile) -> AnyView {
        guard commit == nil, let found = detail.files.first(where: { $0.path == file.path }) else { return AnyView(EmptyView()) }
        let status = viewed.status(found, in: key)
        let seen = status == .viewed
        return AnyView(HStack(spacing: NookTheme.Spacing.xs) {
            if status == .changed {
                Text(tr("agents.pr.files.changedSince")).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.amber)
            } else if PullRequestFileOrder.kind(file.path) == .generated {
                Text(tr("agents.pr.files.generated")).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            }
            ToolbarIconButton(seen ? "checkmark.circle.fill" : "circle", tr(seen ? "agents.pr.files.unmarkViewed" : "agents.pr.files.markViewed"),
                              height: 20, width: 20) {
                viewed.setViewed(!seen, file: found, in: key)
                viewed.save()
                if !seen { expanded.remove(file.id) }
            }
        })
    }

    /// Everything you still have to read open, the files you viewed and generated ones folded.
    private func unfold(_ head: String) {
        guard openedFor != head, detail.activityLoaded else { return }
        openedFor = head
        expanded = Set(detail.files.filter { viewed.status($0, in: key) != .viewed && PullRequestFileOrder.kind($0.path) != .generated }.map(\.path))
    }

    private func readCommit() async {
        commitError = nil
        guard let commit, commitFiles[commit] == nil else { return }
        let forge = PullRequestForges.client(account: accountID, path: detail.repo)
        guard let token = forge != nil ? "" : GitHubPullRequestDetail.token(accountID: accountID) else {
            commitError = tr("agents.pr.noToken")
            return
        }
        do {
            let read = forge != nil ? try await forge!.commitFiles(sha: commit) : try await GitHubPullRequestDetail.commitFiles(repo: detail.repo, sha: commit, token: token)
            commitFiles[commit] = read
            expanded.formUnion(read.map(\.path))
        } catch {
            commitError = error.localizedDescription
        }
    }
}

extension PullRequestDetailView {
    /// The file's name in full brightness, the folder it is in dimmed before it.
    func filePath(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let folder = String(path.dropLast(name.count))
        return (Text(folder).foregroundStyle(NookTheme.textTertiary) + Text(name).foregroundStyle(NookTheme.paper))
            .font(NookTheme.TextStyle.code)
            .lineLimit(1)
            .truncationMode(.head)
            .help(path)
    }
}
