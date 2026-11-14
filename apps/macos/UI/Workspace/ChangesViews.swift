import AppKit
import SwiftUI

/// Review changes, laid out as a stacked diff (`StackedDiffList`): a toolbar, then every changed file in one
/// scroll, folded until you open it; the file you came for opens at once. Hovering a line offers a comment for the agent;
/// the comments go to it together from the bar at the bottom.
struct ChangesSheet: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    let initialFile: GitFileChange?
    /// Set when shown inside the notch: closes it there (and the notch shows the title).
    var onClose: (() -> Void)? = nil
    private var embedded: Bool { onClose != nil }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @State private var expanded: Set<String> = []
    @State private var showsTree = false
    /// The branch as the header's "+58 −6" counts it: everything since it left its base, committed (and merged) work
    /// included, not only what is uncommitted. Read for the session's folder; empty until read, or when it is not on
    /// this Mac.
    @State private var branch: FolderGitModel?
    @State private var branchFiles: [GitFileChange] = []

    private var uncommitted: [GitFileChange] { workspace.git[runID]?.status?.files ?? [] }
    /// The branch's changes, else (no base to compare with, or a remote session) what is uncommitted.
    private var files: [GitFileChange] { branchFiles.isEmpty ? uncommitted : branchFiles }
    private var directory: String { workspace.run(runID)?.workingDirectory ?? "" }

    private func readBranch() async {
        guard !directory.isEmpty else { return }
        let model: FolderGitModel
        if let branch, branch.directory == directory {
            model = branch
        } else {
            // A model starts with what the folder showed last time, so the list is there at once.
            model = FolderGitModel(directory: directory)
            branch = model
            branchFiles = model.changes
        }
        await model.refresh()
        branchFiles = model.changes
    }

    private func diff(_ change: GitFileChange, options: DiffReadOptions) async throws -> String {
        if let branch, branchFiles.contains(where: { $0.path == change.path }) { return try await branch.diff(change, options: options) }
        return try await workspace.diff(runID, file: change, options: options)
    }

    var body: some View {
        let files = files.map(StackedDiffFile.init)
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if !embedded {
                    Text(tr("ws.changes.title")).font(NookTheme.TextStyle.title)
                    if let run = workspace.run(runID) {
                        Text(run.branch ?? run.projectName).font(NookTheme.TextStyle.code).foregroundStyle(WS.secondary)
                    }
                } else {
                    Text(tr("agents.turn.changedFiles", files.count))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                // The same bar as a folder's changes in the side panel: read git again, then fold or show the tree. Dimmed
                // while git is read, so two quick clicks never race and leave the older result in view.
                if embedded {
                    ToolbarIconButton("arrow.clockwise", tr("agents.pulls.refresh"),
                                      enabled: workspace.git[runID]?.loading != true) {
                        workspace.refreshGit(runID)
                        Task { await readBranch() }
                    }
                }
                StackedDiffToolbar(files: files, expanded: $expanded, showsTree: $showsTree)
                if !embedded {
                    Button(tr("button.close")) { close() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, embedded ? NookTheme.Spacing.sm : 14)
            .frame(height: embedded ? SidePanelMetrics.toolbar : 48)
            .padding(.bottom, embedded ? SidePanelMetrics.toolbarGap : 0)
            if !embedded { NookDivider() }
            if files.isEmpty {
                StackedDiffNote(text: tr("ws.changes.noDiffDetail"))
            } else {
                ChangesDiffList(workspace: workspace, runID: runID, scope: runID.uuidString, files: files,
                                comments: workspace.reviewComments[runID] ?? [], expanded: $expanded, showsTree: showsTree,
                                focus: initialFile?.path,
                                hunkable: workspace.run(runID)?.isRemote == false ? Set(uncommitted.map(\.path)) : []) { file, options in
                    guard let change = self.files.first(where: { $0.path == file.path }) else { return "" }
                    return try await diff(change, options: options)
                }
                // The sheet redraws with every change to the sessions (an agent streaming in another window); the list of
                // files, hundreds of them after a big change, only when they, the comments or the folding changed.
                .equatable()
            }
            ReviewCommentsBar(runID: runID, sent: close)
        }
        .frame(minWidth: embedded ? nil : 820, idealWidth: embedded ? nil : 1040, maxWidth: embedded ? CGFloat.infinity : nil,
               minHeight: embedded ? nil : 520, idealHeight: embedded ? nil : 700, maxHeight: embedded ? CGFloat.infinity : nil)
        .background(embedded ? Color.clear : WS.background)
        .onAppear { workspace.markReviewed(runID) }
        .task(id: directory) { await readBranch() }
        // The agent wrote or committed: read the branch again.
        .onChange(of: uncommitted) { _, _ in Task { await readBranch() } }
    }
}

