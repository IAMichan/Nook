import SwiftUI

// Changes laid out as a stacked diff: every file in one scroll under a header that sticks while you read it,
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
        case .added: return NookTheme.diffAdded
        case .deleted: return NookTheme.diffRemoved
        case .modified, .renamed: return NookTheme.diffModified
        }
    }
}

/// How every stacked diff is shown, kept across launches: set in `StackedDiffToolbar`, read by `StackedDiffList`.
enum DiffDisplayKeys {
    static let wrap = "nook.diff.wrapLines"
    static let split = "nook.diff.split"
    static let ignoreWhitespace = "nook.diff.ignoreWhitespace"
    static let hideTests = "nook.diff.hideTests"
}

/// What a `DiffText` inside a `StackedDiffList` draws besides the diff: wrapped or scrolled lines, one column or two, and
/// the words a find looks for. Handed down through the environment, so every place that draws a diff follows it.
struct DiffDisplay: Equatable {
    var wrap = true
    var split = false
    /// The words of an open find (trimmed); empty when there is none.
    var query = ""
    /// The selected match, drawn stronger than the others.
    var current: DiffFind.Match?
}

extension EnvironmentValues {
    @Entry var diffDisplay = DiffDisplay()
}

/// The toolbar's right end over a `StackedDiffList`: the total lines, how the diff is shown (wrap, side by side, without
/// whitespace changes, without tests), fold or unfold every file, the tree of files.
struct StackedDiffToolbar: View {
    let files: [StackedDiffFile]
    @Binding var expanded: Set<String>
    @Binding var showsTree: Bool
    /// Off where the diff comes as it is and cannot leave out whitespace (a forge's patch).
    var hidesWhitespace = true
    @AppStorage(DiffDisplayKeys.wrap) private var wrap = true
    @AppStorage(DiffDisplayKeys.split) private var split = false
    @AppStorage(DiffDisplayKeys.ignoreWhitespace) private var ignoreWhitespace = false
    @AppStorage(DiffDisplayKeys.hideTests) private var hideTests = false

    var body: some View {
        let files = hideTests ? files.filter { !DiffFileFilter.isTest($0.path) } : files
        let allOpen = !files.isEmpty && files.allSatisfy { expanded.contains($0.id) }
        HStack(spacing: NookTheme.Spacing.xs) {
            EditLinesLabel(lines: EditLines(added: files.reduce(0) { $0 + ($1.additions ?? 0) },
                                            removed: files.reduce(0) { $0 + ($1.deletions ?? 0) }), size: 11)
                .padding(.trailing, NookTheme.Spacing.xs)
            if hidesWhitespace {
                ToolbarIconButton("text.word.spacing", tr(ignoreWhitespace ? "agents.diff.showWhitespace" : "agents.diff.hideWhitespace"),
                                  height: 28, width: 28, selected: ignoreWhitespace, symbolSize: 13) { ignoreWhitespace.toggle() }
            }
            ToolbarIconButton("testtube.2", tr(hideTests ? "agents.diff.showTests" : "agents.diff.hideTests"),
                              height: 28, width: 28, selected: hideTests, symbolSize: 13) { hideTests.toggle() }
            ToolbarIconButton("arrow.turn.down.left", tr(wrap ? "agents.diff.noWrap" : "agents.diff.wrap"),
                              height: 28, width: 28, selected: wrap, symbolSize: 13) { wrap.toggle() }
            ToolbarIconButton(split ? "rectangle.split.2x1" : "rectangle", tr(split ? "agents.diff.unified" : "agents.diff.split"),
                              height: 28, width: 28, selected: split, symbolSize: 13) { split.toggle() }
            ToolbarIconButton(allOpen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              tr(allOpen ? "agents.diff.collapseAll" : "agents.diff.expandAll"), height: 28, width: 28, enabled: !files.isEmpty, symbolSize: 13) {
                // Not animated: fading every diff in at once laid all of them out on each frame.
                expanded = allOpen ? [] : Set(files.map(\.id))
            }
            ToolbarIconButton(showsTree ? "sidebar.trailing" : "sidebar.right",
                              tr(showsTree ? "agents.diff.hideFiles" : "agents.diff.showFiles"), height: 28, width: 28, symbolSize: 13) {
                withAnimation(NookTheme.reveal) { showsTree.toggle() }
            }
        }
    }
}

