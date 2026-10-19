import SwiftUI
import AppKit

/// Git as seen from the folder a session works in, for any session: one Nook runs, one in a terminal, or an earlier
/// one. Reads the branch, the changes and what is not pushed yet, and switches branches or pushes on request.
@MainActor
final class FolderGitModel: ObservableObject {
    @Published private(set) var status: GitStatus?
    @Published private(set) var branches: [String] = []
    @Published private(set) var remotes: [String] = []
    /// What the branch compares against: the remote's default branch ("origin/main"), else the local one.
    @Published private(set) var base: String?
    /// What the branch changed since it left `base`: commits not yet merged (pushed or not) and the working tree.
    @Published private(set) var changes: [GitFileChange] = []
    /// The commit `changes` compare against; nil when only the working tree counts.
    private var comparedTo: String?
    /// The repository root; git reports paths relative to it, so everything runs there.
    @Published private(set) var root: String?
    @Published private(set) var working = false
    @Published var error: String?

    let directory: String
    /// Resolved off the main thread in `refresh()`; creating the model must never spawn a process.
    private var git: GitService?

    nonisolated init(directory: String) {
        self.directory = directory
    }

    var isRepository: Bool { root != nil && status != nil }
    /// What is not committed yet.
    var files: [GitFileChange] { status?.files ?? [] }
    var added: Int { changes.compactMap(\.added).reduce(0, +) }
    var removed: Int { changes.compactMap(\.removed).reduce(0, +) }

    /// A branch that has commits the remote does not have yet, or no upstream at all.
    var canPush: Bool {
        guard let status, status.branch != nil, !status.detached, !remotes.isEmpty, !working else { return false }
        return status.upstream == nil || status.ahead > 0
    }

    func refresh() async {
        if git == nil { git = await Task.detached(priority: .utility) { GitService.shared }.value }
        guard let git, !directory.isEmpty, FileManager.default.fileExists(atPath: directory) else {
            root = nil
            status = nil
            changes = []
            return
        }
        let directory = directory
        let result = await Task.detached(priority: .utility) { () -> (root: String?, status: GitStatus?, branches: [String], remotes: [String], base: String?, changes: [GitFileChange], comparedTo: String?) in
            guard let root = git.repositoryRoot(for: directory) else { return (nil, nil, [], [], nil, [], nil) }
            let status = try? git.status(root)
            let local = (try? git.branches(root))?.local ?? []
            let remotes = git.remotes(root)
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            let base = git.defaultBranch(root, remote: remote).map { git.comparisonBase(root, base: $0, remote: remote) }
            // Against where the branch left its base (else its upstream), so committed work still counts as a change.
            let comparedTo = status.flatMap { status in
                [base, status.upstream].compactMap { $0 }.lazy.compactMap { git.mergeBase(root, base: $0) }.first
            }
            let changes = comparedTo.flatMap { ref in status.flatMap { try? git.changes(root, since: ref, status: $0) } }
            return (root, status, local, remotes, base, changes ?? status?.files ?? [], changes == nil ? nil : comparedTo)
        }.value
        if root != result.root { root = result.root }
        if status != result.status { status = result.status }
        let sorted = result.branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if branches != sorted { branches = sorted }
        if remotes != result.remotes { remotes = result.remotes }
        if base != result.base { base = result.base }
        if changes != result.changes { changes = result.changes }
        comparedTo = result.comparedTo
    }

    func checkout(_ branch: String) {
        guard let git, let root, !working, branch != status?.branch else { return }
        perform { try git.checkout(root, branch: branch) }
    }

    func push() {
        guard let git, let root, canPush, let branch = status?.branch else { return }
        let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
        perform { try git.push(root, remote: remote, branch: branch) }
    }

    func diff(_ file: GitFileChange) async throws -> String {
        guard let git, let root else { throw GitError(tr("ws.error.noGit")) }
        let ref = file.kind == .untracked ? nil : comparedTo
        return try await Task.detached(priority: .userInitiated) {
            guard let ref else { return try git.diff(root, file: file) }
            return try git.diff(root, path: file.path, from: ref, to: nil)
        }.value
    }

