import SwiftUI

// The Mac's home on the Nook tab (`HomeDigest`, `CompanionOp.home`): "At a glance" with the agenda, the plan limits and
// what plays, as cards side by side that scroll sideways on a phone, and "Start with", the Mac's own starters. The
// agents card of the Mac is the overview's tiles above it.

/// The glance's cards, in the Mac's order (`HomeGlanceGrid`); a card with nothing to say leaves its place to the next.
struct HomeGlanceRow: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var router: TabRouter
    let home: HomeDigest
    /// A new chat that opens with this question (an event's "prepare me").
    let ask: (String) -> Void

    private var today: [HomeDigest.Event] {
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600).timeIntervalSince1970
        return home.events.filter { $0.start < end }
    }

    var body: some View {
        if !home.events.isEmpty || !home.accounts.isEmpty || home.track != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("At a glance")
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        if !home.events.isEmpty { agenda }
                        if home.accounts.contains(where: { !$0.limits.isEmpty }) { limits }
                        if let track = home.track { HomeMusicCard(track: track) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .scrollClipDisabled()
            }
        }
    }

    private var agenda: some View {
        let events = today.isEmpty ? Array(home.events.prefix(2)) : Array(today.prefix(3))
        return GlanceCard(symbol: "calendar", title: String(localized: "Agenda"),
                          status: today.isEmpty ? "" : String(localized: "\(today.count) today")) {
            ForEach(events) { event in
                Button {
                    Haptics.tap()
                    ask(String(localized: "Prepare me for \(event.title)"))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                        Text(Date(timeIntervalSince1970: event.start), format: .dateTime.hour().minute())
                            .font(Theme.TextStyle.detail).monospacedDigit().foregroundStyle(Theme.textSecondary)
                        Text(verbatim: event.title)
                            .font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressFade())
                .accessibilityHint("Asks Nook to prepare you for it")
            }
        }
    }

    /// Per account its fullest window, as the Mac's limits card: what you would run out of first.
    private var limits: some View {
        let rows = home.accounts.compactMap { account in
            account.limits.max { $0.percent < $1.percent }.map { (account, $0) }
        }
        let several = Dictionary(grouping: home.accounts, by: \.agent).filter { $0.value.count > 1 }.keys
        return Button {
            Haptics.tap()
            router.sheet = .settings
        } label: {
            GlanceCard(symbol: "gauge.with.dots.needle.50percent", title: String(localized: "Limits")) {
                ForEach(rows.prefix(3), id: \.0.id) { account, limit in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(verbatim: several.contains(account.agent) ? "\(account.agent) · \(account.account)" : account.agent)
                                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textStrong).lineLimit(1)
                            Spacer(minLength: Theme.Spacing.sm)
                            Text(verbatim: "\(Int(limit.percent.rounded()))%")
                                .font(Theme.TextStyle.caption).monospacedDigit()
                                .foregroundStyle(limit.percent >= 80 ? Theme.amber : Theme.textSecondary)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.smoke)
                                Capsule().fill(limit.percent >= 80 ? Theme.amber : Theme.iris)
                                    .frame(width: proxy.size.width * min(1, max(0, limit.percent / 100)))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
        .buttonStyle(PressFade())
        .accessibilityHint("Opens Settings with your usage")
    }
}

/// What plays on the Mac, with its buttons when this phone may use them (`CompanionScope.music`).
private struct HomeMusicCard: View {
    @EnvironmentObject private var client: CompanionClient
    let track: HomeDigest.Track

    var body: some View {
        GlanceCard(symbol: "music.note", title: track.app.isEmpty ? String(localized: "Now playing") : track.app,
                   status: track.playing ? String(localized: "Playing") : String(localized: "Paused")) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(verbatim: track.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                Text(verbatim: track.artist).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            if client.controlsMusic {
                HStack(spacing: Theme.Spacing.lg) {
                    control("backward.fill", label: "Previous track", command: "previous")
                    control(track.playing ? "pause.fill" : "play.fill", label: track.playing ? "Pause" : "Play", command: "playpause")
                    control("forward.fill", label: "Next track", command: "next")
                }
            }
        }
    }

    private func control(_ symbol: String, label: LocalizedStringKey, command: String) -> some View {
        Button {
            Haptics.tap()
            Task { await client.music(command) }
        } label: {
            Image(icon: symbol)
                .font(Theme.font(14, .semibold))
                .foregroundStyle(Theme.paper)
                .frame(width: 44, height: 36)
                .roundedBackground(Theme.smoke, radius: Theme.Radius.control)
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

/// A glance card, the Mac's `GlanceCard`: a symbol and a title with a short status on the right, then its lines.
private struct GlanceCard<Content: View>: View {
    let symbol: String
    let title: String
    var status: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(icon: symbol)
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14)
                Text(verbatim: title)
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.sm)
                if !status.isEmpty {
                    Text(verbatim: status).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 236, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .roundedBackground(Theme.field, radius: Theme.Radius.panel)
        .roundedHitShape(Theme.Radius.panel)
    }
}

/// "Start with": the Mac's starters (`HomeDigest.suggestions`), two per row.
struct HomeStarters: View {
    let suggestions: [String]
    let ask: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Start with")
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textTertiary)
                SuggestionGrid(suggestions: suggestions, ask: ask)
            }
        }
    }
}
