import SwiftUI

// The calm overview on top of the Nook tab: what needs you across your agents and your chats, in one glance, so the first
// screen you open says where your attention is wanted before you go looking. A tap goes to that tab.

/// A soft light behind Nook's mark, so he sits in his own glow on a welcome or an empty screen.
struct NookAura: View {
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Theme.iris.opacity(0.22), Theme.iris.opacity(0.06), Theme.iris.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A greeting for the time of day, and under it what waits on you, what works, and what is unread as tiles that open
/// their tab. When nothing asks for you it says so in one quiet line instead.
struct AttentionOverview: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var router: TabRouter

    private var waiting: Int { client.sessions.filter(SessionListView.needsYou).count }
    private var working: Int {
        client.sessions.count(where: { !SessionListView.needsYou($0) && $0.attention == "working" })
    }
    private var unread: Int { client.allows(.chats) ? client.inbox.count(where: { $0.unread > 0 }) : 0 }
    private var calm: Bool { waiting == 0 && working == 0 && unread == 0 }
    /// The Mac's own "For you" rows (`HomeDigest.lines`), which the greeting counts as the Mac's does.
    private var macLines: Int? { client.home.map { min($0.lines.count, ForYouCard.limit) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // The Mac's home: the date, quiet, over the greeting.
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textTertiary)
                Text(macLines.map { Self.greeting(for: Date(), counting: $0) } ?? Self.greeting(for: Date()))
                    .font(Theme.TextStyle.heading)
                    .foregroundStyle(Theme.paper)
            }
            if calm, macLines ?? 0 == 0 {
                Label {
                    Text("All calm. Nothing needs you right now.").foregroundStyle(Theme.textSecondary)
                } icon: {
                    Image(icon: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                }
                .font(Theme.TextStyle.body)
                .transition(.opacity)
            } else {
                if !calm {
                    HStack(spacing: Theme.Spacing.md) {
                    // In the Agents list's order: what happens, then what is left for you.
                    if working > 0 {
                        OverviewTile(count: working, title: String(localized: "Working"),
                                     symbol: "circle.dotted", tint: Theme.blue) { open(.agents) }
                    }
                    if waiting > 0 {
                        OverviewTile(count: waiting, title: String(localized: "Waiting on you"),
                                     symbol: "hand.raised.fill", tint: Theme.amber, urgent: true) { open(.agents) }
                    }
                    if unread > 0 {
                        OverviewTile(count: unread, title: String(localized: "Unread chats"),
                                     symbol: "bubble.left.and.bubble.right.fill", tint: Theme.textSecondary) { open(.chats) }
                    }
                    }
                    .transition(.opacity)
                }
                ForYouCard()
                    .transition(.opacity)
            }
        }
        .padding(.top, Theme.Spacing.md)
        .animation(Theme.reveal, value: [waiting, working, unread])
    }

    private func open(_ tab: CompanionTab) {
        Haptics.tap()
        withAnimation(Theme.reveal) { router.tab = tab }
    }

    /// Morning, afternoon, evening, and a gentle word late at night.
    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return String(localized: "Good morning")
        case 12..<18: return String(localized: "Good afternoon")
        case 18..<23: return String(localized: "Good evening")
        default: return String(localized: "Working late?")
        }
    }

    /// The Mac's greeting, which says how much is there for you ("Good morning. Two things for you.").
    static func greeting(for date: Date, counting count: Int) -> String {
        let salutation: String
        switch Calendar.current.component(.hour, from: date) {
        case 0..<6: salutation = String(localized: "Good night")
        case 6..<12: salutation = String(localized: "Good morning")
        case 12..<18: salutation = String(localized: "Good afternoon")
        default: salutation = String(localized: "Good evening")
        }
        switch count {
        case 0: return String(localized: "\(salutation). Nothing waiting for you.")
        case 1: return String(localized: "\(salutation). One thing for you.")
        default: return String(localized: "\(salutation). \(count) things for you.")
        }
    }
}