    private func perform(_ action: @escaping @Sendable () throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try action() }.value
            } catch let failure {
                error = failure.localizedDescription
            }
            working = false
            await refresh()
        }
    }
}

/// Top right in a session: the branch and what changed ("agents-cleanup +29 −12"). Opens the session panel: the
/// machine, open the folder in an app, project scripts, the base branch, the git action the branch needs, the changes.
struct FolderGitButton: View {
    @StateObject private var model: FolderGitModel
    /// A session Nook runs: its commit, push and pull request go through the workspace.
    let runID: UUID?
    /// While the agent works in this folder Nook does not switch its branch underneath it.
    let agentWorking: Bool
    /// Shows the changes; for sessions Nook runs this opens its own review, otherwise the folder's.
    let showChanges: () -> Void
    /// Called after a push or branch switch, so a session Nook runs can refresh its own view of git.
    var onChange: (() -> Void)? = nil
    @State private var open = false

    init(directory: String, runID: UUID? = nil, agentWorking: Bool, showChanges: @escaping () -> Void, onChange: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: FolderGitModel(directory: directory))
        self.runID = runID
        self.agentWorking = agentWorking
        self.showChanges = showChanges
        self.onChange = onChange
    }

    var body: some View {
        Group {
            if !model.directory.isEmpty {
                Button { open.toggle() } label: {
                    if model.isRepository {
                        label(icon: "arrow.triangle.branch", text: model.status?.branch ?? tr("agents.git.detached"), counts: true)
                    } else {
                        label(icon: "folder", text: URL(fileURLWithPath: model.directory).lastPathComponent, counts: false)
                    }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(model.error ?? (model.root.map(AgentPathFormat.tilde) ?? AgentPathFormat.tilde(model.directory)))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    SessionPanel(model: model, runID: runID, agentWorking: agentWorking, showChanges: showChanges) { open = false }
                }
            }
        }
        .task(id: model.directory) {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        .onChange(of: model.working) { _, working in
            if !working { onChange?() }
        }
    }

    private func label(icon: String, text: String, counts: Bool) -> some View {
        HStack(spacing: 6) {
            if model.working {
                ProgressView().controlSize(.mini)
            } else if model.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(NookTheme.coral)
            } else {
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
            }
            Text(text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
            if counts, !model.changes.isEmpty {
                Text("+\(model.added)").foregroundStyle(NookTheme.mint)
                Text("−\(model.removed)").foregroundStyle(NookTheme.coral)
            }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
        }
        .font(NookTheme.font(12, .medium))
        .foregroundStyle(NookTheme.textSecondary)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

/// The changes in a folder, inside the notch: files on the left, the diff of the chosen file on the right.
struct FolderChangesSheet: View {
    @StateObject private var model: FolderGitModel
    @State private var selected: String?
    @State private var diff = ""
    @State private var loading = false
    @State private var error: String?

    init(directory: String) {
        _model = StateObject(wrappedValue: FolderGitModel(directory: directory))
    }

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.changes) { file in
                        Button { selected = file.path } label: {
                            FileChangeRow(file: file)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 7).fill(selected == file.path ? NookTheme.smoke : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.changes.isEmpty {
                        Text(tr("agents.git.noChanges"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(8)
                    }
                }
            }
            .frame(width: 240)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await model.refresh()
            if selected == nil { selected = model.changes.first?.path }
        }
        .onChange(of: selected) { _, path in load(path) }
    }

    private func load(_ path: String?) {
        guard let path, let file = model.changes.first(where: { $0.path == path }) else { diff = ""; return }
        loading = true
        error = nil
        Task {
            do {
                diff = try await model.diff(file)
            } catch let failure {
                error = failure.localizedDescription
            }
            loading = false
        }
    }
}
