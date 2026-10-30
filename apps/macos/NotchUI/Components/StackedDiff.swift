import SwiftUI

// Changes laid out: every file in one scroll under a header that sticks while you read it,
// all of them folded at first so the panel opens as a short list of files; a click on a header unfolds its diff,
// which is read only then. The toolbar above folds or unfolds them all and shows a tree of the files beside them.

/// One changed file in a `StackedDiffList`.
struct StackedDiffFile: Identifiable, Equatable {
    let path: String
    var previousPath: String? = nil
    var kind: ChangedFilesTree.FileStat.Kind = .modified
    /// Nil when the host did not count them (a binary file).
    var additions: Int? = nil
    var deletions: Int? = nil
    var id: String { path }

    /// The chevron's color says what happened to the file: added, removed, or changed.
    var tint: Color {
        switch kind {
        case .added: return NookTheme.mint
        case .deleted: return NookTheme.coral
        case .modified, .renamed: return NookTheme.blue
        }
    }
}

/// The toolbar's right end over a `StackedDiffList`: the total lines, fold or unfold every file, the tree of files.
struct StackedDiffToolbar: View {
    let files: [StackedDiffFile]
    @Binding var expanded: Set<String>
    @Binding var showsTree: Bool

    var body: some View {
        let allOpen = !files.isEmpty && files.allSatisfy { expanded.contains($0.id) }
        HStack(spacing: NookTheme.Spacing.xxs) {
            EditLinesLabel(lines: EditLines(added: files.reduce(0) { $0 + ($1.additions ?? 0) },
                                            removed: files.reduce(0) { $0 + ($1.deletions ?? 0) }), size: 11)
                .padding(.trailing, NookTheme.Spacing.xs)
            ToolbarIconButton(allOpen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              tr(allOpen ? "agents.diff.collapseAll" : "agents.diff.expandAll"), enabled: !files.isEmpty) {
                // Not animated: fading every diff in at once laid all of them out on each frame.
                expanded = allOpen ? [] : Set(files.map(\.id))
            }
            ToolbarIconButton(showsTree ? "sidebar.trailing" : "sidebar.right",
                              tr(showsTree ? "agents.diff.hideFiles" : "agents.diff.showFiles")) {
                withAnimation(NookTheme.reveal) { showsTree.toggle() }
            }
        }
    }
}

/// Every file of a change in one scroll, each under a sticky 32 pt header (chevron in the file's color, its path, a
/// copy button, its lines); a folded file is only its header. `diff` reads a file's diff when it is first unfolded,
/// `content` draws it (by default a `DiffText`). With `showsTree` a tree of the files sits on the right; a click there
/// unfolds the file and scrolls to it.
struct StackedDiffList<Content: View>: View {
    let files: [StackedDiffFile]
    /// Tells this change apart from another (a folder, a turn) in the cache of diffs already read.
    let scope: String
    @Binding var expanded: Set<String>
    var showsTree = false
    /// A file to unfold and scroll to (a file picked elsewhere, such as in a turn's changed-files card).
    var focus: String? = nil
    let diff: (StackedDiffFile) async throws -> String
    @ViewBuilder var content: (StackedDiffFile, String) -> Content
    @State private var reveal: String?
    @State private var width: Double = 0

    /// The 200 pt tree leaves the diffs too little room in a narrow side panel: there it waits until there is room.
    private var treeFits: Bool { width == 0 || width >= 440 }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(files) { file in
                            Section {
                                if expanded.contains(file.id) {
                                    StackedDiffBody(file: file, scope: scope, diff: diff, content: content)
                                        .padding(.bottom, NookTheme.Spacing.sm)
                                }
                            } header: {
                                StackedDiffHeader(file: file, open: expanded.contains(file.id)) { toggle(file) }
                            }
                            .id(file.id)
                        }
                    }
                }
                .onAppear { if let focus { reveal = focus } }
                .onChange(of: focus) { _, path in if let path { reveal = path } }
                .onChange(of: reveal) { _, path in
                    guard let path else { return }
                    expanded.insert(path)
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(path, anchor: .top) }
                    reveal = nil
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsTree && treeFits {
                NookDivider(vertical: true)
                // Only when the files change: the tree is built again on each of its own draws.
                StackedDiffTree(files: files) { reveal = $0 }
                    .equatable()
                    .frame(width: 200)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(WS.code)
        .onLayoutWidthChange { width = $0 }
    }

    /// The diff is simply there (or gone); only the header's chevron turns. A whole diff fading in was laid out on every
    /// frame of it.
    private func toggle(_ file: StackedDiffFile) {
        if expanded.contains(file.id) { expanded.remove(file.id) } else { expanded.insert(file.id) }
    }
}

extension StackedDiffList where Content == EquatableView<DiffText> {
    init(files: [StackedDiffFile], scope: String, expanded: Binding<Set<String>>, showsTree: Bool = false,
         focus: String? = nil, diff: @escaping (StackedDiffFile) async throws -> String) {
        self.init(files: files, scope: scope, expanded: expanded, showsTree: showsTree, focus: focus, diff: diff) { file, text in
            // The panel beside a streaming session redraws many times a second; the diff only when it changed.
            DiffText(text: text, stacked: true, path: file.path).equatable()
        }
    }
}

