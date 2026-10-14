import SwiftUI

/// Review changes: file list on the left, diff of selected file on the right.
struct ChangesSheet: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    let initialFile: GitFileChange?
    @State private var selected: String?
    @State private var diff = ""
    @State private var loading = false
    @State private var error: String?

    private var files: [GitFileChange] { workspace.git[runID]?.status?.files ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("ws.changes.title")).font(NookTheme.font(15, .semibold))
                if let run = workspace.run(runID) {
                    Text(run.branch ?? run.projectName).font(NookTheme.mono(12)).foregroundStyle(WS.secondary)
                }
                Spacer()
                Button(tr("button.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            HSplitView {
                List(selection: $selected) {
                    ForEach(files) { file in
                        FileChangeRow(file: file).tag(file.path)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                Group {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error {
                        WSEmptyState(symbol: "exclamationmark.triangle", title: tr("ws.changes.error"), message: error)
                    } else if diff.isEmpty {
                        WSEmptyState(symbol: "doc.text.magnifyingglass", title: tr("ws.changes.noDiff"), message: tr("ws.changes.noDiffDetail"))
                    } else {
                        DiffText(text: diff)
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 520, idealHeight: 700)
        .background(WS.background)
        .preferredColorScheme(.dark)
        .onAppear {
            workspace.markReviewed(runID)
            selected = initialFile?.path ?? files.first?.path
        }
        .onChange(of: selected) { _, path in load(path) }
        .task { load(selected) }
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
    @State private var message = ""
    @State private var included: Set<String> = []
    @State private var working = false
    @State private var error: String?
    @State private var done: String?

    private var files: [GitFileChange] { workspace.git[runID]?.status?.files ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("ws.commit.title")).font(NookTheme.font(15, .semibold))
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
                .font(NookTheme.mono(12))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(WS.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(WS.border, lineWidth: 1))
            if let run = workspace.run(runID), message.isEmpty {
                Button(tr("ws.commit.useTitle")) { message = run.title }
                    .buttonStyle(.link)
                    .font(NookTheme.font(11.5))
            }
            if let error { Text(error).font(NookTheme.font(12)).foregroundStyle(NookTheme.coralSoft) }
            if let done { Text(tr("ws.commit.done", done)).font(NookTheme.font(12)).foregroundStyle(NookTheme.mint) }
            HStack {
                Text(tr("ws.commit.note")).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                Spacer()
                Button(tr("button.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("ws.commit.action", included.count)) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || included.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || done != nil)
            }
        }
        .padding(18)
        .frame(width: 560)
        .preferredColorScheme(.dark)
        .onAppear { included = Set(files.map(\.path)) }
    }

    private func commit() {
        working = true
        error = nil
        Task {
            do {
                done = try await workspace.commit(runID, message: message, paths: Array(included))
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
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
    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = ""
    @State private var draft = true
    @State private var repo: String?
    @State private var branch: String?
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var created: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("ws.pr.title")).font(NookTheme.font(15, .semibold))
            if loading {
                ProgressView()
            } else if repo == nil {
                Text(tr("ws.pr.notGitHub")).font(NookTheme.font(12.5)).foregroundStyle(WS.secondary)
            } else {
                Form {
                    LabeledContent(tr("ws.pr.repo"), value: repo ?? "")
                    LabeledContent(tr("ws.pr.head"), value: branch ?? "—")
                    TextField(tr("ws.pr.base"), text: $base)
                    TextField(tr("ws.pr.titleField"), text: $title)
                    TextField(tr("ws.pr.body"), text: $bodyText, axis: .vertical).lineLimit(3...8)
                    Toggle(tr("ws.pr.draft"), isOn: $draft)
                        .disabled(!GitHubPullRequests.isAvailable)
                }
                .formStyle(.grouped)
                Text(GitHubPullRequests.isAvailable ? tr("ws.pr.viaConnector") : tr("ws.pr.viaBrowser"))
                    .font(NookTheme.font(11.5)).foregroundStyle(WS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(NookTheme.font(12)).foregroundStyle(NookTheme.coralSoft) }
            if let created {
                Link(tr("ws.pr.created"), destination: created).font(NookTheme.font(12.5, .semibold))
            }
            HStack {
                Spacer()
                Button(tr("button.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(GitHubPullRequests.isAvailable ? tr("ws.pr.create") : tr("ws.pr.openGitHub")) { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || repo == nil || branch == nil || base.isEmpty || title.isEmpty || created != nil)
            }
        }
        .padding(18)
        .frame(width: 560)
        .preferredColorScheme(.dark)
        .task {
            let run = workspace.run(runID)
            title = run?.title ?? ""
            base = run?.baseBranch ?? ""
            bodyText = run.map { tr("ws.pr.bodyDefault", $0.task) } ?? ""
            repo = await workspace.githubRepository(runID)
            branch = await workspace.currentBranch(runID)
            loading = false
        }
    }

    private func create() {
        guard let repo, let branch else { return }
        let cleanBase = base.hasPrefix("origin/") ? String(base.dropFirst(7)) : base
        guard GitHubPullRequests.isAvailable else {
            if let url = GitHubRemote.compareURL(repo: repo, base: cleanBase, head: branch) { NSWorkspace.shared.open(url) }
            dismiss()
            return
        }
        working = true
        error = nil
        Task {
            do {
                created = try await GitHubPullRequests.create(repo: repo, title: title, body: bodyText, head: branch, base: cleanBase, draft: draft)
            } catch let failure {
                error = failure.localizedDescription + " " + tr("ws.pr.pushFirst")
            }
            working = false
        }
    }
}
