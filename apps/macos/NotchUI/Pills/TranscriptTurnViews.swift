import SwiftUI

/// Which changes the diff panel next to a conversation shows: one turn (or every turn, `all`), and in it one file or all.
struct TurnDiffSelection: Equatable {
    static let all = "all"

    /// A turn's id (TurnDiff.id), or `all`.
    var turn: String
    /// A file's path relative to the session's folder; nil for every file of the turn.
    var file: String? = nil
}

/// Under the answer of a turn that changed files (the changed-files card): "3 changed files +12 −4", the files
/// as a folder tree with what each got, and "Open diff". A click on a file opens its diff in the side panel.
struct TurnChangesCard: View {
    let turn: TurnDiff
    let directory: String?
    let open: (_ file: String?) -> Void
    /// Folders you folded shut; every folder starts open.
    @State private var closed: Set<String> = []
    @State private var folded = false

    var body: some View {
        let tree = turn.tree(relativeTo: directory)
        VStack(alignment: .leading, spacing: 0) {
            header
            if !folded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.flatten(expanded: tree.expandAll.subtracting(closed))) { row in
                        TurnChangesRow(row: row, open: !closed.contains(row.path)) {
                            if row.isDirectory {
                                withAnimation(NookTheme.reveal) {
                                    if closed.contains(row.path) { closed.remove(row.path) } else { closed.insert(row.path) }
                                }
                            } else {
                                open(row.path)
                            }
                        }
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
                .padding(.bottom, NookTheme.Spacing.xs)
            }
        }
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.field))
        .padding(.top, NookTheme.Spacing.sm)
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.reveal) { folded.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(NookTheme.font(9, .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    Text(tr("agents.turn.changedFiles", turn.files.count))
                        .foregroundStyle(NookTheme.textSecondary)
                    EditLinesLabel(lines: turn.lines, size: 11)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: NookTheme.Spacing.sm)
            Button { open(nil) } label: {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(systemName: "plusminus")
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
                    Image(systemName: "chevron.right")
                        .font(NookTheme.font(8, .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: "folder").font(NookTheme.font(10.5))
                } else {
                    Color.clear.frame(width: 10, height: 1)
                    Image(systemName: row.kind == .added ? "doc.badge.plus" : "doc.text").font(NookTheme.font(10.5))
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
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(hovering ? NookTheme.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.isDirectory ? row.path : tr("agents.turn.showFile", row.path))
    }
}

/// The diff panel next to a conversation: pick a turn or the whole session at the top, read the diff of
/// every file or of one, with the files of that choice in a column beside it. Made from the agent's own edits, so it
/// shows what each turn did, also for a session whose folder is not on this Mac.
struct TurnDiffPanel: View {
    let turns: [TurnDiff]
    @Binding var selection: TurnDiffSelection
    let directory: String?
    @Binding var wide: Bool
    /// Reads the real diff of these files in this turn (a session Nook runs: from its git snapshots); nil, or when it
    /// fails, the diff made from the agent's edits shows.
    var load: ((TurnDiff, [TurnDiff.File]) async throws -> String)? = nil
    let close: () -> Void
    @AppStorage("nook.agents.diffFiles") private var showFiles = true

    private var current: TurnDiff {
        if selection.turn == TurnDiffSelection.all { return TurnDiff.session(turns) }
        return turns.first { $0.id == selection.turn } ?? turns.last ?? TurnDiff.session([])
    }

    var body: some View {
        let current = current
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            header(current)
            ToolSurface {
                HStack(spacing: 0) {
                    diff(current).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showFiles, !current.files.isEmpty {
                        NookDivider(vertical: true)
                        files(current).frame(width: 190)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ current: TurnDiff) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: "plusminus").font(NookTheme.font(11, .semibold)).foregroundStyle(NookTheme.textTertiary)
            Menu {
                Button(tr("agents.diff.allTurns")) { selection = TurnDiffSelection(turn: TurnDiffSelection.all) }
                Divider()
                ForEach(turns.reversed()) { turn in
                    Button(title(turn) + "  +\(turn.lines.added) −\(turn.lines.removed)") {
                        selection = TurnDiffSelection(turn: turn.id)
                    }
                }
            } label: {
                Text(selection.turn == TurnDiffSelection.all ? tr("agents.diff.allTurns") : title(current))
                    .font(NookTheme.TextStyle.strong)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Text(tr("agents.turn.changedFiles", current.files.count))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            ToolbarIconButton(showFiles ? "sidebar.trailing" : "sidebar.right", tr(showFiles ? "agents.diff.hideFiles" : "agents.diff.showFiles")) {
                withAnimation(NookTheme.reveal) { showFiles.toggle() }
            }
            ToolbarIconButton(wide ? "arrow.right.to.line" : "arrow.left.to.line", tr(wide ? "ws.outputs.narrow" : "ws.outputs.widen")) {
                withAnimation(NookTheme.reveal) { wide.toggle() }
            }
            ToolbarIconButton("xmark", tr("ws.outputs.close"), close)
        }
        .frame(height: 30)
    }

    /// "Turn 3", or "Latest turn" for the last one.
    private func title(_ turn: TurnDiff) -> String {
        turn.id == turns.last?.id ? tr("agents.diff.latestTurn") : tr("agents.diff.turn", turn.number)
    }

    @ViewBuilder
    private func diff(_ current: TurnDiff) -> some View {
        if current.files.isEmpty {
            ListEmptyNote(tr("agents.diff.none"), padding: NookTheme.Spacing.xl)
        } else {
            let shown = selection.file.flatMap { current.file($0, relativeTo: directory) }.map { [$0] } ?? current.files
            let key = selection.turn + "|" + (selection.file ?? "")
            if let load {
                LoadedTurnDiff(fallback: TurnDiff.diff(shown)) { try await load(current, shown) }
                    .id(key)
            } else {
                DiffText(text: TurnDiff.diff(shown)).id(key)
            }
        }
    }

    private func files(_ current: TurnDiff) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                fileRow(name: tr("agents.diff.allFiles"), folder: "", lines: current.lines, chosen: selection.file == nil) {
                    selection.file = nil
                }
                ForEach(current.files) { file in
                    let path = TurnDiff.relative(file.path, to: directory)
                    let name = (path as NSString).lastPathComponent
                    fileRow(name: name, folder: String(path.dropLast(name.count)), lines: file.lines, chosen: selection.file == path) {
                        selection.file = path
                    }
                    .help(path)
                }
            }
            .padding(NookTheme.Spacing.xs)
        }
    }

    private func fileRow(name: String, folder: String, lines: EditLines, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text(name)
                        .font(NookTheme.mono(11.5))
                        .foregroundStyle(chosen ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    EditLinesLabel(lines: lines, size: 10)
                }
                if !folder.isEmpty {
                    Text(folder)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .padding(.vertical, NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(chosen ? NookTheme.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A diff read when it shows (from git); while it loads, or when it cannot be read, the diff from the agent's edits.
private struct LoadedTurnDiff: View {
    let fallback: String
    let load: () async throws -> String
    @State private var text: String?

    var body: some View {
        Group {
            if let text, !text.isEmpty {
                DiffText(text: text)
            } else if text == nil && fallback.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fallback.isEmpty {
                ListEmptyNote(tr("agents.diff.none"), padding: NookTheme.Spacing.xl)
            } else {
                DiffText(text: fallback)
            }
        }
        .task { text = (try? await load()) ?? "" }
    }
}
