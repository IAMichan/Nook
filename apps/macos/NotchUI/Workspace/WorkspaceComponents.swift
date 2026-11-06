import SwiftUI

/// Workspace colors. A neutral, near-black dark theme in the manner of a code tool: surfaces lift by a few percent of
/// white, lines are faint white, and color always represents state.
enum WS {
    static let background = NookTheme.canvas
    /// The sidebar and the inspector: the canvas lifted a little.
    static let sidebar = NookTheme.surface
    static let surface = Color(hex: 0x151517)
    static let raised = Color(hex: 0x1B1B1E)
    static let border = NookTheme.border
    static let subtle = Color.white.opacity(0.04)
    /// A row or control under the pointer.
    static let hover = Color.white.opacity(0.045)
    /// The selected row.
    static let selected = Color.white.opacity(0.085)
    static let text = NookTheme.paper
    static let secondary = NookTheme.textSecondary
    static let tertiary = NookTheme.textTertiary
    static let code = Color(hex: 0x08080A)
}

extension RunStatus {
    var label: String { tr("ws.status." + rawValue) }

    var color: Color {
        switch self {
        case .preparing: return NookTheme.textSecondary
        case .running: return NookTheme.iris
        case .waitingApproval: return NookTheme.amber
        case .completed: return NookTheme.mint
        case .failed: return NookTheme.coral
        case .stopped: return NookTheme.textTertiary
        }
    }

    var symbol: String {
        switch self {
        case .preparing: return "hourglass"
        case .running: return "circle.dotted"
        case .waitingApproval: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        }
    }
}

extension ExecutionMode {
    var label: String { tr("ws.mode." + rawValue) }
    var help: String { tr("ws.mode." + rawValue + ".help") }
}

extension PermissionPolicy {
    var label: String { tr("ws.permission." + rawValue) }
    /// Claude Code and Codex each have their own words; the ACP agents share one text.
    func help(for provider: RunProvider) -> String {
        tr("ws.permission." + rawValue + ".help." + (provider.usesACP ? "acp" : provider.rawValue))
    }
}

extension IsolationMode {
    var label: String { tr("ws.isolation." + rawValue) }
}

extension GitChangeKind {
    var color: Color {
        switch self {
        case .added, .untracked: return NookTheme.mint
        case .deleted: return NookTheme.coral
        case .conflicted: return NookTheme.amber
        case .modified, .typeChanged: return NookTheme.iris
        case .renamed, .copied: return NookTheme.blue
        }
    }
}

/// A one-point line between the window's columns: fainter than a system divider.
struct WSHairline: View {
    var body: some View {
        Rectangle().fill(WS.border).frame(width: 1)
    }
}

/// "● Running" as a compact status badge.
struct StatusBadge: View {
    let status: RunStatus
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(NookTheme.font(compact ? 9 : 10, .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: status == .running)
            if !compact {
                Text(status.label)
                    .font(NookTheme.TextStyle.label)
            }
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, compact ? 0 : 8)
        .frame(height: compact ? 16 : 22)
        .background {
            if !compact { Capsule().fill(status.color.opacity(0.13)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.label)
    }
}

/// Section header for sidebar or inspector.
struct WSSectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(WS.tertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                Text(trailing).font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
            }
        }
    }
}

/// Key-value row for the inspector. "Not available" is displayed explicitly when absent.
struct InfoRow: View {
    let label: String
    let value: String?
    var mono = false
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
            Text(label)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(WS.tertiary)
                .frame(width: 104, alignment: .leading)
            Text(value ?? tr("ws.unavailable"))
                .font(mono ? NookTheme.mono(11.5) : NookTheme.font(12, value == nil ? .regular : .medium))
                .foregroundStyle(value == nil ? WS.tertiary : WS.text)
                .italic(value == nil)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .help(help ?? "")
    }
}

