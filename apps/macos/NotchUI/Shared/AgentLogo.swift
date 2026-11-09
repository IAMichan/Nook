import SwiftUI

// Shared with the iPhone (apps/ios/project.yml): an agent's logo looks the same in both apps.

/// The mark of a coding agent, drawn in code so every agent has one without image assets: the real brand marks where we
/// have them (Claude, OpenAI for Codex, Gemini, …), Antigravity's arch, and a letter for the rest.
struct AgentLogo: View {
    /// The agent's display name, as the rest of the app uses it ("Claude Code", "Codex", "Antigravity").
    let agent: String
    var size: CGFloat = 16

    init(agent: String, size: CGFloat = 16) {
        self.agent = agent
        self.size = size
    }

    private enum Style {
        case brand(BrandLogo)
        case antigravity
        case letter(String, Color)
    }

    private var style: Style {
        let name = agent.lowercased()
        if name.contains("antigravity") { return .antigravity }
        if let brand = BrandLogo.forName(name) { return .brand(brand) }
        let palette = [NookTheme.iris, NookTheme.mint, NookTheme.amber, NookTheme.coral, NookTheme.blue]
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
        case .brand(let logo):
            BrandMark(logo: logo, size: size)
        case .antigravity:
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(hex: 0x17171B))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(NookTheme.line2, lineWidth: 0.5))
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
                        .font(NookTheme.rounded(size * 0.52, .bold))
                        .foregroundStyle(color)
                )
        }
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

/// An account's badge: whether it is someone's own or their employer's, or a bare API key (paid per question), and the
/// color and name you gave it, so several accounts of one agent are told apart at a glance.
struct AccountTag: Hashable {
    enum Role: Hashable { case personal, work, apiKey }

    var role: Role
    /// The account's own color (0xRRGGBB, `AgentProfile.accent`); nil keeps the role's color and symbol.
    var accent: UInt32? = nil
    /// The account's name ("Work", "Acme"), for the letter on a colored badge and its tooltip.
    var name: String = ""
    /// The account's own icon (an SF Symbol name, `AgentProfile.icon`), drawn centered on the badge instead of the letter.
    var icon: String? = nil

    static let personal = AccountTag(role: .personal)
    static let work = AccountTag(role: .work)
    static let apiKey = AccountTag(role: .apiKey)

    fileprivate static let workWords = ["werk", "work", "zakelijk", "business", "bedrijf", "company", "team", "kantoor", "office", "arbeit", "firma"]

    /// The colors offered for an account in Settings › Agents, each with the name VoiceOver reads.
    static let swatches: [(hex: UInt32, name: String)] = [
        (0x8B7BFF, "settings.accent.violet"), (0x5AA9FF, "settings.accent.blue"), (0x5ED6A6, "settings.accent.mint"),
        (0xF2B866, "settings.accent.amber"), (0xEF7B73, "settings.accent.coral"), (0xFF7EB6, "settings.accent.pink"),
    ]

    /// The icons offered for an account in Settings › Agents, each with the name VoiceOver reads.
    static let symbols: [(symbol: String, name: String)] = [
        ("person.fill", "accounts.icon.person"), ("briefcase.fill", "accounts.icon.briefcase"),
        ("house.fill", "accounts.icon.home"), ("building.2.fill", "accounts.icon.building"),
        ("star.fill", "accounts.icon.star"), ("heart.fill", "accounts.icon.heart"),
        ("bolt.fill", "accounts.icon.bolt"), ("flame.fill", "accounts.icon.flame"),
        ("leaf.fill", "accounts.icon.leaf"), ("globe", "accounts.icon.globe"),
        ("graduationcap.fill", "accounts.icon.school"), ("flask.fill", "accounts.icon.lab"),
        ("hammer.fill", "accounts.icon.tools"), ("terminal.fill", "accounts.icon.terminal"),
        ("cloud.fill", "accounts.icon.cloud"), ("lock.fill", "accounts.icon.lock"),
        ("key.fill", "accounts.icon.key"), ("sparkles", "accounts.icon.sparkles"),
    ]

    /// An account color as SwiftUI draws it; the one place a stored account color becomes a `Color`.
    static func color(_ hex: UInt32) -> Color { Color(hex: hex) }

    var label: String {
        if !name.isEmpty { return name }
        switch role {
        case .personal: return sharedText("agents.account.personal", "Personal account")
        case .work: return sharedText("agents.account.work", "Work account")
        case .apiKey: return sharedText("accounts.method.apiKey", "API key")
        }
    }

    /// The first letter of the account's name, shown on a colored badge instead of the role's symbol.
    fileprivate var initial: String? {
        guard accent != nil, icon == nil, let letter = name.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(letter).uppercased()
    }