/// The comments on a diff's lines, under it: they go to the agent together. Nothing without any.
struct ReviewCommentsBar: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    var sent: () -> Void = {}

    var body: some View {
        if let comments = workspace.reviewComments[runID], !comments.isEmpty {
            NookDivider()
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: "text.bubble").foregroundStyle(NookTheme.amber)
                Text(tr("ws.review.count", comments.count))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                Spacer()
                SmallGhostButton(title: tr("ws.review.discard")) { workspace.reviewComments[runID] = nil }
                NookPrimaryButton(title: tr("ws.review.send")) {
                    workspace.sendReviewComments(runID)
                    sent()
                }
            }
            .padding(10)
        }
    }
}

/// The diff of a session Nook runs in the Changes tab: the files with comments on their lines. Apart from the panel, so
/// only this part follows the workspace.
struct RunDiffList: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    let files: [StackedDiffFile]
    let scope: String
    @Binding var expanded: Set<String>
    let showsTree: Bool
    let focus: String?
    let diff: (StackedDiffFile, DiffReadOptions) async throws -> String

    var body: some View {
        ChangesDiffList(workspace: workspace, runID: runID, scope: scope, files: files,
                        comments: workspace.reviewComments[runID] ?? [], expanded: $expanded, showsTree: showsTree,
                        focus: focus, diff: diff)
            .equatable()
            .onAppear { workspace.markReviewed(runID) }
    }
}

/// The stacked diff of a session's changes, with comments on its lines. Equatable on what it shows, so the sheet
/// redrawing around it does not lay out every file's header again.
private struct ChangesDiffList: View, Equatable {
    /// Passed, not observed: its every change would redraw the list.
    let workspace: WorkspaceManager
    let runID: UUID
    /// Tells this diff apart in the cache of diffs already read (`StackedDiffList`).
    let scope: String
    let files: [StackedDiffFile]
    let comments: [ReviewComment]
    @Binding var expanded: Set<String>
    let showsTree: Bool
    let focus: String?
    /// The files whose hunks can be staged or discarded one by one: the changed files of a session on this Mac.
    var hunkable: Set<String> = []
    let diff: (StackedDiffFile, DiffReadOptions) async throws -> String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.runID == rhs.runID && lhs.scope == rhs.scope && lhs.files == rhs.files && lhs.comments == rhs.comments
            && lhs.expanded == rhs.expanded && lhs.showsTree == rhs.showsTree && lhs.focus == rhs.focus && lhs.hunkable == rhs.hunkable
    }

    /// Stages (accept) or discards (reject) one hunk of a file; discarding asks first, as it cannot be undone.
    private func applyHunk(path: String, text: String, index: Int, action: HunkAction) {
        guard let patch = HunkPatch(diff: text).patch(hunk: index) else { return }
        let name = (path as NSString).lastPathComponent
        if action == .reject {
            let alert = NSAlert()
            alert.messageText = tr("agents.diff.hunk.confirm")
            alert.informativeText = tr("agents.diff.hunk.confirm.detail", name)
            alert.addButton(withTitle: tr("file.viewer.discard.confirm"))
            alert.addButton(withTitle: tr("button.cancel"))
            guard alert.runAboveNotch() == .alertFirstButtonReturn else { return }
        }
        let workspace = workspace
        let runID = runID
        Task {
            do {
                try await workspace.applyHunk(runID, patch: patch, action: action)
                ToastCenter.shared.success(tr(action == .accept ? "agents.diff.hunk.staged" : "agents.diff.hunk.discarded"), detail: name)
            } catch {
                ToastCenter.shared.error(tr("agents.diff.hunk.failed"), detail: error.localizedDescription)
            }
        }
    }

    var body: some View {
        StackedDiffList(files: files, scope: scope, expanded: $expanded, showsTree: showsTree,
                        focus: focus, diff: diff) { file, text in
            DiffText(text: text, comments: comments.filter { $0.path == file.path && ($0.scope == nil || $0.scope == scope) },
                     onComment: { line, code, comment in
                         workspace.addReviewComment(runID, ReviewComment(path: file.path, line: line, code: code, text: comment, scope: scope))
                     },
                     onRemoveComment: { workspace.removeReviewComment(runID, $0) }, stacked: true, path: file.path,
                     scope: runID.uuidString + "\n" + file.path,
                     onHunk: hunkable.contains(file.path) && file.kind == .modified ? { index, action in
                         applyHunk(path: file.path, text: text, index: index, action: action)
                     } : nil)
                // Only when the diff or its comments changed.
                .equatable()
                .sessionFileMenu(workspace, runID: runID, path: file.path)
        }
    }
}

