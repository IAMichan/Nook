import SwiftUI

/// Workspace colors. A neutral, near-black dark theme in the manner of a code tool: surfaces lift by a few percent of
/// white, lines are faint white, and color always represents state.
enum WS {
    static let background = NookTheme.canvas
    /// The sidebar and the inspector: the canvas lifted a little.
    static let sidebar = NookTheme.surface
    static let surface = Color(hex: 0x141416)
    static let raised = Color(hex: 0x1A1A1D)
    static let border = Color.white.opacity(0.07)
    static let subtle = Color.white.opacity(0.05)
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
                    .font(NookTheme.font(11.5, .semibold))
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
            Text(title.uppercased())
                .font(NookTheme.font(10.5, .semibold))
                .tracking(0.6)
                .foregroundStyle(WS.tertiary)
            Spacer()
            if let trailing {
                Text(trailing).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(NookTheme.font(12))
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

/// Empty state view: calm presentation with a single clear call-to-action.
struct WSEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(NookTheme.font(26, .light))
                .foregroundStyle(WS.tertiary)
            Text(title)
                .font(NookTheme.font(15, .semibold))
                .foregroundStyle(WS.text)
            Text(message)
                .font(NookTheme.font(12.5))
                .foregroundStyle(WS.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A unified diff as a code review shows it: line numbers of the old and new file in a gutter, hunks as separators,
/// added and removed lines tinted, and the changed words of an edited line highlighted. Long lines wrap.
struct DiffText: View {
    /// Review comments on this file: shown under their line. With `onComment`, hovering a line
    /// offers a comment button.
    var comments: [ReviewComment] = []
    var onComment: ((_ line: Int?, _ code: String, _ text: String) -> Void)? = nil
    var onRemoveComment: ((UUID) -> Void)? = nil
    private let rows: [UnifiedDiff.Row]
    /// Width of one line-number column, from the largest number in the diff.
    private let numberWidth: CGFloat
    @State private var hovered: Int?
    @State private var editing: Int?
    @State private var commentDraft = ""

    init(text: String, comments: [ReviewComment] = [],
         onComment: ((_ line: Int?, _ code: String, _ text: String) -> Void)? = nil,
         onRemoveComment: ((UUID) -> Void)? = nil) {
        self.comments = comments
        self.onComment = onComment
        self.onRemoveComment = onRemoveComment
        rows = UnifiedDiff.rows(text)
        let largest = rows.reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }
        numberWidth = CGFloat(max(String(largest).count, 2)) * 6.6 + 14
    }

    private static let codeColor = NookTheme.textStrong
    private static let hunkColor = NookTheme.blue
    private var gutterWidth: CGFloat { numberWidth * 2 + markerWidth }
    private let markerWidth: CGFloat = 16

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    switch row.kind {
                    case .file: fileRow(row, first: index == 0)
                    case .hunk: hunkRow(row)
                    case .note: noteRow(row)
                    case .context, .add, .remove:
                        lineRow(row, index: index)
                        ForEach(comments.filter { $0.code == row.raw && $0.line == row.new }) { comment in
                            commentRow(comment)
                        }
                        if editing == index {
                            editor(line: row.new, code: row.raw)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .background(WS.code)
    }

    private func lineRow(_ row: UnifiedDiff.Row, index: Int) -> some View {
        let tint = accent(row.kind)
        return HStack(alignment: .top, spacing: 0) {
            number(row.old)
            number(row.new)
            Text(verbatim: row.kind == .add ? "+" : row.kind == .remove ? "−" : "")
                .font(NookTheme.mono(11.5, .semibold))
                .foregroundStyle(tint ?? .clear)
                .frame(width: markerWidth, alignment: .center)
            Text(code(row))
                .font(NookTheme.mono(11.5))
                .foregroundStyle(row.kind == .context ? Self.codeColor.opacity(0.82) : Self.codeColor)
                .fixedSize(horizontal: false, vertical: true)
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
        .background(hovered == index && onComment != nil ? WS.hover : .clear)
        .overlay(alignment: .topTrailing) {
            if onComment != nil, hovered == index, editing != index {
                Button {
                    commentDraft = ""
                    editing = index
                } label: {
                    Image(systemName: "plus.bubble.fill")
                        .font(NookTheme.font(11, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .help(tr("ws.review.add"))
            }
        }
        .onHover { inside in if inside { hovered = index } else if hovered == index { hovered = nil } }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(NookTheme.mono(10.5))
            .foregroundStyle(WS.tertiary)
            .padding(.trailing, 7)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.top, 1)
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
                .foregroundStyle(Self.hunkColor.opacity(0.8))
                .frame(width: numberWidth * 2)
            Text(UnifiedDiff.hunkLabel(row.raw))
                .font(NookTheme.mono(10.5))
                .foregroundStyle(Self.hunkColor)
                .padding(.leading, markerWidth)
            if !row.text.isEmpty {
                Text(row.text)
                    .font(NookTheme.mono(10.5))
                    .foregroundStyle(WS.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .background(Self.hunkColor.opacity(0.07))
        .overlay(alignment: .top) { Rectangle().fill(WS.border).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(WS.border).frame(height: 1) }
        .padding(.top, 6)
    }

    private func fileRow(_ row: UnifiedDiff.Row, first: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(NookTheme.font(11))
                .foregroundStyle(WS.secondary)
            Text(row.text)
                .font(NookTheme.mono(11.5, .semibold))
                .foregroundStyle(WS.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").font(NookTheme.font(10)).foregroundStyle(NookTheme.amber)
            Text(comment.text)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let onRemoveComment {
                Button { onRemoveComment(comment.id) } label: {
                    Image(systemName: "xmark").font(NookTheme.font(9, .bold)).foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(tr("ws.review.remove"))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.amber.opacity(0.08)))
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.leading, gutterWidth)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
    }

    private func editor(line: Int?, code: String) -> some View {
        HStack(spacing: 8) {
            TextField("", text: $commentDraft, prompt: Text(tr("ws.review.placeholder")).foregroundStyle(NookTheme.textTertiary),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...4)
                .onSubmit { save(line: line, code: code) }
                .onExitCommand { editing = nil }
            SmallGhostButton(title: tr("button.cancel")) { editing = nil }
            SmallGhostButton(title: tr("ws.review.save")) { save(line: line, code: code) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.field))
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.leading, gutterWidth)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
    }

    private func save(line: Int?, code: String) {
        let clean = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onComment?(line, code, clean)
        commentDraft = ""
        editing = nil
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(AgentPathFormat.duration(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }
}

extension WorkspaceRun {
    /// The models offered for the next turn: the agent's suggestions plus the one this session already uses.
    var modelChoices: [String] {
        var list = provider.suggestedModels
        if !model.isEmpty, !list.contains(model) { list.append(model) }
        return list
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
        Picker(tr("agents.run.model"), selection: Binding(get: { run.model }, set: { workspace.configure(run.id, model: $0) })) {
            ForEach(run.modelChoices, id: \.self) { model in
                Text(model.isEmpty ? tr("ws.model.default") : model).tag(model)
            }
        }
    }
}