/// A unified diff as a code review shows it: line numbers of the old and new file in a gutter, hunks as separators,
/// added and removed lines tinted, and the changed words of an edited line highlighted. Code in a language
/// `SyntaxTokenizer` knows shows plain first and gets its syntax colors once a background task has them. Inside a
/// `StackedDiffList` it follows the list's `DiffDisplay`: long lines wrap or scroll sideways, the old and new file
/// stand side by side, and the words of a find are marked.
struct DiffText: View, Equatable {
    /// Review comments on this file: shown under their line. With `onComment`, hovering a line
    /// offers a comment button.
    var comments: [ReviewComment] = []
    var onComment: ((_ line: Int?, _ code: String, _ text: String) -> Void)? = nil
    var onRemoveComment: ((UUID) -> Void)? = nil
    /// Like `onComment` with the whole line, for what needs the old file's number of a removed line.
    /// The first row is set for a comment on several lines: Shift on a second line's + picks the range.
    var onRowComment: ((UnifiedDiff.Row, UnifiedDiff.Row?, String) -> Void)? = nil
    /// New-file lines with something drawn under them, what is drawn, and what tells one drawing from the next.
    var annotationLines: Set<Int> = []
    var annotationVersion = ""
    var annotation: ((Int) -> AnyView)? = nil
    /// One file of a `StackedDiffList`: no scroll view of its own and no file line, its header above says which file.
    var stacked = false
    private let rows: [UnifiedDiff.Row]
    /// Width of one line-number column, from the largest number in the diff.
    private let numberWidth: CGFloat
    private let text: String
    /// The file whose language colors the code: given, or the first file the diff names.
    private let syntaxPath: String?
    private let syntaxKey: DiffSyntax.Key
    /// The syntax-colored lines, once worked out (`DiffSyntaxStyle`); until then the code is plain.
    @State private var colored: DiffSyntaxStyle.Lines?
    @State private var editing: Int?
    /// The first line of a comment on several lines; `editing` is then the last.
    @State private var rangeStart: Int?
    @State private var commentDraft = ""
    @Environment(\.diffDisplay) private var display
    /// The width the diff is given, so lines that scroll sideways (not wrapped) still fill it.
    @State private var width: Double = 0

    /// What the comment actions act on (a session and file): with the same diff in another session, the view is drawn
    /// again so its actions are that session's.
    private let scope: String?
    /// The file's path as the stacked list names it: the scroll ids of the lines, and which file a find's match is in.
    private let anchor: String?

