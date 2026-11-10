import SwiftUI

/// Which changes the diff panel next to a conversation shows: one turn (or every turn, `all`), or what git knows about
/// the folder (what is not committed, the branch against its base, one commit), and in it one file or all.
struct TurnDiffSelection: Equatable {
    static let all = "all"
    static let uncommitted = "git:uncommitted"
    static let branch = "git:branch"
    static let commitPrefix = "git:commit:"

    /// A turn's id (TurnDiff.id), `all`, or one of the git choices above.
    var turn: String
    /// A file's path relative to the session's folder; nil for every file of the turn.
    var file: String? = nil

    enum Source: Equatable {
        case turns
        case turn(String)
        case uncommitted
        case branch
        case commit(String)

        var isGit: Bool {
            switch self {
            case .uncommitted, .branch, .commit: return true
            case .turns, .turn: return false
            }
        }
    }

    var source: Source {
        if turn == Self.all { return .turns }
        if turn == Self.uncommitted { return .uncommitted }
        if turn == Self.branch { return .branch }
        if turn.hasPrefix(Self.commitPrefix) { return .commit(String(turn.dropFirst(Self.commitPrefix.count))) }
        return .turn(turn)
    }

    static func commit(_ id: String) -> TurnDiffSelection { TurnDiffSelection(turn: commitPrefix + id) }
}

/// Calls `changed` when git's view of a session Nook runs changes. Apart from the panel, which then does not redraw with
/// every change to every session.
private struct RunGitWatcher: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    let changed: () -> Void

    var body: some View {
        Color.clear.onChange(of: workspace.git[runID]?.status?.files ?? []) { _, _ in changed() }
    }
}

/// Under the answer of a turn that changed files (the changed-files card): "3 changed files +12 −4", the files
/// as a folder tree with what each got, and "Open diff". A click on a file opens its diff in the side panel.
struct TurnChangesCard: View {
    let turn: TurnDiff
    let directory: String?
    let open: (_ file: String?) -> Void
    /// Folders you opened; every folder starts closed, so a big turn stays one short list.
    @State private var opened: Set<String> = []
    @State private var folded = false

    var body: some View {
        let tree = turn.tree(relativeTo: directory)
        VStack(alignment: .leading, spacing: 0) {
            header(tree)
            if !folded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.flatten(expanded: opened)) { row in
                        TurnChangesRow(row: row, open: opened.contains(row.path)) {
                            if row.isDirectory {
                                withAnimation(NookTheme.reveal) {
                                    if opened.contains(row.path) { opened.remove(row.path) } else { opened.insert(row.path) }
                                }
                            } else {
                                open(row.path)
                            }
                        }
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.sm)
                .padding(.bottom, NookTheme.Spacing.sm)
            }
        }
        .roundedBackground(NookTheme.well, radius: NookTheme.Radius.control)
    }

    private func header(_ tree: ChangedFilesTree) -> some View {
        let all = tree.expandAll
        let allOpen = !all.isEmpty && all.isSubset(of: opened)
        return HStack(spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.reveal) { folded.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: "chevron.right")
                        .font(NookTheme.font(9, .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    Text(tr("agents.turn.changedFiles", turn.files.count))
                        .foregroundStyle(NookTheme.paper)
                    EditLinesLabel(lines: turn.lines, size: 11)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: NookTheme.Spacing.sm)
            if !all.isEmpty {
                ToolbarIconButton(allOpen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  tr(allOpen ? "agents.turn.collapseFolders" : "agents.turn.expandFolders"), height: 20, width: 20) {
                    withAnimation(NookTheme.reveal) { opened = allOpen ? [] : all }
                }
            }
            Button { open(nil) } label: {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(icon: "plusminus")
                    Text(tr("agents.turn.openDiff"))
                }
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("agents.turn.openDiff"))
        }
        .font(NookTheme.TextStyle.label)
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
    }
}

/// One folder or file of a changed-files tree: indented by its depth, the folder's or file's lines on the right.
private struct TurnChangesRow: View {
    let row: ChangedFilesTree.Row
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if row.isDirectory {
                    Image(icon: "chevron.right")
                        .font(NookTheme.font(8, .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Image(icon: "folder").font(NookTheme.font(10.5))
                } else {
                    Color.clear.frame(width: 10, height: 1)
                    Image(icon: row.kind == .added ? "doc.badge.plus" : "doc.text").font(NookTheme.font(10.5))
                }
                Text(row.name)
                    .font(NookTheme.mono(row.isDirectory ? 11 : 11.5))
                    .foregroundStyle(row.isDirectory ? NookTheme.textTertiary : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: NookTheme.Spacing.sm)
                if row.stats.hasNumbers {
                    EditLinesLabel(lines: EditLines(added: row.stats.added, removed: row.stats.removed), size: 10)
                }
            }
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.leading, NookTheme.Spacing.sm + CGFloat(row.depth) * 14)
            .padding(.trailing, NookTheme.Spacing.sm)
            .frame(height: 28)
            .roundedBackground(hovering ? NookTheme.rowHover : Color.clear, radius: NookTheme.Radius.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.isDirectory ? row.path : tr("agents.turn.showFile", row.path))
    }
}

