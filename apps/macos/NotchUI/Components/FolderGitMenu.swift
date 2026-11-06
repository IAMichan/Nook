import SwiftUI
import AppKit

/// Git as seen from the folder a session works in, for any session: one Nook runs, one in a terminal, or an earlier
/// one. Reads the branch, the changes and what is not pushed yet, and and switches branches on request.
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

    /// What only changes when refs move (the root, branches, remotes, the base and where the branch left it). Reused
    /// between refreshes while the branch, its upstream, its commits and ahead/behind stay the same, for at most
    /// `refsMaxAge`: a refresh then starts four git processes (the commits, status and the diffs) instead of about ten.
    /// The commits are in the key because a merge moves the split point without changing ahead/behind once it is pushed.
    private struct Refs: Sendable {
        var root: String
        var key: String
        var at: Date
        var branches: [String]
        var remotes: [String]
        var base: String?
        var comparedTo: String?
    }
    private var refs: Refs?
    private static let refsMaxAge: TimeInterval = 60

    /// What the last model of a folder read, so a session you switch back to shows its branch, changes and panel at
    /// once (and takes the same height) while the refresh brings it up to date, instead of filling in row by row.
    private struct Snapshot: Sendable {
        var root: String?
        var status: GitStatus?
        var branches: [String]
        var remotes: [String]
        var base: String?
        var changes: [GitFileChange]
        var comparedTo: String?
        var refs: Refs?
    }
    private static let snapshots = SnapshotStore()

    /// Locked rather than main-actor bound, so the cache itself can be read from any thread.
    private final class SnapshotStore: @unchecked Sendable {
        private let lock = NSLock()
        private var byDirectory: [String: Snapshot] = [:]
        private var order: [String] = []
        private let limit = 24

        func get(_ directory: String) -> Snapshot? {
            lock.lock(); defer { lock.unlock() }
            return byDirectory[directory]
        }

        func set(_ snapshot: Snapshot, for directory: String) {
            lock.lock(); defer { lock.unlock() }
            byDirectory[directory] = snapshot
            order.removeAll { $0 == directory }
            order.append(directory)
            while order.count > limit { byDirectory[order.removeFirst()] = nil }
        }
    }

    /// The refresh under way: the session panel and the branch button ask together as a session opens, and share it.
    private var refreshing: Task<Void, Never>?

    /// For a view's `StateObject`: SwiftUI makes it on the main thread, from an autoclosure the compiler does not see as
    /// main-actor bound.
    nonisolated static func make(directory: String) -> FolderGitModel {
        MainActor.assumeIsolated { FolderGitModel(directory: directory) }
    }

    init(directory: String) {
        self.directory = directory
        if let known = Self.snapshots.get(directory) {
            _root = Published(initialValue: known.root)
            _status = Published(initialValue: known.status)
            _branches = Published(initialValue: known.branches)
            _remotes = Published(initialValue: known.remotes)
            _base = Published(initialValue: known.base)
            _changes = Published(initialValue: known.changes)
            comparedTo = known.comparedTo
            refs = known.refs
        }
    }

    var isRepository: Bool { root != nil && status != nil }
    /// What is not committed yet.
    var files: [GitFileChange] { status?.files ?? [] }
    var added: Int { changes.compactMap(\.added).reduce(0, +) }
    var removed: Int { changes.compactMap(\.removed).reduce(0, +) }

    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await read() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func read() async {
        if git == nil { git = await Task.detached(priority: .utility) { GitService.shared }.value }
        guard let git, !directory.isEmpty, FileManager.default.fileExists(atPath: directory) else {
            root = nil
            status = nil
            changes = []
            return
        }
        let directory = directory
        let cached = refs.flatMap { Date().timeIntervalSince($0.at) < Self.refsMaxAge ? $0 : nil }
        let result = await Task.detached(priority: .utility) { () -> (root: String?, status: GitStatus?, branches: [String], remotes: [String], base: String?, changes: [GitFileChange], comparedTo: String?, refs: Refs?) in
            guard let root = cached?.root ?? git.repositoryRoot(for: directory) else { return (nil, nil, [], [], nil, [], nil, nil) }
            let status = try? git.status(root)
            let commits = git.headCommits(root).joined(separator: ",")
            let key = status.map { "\($0.branch ?? "")|\($0.upstream ?? "")|\($0.ahead)|\($0.behind)|\($0.detached)|\(commits)" } ?? ""
            let refs: Refs
            if let cached, cached.root == root, cached.key == key, status != nil {
                refs = cached
            } else {
                let local = (try? git.branches(root))?.local ?? []
                let remotes = git.remotes(root)
                let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
                let base = git.defaultBranch(root, remote: remote).map { git.comparisonBase(root, base: $0, remote: remote) }
                // Against where the branch left its base (else its upstream), so committed and merged work still counts.
                let comparedTo = status.flatMap { status in
                    [base, status.upstream].compactMap { $0 }.lazy.compactMap { git.branchPoint(root, base: $0) }.first
                }
                refs = Refs(root: root, key: key, at: Date(), branches: local, remotes: remotes, base: base, comparedTo: comparedTo)
            }
            let changes = refs.comparedTo.flatMap { ref in status.flatMap { try? git.changes(root, since: ref, status: $0) } }
            return (root, status, refs.branches, refs.remotes, refs.base, changes ?? status?.files ?? [], changes == nil ? nil : refs.comparedTo,
                    status == nil ? nil : refs)
        }.value
        refs = result.refs
        if root != result.root { root = result.root }
        if status != result.status { status = result.status }
        let sorted = result.branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if branches != sorted { branches = sorted }
        if remotes != result.remotes { remotes = result.remotes }
        if base != result.base { base = result.base }
        if changes != result.changes { changes = result.changes }
        comparedTo = result.comparedTo
        Self.snapshots.set(Snapshot(root: root, status: status, branches: branches, remotes: remotes, base: base,
                                    changes: changes, comparedTo: comparedTo, refs: refs), for: directory)
    }

    func checkout(_ branch: String) {
        guard let git, let root, !working, branch != status?.branch else { return }
        perform(done: tr("ws.git.checkedOut", branch), failed: tr("ws.git.checkoutFailed", branch)) {
            try git.checkout(root, branch: branch)
        }
    }

    func diff(_ file: GitFileChange, options: DiffReadOptions = .standard) async throws -> String {
        guard let git, let root else { throw GitError(tr("ws.error.noGit")) }
        let ref = file.kind == .untracked ? nil : comparedTo
        return try await Task.detached(priority: .userInitiated) {
            guard let ref else { return try git.diff(root, file: file, ignoreWhitespace: options.ignoreWhitespace) }
            return try git.diff(root, path: file.path, from: ref, to: nil, ignoreWhitespace: options.ignoreWhitespace)
        }.value
    }

    /// Runs a git action off the main thread and reports how it went as a toast; a failure also marks the button.
    private func perform(done: String, failed: String, _ action: @escaping @Sendable () throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try action() }.value
                ToastCenter.shared.success(done)
            } catch let failure {
                error = failure.localizedDescription
                ToastCenter.shared.error(failure, title: failed)
            }
            working = false
            // A checkout or push moves refs: read them again.
            refs = nil
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
    /// With room beside the conversation the session panel stays open on the right (`DockedSessionPanel`); this
    /// button, which opens it as a popover, steps aside.
    @Environment(\.sessionPanelDocked) private var docked

    init(directory: String, runID: UUID? = nil, agentWorking: Bool, showChanges: @escaping () -> Void, onChange: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: FolderGitModel.make(directory: directory))
        self.runID = runID
        self.agentWorking = agentWorking
        self.showChanges = showChanges
        self.onChange = onChange
    }

    var body: some View {
        Group {
            if !model.directory.isEmpty, !docked {
                HStack(spacing: 0) {
                    Button { open.toggle() } label: {
                        if model.isRepository {
                            label(icon: "arrow.triangle.branch", text: model.status?.branch ?? tr("agents.git.detached"))
                        } else {
                            label(icon: "folder", text: URL(fileURLWithPath: model.directory).lastPathComponent)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(model.error ?? (model.root.map(AgentPathFormat.tilde) ?? AgentPathFormat.tilde(model.directory)))
                    .popover(isPresented: $open, arrowEdge: .bottom) {
                        SessionPanel(model: model, runID: runID, agentWorking: agentWorking, showChanges: showChanges) { open = false }
                    }
                    // The counts open the changes themselves.
                    if model.isRepository, !model.changes.isEmpty {
                        ToolbarGroupDivider()
                        Button(action: showChanges) {
                            HStack(spacing: NookTheme.Spacing.sm) {
                                // Neutral counts in the header; the diff itself keeps its colors.
                                Text("+\(model.added)").foregroundStyle(NookTheme.textTertiary)
                                Text("−\(model.removed)").foregroundStyle(NookTheme.textTertiary)
                            }
                            .font(NookTheme.TextStyle.label)
                            .padding(.horizontal, NookTheme.Spacing.sm)
                            .frame(height: ToolbarGroup.itemHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tr("agents.git.changes", model.changes.count))
                        .fixedSize()
                    }
                }
                .toolbarGroup()
            }
        }
        .task(id: "\(model.directory)|\(docked)") {
            while !Task.isCancelled, !docked {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        .onChange(of: model.working) { _, working in
            if !working { onChange?() }
        }
    }

    private func label(icon: String, text: String) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if model.working {
                ProgressView().controlSize(.mini)
            } else if model.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(NookTheme.font(10)).foregroundStyle(NookTheme.coral)
            } else {
                Image(systemName: icon).font(NookTheme.font(10, .medium))
            }
            // The branch truncates when a wide side panel leaves the header little room, instead of the button
            // keeping its width and running on under the panel.
            Text(text).lineLimit(1).truncationMode(.middle).frame(minWidth: 0, maxWidth: 150, alignment: .leading)
            Image(systemName: "chevron.down").font(NookTheme.font(7.5, .bold)).opacity(0.5)
        }
        .font(NookTheme.TextStyle.label)
        .foregroundStyle(NookTheme.textSecondary)
        .padding(.horizontal, 7)
        .frame(height: ToolbarGroup.itemHeight)
        .contentShape(Rectangle())
    }
}

extension EnvironmentValues {
    /// The session panel is docked beside the conversation, so the header's branch button is not needed.
    @Entry var sessionPanelDocked = false
}

/// The session panel as a card beside the conversation, as tall as what it holds, for a window with room for it, until
/// you close it. It is the same panel the branch button opens as a popover when the window is narrower or it is closed.
struct DockedSessionPanel: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @StateObject private var model: FolderGitModel
    let runID: UUID?
    let agentWorking: Bool
    let showChanges: () -> Void

    init(directory: String, runID: UUID?, agentWorking: Bool, showChanges: @escaping () -> Void) {
        _model = StateObject(wrappedValue: FolderGitModel.make(directory: directory))
        self.runID = runID
        self.agentWorking = agentWorking
        self.showChanges = showChanges
    }

    var body: some View {
        ScrollView {
            SessionPanel(model: model, runID: runID, agentWorking: agentWorking, showChanges: showChanges, close: {}, docked: true)
                .cardBackground(NookTheme.field, stroke: NookTheme.border, radius: NookTheme.Radius.conversationCard, style: .continuous)
                // The scroll view would cut off the card's outline.
                .padding(.vertical, NookTheme.Spacing.xxs)
                .padding(.trailing, NookTheme.Spacing.sm)
        }
        .scrollIndicators(.never)
        .task(id: model.directory) {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        .onChange(of: model.working) { _, working in
            if !working, let runID { workspace.refreshGit(runID) }
        }
    }
}

/// The changes in a folder, laid out as a stacked diff (`StackedDiffList`): a toolbar with the number of files,
/// the lines and the buttons that fold every file or show the tree, then every file in one scroll, folded until you
/// open it.
struct FolderChangesSheet: View {
    @StateObject private var model: FolderGitModel
    @State private var expanded: Set<String> = []
    @State private var showsTree = false
    @State private var loaded = false

    init(directory: String) {
        _model = StateObject(wrappedValue: FolderGitModel.make(directory: directory))
    }

    var body: some View {
        let files = model.changes.map(StackedDiffFile.init)
        VStack(spacing: 0) {
            SidePanelToolbar {
                Text(tr("agents.turn.changedFiles", files.count))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.sm)
                ToolbarIconButton("arrow.clockwise", tr("agents.pulls.refresh")) { Task { await model.refresh() } }
                StackedDiffToolbar(files: files, expanded: $expanded, showsTree: $showsTree)
            }
            if files.isEmpty {
                StackedDiffNote(text: loaded ? tr("agents.git.noChanges") : tr("ws.timeline.working"))
            } else {
                StackedDiffList(files: files, scope: model.directory, expanded: $expanded, showsTree: showsTree) { file, options in
                    guard let change = model.changes.first(where: { $0.path == file.path }) else { return "" }
                    return try await model.diff(change, options: options)
                }
            }
        }
        .task {
            await model.refresh()
            loaded = true
        }
    }
}
