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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // The Mac's home: the date, quiet, over the greeting.
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textTertiary)
                Text(Self.greeting(for: Date()))
                    .font(Theme.TextStyle.heading)
                    .foregroundStyle(Theme.paper)
            }
            if calm {
                Label {
                    Text("All calm. Nothing needs you right now.").foregroundStyle(Theme.textSecondary)
                } icon: {
                    Image(icon: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                }
                .font(Theme.TextStyle.body)
                .transition(.opacity)
            } else {
                HStack(spacing: Theme.Spacing.md) {
                    if waiting > 0 {
                        OverviewTile(count: waiting, title: String(localized: "Waiting on you"),
                                     symbol: "hand.raised.fill", tint: Theme.amber, urgent: true) { open(.agents) }
                    }
                    if working > 0 {
                        OverviewTile(count: working, title: String(localized: "Working"),
                                     symbol: "circle.dotted", tint: Theme.blue) { open(.agents) }
                    }
                    if unread > 0 {
                        OverviewTile(count: unread, title: String(localized: "Unread chats"),
                                     symbol: "bubble.left.and.bubble.right.fill", tint: Theme.textSecondary) { open(.chats) }
                    }
                }
                .transition(.opacity)
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
                LinearGradient(colors: [tint.opacity(urgent ? 0.14 : 0.06), tint.opacity(0)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Theme.shape(Theme.Radius.panel)
            )
            .cardBackground(Theme.surface, stroke: urgent ? tint.opacity(0.35) : Theme.line2,
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

    private enum Row: Identifiable {
        case session(SessionDigest)
        case chat(InboxChatDigest)

        var id: String {
            switch self {
            case .session(let session): return "s:" + session.id
            case .chat(let chat): return "c:" + chat.id
            }
        }
        var date: Double {
            switch self {
            case .session(let session): return session.updated
            case .chat(let chat): return chat.last
            }
        }
    }

    private var rows: [Row] {
        let sessions = client.sessions.filter(SessionListView.needsYou).sorted { $0.updated > $1.updated }.map(Row.session)
        let chats = client.allows(.chats)
            ? client.inbox.filter { $0.unread > 0 }.sorted { $0.last > $1.last }.map(Row.chat) : []
        // What waits on you first: an agent stands still until you answer; a chat can wait.
        return Array((sessions + chats).prefix(6))
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
        }
    }
}
