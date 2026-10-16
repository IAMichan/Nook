import SwiftUI

/// The mark of a coding agent, drawn in code so every agent has one without image assets: Claude's spark, Codex's
/// prompt, Gemini's star, Antigravity's arch, and a letter for the rest.
struct AgentLogo: View {
    /// The agent's display name, as the rest of the app uses it ("Claude Code", "Codex", "Antigravity").
    let agent: String
    var size: CGFloat = 16

    init(agent: String, size: CGFloat = 16) {
        self.agent = agent
        self.size = size
    }

    init(_ kind: AgentKind, size: CGFloat = 16) {
        self.agent = kind.name
        self.size = size
    }

    private enum Style {
        case claude, codex, gemini, antigravity
        case letter(String, Color)
    }

    private var style: Style {
        let name = agent.lowercased()
        if name.contains("claude") { return .claude }
        if name.contains("codex") { return .codex }
        if name.contains("antigravity") { return .antigravity }
        if name.contains("gemini") { return .gemini }
        let palette = [NookTheme.iris, NookTheme.mint, NookTheme.amber, NookTheme.coral, Color(hex: 0x8AB4F8)]
        let index = abs(agent.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return .letter(String(agent.prefix(1)).uppercased(), palette[index])
    }

    var body: some View {
        logo
            .frame(width: size, height: size)
            .accessibilityLabel(agent)
    }

    @ViewBuilder
    private var logo: some View {
        let corner = size * 0.28
        switch style {
        case .claude:
            ClaudeSpark()
                .stroke(Color(hex: 0xD97757), style: StrokeStyle(lineWidth: max(1.4, size * 0.12), lineCap: .round))
                .padding(size * 0.06)
        case .codex:
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8FA8FF), Color(hex: 0x3B46C8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    PromptGlyph()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: max(1, size * 0.08), lineCap: .round, lineJoin: .round))
                        .padding(size * 0.27)
                )
        case .gemini:
            GeminiStar()
                .fill(LinearGradient(colors: [Color(hex: 0x4F8BF7), Color(hex: 0x9B72F2)], startPoint: .bottomLeading, endPoint: .topTrailing))
        case .antigravity:
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(hex: 0x17171B))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(Color(hex: 0x2A2A30), lineWidth: 0.5))
                .overlay(
                    ArchGlyph()
                        .stroke(LinearGradient(colors: [Color(hex: 0x4F8BF7), Color(hex: 0xEA4335), Color(hex: 0xFBBC04)],
                                               startPoint: .bottomLeading, endPoint: .topTrailing),
                                style: StrokeStyle(lineWidth: max(1, size * 0.09), lineCap: .round, lineJoin: .round))
                        .padding(size * 0.22)
                )
        case .letter(let letter, let color):
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(color.opacity(0.2))
                .overlay(
                    Text(letter)
                        .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                )
        }
    }
}

/// Eight rays from the center.
private struct ClaudeSpark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for step in 0..<4 {
            let angle = Double(step) * .pi / 4
            let reach = step % 2 == 0 ? radius : radius * 0.82
            let dx = CGFloat(cos(angle)) * reach
            let dy = CGFloat(sin(angle)) * reach
            path.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            path.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
        }
        return path
    }
}

/// ">_"
private struct PromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.12))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.maxY - rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.05))
        return path
    }
}

/// A four-pointed star with curved sides.
private struct GeminiStar: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: center)
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: center)
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: center)
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: center)
        path.closeSubpath()
        return path
    }
}

/// An "A" without its point cut off: two legs and a bar.
private struct ArchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.26, y: rect.minY + rect.height * 0.66))
        return path
    }
}

/// Whether an account is someone's own or their employer's.
enum AccountKind {
    case personal, work

    private static let workWords = ["werk", "work", "zakelijk", "business", "bedrijf", "company", "team", "kantoor", "office", "arbeit", "firma"]

    /// Work when the account belongs to an organization, or when you named it that way ("Werk", "Business");
    /// otherwise personal.
    @MainActor
    static func of(_ profile: AgentProfile, app: AppModel) -> AccountKind {
        if let organization = app.history.profileAccounts[profile.id]?.organization, !organization.isEmpty { return .work }
        let label = profile.label.lowercased()
        if workWords.contains(where: { label.contains($0) }) { return .work }
        return .personal
    }

    var label: String { tr(self == .work ? "agents.account.work" : "agents.account.personal") }
}

/// A small round badge: a person for a personal account, a briefcase for a work account.
struct AccountBadge: View {
    let kind: AccountKind
    var size: CGFloat = 10
    /// The color behind the badge, drawn as a thin ring so it stands free of the logo.
    var ring: Color = Color(hex: 0x09090A)

    var body: some View {
        Circle()
            .fill(kind == .work ? Color(hex: 0x3D58D6) : Color(hex: 0x3A3A42))
            .overlay(
                Image(systemName: kind == .work ? "briefcase.fill" : "person.fill")
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
            )
            .frame(width: size, height: size)
            .overlay(Circle().stroke(ring, lineWidth: 1.5))
            .help(kind.label)
            .accessibilityLabel(kind.label)
    }
}

/// An agent's logo with the badge of the account it runs under.
struct AgentMark: View {
    let agent: String
    var account: AccountKind?
    var size: CGFloat = 16
    var dimmed = false
    var ring: Color = Color(hex: 0x09090A)

    var body: some View {
        AgentLogo(agent: agent, size: size)
            .opacity(dimmed ? 0.5 : 1)
            .overlay(alignment: .bottomTrailing) {
                if let account {
                    AccountBadge(kind: account, size: max(8, size * 0.56), ring: ring)
                        .offset(x: size * 0.28, y: size * 0.22)
                }
            }
            .help(account.map { "\(agent) · \($0.label)" } ?? agent)
    }
}