    fileprivate var symbol: String {
        if let icon { return icon }
        switch role {
        case .personal: return "person.fill"
        case .work: return "briefcase.fill"
        case .apiKey: return "key.fill"
        }
    }

    fileprivate var fill: Color {
        if let accent { return Color(hex: accent) }
        switch role {
        case .personal: return Color(hex: 0x3A3A42)
        case .work: return Color(hex: 0x3D58D6)
        case .apiKey: return Color(hex: 0x9A6F1C)
        }
    }

    /// Black or white, whichever reads better on the badge's color.
    fileprivate var glyph: Color {
        if let accent, NookTheme.relativeLuminance(accent) > 0.45 { return NookTheme.ink.opacity(0.9) }
        return Color.white.opacity(0.92)
    }
}

/// A small round badge: a person for a personal account, a briefcase for a work account, a key for an API key; an account
/// you gave a color shows that color with the first letter of its name, and one you gave an icon shows that icon.
/// The letter or icon sits in the middle of the circle.
struct AccountBadge: View {
    let kind: AccountTag
    var size: CGFloat = 10
    /// The color behind the badge, drawn as a thin ring so it stands free of the logo.
    var ring: Color = NookTheme.rowRest

    var body: some View {
        Circle()
            .fill(kind.fill)
            .overlay {
                Group {
                    if let initial = kind.initial {
                        Text(initial)
                            .font(NookTheme.rounded(size * 0.62, .bold))
                            .minimumScaleFactor(0.5)
                    } else {
                        // Scaled to fit a square inside the circle, so wide and tall symbols alike stay in the middle.
                        // The margin around it is a whole point on each side: a fractional one is rounded to the pixel
                        // grid on one side only, which pushes the icon left on the small badges (an agent row's 8 pt).
                        Image(systemName: kind.symbol)
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.bold)
                            .frame(width: glyphSide, height: glyphSide)
                    }
                }
                .foregroundStyle(kind.glyph)
                .frame(width: size, height: size, alignment: .center)
            }
            .frame(width: size, height: size)
            .overlay(Circle().stroke(ring, lineWidth: 1.5))
            .help(kind.label)
            .accessibilityLabel(kind.label)
    }

    /// The icon's side: about 54% of the badge, with the same whole-point margin left and right, top and bottom.
    private var glyphSide: CGFloat { max(1, size - 2 * (size * 0.23).rounded()) }
}

/// An agent's logo with the badge of the account it runs under.
struct AgentMark: View {
    let agent: String
    var account: AccountTag?
    var size: CGFloat = 16
    var dimmed = false
    var ring: Color = NookTheme.rowRest
    /// Grey at rest, as a row's icon: the brand color comes back under the pointer or when selected.
    var quiet = false

    var body: some View {
        AgentLogo(agent: agent, size: size)
            .saturation(quiet ? 0 : 1)
            .opacity(dimmed ? 0.5 : (quiet ? 0.6 : 1))
            .animation(NookTheme.hover, value: quiet)
            .accountBadge(account, size: size, ring: ring)
            .help(account.map { "\(agent) · \($0.label)" } ?? agent)
    }
}

extension View {
    /// Pins the account badge to the bottom-right corner of a logo of the given size.
    func accountBadge(_ account: AccountTag?, size: CGFloat, ring: Color) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let account {
                // Whole points for its size and place, so the badge and the icon in it land on the pixel grid
                // and the icon stays centered at every logo size.
                AccountBadge(kind: account, size: max(8, (size * 0.56).rounded()), ring: ring)
                    .offset(x: (size * 0.28).rounded(), y: (size * 0.22).rounded())
            }
        }
    }
}

#if os(macOS)
extension AgentLogo {
    init(_ kind: AgentKind, size: CGFloat = 16) {
        self.init(agent: kind.name, size: size)
    }
}

extension AccountTag {
    /// Work when the account belongs to an organization, or when you named it that way ("Werk", "Business");
    /// otherwise personal. Carries the color, icon and name you gave the account (Settings › Agents).
    @MainActor
    static func of(_ profile: AgentProfile, app: AppModel) -> AccountTag {
        let organization = app.history.profileAccounts[profile.id]?.organization ?? ""
        let label = profile.label.lowercased()
        let role: Role = !organization.isEmpty || workWords.contains(where: { label.contains($0) }) ? .work : .personal
        // Only a colored badge shows the name; one without keeps "Work account" / "Personal account" as its tooltip.
        guard profile.hasOwnBadge else { return AccountTag(role: role) }
        let name = !profile.label.isEmpty ? profile.label : (!organization.isEmpty ? organization : tr("agents.personal"))
        return AccountTag(role: role, accent: profile.accent, name: name, icon: profile.icon)
    }
}
#endif