/// Commit: review staged changes before writing the commit message.
struct CommitSheet: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    /// A session Nook runs, or (nil) the repository root in `folder` of one it only sees.
    let runID: UUID?
    var folder: String? = nil
    /// Set when shown inside the notch: closes it there (and the notch shows the title).
    var onClose: (() -> Void)? = nil
    private var embedded: Bool { onClose != nil }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @State private var message = ""
    @State private var included: Set<String> = []
    @State private var working = false
    @State private var error: String?
    @State private var done: String?
    /// The status of `folder`, read when the sheet opens.
    @State private var folderStatus: GitStatus?
    /// `@` in the message: the files of the repository and people from your chats, as plain words.
    @StateObject private var mentionModel = ComposerModel()
    private var mentionConfig: ComposerConfig { .mentions(folder: directory) }

    init(runID: UUID, onClose: (() -> Void)? = nil) {
        self.runID = runID
        self.onClose = onClose
    }

    init(folder: String, onClose: (() -> Void)? = nil) {
        self.runID = nil
        self.folder = folder
        self.onClose = onClose
    }

    private var run: WorkspaceRun? { runID.flatMap { workspace.run($0) } }
    private var directory: String? { run?.workingDirectory ?? folder }
    private var files: [GitFileChange] { runID.flatMap { workspace.git[$0]?.status?.files } ?? folderStatus?.files ?? [] }
    private var branch: String? { runID != nil ? run?.branch : folderStatus?.branch }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if !embedded { Text(tr("ws.commit.title")).font(NookTheme.TextStyle.title) }
            if let directory {
                Text(tr("ws.commit.where", branch ?? "HEAD", AgentPathFormat.tilde(directory)))
                    .font(NookTheme.TextStyle.detail).foregroundStyle(WS.secondary)
            }
            List {
                ForEach(files) { file in
                    Toggle(isOn: Binding(
                        get: { included.contains(file.path) },
                        set: { if $0 { included.insert(file.path) } else { included.remove(file.path) } }
                    )) {
                        FileChangeRow(file: file)
                    }
                    .toggleStyle(.checkbox)
                    .contextMenu {
                        FileContextMenu(absolutePath: runID.map { workspace.absolutePath($0, repositoryPath: file.path) }
                                            ?? folder.map { ($0 as NSString).appendingPathComponent(file.path) },
                                        relativePath: file.path)
                            .environmentObject(workspace)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 260)
            .listStyle(.bordered)
            Text(tr("ws.commit.message")).font(NookTheme.TextStyle.strong)
            MentionSuggestions(model: mentionModel, text: $message, config: mentionConfig)
            TextEditor(text: $message)
                .mentions(mentionModel, text: $message, config: mentionConfig)
                .font(NookTheme.TextStyle.code)
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(NookTheme.Spacing.sm)
                .cardBackground(WS.surface, stroke: WS.border, radius: NookTheme.Radius.chip)
            if let run, message.isEmpty {
                Button(tr("ws.commit.useTitle")) { message = run.title }
                    .buttonStyle(.nookLink)
                    .font(NookTheme.TextStyle.detail)
            }
            if let error { InlineErrorText(error) }
            if let done { Text(tr("ws.commit.done", done)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.mint) }
            AdaptiveActionRow {
                Text(tr("ws.commit.note")).font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                SmallGhostButton(title: tr("button.cancel")) { close() }.keyboardShortcut(.cancelAction)
                SmallPrimaryButton(title: tr("ws.commit.action", included.count)) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || included.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || done != nil)
            }
        }
        .padding(embedded ? 0 : 18)
        // In the panel it takes the width of the tab, however narrow; on its own it keeps its usual 560.
        .frame(width: embedded ? nil : 560)
        .frame(maxWidth: .infinity, alignment: embedded ? .topLeading : .center)
        .task {
            if let folder { folderStatus = await workspace.folderStatus(folder) }
            included = Set(files.map(\.path))
        }
    }

    private func commit() {
        working = true
        error = nil
        Task {
            do {
                if let runID {
                    done = try await workspace.commit(runID, message: message, paths: Array(included))
                } else if let folder {
                    done = try await workspace.commit(folder: folder, message: message, paths: Array(included))
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                close()
            } catch let failure {
                error = failure.localizedDescription
            }
            working = false
        }
    }
}

