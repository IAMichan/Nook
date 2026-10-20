import SwiftUI

/// Nook's home on the iPhone, as the empty notch is on the Mac: the day and a greeting, what needs you (answered right
/// here), the rows of "For you", the agenda, what plays, your limits, and where to start a chat.
struct TodayView: View {
    @EnvironmentObject private var client: CompanionClient
    let openChat: (String) -> Void
    let openUsage: () -> Void

    private var home: HomeDigest? { client.home }
    private var waiting: [SessionDigest] {
        client.sessions.filter(SessionListView.needsYou).sorted { $0.updated > $1.updated }
    }
    private var working: Int { client.sessions.filter { $0.attention == "working" }.count }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header
                ConnectionLine()
                if !client.can(CompanionFeature.home), client.phase == .connected {
                    Banner(text: String(localized: "Update Nook on your Mac to see your day, music and usage here."), symbol: "arrow.down.circle")
                }
                HStack(spacing: Theme.Spacing.sm) {
                    OverviewTile(count: waiting.count, title: "Needs you", symbol: "hand.raised.fill", color: Theme.amber, highlight: true)
                    OverviewTile(count: working, title: "Working", symbol: "bolt.fill", color: Theme.iris)
                    OverviewTile(count: home?.events.count ?? 0, title: "Agenda", symbol: "calendar", color: Theme.mint)
                }
                if !waiting.isEmpty {
                    SectionHeader(title: "Needs you", count: waiting.count, color: Theme.amber)
                    ForEach(waiting.prefix(3)) { SessionCard(session: $0) }
                }
                if let home {
                    if !home.lines.isEmpty {
                        SectionHeader(title: "For you")
                        ForYouCard(lines: home.lines)
                    }
                    if !home.events.isEmpty {
                        SectionHeader(title: "Agenda")
                        AgendaCard(events: home.events)
                    }
                    if let track = home.track {
                        SectionHeader(title: "Now playing")
                        NowPlayingCard(track: track, read: client.homeRead)
                    }
                    if home.accounts.contains(where: { !$0.limits.isEmpty }) {
                        SectionHeader(title: "Limits")
                        LimitsGlance(accounts: home.accounts, open: openUsage)
                    }
                    if !home.suggestions.isEmpty, client.can(CompanionFeature.chat) {
                        SectionHeader(title: "Start with")
                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(home.suggestions, id: \.self) { suggestion in
                                SuggestionRow(text: suggestion) { openChat(suggestion) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .refreshable { await client.loadHome() }
        .navigationDestination(for: String.self) { id in SessionDetailView(sessionID: id) }
        .toolbar(.hidden, for: .navigationBar)
        .screen()
        .task {
            while !Task.isCancelled {
                await client.loadHome()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
            Text(Self.greeting()).font(.largeTitle.weight(.bold)).foregroundStyle(Theme.text)
            Group {
                if waiting.isEmpty {
                    Text("All quiet. Here is your day.")
                } else {
                    Text("\(waiting.count) sessions wait for you")
                }
            }
            .font(.callout).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, Theme.Spacing.xl)
    }

    private static func greeting() -> String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<6: return String(localized: "Good night")
        case 6..<12: return String(localized: "Good morning")
        case 12..<18: return String(localized: "Good afternoon")
        default: return String(localized: "Good evening")
        }
    }
}

// MARK: For you

private struct ForYouCard: View {
    let lines: [HomeDigest.Line]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 52) }
                HStack(spacing: Theme.Spacing.md) {
                    LineIcon(icon: line.icon, tone: line.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                        if !line.subtitle.isEmpty {
                            Text(line.subtitle).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
        .card(padding: Theme.Spacing.md)
    }
}

/// The icon of a "For you" row: an agent's mark, a connection's symbol, or Nook's own symbol, in the row's color.
private struct LineIcon: View {
    let icon: String
    let tone: String

    var body: some View {
        let parts = icon.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        if kind == "agent" {
            AgentIcon(agent: value, size: 36)
        } else {
            let color = Self.color(tone)
            Image(systemName: kind == "source" ? Self.sourceSymbol(value) : (value.isEmpty ? "circle.fill" : value))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    static func color(_ tone: String) -> Color {
        switch tone {
        case "amber": return Theme.amber
        case "coral": return Theme.coral
        case "mint": return Theme.mint
        default: return Theme.iris
        }
    }

    static func sourceSymbol(_ id: String) -> String {
        switch id {
        case "calendar": return "calendar"
        case "mail": return "envelope.fill"
        case "reminders": return "checklist"
        case "notes": return "note.text"
        case "github", "gitlab": return "chevron.left.forwardslash.chevron.right"
        case "whatsapp", "messages": return "message.fill"
        case "music": return "music.note"
        case "weather": return "cloud.sun.fill"
        default: return "square.grid.2x2.fill"
        }
    }
}

// MARK: Agenda

private struct AgendaCard: View {
    let events: [HomeDigest.Event]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 64) }
                EventRow(event: event).padding(.vertical, Theme.Spacing.sm)
            }
        }
        .card(padding: Theme.Spacing.md)
    }
}