/// One number of the overview: how many, in what, with the state's color on its mark only; a tile that waits on you
/// gets a faint edge and glow in that color, as a notice does.
private struct OverviewTile: View {
    let count: Int
    let title: String
    let symbol: String
    let tint: Color
    var urgent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: 0) {
                    Image(icon: symbol)
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(tint)
                    Spacer(minLength: Theme.Spacing.sm)
                    Image(icon: "chevron.right")
                        .font(Theme.font(10, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(count, format: .number)
                    .font(Theme.rounded(26, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.paper)
                    .contentTransition(.numericText())
                Text(title)
                    .font(Theme.TextStyle.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [tint.opacity(urgent ? 0.08 : 0.04), tint.opacity(0)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Theme.shape(Theme.Radius.panel)
            )
            .cardBackground(Theme.surface, stroke: urgent ? tint.opacity(0.22) : Theme.line2,
                            radius: Theme.Radius.panel)
            .roundedHitShape(Theme.Radius.panel)
        }
        .buttonStyle(PressFade())
        .accessibilityElement(children: .combine)
    }
}

/// "For you", as on the Mac's home: the sessions that wait on you and the chats with something unread, by name, in one
/// card, so you go straight to the one thing instead of to a list first. At most six; the tiles above count the rest.
struct ForYouCard: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var router: TabRouter

    /// The most rows the card shows, as on the Mac.
    static let limit = 6

    private enum Row: Identifiable {
        case session(SessionDigest)
        case chat(InboxChatDigest)
        /// One of the Mac's own rows (`HomeDigest.Line`): an agent that waits, the next meeting, a connection.
        case mac(HomeDigest.Line)

        var id: String {
            switch self {
            case .session(let session): return "s:" + session.id
            case .chat(let chat): return "c:" + chat.id
            case .mac(let line): return "m:" + line.id
            }
        }
    }

    private var rows: [Row] {
        // With the Mac's home: its own rows, as its Nook tab shows them.
        if let home = client.home { return Array(home.lines.prefix(Self.limit).map(Row.mac)) }
        let sessions = client.sessions.filter(SessionListView.needsYou).sorted { $0.updated > $1.updated }.map(Row.session)
        let chats = client.allows(.chats)
            ? client.inbox.filter { $0.unread > 0 }.sorted { $0.last > $1.last }.map(Row.chat) : []
        // What waits on you first: an agent stands still until you answer; a chat can wait.
        return Array((sessions + chats).prefix(Self.limit))
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("For you")
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textTertiary)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 52) }
                        Button { open(row) } label: { label(row) }
                            .buttonStyle(RowPress())
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                .cardBackground(Theme.surface, stroke: Theme.line2, radius: Theme.Radius.panel)
            }
        }
    }

    @ViewBuilder
    private func label(_ row: Row) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            switch row {
            case .session(let session):
                HomeLogo(content: .agent(session.agent), size: 32)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(verbatim: session.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                    Text(verbatim: session.items.first?.title ?? session.folder)
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.sm)
                StatusPill(attention: session.items.first.map { $0.kind == .approval ? "approval" : "input" } ?? session.attention,
                           short: true)
            case .chat(let chat):
                InboxAvatar(name: chat.name, app: chat.app, size: 32, picture: nil)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(verbatim: chat.name).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                    Text(verbatim: chat.preview).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Text(chat.unread, format: .number)
                    .font(Theme.TextStyle.caption).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(Theme.paper))
            case .mac(let line):
                HomeLogo(content: Self.logo(line.icon), tint: Self.tint(line.tone), size: 32)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(verbatim: line.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                    if !line.subtitle.isEmpty {
                        Text(verbatim: line.subtitle).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .contentShape(Rectangle())
    }

    private func open(_ row: Row) {
        Haptics.tap()
        switch row {
        case .session(let session): client.openSession = session.id
        case .chat(let chat): router.openChat = chat.id
        case .mac(let line):
            // An agent's row opens Agents; a session that waits is there on top.
            if line.icon.hasPrefix("agent:") { withAnimation(Theme.reveal) { router.tab = .agents } }
        }
    }

    /// The row's icon as the Mac names it: "agent:<name>", "symbol:<SF Symbol>" or "source:<connection>".
    private static func logo(_ icon: String) -> HomeLogo.Content {
        if icon.hasPrefix("agent:") { return .agent(String(icon.dropFirst(6))) }
        if icon.hasPrefix("symbol:") { return .symbol(String(icon.dropFirst(7))) }
        return .symbol("link")
    }

    /// The state colors keep their meaning; anything else is Nook's own iris.
    private static func tint(_ tone: String) -> Color {
        switch tone {
        case "amber": return Theme.amber
        case "mint": return Theme.mint
        case "coral": return Theme.coral
        default: return Theme.iris
        }
    }
}
