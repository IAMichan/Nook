import SwiftUI

/// Workspace colors. Dark theme consistent with Nook; color always represents state.
enum WS {
    static let background = Color(hex: 0x111115)
    static let surface = Color(hex: 0x17171C)
    static let raised = Color(hex: 0x1D1D23)
    static let border = Color(hex: 0x2A2A33)
    static let subtle = Color(hex: 0x22222A)
    static let text = NookTheme.paper
    static let secondary = NookTheme.textSecondary
    static let tertiary = NookTheme.textTertiary
    static let code = Color(hex: 0x0C0C10)
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
    func help(for provider: RunProvider) -> String { tr("ws.permission." + rawValue + ".help." + provider.rawValue) }
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

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
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

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    Text(line.isEmpty ? " " : line)
                        .font(NookTheme.mono(11.5))
                        .foregroundStyle(color(line))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .background(WS.code)
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

/// Mode, permissions and model for the next turn of a session Nook runs. Only while the agent is idle.
struct NextTurnSettings: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let run: WorkspaceRun

    var body: some View {
        let idle = !run.status.isActive
        let capabilities = run.provider.capabilities
        Picker(tr("agents.run.mode"), selection: Binding(get: { run.mode }, set: { workspace.configure(run.id, mode: $0) })) {
            ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
        }
        .disabled(!idle || !capabilities.planMode)
        Picker(tr("agents.run.permission"), selection: Binding(get: { run.permission }, set: { workspace.configure(run.id, permission: $0) })) {
            ForEach(capabilities.policies) { Text($0.label).tag($0) }
        }
        .disabled(!idle)
        Picker(tr("agents.run.model"), selection: Binding(get: { run.model }, set: { workspace.configure(run.id, model: $0) })) {
            ForEach(run.modelChoices, id: \.self) { model in
                Text(model.isEmpty ? tr("ws.model.default") : model).tag(model)
            }
        }
        .disabled(!idle)
    }
}
