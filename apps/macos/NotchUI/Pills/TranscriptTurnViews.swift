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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.field))
    }

    private func header(_ tree: ChangedFilesTree) -> some View {
        let all = tree.expandAll
        let allOpen = !all.isEmpty && all.isSubset(of: opened)
        return HStack(spacing: NookTheme.Spacing.sm) {
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
            if !all.isEmpty {
                ToolbarIconButton(allOpen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  tr(allOpen ? "agents.turn.collapseFolders" : "agents.turn.expandFolders"), height: 20, width: 20) {
                    withAnimation(NookTheme.reveal) { opened = allOpen ? [] : all }
                }
            }
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
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(hovering ? NookTheme.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.isDirectory ? row.path : tr("agents.turn.showFile", row.path))
    }
}

/// The diff panel next to a conversation: pick a turn or the whole session at the top, then
/// every file of that choice in one scroll under sticky headers (`StackedDiffList`), folded until you open one; a file
/// picked in a turn's changed-files card opens and scrolls into view. Made from the agent's own edits, so it shows what
/// each turn did, also for a session whose folder is not on this Mac.
struct TurnDiffPanel: View {
    let turns: [TurnDiff]
    @Binding var selection: TurnDiffSelection
    let directory: String?
    @Binding var wide: Bool
    /// Reads the real diff of these files in this turn (a session Nook runs: from its git snapshots); nil, or when it
    /// fails, the diff made from the agent's edits shows.
    var load: ((TurnDiff, [TurnDiff.File]) async throws -> String)? = nil
    let close: () -> Void
    @AppStorage("nook.agents.diffFiles") private var showFiles = false
    @State private var expanded: Set<String> = []

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
        let current = current
        let files = current.files.map { file in
            StackedDiffFile(path: TurnDiff.relative(file.path, to: directory),
                            kind: file.patches.first?.hasPrefix("@@ -0,0") == true ? .added : .modified,
                            additions: file.lines.added, deletions: file.lines.removed)
        }
        VStack(alignment: .leading, spacing: 0) {
            header(current, files: files)
            NookDivider()
            if files.isEmpty {
                StackedDiffNote(text: tr("agents.diff.none"))
            } else {
                StackedDiffList(files: files, scope: "turn|" + selection.turn, expanded: $expanded, showsTree: showFiles,
                                focus: selection.file) { file in
                    guard let source = current.file(file.path, relativeTo: directory) else { return "" }
                    let fallback = TurnDiff.diff([source])
                    guard let load else { return fallback }
                    let loaded = (try? await load(current, [source])) ?? ""
                    return loaded.isEmpty ? fallback : loaded
                }
                .id(selection.turn)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let file = selection.file { expanded = [file] } }
        .onChange(of: selection.turn) { _, _ in expanded = selection.file.map { [$0] } ?? [] }
    }

    /// The side panel's own header (`SidePanelHeader`): the turn to show and how many files it changed.
    private func header(_ current: TurnDiff, files: [StackedDiffFile]) -> some View {
        SidePanelHeader(closeHelp: tr("ws.outputs.close"), wide: $wide, close: close) {
            ComposerDropdown(width: 240) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text(selection.turn == TurnDiffSelection.all ? tr("agents.diff.allTurns") : title(current))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(NookTheme.font(9, .bold)).opacity(0.7)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .padding(.horizontal, NookTheme.Spacing.sm)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.smoke))
                .contentShape(Rectangle())
            } content: {
                DropdownRow(title: tr("agents.diff.allTurns"), chosen: selection.turn == TurnDiffSelection.all) {
                    selection = TurnDiffSelection(turn: TurnDiffSelection.all)
                }
                DropdownDivider()
                ForEach(turns.reversed()) { turn in
                    DropdownRow(title: title(turn), trailing: "+\(turn.lines.added) −\(turn.lines.removed)",
                                chosen: selection.turn == turn.id) {
                        selection = TurnDiffSelection(turn: turn.id)
                    }
                }
            }
            Text(tr("agents.turn.changedFiles", files.count))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
        } actions: {
            StackedDiffToolbar(files: files, expanded: $expanded, showsTree: $showFiles)
        }
    }

    /// "Turn 3", or "Latest turn" for the last one.
    private func title(_ turn: TurnDiff) -> String {
        turn.id == turns.last?.id ? tr("agents.diff.latestTurn") : tr("agents.diff.turn", turn.number)
    }
}

