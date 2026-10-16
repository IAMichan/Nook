import SwiftUI
import AppKit

/// Git as seen from the folder a session works in, for any session: one Nook runs, one in a terminal, or an earlier
/// one. Reads the branch, the changes and what is not pushed yet, and switches branches or pushes on request.
@MainActor
final class FolderGitModel: ObservableObject {
    @Published private(set) var status: GitStatus?
    @Published private(set) var branches: [String] = []
    @Published private(set) var remotes: [String] = []
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
    var files: [GitFileChange] { status?.files ?? [] }
    var added: Int { files.compactMap(\.added).reduce(0, +) }
    var removed: Int { files.compactMap(\.removed).reduce(0, +) }

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
            return
        }
        let directory = directory
        let result = await Task.detached(priority: .utility) { () -> (root: String?, status: GitStatus?, branches: [String], remotes: [String]) in
            guard let root = git.repositoryRoot(for: directory) else { return (nil, nil, [], []) }
            let status = try? git.status(root)
            let local = (try? git.branches(root))?.local ?? []
            return (root, status, local, git.remotes(root))
        }.value
        if root != result.root { root = result.root }
        if status != result.status { status = result.status }
        let sorted = result.branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if branches != sorted { branches = sorted }
        if remotes != result.remotes { remotes = result.remotes }
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
        return try await Task.detached(priority: .userInitiated) { try git.diff(root, file: file) }.value
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

/// Top right in a session: the branch and what changed ("agents-cleanup +29 −12"). Opens a menu to open the folder,
/// switch branch, push, and look at the changes.
struct FolderGitButton: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: FolderGitModel
    /// While the agent works in this folder Nook does not switch its branch underneath it.
    let agentWorking: Bool
    /// Shows the changes; for sessions Nook runs this opens its own review, otherwise the folder's.
    let showChanges: () -> Void
    /// Called after a push or branch switch, so a session Nook runs can refresh its own view of git.
    var onChange: (() -> Void)? = nil

    init(directory: String, agentWorking: Bool, showChanges: @escaping () -> Void, onChange: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: FolderGitModel(directory: directory))
        self.agentWorking = agentWorking
        self.showChanges = showChanges
        self.onChange = onChange
    }

    var body: some View {
        Group {
            if model.isRepository {
                menu
            } else if !model.directory.isEmpty {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: model.directory, isDirectory: true))
                } label: {
                    label(icon: "folder", text: URL(fileURLWithPath: model.directory).lastPathComponent, counts: false)
                }
                .buttonStyle(.plain)
                .help(tr("button.openFolder"))
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

    private var menu: some View {
        Menu {
            Button(tr("agents.git.openFinder")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: model.directory, isDirectory: true))
            }
            Button(tr("button.openTerminalHere")) { app.openTerminal(in: model.directory) }
            Divider()
            Menu(model.status?.branch ?? tr("agents.git.detached")) {
                ForEach(model.branches, id: \.self) { branch in
                    Button {
                        model.checkout(branch)
                    } label: {
                        if branch == model.status?.branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                    }
                }
            }
            .disabled(agentWorking || model.working || model.branches.count < 2)
            Button(model.status.map { $0.ahead > 0 ? tr("agents.git.pushAhead", $0.ahead) : tr("agents.git.push") } ?? tr("agents.git.push")) {
                model.push()
            }
            .disabled(!model.canPush)
            Button(model.files.isEmpty ? tr("agents.git.noChanges") : tr("agents.git.changes", model.files.count)) {
                showChanges()
            }
            .disabled(model.files.isEmpty)
            if agentWorking {
                Divider()
                Text(tr("agents.git.lockedWhileWorking"))
            }
        } label: {
            label(icon: "arrow.triangle.branch", text: model.status?.branch ?? tr("agents.git.detached"), counts: true)
        }
        .composerMenu()
        .help(model.error ?? (model.root.map(AgentPathFormat.tilde) ?? ""))
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
            if counts, !model.files.isEmpty {
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
                    ForEach(model.files) { file in
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
                    if model.files.isEmpty {
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
            if selected == nil { selected = model.files.first?.path }
        }
        .onChange(of: selected) { _, path in load(path) }
    }

    private func load(_ path: String?) {
        guard let path, let file = model.files.first(where: { $0.path == path }) else { diff = ""; return }
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
