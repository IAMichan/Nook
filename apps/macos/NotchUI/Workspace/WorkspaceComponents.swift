import SwiftUI

/// Workspace colors. A neutral, near-black dark theme in the manner of a code tool: surfaces lift by a few percent of
/// white, lines are faint white, and color always represents state.
enum WS {
    static let background = Color(hex: 0x0B0B0D)
    /// The sidebar and the inspector: the canvas lifted a little.
    static let sidebar = Color(hex: 0x121214)
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
        case .renamed, .copied: return Color(hex: 0x8AB4F8)
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
                .font(.system(size: compact ? 9 : 10, weight: .bold))
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

/// Compact tinted badge: agent, model, account.
struct Chip: View {
    let text: String
    var color: Color = WS.secondary
    var systemImage: String?
    /// Shows this agent's logo in front of the text.
    var agent: AgentKind?

    var body: some View {
        HStack(spacing: 4) {
            if let agent {
                AgentLogo(agent, size: 12)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9.5, weight: .semibold))
            }
            Text(text).lineLimit(1)
        }
        .font(NookTheme.font(11.5, .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(WS.subtle))
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
                .font(.system(size: 26, weight: .light))
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

/// Syntax-colored diff view. Performant for large diffs using LazyVStack.
struct DiffText: View {
    let text: String
    /// Review comments on this file: shown under their line. With `onComment`, hovering a line
    /// offers a comment button.
    var comments: [ReviewComment] = []
    var onComment: ((_ line: Int?, _ code: String, _ text: String) -> Void)? = nil
    var onRemoveComment: ((UUID) -> Void)? = nil
    @State private var hovered: Int?
    @State private var editing: Int?
    @State private var commentDraft = ""

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let numbers = ReviewComments.newLineNumbers(lines)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    let commentable = onComment != nil && (line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" "))
                        && !line.hasPrefix("+++") && !line.hasPrefix("---")
                    HStack(spacing: 0) {
                        Text(line.isEmpty ? " " : line)
                            .font(NookTheme.mono(11.5))
                            .foregroundStyle(color(line))
                            .padding(.horizontal, 10)
                        Spacer(minLength: 0)
                        if commentable && hovered == index && editing != index {
                            Button {
                                commentDraft = ""
                                editing = index
                            } label: {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(NookTheme.paper)
                                    .padding(.horizontal, 6)
                            }
                            .buttonStyle(.plain)
                            .help(tr("ws.review.add"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line))
                    .onHover { inside in if inside { hovered = index } else if hovered == index { hovered = nil } }
                    ForEach(comments.filter { $0.code == line && $0.line == numbers[index] }) { comment in
                        commentRow(comment)
                    }
                    if editing == index {
                        editor(line: numbers[index], code: line)
                    }
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .background(WS.code)
    }

    private func commentRow(_ comment: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").font(.system(size: 10)).foregroundStyle(NookTheme.amber)
            Text(comment.text)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let onRemoveComment {
                Button { onRemoveComment(comment.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(tr("ws.review.remove"))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.amber.opacity(0.08)))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 520, alignment: .leading)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func save(line: Int?, code: String) {
        let clean = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onComment?(line, code, clean)
        commentDraft = ""
        editing = nil
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return WS.secondary }
        if line.hasPrefix("+") { return NookTheme.mintSoft }
        if line.hasPrefix("-") { return NookTheme.coralSoft }
        if line.hasPrefix("@@") { return Color(hex: 0x8AB4F8) }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return WS.tertiary }
        return Color(hex: 0xC9C7D2)
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return NookTheme.mint.opacity(0.07) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return NookTheme.coral.opacity(0.07) }
        return .clear
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