    init(text: String, comments: [ReviewComment] = [],
         onComment: ((_ line: Int?, _ code: String, _ text: String) -> Void)? = nil,
         onRemoveComment: ((UUID) -> Void)? = nil, stacked: Bool = false, path: String? = nil, scope: String? = nil,
         onRowComment: ((UnifiedDiff.Row, UnifiedDiff.Row?, String) -> Void)? = nil, annotationLines: Set<Int> = [], annotationVersion: String = "",
         annotation: ((Int) -> AnyView)? = nil) {
        self.onRowComment = onRowComment
        self.annotationLines = annotationLines
        self.annotationVersion = annotationVersion
        self.annotation = annotation
        self.scope = scope
        self.stacked = stacked
        self.anchor = path
        self.text = text
        syntaxPath = path ?? DiffSyntax.firstPath(in: text)
        let key = DiffSyntax.Key(path: syntaxPath, text: text)
        syntaxKey = key
        // A diff seen before opens in its colors: plain first and colored a frame later measured every line twice.
        _colored = State(initialValue: DiffSyntaxStyle.cache.value(for: key))
        self.comments = comments
        self.onComment = onComment
        self.onRemoveComment = onRemoveComment
        if let parsed = Self.parsed.value(for: key) {
            rows = parsed.rows
            numberWidth = parsed.numberWidth
        } else {
            let parsedRows = UnifiedDiff.rows(text)
            let largest = parsedRows.reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }
            let width = CGFloat(max(String(largest).count, 2)) * 6.6 + 14
            // The cache counts diffs, not bytes: a huge one (a generated file) is parsed each time instead of kept.
            if text.utf8.count <= 1_000_000 { Self.parsed.set((rows: parsedRows, numberWidth: width), for: key) }
            rows = parsedRows
            numberWidth = width
        }
    }

    /// Drawn again only when what it shows changed (with `.equatable()` where it is used): every line of a long diff is
    /// a row of its own. The closures do the same for the same `scope`.
    static func == (a: DiffText, b: DiffText) -> Bool {
        a.syntaxKey == b.syntaxKey && a.syntaxPath == b.syntaxPath && a.stacked == b.stacked && a.scope == b.scope
            && a.anchor == b.anchor && a.comments == b.comments
            && (a.onComment == nil) == (b.onComment == nil) && (a.onRemoveComment == nil) == (b.onRemoveComment == nil)
            && (a.onRowComment == nil) == (b.onRowComment == nil) && a.annotationVersion == b.annotationVersion
    }

    /// The rows of the diffs shown lately: a diff is made again with each redraw of the view around it (a side panel
    /// beside a session that streams redraws many times a second), and reading every line of it again is for nothing.
    private static let parsed = BoundedCache<DiffSyntax.Key, (rows: [UnifiedDiff.Row], numberWidth: CGFloat)>(limit: 48)

    private static let hunkColor = NookTheme.blue
    private var gutterWidth: CGFloat { numberWidth * 2 + DiffLineRow.markerWidth }

    var body: some View {
        Group {
            if stacked && !display.wrap {
                // Lines keep their length and the file scrolls sideways; every line is at least as wide as the view, so
                // the tints of the short ones still reach its edge.
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 0) { lines }
                        .frame(minWidth: width, alignment: .leading)
                }
                .background(WS.code)
                .onLayoutWidthChange { width = $0 }
            } else if stacked {
                // Lazy as well inside the list's own lazy stack: a long file builds only the lines in view, not all of
                // them at once when it scrolls in.
                LazyVStack(alignment: .leading, spacing: 0) { lines }
                    .background(WS.code)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) { lines }
                        .padding(.bottom, NookTheme.Spacing.md)
                }
                .background(WS.code)
            }
        }
        .task(id: syntaxKey) {
            if let kept = DiffSyntaxStyle.cache.value(for: syntaxKey) {
                colored = kept
                return
            }
            colored = nil
            guard syntaxPath.flatMap(SyntaxLanguage.detect) != nil || rows.contains(where: { $0.kind == .file }) else { return }
            let lines = await DiffSyntaxStyle.lines(for: text, path: syntaxPath, key: syntaxKey)
            if !Task.isCancelled { colored = lines }
        }
    }

    @ViewBuilder
    private var lines: some View {
        if display.split && stacked {
            splitLines
        } else {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    switch row.kind {
                    case .file: if !stacked { fileRow(row, first: index == 0) }
                    case .hunk: hunkRow(row)
                    case .note: noteRow(row)
                    case .context, .add, .remove:
                        lineRow(row, index: index)
                            .id(rowID(index))
                        // Most diffs have no comments: no search through them for every line.
                        if !comments.isEmpty {
                            ForEach(comments.filter { $0.code == row.raw && $0.line == row.new }) { comment in
                                commentRow(comment)
                            }
                        }
                        if editing == index {
                            editor(line: row.new, code: row.raw)
                        }
                        if let annotation, let line = row.new, annotationLines.contains(line) { annotation(line) }
                    }
                }
        }
    }

    /// The old file on the left and the new on the right (`SplitDiff`); hunk headers and notes span both. Comments show
    /// under the line they are on; new ones are written in the one-column view.
    @ViewBuilder
    private var splitLines: some View {
        let split = SplitDiff.lines(rows)
        ForEach(split.indices, id: \.self) { index in
            let line = split[index]
            if let full = line.full {
                switch rows[full].kind {
                case .hunk: hunkRow(rows[full])
                case .file: EmptyView()
                default: noteRow(rows[full])
                }
            } else {
                DiffSplitRow(left: line.left.map(cell), right: line.right.map(cell), numberWidth: numberWidth, wrap: display.wrap)
                    .equatable()
                    .id(rowID(line.left ?? line.right ?? index))
                if !comments.isEmpty, let right = line.right {
                    ForEach(comments.filter { $0.code == rows[right].raw && $0.line == rows[right].new }) { comment in
                        commentRow(comment)
                    }
                }
                if let annotation, let right = line.right, let number = rows[right].new, annotationLines.contains(number) {
                    annotation(number)
                }
            }
        }
    }

    private func cell(_ index: Int) -> DiffSplitRow.Cell {
        let row = rows[index]
        return DiffSplitRow.Cell(row: row, code: marked(colored?[index] ?? code(row), row: index), tint: accent(row.kind))
    }

    /// The scroll id of a code line, which a find in the stacked list scrolls to.
    private func rowID(_ index: Int) -> String {
        DiffFind.rowID(path: anchor ?? "", row: index)
    }

    private func lineRow(_ row: UnifiedDiff.Row, index: Int) -> some View {
        DiffLineRow(row: row, code: marked(colored?[index] ?? code(row), row: index), tint: accent(row.kind),
                    numberWidth: numberWidth, commentable: onComment != nil || onRowComment != nil, editing: editing == index,
                    wrap: display.wrap || !stacked) {
            if onRowComment != nil, NSEvent.modifierFlags.contains(.shift), let current = editing, current != index {
                rangeStart = min(current, index)
                editing = max(current, index)
            } else {
                rangeStart = nil
                commentDraft = ""
                editing = index
            }
        }
        .equatable()
    }

    /// The words of an open find marked in the line, the selected match stronger than the others.
    private func marked(_ code: AttributedString, row index: Int) -> AttributedString {
        guard !display.query.isEmpty else { return code }
        let current = display.current.flatMap { $0.path == anchor && $0.row == index ? $0.occurrence : nil }
        var code = code
        var start = code.startIndex
        var occurrence = 0
        while start < code.endIndex, let range = code[start...].range(of: display.query, options: DiffFind.options) {
            code[range].backgroundColor = NookTheme.amber.opacity(occurrence == current ? 0.75 : 0.28)
            occurrence += 1
            start = range.upperBound
        }
        return code
    }

    /// The line's code, with the changed part of an edited line on a stronger tint.
    private func code(_ row: UnifiedDiff.Row) -> AttributedString {
        let text = row.text.isEmpty ? " " : row.text
        guard let changed = row.changed, let tint = accent(row.kind) else { return AttributedString(text) }
        let units = text.utf16
        guard changed.upperBound <= units.count,
              let head = String(units.prefix(changed.lowerBound)),
              let middle = String(units.dropFirst(changed.lowerBound).prefix(changed.count)),
              let tail = String(units.dropFirst(changed.upperBound)) else { return AttributedString(text) }
        var highlight = AttributedString(middle)
        highlight.backgroundColor = tint.opacity(0.32)
        return AttributedString(head) + highlight + AttributedString(tail)
    }

    private func accent(_ kind: UnifiedDiff.Kind) -> Color? {
        switch kind {
        case .add: return NookTheme.mint
        case .remove: return NookTheme.coral
        default: return nil
        }
    }

    private func hunkRow(_ row: UnifiedDiff.Row) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.up.and.down")
                .font(NookTheme.font(9, .semibold))
                .foregroundStyle(WS.tertiary)
                .frame(width: numberWidth * 2)
            Text(UnifiedDiff.hunkLabel(row.raw))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(WS.tertiary)
                .padding(.leading, DiffLineRow.markerWidth)
            if !row.text.isEmpty {
                Text(row.text)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(WS.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, NookTheme.Spacing.md)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .background(WS.subtle)
    }

    private func fileRow(_ row: UnifiedDiff.Row, first: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(WS.secondary)
            Text(row.text)
                .font(NookTheme.mono(13, .semibold))
                .foregroundStyle(WS.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .background(WS.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(WS.border).frame(height: 1) }
        .padding(.top, first ? 0 : 14)
    }

    private func noteRow(_ row: UnifiedDiff.Row) -> some View {
        Text(row.text)
            .font(NookTheme.mono(10.5))
            .italic()
            .foregroundStyle(WS.tertiary)
            .padding(.leading, gutterWidth)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commentRow(_ comment: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            Image(systemName: "text.bubble.fill").font(NookTheme.font(10)).foregroundStyle(NookTheme.amber)
            Text(comment.text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let onRemoveComment {
                ToolbarIconButton("xmark", tr("ws.review.remove"), height: 20, width: 20) { onRemoveComment(comment.id) }
            }
        }
        .padding(NookTheme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.amber.opacity(0.08)))
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.leading, gutterWidth)
        .padding(.trailing, 10)
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    private func editor(line: Int?, code: String) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if let rangeStart, let first = rows[rangeStart].new ?? rows[rangeStart].old, let last = line ?? editing.flatMap({ rows[$0].old }) {
                Text(verbatim: "\(first)–\(last)").font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary).fixedSize()
            }
            TextField("", text: $commentDraft, prompt: Text(tr("ws.review.placeholder")).foregroundStyle(NookTheme.textTertiary),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...4)
                .onSubmit { save(line: line, code: code) }
                .onExitCommand { editing = nil }
            SmallGhostButton(title: tr("button.cancel")) { editing = nil }
            SmallGhostButton(title: tr("ws.review.save")) { save(line: line, code: code) }
        }
        .padding(NookTheme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.field))
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.leading, gutterWidth)
        .padding(.trailing, 10)
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    private func save(line: Int?, code: String) {
        let clean = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onComment?(line, code, clean)
        if let editing { onRowComment?(rows[editing], rangeStart.map { rows[$0] }, clean) }
        commentDraft = ""
        editing = nil
        rangeStart = nil
    }
}