private struct EventRow: View {
    let event: HomeDigest.Event

    private var start: Date { Date(timeIntervalSince1970: event.start) }
    private var end: Date { Date(timeIntervalSince1970: event.end) }
    private var now: Bool { start <= .now && end > .now }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(start, format: .dateTime.hour().minute()).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(now ? Theme.mint : Theme.text)
                Text(end, format: .dateTime.hour().minute()).font(.caption2).monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 48, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(now ? Theme.mint : Theme.iris).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    if now {
                        Text("Now").font(.caption2.weight(.bold)).foregroundStyle(Theme.canvas)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.mint, in: Capsule())
                    }
                }
                let detail = [event.location, event.calendar].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                if !Calendar.current.isDateInToday(start) {
                    Text(start, format: .dateTime.weekday(.wide)).font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Now playing

/// What plays on the Mac, with the player's three buttons. The position runs on between two readings.
private struct NowPlayingCard: View {
    @EnvironmentObject private var client: CompanionClient
    let track: HomeDigest.Track
    let read: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(LinearGradient(colors: [Color(hex: 0xFF8A5B), Theme.coral], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    Text([track.artist, track.app].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let position = min(track.duration, track.position + (track.playing ? context.date.timeIntervalSince(read) : 0))
                    VStack(spacing: 4) {
                        ProgressView(value: position, total: track.duration).tint(Theme.text)
                        HStack {
                            Text(Self.time(position))
                            Spacer()
                            Text(Self.time(track.duration))
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            HStack(spacing: 36) {
                Spacer()
                control("backward.fill", "previous", label: "Previous track")
                Button { press("playpause") } label: {
                    Image(systemName: track.playing ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold)).foregroundStyle(Theme.canvas)
                        .frame(width: 56, height: 56).background(Theme.text, in: Circle())
                }
                .accessibilityLabel(track.playing ? "Pause" : "Play")
                control("forward.fill", "next", label: "Next track")
                Spacer()
            }
        }
        .card()
    }

    private func control(_ symbol: String, _ command: String, label: LocalizedStringKey) -> some View {
        Button { press(command) } label: {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.text).frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }

    private func press(_ command: String) {
        Haptics.tap()
        Task { await client.music(command) }
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: Limits and starters

/// The highest window of each account, one line each; the whole card opens Usage.
private struct LimitsGlance: View {
    let accounts: [UsageDigest.Account]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(spacing: Theme.Spacing.md) {
                ForEach(accounts.filter { !$0.limits.isEmpty }) { account in
                    let top = account.limits.max { $0.percent < $1.percent }
                    HStack(spacing: Theme.Spacing.md) {
                        AgentIcon(agent: account.agent, size: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(account.agent).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                Text(account.account).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                Spacer()
                                if let top {
                                    Text(verbatim: "\(Int(top.percent.rounded()))%").font(.subheadline.weight(.bold)).monospacedDigit()
                                        .foregroundStyle(UsageTone.text(top.percent))
                                }
                            }
                            if let top {
                                UsageBar(fraction: top.percent / 100, color: UsageTone.fill(top.percent, agent: account.agent), pace: top.pace())
                            }
                        }
                    }
                }
                HStack {
                    Text("All usage").font(.footnote.weight(.semibold)).foregroundStyle(Theme.iris)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.iris)
                }
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}

struct SuggestionRow: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "sparkles").font(.footnote.weight(.semibold)).foregroundStyle(Theme.iris)
                Text(text).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}