/// A session's one diff, the Changes tab of its panels: pick what the branch changed, what is not committed, one of the
/// newest commits, a turn or the whole session; then every file of that choice in one scroll under sticky headers
/// (`StackedDiffList`), folded until you open one. A file picked in a turn's changed-files card opens and scrolls into
/// view. The turns are made from the agent's own edits, so they show what each turn did, also for a session whose folder
/// is not on this Mac. In a session Nook runs, hovering a line offers a comment for the agent, whatever the choice.
struct TurnDiffPanel: View {
    let turns: [TurnDiff]
    @Binding var selection: TurnDiffSelection
    let directory: String?
    /// A session Nook runs: its lines take comments for the agent, and the panel follows its git state.
    var runID: UUID? = nil
    /// Reads the real diff of these files in this turn (a session Nook runs: from its git snapshots); nil, or when it
    /// fails, the diff made from the agent's edits shows.
    var load: ((TurnDiff, [TurnDiff.File], DiffReadOptions) async throws -> String)? = nil
    @AppStorage("nook.agents.diffFiles") private var showFiles = false
    @State private var expanded: Set<String> = []
    /// What git knows about the folder; read when the panel opens, nothing for a folder that is not on this Mac.
    @StateObject private var git: GitDiffSources

    init(turns: [TurnDiff], selection: Binding<TurnDiffSelection>, directory: String?, runID: UUID? = nil,
         load: ((TurnDiff, [TurnDiff.File], DiffReadOptions) async throws -> String)? = nil) {
        self.turns = turns
        _selection = selection
        self.directory = directory
        self.runID = runID
        self.load = load
        _git = StateObject(wrappedValue: GitDiffSources.make(directory: directory ?? ""))
    }

    /// The whole session's diff for the turns it was made from: merging every turn's edits is not done again for each
    /// redraw of the panel while the agent streams.
    private final class SessionMemo {
        var turns: [TurnDiff]?
        var value = TurnDiff.session([])
    }
    @State private var sessionMemo = SessionMemo()

    private var current: TurnDiff {
        if selection.turn == TurnDiffSelection.all {
            if sessionMemo.turns != turns {
                sessionMemo.value = TurnDiff.session(turns)
                sessionMemo.turns = turns
            }
            return sessionMemo.value
        }
        return turns.first { $0.id == selection.turn } ?? turns.last ?? TurnDiff.session([])
    }