/// One code line of a `DiffText`: the old and new line number, the marker, and the code. A view of its own with its own
/// hover, so the pointer passing over lines (also while the list scrolls under it) redraws only the line it enters and
/// leaves, not every line of the diff.
struct DiffLineRow: View, Equatable {
    static let markerWidth: CGFloat = 16
    private static let codeColor = NookTheme.textStrong

    let row: UnifiedDiff.Row
    let code: AttributedString
    let tint: Color?
    let numberWidth: CGFloat
    /// Hovering the line offers a comment button.
    let commentable: Bool
    /// The comment editor is open under this line: no button over it.
    let editing: Bool
    /// Long lines wrap; otherwise they keep their length and the diff scrolls sideways.
    let wrap: Bool
    let comment: () -> Void
    @State private var hovering = false

    static func == (a: DiffLineRow, b: DiffLineRow) -> Bool {
        a.row == b.row && a.code == b.code && a.tint == b.tint && a.numberWidth == b.numberWidth
            && a.commentable == b.commentable && a.editing == b.editing && a.wrap == b.wrap
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(row.old)
            number(row.new)
            Text(verbatim: row.kind == .add ? "+" : row.kind == .remove ? "−" : "")
                .font(NookTheme.mono(13, .semibold))
                .foregroundStyle(tint ?? .clear)
                .frame(width: Self.markerWidth, alignment: .center)
            Text(code)
                .font(NookTheme.mono(13))
                .foregroundStyle(row.kind == .context ? Self.codeColor.opacity(0.82) : Self.codeColor)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 28)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1.5)
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                (tint?.opacity(0.16) ?? WS.subtle.opacity(0.5)).frame(width: numberWidth * 2)
                (tint?.opacity(0.08) ?? .clear)
            }
        }
        .background(hovering && commentable ? WS.hover : .clear)
        .overlay(alignment: .topTrailing) {
            if commentable, hovering, !editing {
                Button(action: comment) {
                    Image(systemName: "plus.bubble.fill")
                        .font(NookTheme.font(11, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .padding(.horizontal, 7)
                        .padding(.vertical, NookTheme.Spacing.xxs)
                }
                .buttonStyle(.plain)
                .help(tr("ws.review.add"))
            }
        }
        // A diff without comments has nothing to show under the pointer: no state changes while it moves.
        .onHover { inside in if commentable { hovering = inside } }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(NookTheme.mono(10.5))
            .foregroundStyle(WS.tertiary)
            .padding(.trailing, 7)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.top, 1)
    }
}