extension StackedDiffFile {
    /// A file from `git status`.
    init(_ change: GitFileChange) {
        let kind: ChangedFilesTree.FileStat.Kind
        switch change.kind {
        case .added, .untracked: kind = .added
        case .deleted: kind = .deleted
        case .renamed, .copied: kind = .renamed(from: change.oldPath ?? "")
        case .modified, .conflicted, .typeChanged: kind = .modified
        }
        self.init(path: change.path, previousPath: change.oldPath, kind: kind, additions: change.added, deletions: change.removed)
    }
}

/// What the panel shows when a change has no files, or while it is first read: one quiet line in the middle.
struct StackedDiffNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, NookTheme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A file's header: the chevron in the file's color, the path cut at its start, a copy button, and its lines. A click
/// anywhere else folds or unfolds it; under the pointer a thin bar marks its left edge.
private struct StackedDiffHeader: View {
    let file: StackedDiffFile
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "chevron.right")
                .font(NookTheme.font(10, .bold))
                .foregroundStyle(file.tint)
                .rotationEffect(.degrees(open ? 90 : 0))
                .animation(NookTheme.reveal, value: open)
                .frame(width: 16)
            Text(file.path)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
            if let previous = file.previousPath {
                Text("← " + (previous as NSString).lastPathComponent)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", tr("agents.diff.copyPath"), height: 20, width: 20) {
                Pasteboard.copy(file.path)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .opacity(hovering || copied ? 1 : 0)
            Spacer(minLength: NookTheme.Spacing.sm)
            if file.additions != nil || file.deletions != nil {
                EditLinesLabel(lines: EditLines(added: file.additions ?? 0, removed: file.deletions ?? 0), size: 11)
            }
        }
        .padding(.leading, NookTheme.Spacing.sm)
        .padding(.trailing, NookTheme.Spacing.md)
        .frame(height: 32)
        .background(WS.code)
        .overlay(alignment: .leading) {
            if hovering { NookTheme.paper.opacity(0.24).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { NookDivider() }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(open ? tr("compose.queue.expanded") : "")
    }
}

/// A file's diff, read the first time it unfolds; a diff read before shows at once while it is read again.
private struct StackedDiffBody<Content: View>: View {
    let file: StackedDiffFile
    let scope: String
    let diff: (StackedDiffFile) async throws -> String
    let content: (StackedDiffFile, String) -> Content
    @State private var text: String?
    @State private var error: String?

    private var key: String { scope + "|" + file.path }

    var body: some View {
        Group {
            if let text, !text.isEmpty {
                content(file, text)
            } else if let error {
                Text(error)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .padding(NookTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if text != nil {
                Text(tr("ws.changes.noDiff"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(NookTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
                    .padding(NookTheme.Spacing.md)
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: key) {
            if let cached = DiffCache.diff(key) {
                text = cached
                // Scrolled back into view (the lazy stack built it again): a diff read moments ago stands.
                if StackedDiffReads.shared.isFresh(key) { return }
            }
            do {
                let fresh = try await diff(file)
                DiffCache.store(fresh, key)
                StackedDiffReads.shared.mark(key)
                text = fresh
                error = nil
            } catch let failure {
                if text == nil { error = failure.localizedDescription }
            }
        }
    }
}

/// When each diff was last read, so one that scrolls out of view and back is not read again straight away.
private final class StackedDiffReads: @unchecked Sendable {
    static let shared = StackedDiffReads()
    /// How long a diff read counts as current.
    private let fresh: TimeInterval = 5
    private var readAt: [String: Date] = [:]
    private let lock = NSLock()

    func isFresh(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readAt[key].map { Date().timeIntervalSince($0) < fresh } ?? false
    }

    func mark(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        readAt[key] = now
        if readAt.count > 200 { readAt = readAt.filter { now.timeIntervalSince($0.value) < fresh } }
    }
}

/// The files as a tree beside the diffs: folders of one child merged ("src/app"), each file in its state's color. A click
/// on a file shows its diff. Equatable on its files: `select` only sets the list's state, which stays the same.
private struct StackedDiffTree: View, Equatable {
    let files: [StackedDiffFile]
    let select: (String) -> Void
    @State private var closed: Set<String> = []

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.files == rhs.files }

    var body: some View {
        let tree = ChangedFilesTree.build(files.map {
            ChangedFilesTree.FileStat(path: $0.path, added: $0.additions, removed: $0.deletions, kind: $0.kind)
        })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("agents.diff.files")).foregroundStyle(NookTheme.paper)
                Spacer(minLength: 0)
                Text("\(files.count)").monospacedDigit()
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 32)
            NookDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.flatten(expanded: tree.expandAll.subtracting(closed))) { row in
                        StackedDiffTreeRow(row: row, open: !closed.contains(row.path)) {
                            if row.isDirectory {
                                withAnimation(NookTheme.reveal) {
                                    if closed.contains(row.path) { closed.remove(row.path) } else { closed.insert(row.path) }
                                }
                            } else {
                                select(row.path)
                            }
                        }
                    }
                }
                .padding(NookTheme.Spacing.xs)
            }
        }
    }
}

private struct StackedDiffTreeRow: View {
    let row: ChangedFilesTree.Row
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch row.kind {
        case .added?: return NookTheme.mint
        case .deleted?: return NookTheme.coral
        default: return hovering ? NookTheme.paper : NookTheme.textSecondary
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                if row.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(NookTheme.font(8, .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                        .foregroundStyle(NookTheme.textTertiary)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Text(row.name)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(row.isDirectory ? NookTheme.textTertiary : tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, NookTheme.Spacing.xs + CGFloat(row.depth) * 12)
            .padding(.trailing, NookTheme.Spacing.xs)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(hovering ? NookTheme.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.path)
    }
}