    var body: some View {
        let source = selection.source
        let current = current
        let changes = source.isGit ? git.files(selection) : nil
        let files = changes.map { $0.map(StackedDiffFile.init) } ?? (source.isGit ? [] : current.files.map { file in
            StackedDiffFile(path: TurnDiff.relative(file.path, to: directory),
                            kind: file.patches.first?.hasPrefix("@@ -0,0") == true ? .added : .modified,
                            additions: file.lines.added, deletions: file.lines.removed)
        })
        VStack(alignment: .leading, spacing: 0) {
            toolbar(current, files: files)
            if files.isEmpty {
                StackedDiffNote(text: source.isGit && (changes == nil || !git.loaded) ? tr("ws.timeline.working") : tr("agents.diff.none"))
            } else {
                let read: (StackedDiffFile, DiffReadOptions) async throws -> String = { file, options in
                    if source.isGit {
                        guard let change = changes?.first(where: { $0.path == file.path }) else { return "" }
                        return try await git.diff(selection, file: change, options: options)
                    }
                    guard let source = current.file(file.path, relativeTo: directory) else { return "" }
                    // The agent's own edits: git cannot leave out their whitespace, so their hunks that only change it go.
                    let made = TurnDiff.diff([source])
                    let fallback = options.ignoreWhitespace ? UnifiedDiffFilter.droppingWhitespaceOnlyHunks(made) : made
                    guard let load else { return fallback }
                    let loaded = (try? await load(current, [source], options)) ?? ""
                    return loaded.isEmpty ? fallback : loaded
                }
                // The cache of read diffs is shared: two worktrees of one repository have the same paths.
                let scope = (runID?.uuidString ?? directory ?? "") + "|turn|" + selection.turn
                // Git's paths start at the repository, a file step's at the session's folder, which may lie deeper.
                let focus = selection.file.map { file in
                    files.first { $0.path == file || $0.path.hasSuffix("/" + file) }?.path ?? file
                }
                if let runID {
                    RunDiffList(runID: runID, files: files, scope: scope, expanded: $expanded, showsTree: showFiles,
                                focus: focus, diff: read)
                        .id(selection.turn)
                } else {
                    StackedDiffList(files: files, scope: scope, expanded: $expanded, showsTree: showFiles,
                                    focus: focus, diff: read)
                        .id(selection.turn)
                }
            }
            // Under the list, also when the choice shows no files: comments you made stay yours to send.
            if let runID { ReviewCommentsBar(runID: runID) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let file = selection.file { expanded = [file] } }
        .onChange(of: selection.turn) { _, _ in expanded = selection.file.map { [$0] } ?? [] }
        // Git is read when the panel opens and again when one of its choices is picked; never while it sits idle.
        .task(id: directory) {
            await git.refresh()
            fallBackFromGit()
        }
        // A session Nook runs: what the agent wrote or committed shows without asking.
        .background { if let runID { RunGitWatcher(runID: runID) { Task { await git.refresh() } } } }
        .task(id: selection.turn) {
            switch selection.source {
            case .commit(let id): await git.loadCommit(id)
            case .uncommitted, .branch: await git.refresh()
            case .turns, .turn: break
            }
            fallBackFromGit()
        }
    }

    /// Not a git folder (or not on this Mac): the agent's turns are what there is to show, with the file you came for.
    private func fallBackFromGit() {
        guard selection.source.isGit, git.loaded, !git.isRepository else { return }
        selection = TurnDiffSelection(turn: TurnDiffSelection.all, file: selection.file)
    }

    /// The tab's bar (`SidePanelToolbar`): what to show and how many files it changed, then read git again and the
    /// buttons that fold every file or show the tree.
    private func toolbar(_ current: TurnDiff, files: [StackedDiffFile]) -> some View {
        SidePanelToolbar {
            ComposerDropdown(width: 300) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text(title(of: selection, current: current))
                        .lineLimit(1)
                    Image(icon: "chevron.down").font(NookTheme.font(9, .bold)).opacity(0.7)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .padding(.horizontal, NookTheme.Spacing.sm)
                .frame(height: 24)
                .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
                .contentShape(Rectangle())
            } content: {
                DropdownList(maxHeight: 420) {
                    // What most often is the question comes first: what this branch changed.
                    if git.isRepository {
                        gitRows
                        if !turns.isEmpty { DropdownDivider() }
                    }
                    if !turns.isEmpty {
                        DropdownRow(title: tr("agents.diff.allTurns"), chosen: selection.turn == TurnDiffSelection.all) {
                            selection = TurnDiffSelection(turn: TurnDiffSelection.all)
                        }
                        ForEach(turns.reversed()) { turn in
                            DropdownRow(title: title(turn), trailing: "+\(turn.lines.added) −\(turn.lines.removed)",
                                        chosen: selection.turn == turn.id) {
                                selection = TurnDiffSelection(turn: turn.id)
                            }
                        }
                    }
                }
            }
            Text(tr("agents.turn.changedFiles", files.count))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: NookTheme.Spacing.xs)
            if git.isRepository {
                ToolbarIconButton("arrow.clockwise", tr("agents.pulls.refresh")) { Task { await git.refresh() } }
            }
            StackedDiffToolbar(files: files, expanded: $expanded, showsTree: $showFiles)
        }
    }

    /// What git knows about the folder: what is not committed, the branch, the newest commits.
    @ViewBuilder
    private var gitRows: some View {
        DropdownRow(symbol: "pencil.line", title: tr("agents.diff.uncommitted"),
                    trailing: git.folder.files.isEmpty ? nil : String(git.folder.files.count),
                    chosen: selection.turn == TurnDiffSelection.uncommitted) {
            selection = TurnDiffSelection(turn: TurnDiffSelection.uncommitted)
        }
        DropdownRow(symbol: "arrow.triangle.branch", title: branchTitle,
                    trailing: "+\(git.folder.added) −\(git.folder.removed)",
                    chosen: selection.turn == TurnDiffSelection.branch) {
            selection = TurnDiffSelection(turn: TurnDiffSelection.branch)
        }
        if !git.commits.isEmpty {
            DropdownHeader(title: tr("agents.diff.commits"))
            ForEach(git.commits) { commit in
                DropdownRow(title: commit.subject, trailing: commit.shortID,
                            chosen: selection.source == .commit(commit.id)) {
                    selection = .commit(commit.id)
                }
                .help(commit.date.map { "\(commit.author) · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? commit.author)
            }
        }
        // An older commit an agent's answer linked to.
        if let linked = git.linked, !git.commits.contains(where: { $0.id == linked.id }) {
            DropdownHeader(title: tr("sc.diff.linkedCommit"))
            DropdownRow(title: linked.subject, trailing: linked.shortID, chosen: selection.source == .commit(linked.id)) {
                selection = .commit(linked.id)
            }
        }
    }

    /// "Branch vs origin/main", or "Branch changes" when there is no base to name.
    private var branchTitle: String {
        git.folder.base.map { tr("agents.diff.branchVs", $0) } ?? tr("agents.diff.branch")
    }

    private func title(of selection: TurnDiffSelection, current: TurnDiff) -> String {
        switch selection.source {
        case .turns: return tr("agents.diff.allTurns")
        case .turn: return title(current)
        case .uncommitted: return tr("agents.diff.uncommitted")
        case .branch: return branchTitle
        case .commit(let id): return git.commit(id)?.subject ?? String(id.prefix(7))
        }
    }

    /// "Turn 3", or "Latest turn" for the last one.
    private func title(_ turn: TurnDiff) -> String {
        turn.id == turns.last?.id ? tr("agents.diff.latestTurn") : tr("agents.diff.turn", turn.number)
    }
}
