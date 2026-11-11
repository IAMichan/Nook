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

    /// The colors of this agent's logo: its brand's colors, Antigravity's three, or the color of its letter. The glow
    /// over a browser it drives is drawn in them (`BrowserTakeoverOverlay`).
    static func colors(of agent: String) -> [Color] {
        switch AgentLogo(agent: agent).style {
        case .brand(let logo): return logo.palette
        case .antigravity: return antigravityColors
        case .letter(_, let color): return [color]
        }
    }

    private static let antigravityColors = [Color(hex: 0x4F8BF7), Color(hex: 0xEA4335), Color(hex: 0xFBBC04)]

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
            NookTheme.shape(corner)
                .fill(Color(hex: 0x17171B))
                .roundedStroke(NookTheme.line2, radius: corner, lineWidth: 0.5)
                .overlay(
                    ArchGlyph()
                        .stroke(LinearGradient(colors: Self.antigravityColors,
                                               startPoint: .bottomLeading, endPoint: .topTrailing),
                                style: StrokeStyle(lineWidth: max(1, size * 0.09), lineCap: .round, lineJoin: .round))
                        .padding(size * 0.22)
                )
        case .letter(let letter, let color):
            NookTheme.shape(corner)
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

    /// The account's initials writes them on its badge: two letters of a one-word name ("Work" → "WO"), the
    /// first letter of the first two words otherwise ("Acme Labs" → "AL"). Punctuation splits words ("Claude (hub)" → "CH");
    /// an apostrophe inside a word does not ("Theo's Work" → "TW").
    static func initials(_ name: String) -> String {
        let apostrophes: Set<Character> = ["'", "\u{2019}"]
        let spaced = String(name.map { $0.isPunctuation && !apostrophes.contains($0) ? " " : $0 })
        let words = spaced.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}")) }
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "" }
        if words.count == 1 { return String(first.prefix(2)).uppercased() }
        return words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    /// The letters on the badge: the account's initials, unless you gave it an icon.
    fileprivate var letters: String? {
        guard icon == nil else { return nil }
        let letters = Self.initials(name)
        return letters.isEmpty ? nil : letters
    }

    fileprivate var symbol: String {
        if let icon { return icon }
        switch role {
        case .personal: return "person.fill"
        case .work: return "briefcase.fill"
        case .apiKey: return "key.fill"
        }
    }

    /// The account's own color, or a quiet grey card a badge without one.
    fileprivate var fill: Color {
        if let accent { return Color(hex: accent) }
        if letters != nil { return NookTheme.smoke }
        switch role {
        case .personal: return Color(hex: 0x3A3A42)
        case .work: return Color(hex: 0x3D58D6)
        case .apiKey: return Color(hex: 0x9A6F1C)
        }
    }

    /// Black or white, whichever reads better on the badge's color; the muted text color on the grey card.
    fileprivate var glyph: Color {
        if let accent, NookTheme.relativeLuminance(accent) > 0.45 { return NookTheme.ink.opacity(0.9) }
        if accent == nil, letters != nil { return NookTheme.textSecondary }
        return Color.white.opacity(0.92)
    }
}

/// A small badge in the corner of an agent's logo marks a model of another account: the account's initials on
/// a grey card ("WO" for Work), on the account's own color when you gave it one, or the icon you gave it. A badge with two
/// letters grows into a pill; one letter or an icon stays round. Without a name it falls back to the role's symbol
/// (a person, a briefcase, a key).
struct AccountBadge: View {
    let kind: AccountTag
    var size: CGFloat = 10
    /// The color behind the badge, drawn as a thin ring so it stands free of the logo.
    var ring: Color = NookTheme.rowRest

    var body: some View {
        Group {
            if let letters = kind.letters {
                Text(letters)
                    .font(NookTheme.rounded(size * (letters.count > 1 ? 0.56 : 0.62), .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, letters.count > 1 ? max(1, (size * 0.18).rounded()) : 0)
                    .frame(minWidth: size, minHeight: size, maxHeight: size)
            } else {
                // Scaled to fit a square inside the circle, so wide and tall symbols alike stay in the middle.
                // The margin around it is a whole point on each side: a fractional one is rounded to the pixel
                // grid on one side only, which pushes the icon left on the small badges (an agent row's 8 pt).
                Image(icon: kind.symbol)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.bold)
                    .frame(width: glyphSide, height: glyphSide)
                    .frame(width: size, height: size)
            }
        }
        .foregroundStyle(kind.glyph)
        .background(NookTheme.shape(NookTheme.Radius.chip).fill(kind.fill))
        .overlay(NookTheme.shape(NookTheme.Radius.chip).stroke(ring, lineWidth: 1.5))
        .fixedSize()
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
                AccountBadge(kind: account, size: max(9, (size * 0.62).rounded()), ring: ring)
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
    /// otherwise personal. Carries the account's name (for its initials), and the color and icon you gave it
    /// (Settings › Agents).
    @MainActor
    static func of(_ profile: AgentProfile, app: AppModel) -> AccountTag {
        let organization = app.history.profileAccounts[profile.id]?.organization ?? ""
        let label = profile.label.lowercased()
        let role: Role = !organization.isEmpty || workWords.contains(where: { label.contains($0) }) ? .work : .personal
        return AccountTag(role: role, accent: profile.accent, name: AccountLabel.name(profile, app: app), icon: profile.icon)
    }

    /// The badge on the agent's logo where it runs under `profile`, or nil when there is nothing to tell apart. As in
    ///: an account you gave a color or an icon always shows its badge; otherwise only while you have more than
    /// one account of that agent, so the model picker and the timeline say which account a model belongs to.
    @MainActor
    static func badge(_ profile: AgentProfile?, app: AppModel) -> AccountTag? {
        guard let profile, !app.demoMode else { return nil }
        guard profile.hasOwnBadge || sharesAgent(profile, app: app) else { return nil }
        return of(profile, app: app)
    }

    /// True when another signed-in account of the same agent is on, so a badge is needed to tell the two apart. An
    /// account switched off still counts for itself, so an old session of it keeps its badge.
    @MainActor
    static func sharesAgent(_ profile: AgentProfile, app: AppModel) -> Bool {
        app.linkedProfiles.filter { $0.kind == profile.kind && ($0.isEnabled || $0.id == profile.id) }.count > 1
    }
}
#endif