/// Every file of a change in one scroll, each under a sticky 32 pt header (chevron in the file's color, its path, a
/// copy button, its lines); a folded file is only its header. `diff` reads a file's diff when it is first unfolded,
/// with the toolbar's `DiffReadOptions`; `content` draws it (by default a `DiffText`). With `showsTree` a tree of the
/// files sits on the right; a click there unfolds the file and scrolls to it. The toolbar's choices (`DiffDisplayKeys`)
/// apply here: test files left out, lines wrapped or not, one column or two. ⌘F (`chat.find`) while the pointer is over
/// the list finds words in every file, folded ones too, and unfolds and scrolls to each match in turn.
struct StackedDiffList<Content: View>: View {
    let files: [StackedDiffFile]
    /// Tells this change apart from another (a folder, a turn) in the cache of diffs already read.
    let scope: String
    @Binding var expanded: Set<String>
    var showsTree = false
    /// A file to unfold and scroll to (a file picked elsewhere, such as in a turn's changed-files card).
    var focus: String? = nil
    /// Drawn in a file's header, before its lines.
    var headerAccessory: ((StackedDiffFile) -> AnyView)? = nil
    /// How far the list is scrolled, for a page that folds its top.
    var onScroll: ((PullRequestPageScroll) -> Void)? = nil
    let diff: (StackedDiffFile, DiffReadOptions) async throws -> String
    @ViewBuilder var content: (StackedDiffFile, String) -> Content
    @State private var reveal: String?
    @State private var width: Double = 0
    @AppStorage(DiffDisplayKeys.wrap) private var wrap = true
    @AppStorage(DiffDisplayKeys.split) private var split = false
    @AppStorage(DiffDisplayKeys.ignoreWhitespace) private var ignoreWhitespace = false
    @AppStorage(DiffDisplayKeys.hideTests) private var hideTests = false
    /// The pointer is over the list: ⌘F finds in the diff instead of the conversation beside it.
    @State private var hovering = false
    @State private var finding = false
    @State private var query = ""
    @State private var found = DiffFindState()

    /// The 200 pt tree leaves the diffs too little room in a narrow side panel: there it waits until there is room.
    private var treeFits: Bool { width == 0 || width >= 440 }
    private var options: DiffReadOptions { DiffReadOptions(ignoreWhitespace: ignoreWhitespace) }
    private var shown: [StackedDiffFile] { hideTests ? files.filter { !DiffFileFilter.isTest($0.path) } : files }
    private var display: DiffDisplay {
        DiffDisplay(wrap: wrap, split: split, query: finding ? DiffFindState.trimmed(query) : "",
                    current: finding ? found.currentMatch : nil)
    }

