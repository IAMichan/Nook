import SwiftUI

/// Nook's home on the iPhone, as the empty notch is on the Mac: the day and a greeting, what needs you (answered right
/// here), the rows of "For you", the agenda, what plays, your limits, and where to start a chat.
struct TodayView: View {
    @EnvironmentObject private var client: CompanionClient
    let openChat: (String) -> Void
    let openUsage: () -> Void
    /// The Agents tab with its New session sheet open.
    let newSession: () -> Void
    let openChats: () -> Void

    private var home: HomeDigest? { client.home }
    private var waiting: [SessionDigest] {
        client.sessions.filter(SessionListView.needsYou).sorted { $0.updated > $1.updated }
    }
    private var working: Int { client.sessions.filter { $0.attention == "working" }.count }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                ConnectionLine()
                // What you start from here, first: a session, a question to Nook, an answer in a chat.
                QuickActions(newSession: newSession, askNook: { openChat("") }, openChats: openChats)
                if !client.allows(.read), client.phase == .connected {
                    Banner(text: String(localized: "Seeing sessions and your day is turned off for this iPhone in Nook on your Mac."), symbol: "lock.fill")
                } else if !client.can(CompanionFeature.home), client.phase == .connected {
                    Banner(text: String(localized: "Update Nook on your Mac to see your day, music and usage here."), symbol: "arrow.down.circle")
                }
                if !waiting.isEmpty {
                    SectionHeader(title: "Needs you", count: waiting.count, urgent: true)
                    ForEach(waiting.prefix(3)) { SessionNotice(session: $0) }
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
                        SuggestionGrid(suggestions: home.suggestions) { openChat($0) }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
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
            NookMark(size: 44).padding(.bottom, Theme.Spacing.lg)
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Theme.TextStyle.label).foregroundStyle(Theme.textTertiary)
            Text(Self.greeting()).font(Theme.TextStyle.display).foregroundStyle(Theme.text)
            Group {
                if waiting.isEmpty {
                    Text("All quiet. Here is your day.")
                } else {
                    Text("\(waiting.count) sessions wait for you")
                }
            }
            .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xs)
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
        RowGroup {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { RowSeparator(inset: Theme.Spacing.xl + 34 + Theme.Spacing.lg) }
                TodayRow(line: line)
            }
        }
    }
}

/// A row of your day, the Mac's `TodayRow`: its icon (an agent's or a connection's own, with the row's color as a dot
/// on its corner; a symbol on a tile in that color), the title and one line under it.
private struct TodayRow: View {
    let line: HomeDigest.Line

    private var parts: (kind: String, value: String) {
        let split = line.icon.split(separator: ":", maxSplits: 1).map(String.init)
        return (split.first ?? "", split.count > 1 ? split[1] : "")
    }