/// One line of a side-by-side diff: the old file's row on the left, the new file's on the right, each with its line
/// number, marker and code; an empty side (a line only added or only removed) stays blank.
struct DiffSplitRow: View, Equatable {
    struct Cell: Equatable {
        let row: UnifiedDiff.Row
        let code: AttributedString
        let tint: Color?
    }

    let left: Cell?
    let right: Cell?
    let numberWidth: CGFloat
    let wrap: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(left, number: left?.row.old)
            NookDivider(vertical: true)
            side(right, number: right?.row.new)
        }
    }

    private func side(_ cell: Cell?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(NookTheme.mono(10.5))
                .foregroundStyle(WS.tertiary)
                .padding(.trailing, 7)
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.top, 1)
            Text(verbatim: cell?.row.kind == .add ? "+" : cell?.row.kind == .remove ? "−" : "")
                .font(NookTheme.mono(13, .semibold))
                .foregroundStyle(cell?.tint ?? .clear)
                .frame(width: DiffLineRow.markerWidth, alignment: .center)
            Text(cell?.code ?? AttributedString(" "))
                .font(NookTheme.mono(13))
                .foregroundStyle(cell?.row.kind == .context ? NookTheme.textStrong.opacity(0.82) : NookTheme.textStrong)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, NookTheme.Spacing.md)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                (cell == nil ? WS.subtle.opacity(0.3) : cell?.tint?.opacity(0.16) ?? WS.subtle.opacity(0.5)).frame(width: numberWidth)
                (cell == nil ? WS.subtle.opacity(0.3) : cell?.tint?.opacity(0.08) ?? .clear)
            }
        }
    }
}