    var body: some View {
        let shown = shown
        let hidden = files.count - shown.count
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(shown) { file in
                            Section {
                                if expanded.contains(file.id) {
                                    StackedDiffBody(file: file, scope: scope, options: options, diff: diff, content: content)
                                        .padding(.bottom, NookTheme.Spacing.md)
                                }
                            } header: {
                                StackedDiffHeader(file: file, open: expanded.contains(file.id), accessory: headerAccessory?(file)) { toggle(file) }
                            }
                            .id(file.id)
                        }
                        if hidden > 0 {
                            Text(tr("agents.diff.testsHidden", hidden))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(NookTheme.Spacing.md)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .environment(\.diffDisplay, display)
                .onScrollGeometryChange(for: PullRequestPageScroll.self) { geometry in
                    PullRequestPageScroll(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                          overflow: geometry.contentSize.height - geometry.containerSize.height)
                } action: { _, scroll in
                    onScroll?(scroll)
                }
                .overlay(alignment: .top) {
                    if finding {
                        TimelineFindBar(query: $query, state: found.state, count: found.matches.count, current: found.current,
                                        previous: { step(forward: false) }, next: { step(forward: true) }, close: closeFind)
                            .padding(.horizontal, NookTheme.Spacing.md)
                            .padding(.top, NookTheme.Spacing.sm + 32)
                            .transition(.opacity)
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
                .onChange(of: found.currentMatch) { _, match in
                    guard let match else { return }
                    show(match, proxy: proxy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsTree && treeFits {
                NookDivider(vertical: true)
                // Only when the files change: the tree is built again on each of its own draws.
                StackedDiffTree(files: shown) { reveal = $0 }
                    .equatable()
                    .frame(width: 200)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(WS.code)
        .onLayoutWidthChange { width = $0 }
        .onHover { inside in if hovering != inside { hovering = inside } }
        // Only while the pointer is over the diff (or its find is open): elsewhere ⌘F stays the conversation's.
        .keyCommand("chat.find", enabled: hovering || finding, priority: 1) { openFind() }
        // Typing, other options or other files: look again, a moment after the last key.
        .task(id: finding ? FindKey(query: DiffFindState.trimmed(query), files: shown.map(\.id), options: options, scope: scope) : nil) {
            guard finding else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await search(in: shown)
        }
    }

    private struct FindKey: Equatable {
        var query: String
        var files: [String]
        var options: DiffReadOptions
        var scope: String
    }

    /// The diff is simply there (or gone); only the header's chevron turns. A whole diff fading in was laid out on every
    /// frame of it.
    private func toggle(_ file: StackedDiffFile) {
        if expanded.contains(file.id) { expanded.remove(file.id) } else { expanded.insert(file.id) }
    }

    private func openFind() {
        if !finding { withAnimation(NookTheme.reveal) { finding = true } }
    }

    private func closeFind() {
        withAnimation(NookTheme.reveal) { finding = false }
        found = DiffFindState()
    }

    private func step(forward: Bool) {
        found.step(forward: forward)
    }

    /// Reads every shown file's diff (the ones read before come from the cache) and finds the words in them.
    private func search(in files: [StackedDiffFile]) async {
        let words = DiffFindState.trimmed(query)
        guard !words.isEmpty else {
            found = DiffFindState()
            return
        }
        if found.state != .results { found.state = .searching }
        var read: [(path: String, rows: [UnifiedDiff.Row])] = []
        for file in files {
            guard !Task.isCancelled else { return }
            let key = options.cacheKey(scope: scope, path: file.path)
            let text: String
            if let cached = DiffCache.diff(key) {
                text = cached
            } else {
                guard let fresh = try? await diff(file, options) else { continue }
                DiffCache.store(fresh, key)
                text = fresh
            }
            read.append((file.path, UnifiedDiff.rows(text)))
        }
        guard !Task.isCancelled else { return }
        let matches = await Task.detached(priority: .userInitiated) { DiffFind.matches(words, in: read) }.value
        guard !Task.isCancelled else { return }
        found.update(matches)
    }

    /// Unfolds the match's file and scrolls to its line: first to the file, so its lines are built, then to the line.
    private func show(_ match: DiffFind.Match, proxy: ScrollViewProxy) {
        expanded.insert(match.path)
        proxy.scrollTo(match.path, anchor: .top)
        let target = DiffFind.rowID(path: match.path, row: split ? splitAnchor(match) : match.row)
        Task { @MainActor in
            for delay in [60, 220] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                withAnimation(NookTheme.scroll) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    /// Side by side, a line holds two rows and carries the id of the first of them.
    private func splitAnchor(_ match: DiffFind.Match) -> Int {
        let key = options.cacheKey(scope: scope, path: match.path)
        guard let text = DiffCache.diff(key) else { return match.row }
        let line = SplitDiff.lines(UnifiedDiff.rows(text)).first { $0.left == match.row || $0.right == match.row }
        return line.flatMap { $0.left ?? $0.right ?? $0.full } ?? match.row
    }
}

extension StackedDiffList where Content == EquatableView<DiffText> {
    init(files: [StackedDiffFile], scope: String, expanded: Binding<Set<String>>, showsTree: Bool = false,
         focus: String? = nil, diff: @escaping (StackedDiffFile, DiffReadOptions) async throws -> String) {
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
    var accessory: AnyView? = nil
    let toggle: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(icon: "chevron.right")
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
            CopyIconButton(tr("agents.diff.copyPath"), height: 20, width: 20, showing: $copied) { file.path }
                .opacity(hovering || copied ? 1 : 0)
            Spacer(minLength: NookTheme.Spacing.sm)
            if let accessory { accessory }
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
        .contentShape(Rectangle())
        .nookClickable()
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
    let options: DiffReadOptions
    let diff: (StackedDiffFile, DiffReadOptions) async throws -> String
    let content: (StackedDiffFile, String) -> Content
    @State private var text: String?
    @State private var error: String?
    /// The file's counts when this diff was last read: when they move, the file changed and the diff is read again.
    @State private var readCounts: String?

    private var key: String { options.cacheKey(scope: scope, path: file.path) }
    private var counts: String { "\(file.additions ?? -1)|\(file.deletions ?? -1)" }

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
        .task(id: key + "|" + counts) {
            let moved = readCounts != nil && readCounts != counts
            readCounts = counts
            if let cached = DiffCache.diff(key) {
                text = cached
                // Scrolled back into view (the lazy stack built it again): a diff read moments ago stands.
                if !moved && StackedDiffReads.shared.isFresh(key) { return }
            }
            do {
                let fresh = try await diff(file, options)
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
        case .added?: return NookTheme.diffAdded
        case .deleted?: return NookTheme.diffRemoved
        default: return hovering ? NookTheme.paper : NookTheme.textSecondary
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                if row.isDirectory {
                    Image(icon: "chevron.right")
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
            .roundedBackground(hovering ? NookTheme.rowHover : Color.clear, radius: NookTheme.Radius.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .help(row.path)
    }
}
