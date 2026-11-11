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
        client.sessions.filter { !SessionListView.needsYou($0) && $0.attention == "working" }.count
    }
    private var unread: Int { client.allows(.chats) ? client.inbox.filter { $0.unread > 0 }.count : 0 }
    private var calm: Bool { waiting == 0 && working == 0 && unread == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(Self.greeting(for: Date()))
                .font(Theme.TextStyle.heading)
                .foregroundStyle(Theme.paper)
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