enum WSFormat {
    static func tokens(_ count: Int?) -> String? {
        count.map { TokenTally.format($0) }
    }

    static func cost(_ usd: Double?) -> String? {
        usd.map { AgentPathFormat.cost($0) }
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Increments elapsed time while a turn is active.
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.nookTicks(every: 1)) { context in
            Text(AgentPathFormat.duration(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }
}

/// Mode, permissions and model for the next turn of a session Nook runs, also while it works (see
/// `WorkspaceManager.configure`).
struct NextTurnSettings: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let run: WorkspaceRun

    var body: some View {
        let capabilities = run.provider.capabilities
        Picker(tr("agents.run.mode"), selection: Binding(get: { run.mode }, set: { workspace.configure(run.id, mode: $0) })) {
            ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
        }
        .disabled(!capabilities.planMode)
        Picker(tr("agents.run.permission"), selection: Binding(get: { run.permission }, set: { workspace.configure(run.id, permission: $0) })) {
            ForEach(capabilities.policies) { Text($0.label).tag($0) }
        }
        Picker(tr("agents.run.model"), selection: Binding(get: { run.autoModel == true ? AutoModel.id : run.model },
                                                          set: { workspace.configure(run.id, model: $0) })) {
            Text(tr("auto.model")).tag(AutoModel.id)
            ForEach(modelChoices, id: \.self) { model in
                let choice = workspace.modelChoice(model, for: run.provider, profileID: run.profileID)
                let name = model.isEmpty ? tr("ws.model.default") : choice?.name ?? model
                // A model that needs a newer agent names the update and cannot be picked until then.
                Text(choice?.requiredVersion.map { tr("ws.model.needsUpdate", name, run.provider.displayName, $0) } ?? name)
                    .tag(model)
                    .disabled(choice?.needsUpdate == true)
            }
        }
    }

    /// The models offered for the next turn: the same menu as the composer's (favorites first, older models only while
    /// in use), with the session's model under the name it uses ("opus" stays "opus", so the picker shows it chosen).
    private var modelChoices: [String] {
        workspace.menuModelIDs(for: run.provider, profileID: run.profileID, extra: [run.model])
            .filter { !workspace.hidesLegacyModel($0, for: run.provider, chosen: run.model) }
            .map { workspace.sameModel($0, run.model, for: run.provider) ? run.model : $0 }
    }
}
