import SwiftUI

/// Review changes: file list on the left, diff of selected file on the right.
struct ChangesSheet: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    let initialFile: GitFileChange?
    /// Set when shown inside the notch: closes it there (and the notch shows the title).
    var onClose: (() -> Void)? = nil
    /// In a narrow side panel: the file list above the diff instead of beside it.
    var stacked = false
    private var embedded: Bool { onClose != nil }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @State private var selected: String?
    @State private var diff = ""
    @State private var loading = false
    @State private var error: String?

    private var files: [GitFileChange] { workspace.git[runID]?.status?.files ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack {
                    Text(tr("ws.changes.title")).font(NookTheme.TextStyle.title)
                    if let run = workspace.run(runID) {
                        Text(run.branch ?? run.projectName).font(NookTheme.TextStyle.code).foregroundStyle(WS.secondary)
                    }
                    Spacer()
                    Button(tr("button.close")) { close() }.keyboardShortcut(.cancelAction)
                }
                .padding(14)
                Divider()
            }
            if stacked {
                VSplitView {
                    fileList.frame(minHeight: 90, idealHeight: 160, maxHeight: 320)
                    diffView.frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                }
            } else {
                HSplitView {
                    fileList.frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                    diffView.frame(minWidth: embedded ? 360 : 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Comments on the diff go to the agent together.
            if let comments = workspace.reviewComments[runID], !comments.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble").foregroundStyle(NookTheme.amber)
                    Text(tr("ws.review.count", comments.count))
                        .font(NookTheme.font(12.5))
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
        .onAppear {
            workspace.markReviewed(runID)
            selected = initialFile?.path ?? files.first?.path
        }
        .onChange(of: selected) { _, path in load(path) }
        .task { load(selected) }
    }

    private var fileList: some View {
        List(selection: $selected) {
            ForEach(files) { file in
                FileChangeRow(file: file).tag(file.path)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(embedded ? .hidden : .automatic)
    }

    @ViewBuilder
    private var diffView: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            WSEmptyState(symbol: "exclamationmark.triangle", title: tr("ws.changes.error"), message: error)
        } else if diff.isEmpty {
            WSEmptyState(symbol: "doc.text.magnifyingglass", title: tr("ws.changes.noDiff"), message: tr("ws.changes.noDiffDetail"))
        } else {
            DiffText(text: diff, comments: (workspace.reviewComments[runID] ?? []).filter { $0.path == selected },
                     onComment: { line, code, text in
                         guard let path = selected else { return }
                         workspace.addReviewComment(runID, ReviewComment(path: path, line: line, code: code, text: text))
                     },
                     onRemoveComment: { workspace.removeReviewComment(runID, $0) })
        }
    }

    private func load(_ path: String?) {
        guard let path else { diff = ""; return }
        let file = files.first { $0.path == path } ?? initialFile.flatMap { $0.path == path ? $0 : nil }
        guard let file else { return }
        loading = true
        error = nil
        Task {
            do {
                diff = try await workspace.diff(runID, file: file)
            } catch let failure {
                error = failure.localizedDescription
            }
            loading = false
        }
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

    private var files: [GitFileChange] { workspace.git[runID]?.status?.files ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded { Text(tr("ws.commit.title")).font(NookTheme.TextStyle.title) }
            if let run = workspace.run(runID) {
                Text(tr("ws.commit.where", run.branch ?? "HEAD", AgentPathFormat.tilde(run.workingDirectory)))
                    .font(NookTheme.font(12)).foregroundStyle(WS.secondary)
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
                }
            }
            .frame(minHeight: 160, maxHeight: 260)
            .listStyle(.bordered)
            Text(tr("ws.commit.message")).font(NookTheme.font(12, .semibold))
            TextEditor(text: $message)
                .font(NookTheme.TextStyle.code)
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .cardBackground(WS.surface, stroke: WS.border, radius: 7)
            if let run = workspace.run(runID), message.isEmpty {
                Button(tr("ws.commit.useTitle")) { message = run.title }
                    .buttonStyle(.link)
                    .font(NookTheme.font(11.5))
            }
            if let error { Text(error).font(NookTheme.font(12)).foregroundStyle(NookTheme.coralSoft) }
            if let done { Text(tr("ws.commit.done", done)).font(NookTheme.font(12)).foregroundStyle(NookTheme.mint) }
            HStack {
                Text(tr("ws.commit.note")).font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
                Spacer()
                Button(tr("button.cancel")) { close() }.keyboardShortcut(.cancelAction)
                Button(tr("ws.commit.action", included.count)) { commit() }
                    .buttonStyle(.borderedProminent)
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
    @State private var draft = true
    @State private var repo: RemoteRepository?
    @State private var branch: String?
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var created: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded { Text(tr("ws.pr.title")).font(NookTheme.TextStyle.title) }
            if loading {
                ProgressView()
            } else if repo == nil {
                Text(tr("ws.pr.notGitHub")).font(NookTheme.font(12.5)).foregroundStyle(WS.secondary)
            } else {
                Form {
                    LabeledContent(tr("ws.pr.repo"), value: repo?.displayName ?? "")
                    LabeledContent(tr("ws.pr.head"), value: branch ?? "—")
                    TextField(tr("ws.pr.base"), text: $base)
                    TextField(tr("ws.pr.titleField"), text: $title)
                    TextField(tr("ws.pr.body"), text: $bodyText, axis: .vertical).lineLimit(3...8)
                    Toggle(tr("ws.pr.draft"), isOn: $draft)
                        .disabled(!canCreate)
                }
                .formStyle(.grouped)
                Text(canCreate ? tr("ws.pr.viaConnector", repo?.hostName ?? "") : tr("ws.pr.viaBrowser", repo?.hostName ?? ""))
                    .font(NookTheme.font(11.5)).foregroundStyle(WS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(NookTheme.font(12)).foregroundStyle(NookTheme.coralSoft) }
            if let created {
                Button(tr("ws.pr.created")) { BrowserStore.show(created) }
                    .buttonStyle(.link)
                    .font(NookTheme.font(12.5, .semibold))
            }
            HStack {
                Spacer()
                Button(tr("button.close")) { close() }.keyboardShortcut(.cancelAction)
                Button(canCreate ? tr("ws.pr.create") : tr("ws.pr.openPage", repo?.hostName ?? "")) { create() }
                    .buttonStyle(.borderedProminent)
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
