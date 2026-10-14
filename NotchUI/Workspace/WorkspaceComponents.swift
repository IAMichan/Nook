import SwiftUI

/// Kleuren van de werkruimte. Donker, zoals de rest van Nook; kleur betekent altijd een toestand.
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

/// "● Bezig" als klein label.
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

/// Klein label met een kleurtje: agent, model, account.
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

/// Een sectiekop in het zijpaneel of de inspector.
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

/// Label en waarde naast elkaar, voor de inspector. "Niet beschikbaar" staat er altijd expliciet.
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

/// Een lege toestand: rustig, met één duidelijke actie.
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

/// Een diff met kleuren per regel. Snel genoeg voor grote diffs dankzij LazyVStack.
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
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.unitsStyle = .abbreviated
        if Date().timeIntervalSince(date) < 45 { return tr("ws.justNow") }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

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

/// Telt mee terwijl een beurt loopt.
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(AgentPathFormat.duration(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }
}