/// Pull request: created via GitHub integration or on github.com directly. Always following a push, always user-initiated.
struct PullRequestSheet: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    /// A session Nook runs, or (nil) the repository root in `folder` of one it only sees.
    let runID: UUID?
    var folder: String? = nil
    /// Set when shown inside the notch: closes it there (and the notch shows the title).
    var onClose: (() -> Void)? = nil
    private var embedded: Bool { onClose != nil }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = ""
    @State private var draft = false
    @State private var repo: RemoteRepository?
    @State private var branch: String?
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var created: URL?
    /// The agent writing the title and description from the branch's commits, the template and the repository's rules.
    @State private var writing = false
    /// The repository's pull request template, to point out its sections the description leaves out.
    @State private var template: String?
    /// `@` in the description: the files of the repository and people from your chats, as plain words.
    @StateObject private var mentionModel = ComposerModel()
    private var mentionConfig: ComposerConfig { .mentions(folder: runID.flatMap { workspace.run($0)?.workingDirectory } ?? folder) }

    init(runID: UUID, onClose: (() -> Void)? = nil) {
        self.runID = runID
        self.onClose = onClose
    }

    init(folder: String, onClose: (() -> Void)? = nil) {
        self.runID = nil
        self.folder = folder
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if !embedded { Text(tr("ws.pr.title")).font(NookTheme.TextStyle.title) }
            if loading {
                PatientSpinner().frame(height: 60)
            } else if repo == nil {
                Text(tr("ws.pr.notGitHub")).font(NookTheme.TextStyle.body).foregroundStyle(WS.secondary)
            } else {
                Form {
                    LabeledContent(tr("ws.pr.repo"), value: repo?.displayName ?? "")
                    LabeledContent(tr("ws.pr.head"), value: branch ?? "—")
                    TextField(tr("ws.pr.base"), text: $base)
                    TextField(tr("ws.pr.titleField"), text: $title)
                    MentionSuggestions(model: mentionModel, text: $bodyText, config: mentionConfig)
                    TextField(tr("ws.pr.body"), text: $bodyText, axis: .vertical).lineLimit(3...8)
                        .mentions(mentionModel, text: $bodyText, config: mentionConfig)
                    Toggle(tr("ws.pr.draft"), isOn: $draft)
                        .disabled(!canCreate)
                }
                .formStyle(.grouped)
                Text(canCreate ? tr("ws.pr.viaConnector", repo?.hostName ?? "") : tr("ws.pr.viaBrowser", repo?.hostName ?? ""))
                    .font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if writing {
                BusyLine(tr("ws.quick.generatingPR"), font: NookTheme.TextStyle.detail)
            }
            if !writing, !missingSections.isEmpty {
                Text(tr("ws.pr.missingSections", missingSections.joined(separator: ", ")))
                    .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { InlineErrorText(error) }
            if let created {
                Button(tr("ws.pr.created")) { PullRequestViewer.show(created) }
                    .buttonStyle(.nookLink)
                    .font(NookTheme.TextStyle.strong)
            }
            HStack {
                Spacer()
                SmallGhostButton(title: tr("button.close")) { close() }.keyboardShortcut(.cancelAction)
                SmallPrimaryButton(title: canCreate ? tr("ws.pr.create") : tr("ws.pr.openPage", repo?.hostName ?? "")) { create() }
                    .disabled(working || repo == nil || branch == nil || base.isEmpty || title.isEmpty || created != nil)
            }
        }
        .padding(embedded ? 0 : 18)
        // In the panel it takes the width of the tab, however narrow; on its own it keeps its usual 560.
        .frame(width: embedded ? nil : 560)
        .frame(maxWidth: .infinity, alignment: embedded ? .topLeading : .center)
        .task {
            if let runID {
                let run = workspace.run(runID)
                title = run?.title ?? ""
                base = run?.baseBranch ?? ""
                let root = run?.repoRoot ?? run?.workingDirectory
                template = root.flatMap { GitService.pullRequestTemplate($0) }
                bodyText = template.map(TextGeneration.pullRequestTemplateBody) ?? (run.map { tr("ws.pr.bodyDefault", $0.task) } ?? "")
                repo = await workspace.remoteRepository(runID)
                branch = await workspace.currentBranch(runID)
                if base.isEmpty { base = await workspace.pullRequestBaseBranch(runID) ?? "" }
            } else if let folder {
                repo = await workspace.remoteRepository(folder: folder)
                branch = await workspace.currentBranch(folder: folder)
                base = await workspace.pullRequestBaseBranch(folder: folder) ?? ""
                template = GitService.pullRequestTemplate(folder)
                if let template { bodyText = TextGeneration.pullRequestTemplateBody(template) }
            }
            loading = false
            await writeDraft()
        }
    }

    /// The agent writes the title and description as the git button does: in English, filled in along the repository's
    /// template and its rules for pull requests. What you typed in the meantime stays.
    private func writeDraft() async {
        guard repo != nil, branch != nil else { return }
        let startTitle = title, startBody = bodyText
        writing = true
        defer { writing = false }
        let written: WorkspaceManager.PullRequestDraft?
        if let runID {
            written = await workspace.draftPullRequest(runID)
        } else if let folder {
            written = await workspace.draftPullRequest(folder: folder)
        } else {
            written = nil
        }
        // Already sent (you did not wait for it): the text of the pull request stays as it went out.
        guard let written, created == nil, !working else { return }
        if title == startTitle, !written.title.isEmpty { title = written.title }
        if bodyText == startBody, !written.body.isEmpty { bodyText = written.body }
        if base.isEmpty { base = written.base }
    }

    /// The template's headings the description leaves out.
    private var missingSections: [String] {
        TextGeneration.missingTemplateHeadings(body: bodyText, template: template)
            .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
    }

    private var canCreate: Bool { repo.map(SourceForge.canCreate) ?? false }

    private func create() {
        guard let repo, let branch else { return }
        let cleanBase = base.hasPrefix("origin/") ? String(base.dropFirst(7)) : base
        guard SourceForge.canCreate(repo) else {
            if let url = SourceForge.newRequestPage(repo: repo, base: cleanBase, head: branch, title: title, body: bodyText, draft: draft) { BrowserStore.show(url) }
            close()
            return
        }
        working = true
        error = nil
        Task {
            do {
                let link = try await SourceForge.create(repo: repo, title: title, body: bodyText, head: branch, base: cleanBase, draft: draft)
                created = link
                PullRequestViewer.show(link)
            } catch let failure {
                // Neither of GitHub's APIs took it (a rate limit on both): its page in Nook's browser still does.
                if ConnectorErrorKind.classify(failure) == .rateLimited,
                   let url = SourceForge.newRequestPage(repo: repo, base: cleanBase, head: branch, title: title, body: bodyText, draft: draft) {
                    BrowserStore.show(url)
                    close()
                } else {
                    error = failure.localizedDescription + " " + tr("ws.pr.pushFirst")
                }
            }
            working = false
        }
    }
}

/// The diffs last shown, by session or folder and file, so going back to a file shows its diff at once while git reads
/// it again behind it. Small: diffs can be long, and only the ones you flip between matter.
@MainActor
enum DiffCache {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 40
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    static func diff(_ key: String) -> String? { cache.object(forKey: key as NSString) as String? }

    /// Forgets every diff: after a hunk was staged or discarded, the next read must come from git.
    static func clear() { cache.removeAllObjects() }

    static func store(_ diff: String, _ key: String) {
        cache.setObject(diff as NSString, forKey: key as NSString, cost: diff.utf8.count)
    }
}