    var body: some View {
        let tone = Self.color(line.tone)
        HStack(spacing: Theme.Spacing.lg) {
            Group {
                switch parts.kind {
                case "agent": HomeLogo(content: .agent(parts.value))
                case "source": HomeLogo(content: .symbol(Self.sourceSymbol(parts.value)), tint: Theme.textStrong)
                default: HomeLogo(content: .symbol(parts.value.isEmpty ? "circle.fill" : parts.value), tint: tone)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if parts.kind == "agent" || parts.kind == "source" {
                    Circle().fill(tone).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(line.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(2)
                if !line.subtitle.isEmpty {
                    Text(line.subtitle).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    static func color(_ tone: String) -> Color {
        switch tone {
        case "amber": return Theme.amber
        case "coral": return Theme.coral
        case "mint": return Theme.mint
        default: return Theme.blue
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
        RowGroup {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { RowSeparator(inset: Theme.Spacing.xl + 48 + Theme.Spacing.lg) }
                EventRow(event: event)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.lg)
            }
        }
    }
}

private struct EventRow: View {
    let event: HomeDigest.Event

    private var start: Date { Date(timeIntervalSince1970: event.start) }
    private var end: Date { Date(timeIntervalSince1970: event.end) }
    private var now: Bool { start <= .now && end > .now }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(start, format: .dateTime.hour().minute()).font(Theme.TextStyle.strong).monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text(end, format: .dateTime.hour().minute()).font(Theme.TextStyle.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 48, alignment: .leading)
            Capsule().fill(now ? Theme.mint : Theme.separator).frame(width: 3)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(event.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(2)
                let detail = [event.location, event.calendar].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                if now {
                    HStack(spacing: Theme.Spacing.xs) {
                        PulseDot(color: Theme.mint, size: 6)
                        Text("Now").font(Theme.TextStyle.label).foregroundStyle(Theme.text)
                    }
                } else if !Calendar.current.isDateInToday(start) {
                    Text(start, format: .dateTime.weekday(.wide)).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "music.note")
                    .font(Theme.font(20, .semibold)).foregroundStyle(Theme.textStrong)
                    .frame(width: 52, height: 52)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(track.title).font(Theme.TextStyle.title).foregroundStyle(Theme.text).lineLimit(1)
                    Text([track.artist, track.app].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let position = min(track.duration, track.position + (track.playing ? context.date.timeIntervalSince(read) : 0))
                    VStack(spacing: Theme.Spacing.xs) {
                        UsageBar(fraction: position / track.duration, color: Theme.text, height: 4)
                        HStack {
                            Text(Self.time(position))
                            Spacer()
                            Text(Self.time(track.duration))
                        }
                        .font(Theme.TextStyle.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            // The buttons only where the Mac takes them; the track itself is shown either way.
            if client.can(CompanionFeature.music) {
                HStack(spacing: 36) {
                    Spacer()
                    control("backward.fill", "previous", label: "Previous track")
                    Button { press("playpause") } label: {
                        Image(systemName: track.playing ? "pause.fill" : "play.fill")
                            .font(Theme.font(20, .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 52, height: 52).background(Theme.text, in: Circle())
                    }
                    .accessibilityLabel(playLabel)
                    control("forward.fill", "next", label: "Next track")
                    Spacer()
                }
            }
        }
        .card()
    }

    /// Typed, so both words go through the String Catalog.
    private var playLabel: LocalizedStringKey { track.playing ? "Pause" : "Play" }

    private func control(_ symbol: String, _ command: String, label: LocalizedStringKey) -> some View {
        Button { press(command) } label: {
            Image(systemName: symbol).font(Theme.font(18, .semibold)).foregroundStyle(Theme.text).frame(width: 44, height: 44)
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
            VStack(spacing: Theme.Spacing.xl) {
                ForEach(accounts.filter { !$0.limits.isEmpty }) { account in
                    let top = account.limits.max { $0.percent < $1.percent }
                    HStack(spacing: Theme.Spacing.lg) {
                        AgentIcon(agent: account.agent, size: 30)
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                                Text(account.agent).font(Theme.TextStyle.strong).foregroundStyle(Theme.text)
                                Text(account.account).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                Spacer()
                                if let top {
                                    Text(verbatim: "\(Int(top.percent.rounded()))%").font(Theme.TextStyle.strong).monospacedDigit()
                                        .foregroundStyle(UsageTone.text(top.percent))
                                }
                            }
                            if let top {
                                UsageBar(fraction: top.percent / 100, color: UsageTone.fill(top.percent), pace: top.pace())
                            }
                        }
                    }
                }
                HStack {
                    Text("All usage").font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textTertiary)
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
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "sparkles").font(Theme.font(14, .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 18)
                Text(text).font(Theme.TextStyle.body).foregroundStyle(Theme.textStrong).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Quick actions

/// Why the phone cannot do one of the three things it starts (a session, a question to Nook, an answer in a chat), in
/// words that say how to change it; nil when it can. An action the Mac does not allow stays in sight and says this when
/// tapped, so nothing you look for has quietly disappeared.
enum QuickActionBlock {
    @MainActor
    static func session(_ client: CompanionClient) -> String? {
        if !client.allows(.operate) { return String(localized: "Starting sessions is turned off for this iPhone in Nook on your Mac.") }
        if !client.can(CompanionFeature.start) { return String(localized: "This Mac cannot start sessions from the phone yet. Update Nook on your Mac.") }
        return nil
    }

    @MainActor
    static func nook(_ client: CompanionClient) -> String? {
        if !client.allows(.nookChat) { return String(localized: "Chatting with Nook is turned off for this iPhone in Nook on your Mac.") }
        if !client.can(CompanionFeature.chat) { return String(localized: "Update Nook on your Mac to chat with Nook from your phone.") }
        return nil
    }

    @MainActor
    static func chats(_ client: CompanionClient) -> String? {
        if !client.allows(.chats) { return String(localized: "Chats are turned off for this iPhone in Nook on your Mac.") }
        if !client.can(CompanionFeature.inbox) { return String(localized: "Update Nook on your Mac to read and answer your chats from your phone.") }
        return nil
    }
}

/// The three things you start from the phone, at the top of Today: a session with a coding agent, a question to Nook,
/// and an answer in one of your chats. Each shows what is going on there now (sessions at work, unread chats).
struct QuickActions: View {
    @EnvironmentObject private var client: CompanionClient
    let newSession: () -> Void
    let askNook: () -> Void
    let openChats: () -> Void

    var body: some View {
        let working = client.sessions.filter { $0.attention == "working" }.count
        HStack(spacing: Theme.Spacing.md) {
            QuickActionTile(symbol: "square.and.pencil", title: "New session",
                            detail: working > 0 ? String(localized: "\(working) working") : nil,
                            blocked: QuickActionBlock.session(client), action: newSession)
            QuickActionTile(symbol: "sparkles", title: "Ask Nook", detail: nil,
                            blocked: QuickActionBlock.nook(client), action: askNook)
            QuickActionTile(symbol: "bubble.left.and.bubble.right", title: "Answer a chat",
                            detail: client.inboxUnread > 0 ? String(localized: "\(client.inboxUnread) unread") : nil,
                            blocked: QuickActionBlock.chats(client), action: openChats)
        }
    }
}

/// One quick action: its symbol, what it does, and in quieter text what is going on there. Blocked, it is dimmed and a
/// tap says why instead.
private struct QuickActionTile: View {
    @EnvironmentObject private var client: CompanionClient
    let symbol: String
    let title: LocalizedStringKey
    let detail: String?
    let blocked: String?
    let action: () -> Void

    var body: some View {
        Button {
            if let blocked {
                client.notice = blocked
            } else {
                Haptics.tap()
                action()
            }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Image(systemName: blocked == nil ? symbol : "lock.fill")
                    .font(Theme.font(18, .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(height: 28, alignment: .leading)
                Spacer(minLength: Theme.Spacing.md)
                Text(title)
                    .font(Theme.TextStyle.strong)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail ?? " ")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .card(padding: Theme.Spacing.lg)
            .opacity(blocked == nil ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .accessibilityHint(blocked.map { Text($0) } ?? Text(""))
    }
}
