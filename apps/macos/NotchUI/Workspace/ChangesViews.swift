import SwiftUI

/// Review changes, laid out(`StackedDiffList`): a toolbar, then every changed file in one
/// scroll, folded until you open it; the file you came for opens at once. Hovering a line offers a comment for the agent;
/// the comments go to it together from the bar at the bottom.
struct ChangesSheet: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    let initialFile: GitFileChange?
    /// Set when shown inside the notch: closes it there (and the notch shows the title).
    var onClose: (() -> Void)? = nil
    /// Kept for the side panel's call; the stacked list fits a narrow panel and a wide one alike.
    var stacked = false
    private var embedded: Bool { onClose != nil }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @State private var expanded: Set<String> = []
    @State private var showsTree = false

    private var files: [GitFileChange] { workspace.git[runID]?.status?.files ?? [] }

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
                StackedDiffToolbar(files: files, expanded: $expanded, showsTree: $showsTree)
                if !embedded {
                    Button(tr("button.close")) { close() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, embedded ? NookTheme.Spacing.sm : 14)
            .frame(height: embedded ? 36 : 48)
            NookDivider()
            if files.isEmpty {
                StackedDiffNote(text: tr("ws.changes.noDiffDetail"))
            } else {
                StackedDiffList(files: files, scope: runID.uuidString, expanded: $expanded, showsTree: showsTree,
                                focus: initialFile?.path) { file in
                    guard let change = self.files.first(where: { $0.path == file.path }) else { return "" }
                    return try await workspace.diff(runID, file: change)
                } content: { file, text in
                    DiffText(text: text, comments: (workspace.reviewComments[runID] ?? []).filter { $0.path == file.path },
                             onComment: { line, code, comment in
                                 workspace.addReviewComment(runID, ReviewComment(path: file.path, line: line, code: code, text: comment))
                             },
                             onRemoveComment: { workspace.removeReviewComment(runID, $0) }, stacked: true, path: file.path)
                        .sessionFileMenu(workspace, runID: runID, path: file.path)
                }
            }
            // Comments on the diff go to the agent together.
            if let comments = workspace.reviewComments[runID], !comments.isEmpty {
                NookDivider()
                HStack(spacing: NookTheme.Spacing.md) {
                    Image(systemName: "text.bubble").foregroundStyle(NookTheme.amber)
                    Text(tr("ws.review.count", comments.count))
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer()
                    SmallGhostButton(title: tr("ws.review.discard")) { workspace.reviewComments[runID] = nil }
                    NookPrimaryButton(title: tr("ws.review.send")) {
                        workspace.sendReviewComments(runID)
                        close()
                    }
                }
                .padding(10)
            }
        }
        .frame(minWidth: embedded ? nil : 820, idealWidth: embedded ? nil : 1040, maxWidth: embedded ? CGFloat.infinity : nil,
               minHeight: embedded ? nil : 520, idealHeight: embedded ? nil : 700, maxHeight: embedded ? CGFloat.infinity : nil)
        .background(embedded ? Color.clear : WS.background)
        .onAppear { workspace.markReviewed(runID) }
    }
}

/// Commit: review staged changes before writing the commit message.
struct CommitSheet: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    /// Set when shown inside the notch: closes it there (and the notch shows the title).
    var onClose: (() -> Void)? = nil
    private var embedded: Bool { onClose != nil }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @State private var message = ""
    @State private var included: Set<String> = []
    @State private var working = false
    @State private var error: String?
    @State private var done: String?
    /// `@` in the message: the files of the repository and people from your chats, as plain words.
    @StateObject private var mentionModel = ComposerModel()
    private var mentionConfig: ComposerConfig { .mentions(folder: workspace.run(runID)?.workingDirectory) }

    private var files: [GitFileChange] { workspace.git[runID]?.status?.files ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if !embedded { Text(tr("ws.commit.title")).font(NookTheme.TextStyle.title) }
            if let run = workspace.run(runID) {
                Text(tr("ws.commit.where", run.branch ?? "HEAD", AgentPathFormat.tilde(run.workingDirectory)))
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
                    .sessionFileMenu(workspace, runID: runID, path: file.path)
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
            if let run = workspace.run(runID), message.isEmpty {
                Button(tr("ws.commit.useTitle")) { message = run.title }
                    .buttonStyle(.link)
                    .font(NookTheme.TextStyle.detail)
            }
            if let error { Text(error).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coralSoft) }
            if let done { Text(tr("ws.commit.done", done)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.mint) }
            HStack {
                Text(tr("ws.commit.note")).font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
                Spacer()
                SmallGhostButton(title: tr("button.cancel")) { close() }.keyboardShortcut(.cancelAction)
                SmallPrimaryButton(title: tr("ws.commit.action", included.count)) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || included.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || done != nil)
            }
        }
        .padding(embedded ? 0 : 18)
        .frame(width: 560)
        .frame(maxWidth: .infinity, alignment: embedded ? .topLeading : .center)
        .onAppear { included = Set(files.map(\.path)) }
    }

    private func commit() {
        working = true
        error = nil
        Task {
            do {
                done = try await workspace.commit(runID, message: message, paths: Array(included))
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
    let runID: UUID
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
    /// `@` in the description: the files of the repository and people from your chats, as plain words.
    @StateObject private var mentionModel = ComposerModel()
    private var mentionConfig: ComposerConfig { .mentions(folder: workspace.run(runID)?.workingDirectory) }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if !embedded { Text(tr("ws.pr.title")).font(NookTheme.TextStyle.title) }
            if loading {
                ProgressView()
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
            if let error { Text(error).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coralSoft) }
            if let created {
                Button(tr("ws.pr.created")) { BrowserStore.show(created) }
                    .buttonStyle(.link)
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
        .frame(width: 560)
        .frame(maxWidth: .infinity, alignment: embedded ? .topLeading : .center)
        .task {
            let run = workspace.run(runID)
            title = run?.title ?? ""
            base = run?.baseBranch ?? ""
            bodyText = run.map { tr("ws.pr.bodyDefault", $0.task) } ?? ""
            repo = await workspace.remoteRepository(runID)
            branch = await workspace.currentBranch(runID)
            if base.isEmpty { base = await workspace.pullRequestBaseBranch(runID) ?? "" }
            loading = false
        }
    }

    private var canCreate: Bool { repo.map(SourceForge.canCreate) ?? false }

    private func create() {
        guard let repo, let branch else { return }
        let cleanBase = base.hasPrefix("origin/") ? String(base.dropFirst(7)) : base
        guard SourceForge.canCreate(repo) else {
            if let url = SourceForge.newRequestPage(repo: repo, base: cleanBase, head: branch, title: title, body: bodyText, draft: draft) { NSWorkspace.shared.open(url) }
            close()
            return
        }
        working = true
        error = nil
        Task {
            do {
                created = try await SourceForge.create(repo: repo, title: title, body: bodyText, head: branch, base: cleanBase, draft: draft)
            } catch let failure {
                error = failure.localizedDescription + " " + tr("ws.pr.pushFirst")
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

    static func store(_ diff: String, _ key: String) {
        cache.setObject(diff as NSString, forKey: key as NSString, cost: diff.utf8.count)
    }
}
