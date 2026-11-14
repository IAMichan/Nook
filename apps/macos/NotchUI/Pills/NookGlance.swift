import SwiftUI

// "Where things stand" on the empty Nook chat: what your agents are doing, what is next in your calendar, how full your
// plan limits are and what is playing, as quiet cards two by two. Each card opens the place it summarizes.

/// One agent session as the glance shows it: a Nook run or a session an agent reported through its hooks.
struct GlanceAgent: Identifiable, Equatable {
    enum State: Int, Comparable {
        case needsYou, working
        static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What `NotchViewModel.selectedAgentID` takes to open it: the session's id, or "run:<uuid>" for a Nook run.
    var id: String
    /// The agent's display name, for its logo ("Claude Code", "Codex").
    var agent: String
    var title: String
    var state: State
    var updated: Date

    /// Sessions that need you first, then the most recent.
    static func ordered(_ agents: [GlanceAgent]) -> [GlanceAgent] {
        agents.sorted { lhs, rhs in
            lhs.state != rhs.state ? lhs.state < rhs.state : lhs.updated > rhs.updated
        }
    }
}

/// The cards of the glance, two by two; a card with nothing to say leaves its place to the next.
struct HomeGlance: View {
    let openAgent: (String?) -> Void
    let openMusic: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HomeGlanceGrid(
            agents: agents, events: app.calendar.hasEventAccess ? todaysEvents : nil, limits: limits,
            track: app.nowPlaying.current, openAgent: openAgent,
            prepare: { app.handleUserText(tr("app.today.preparePrompt", $0.title)) },
            openLimits: { app.openUsageModal(.limits) }, openMusic: openMusic,
            playPause: { app.nowPlaying.control(.playPause) })
    }

    /// Nook's own runs that are busy, and the hooked sessions that are (`AppModel.activeAgents`).
    private var agents: [GlanceAgent] {
        let runs = app.workspace.runs.filter { !$0.archived && $0.status.isActive }.map { run in
            GlanceAgent(id: "run:" + run.id.uuidString, agent: run.provider.displayName,
                        title: run.title.isEmpty ? AgentFormat.title(run.task) : run.title,
                        state: run.status == .waitingApproval ? .needsYou : .working, updated: run.updatedAt)
        }
        let sessions = app.activeAgents.map { session in
            let title = AgentFormat.sessionTitle(session, known: nil)
            return GlanceAgent(id: session.id, agent: session.name, title: title.isEmpty ? session.project : title,
                               state: session.status == .waiting || session.approvalID != nil ? .needsYou : .working,
                               updated: session.updated ?? session.started ?? .distantPast)
        }
        return GlanceAgent.ordered(runs + sessions)
    }

    /// What is still to come today (or running now).
    private var todaysEvents: [CalEvent] {
        let now = Date()
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return app.upcoming.filter { $0.end > now && $0.start < endOfDay }
    }

    /// Per connected account, its fullest window: what you would run out of first.
    private var limits: [GlanceLimit] {
        let quota = app.quota
        return app.connectedProfiles.compactMap { profile in
            guard let fullest = quota.limits(for: profile).max(by: { UsageLimitRows.used($0) < UsageLimitRows.used($1) })
            else { return nil }
            let several = app.connectedProfiles.filter { $0.kind == profile.kind }.count > 1
            let name = several ? "\(profile.kind.shortName) · \(AccountLabel.name(profile, app: app))" : profile.kind.shortName
            return GlanceLimit(id: profile.id, agent: profile.kind.shortName, name: name, window: fullest.window,
                               used: UsageLimitRows.used(fullest))
        }
    }
}

/// The glance's cards from plain values, so it draws the same with sample data. `events` is nil without calendar access.
struct HomeGlanceGrid: View {
    let agents: [GlanceAgent]
    let events: [CalEvent]?
    let limits: [GlanceLimit]
    let track: NowPlayingInfo?
    let openAgent: (String?) -> Void
    let prepare: (CalEvent) -> Void
    let openLimits: () -> Void
    let openMusic: () -> Void
    let playPause: () -> Void

    private enum Card: Hashable { case agents, agenda, limits, music }

    /// The cards that have something to say, in their order.
    private var cards: [Card] {
        var cards: [Card] = [.agents]
        if events != nil { cards.append(.agenda) }
        if !limits.isEmpty { cards.append(.limits) }
        if track != nil { cards.append(.music) }
        return cards
    }

    /// Two cards per row, both as tall as the taller one; a last card on its own keeps half the width.
    var body: some View {
        let cards = cards
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { start in
                HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                    card(cards[start])
                    if start + 1 < cards.count {
                        card(cards[start + 1])
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func card(_ card: Card) -> some View {
        switch card {
        case .agents:
            GlanceAgentsCard(agents: agents, open: openAgent)
        case .agenda:
            GlanceAgendaCard(events: events ?? [], prepare: prepare)
        case .limits:
            GlanceLimitsCard(limits: limits, open: openLimits)
        case .music:
            if let track { GlanceMusicCard(track: track, open: openMusic, playPause: playPause) }
        }
    }
}

struct GlanceLimit: Identifiable {
    var id: String
    var agent: String
    var name: String
    var window: String
    var used: Int
}

// MARK: - Card

/// A glance card: a symbol and a title with a short status on the right, then its lines. The whole card is one button
/// that lifts under the pointer, as the starters under it do.
private struct GlanceCard<Content: View>: View {
    let symbol: String
    let title: String
    var status: String = ""
    var statusColor: Color = NookTheme.textTertiary
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: symbol)
                        .font(NookTheme.font(11, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 14)
                    Text(title)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if !status.isEmpty {
                        Text(status)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                    Image(icon: "chevron.right")
                        .font(NookTheme.font(9, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .opacity(hovering ? 1 : 0)
                }
                content()
            }
            .padding(NookTheme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .roundedBackground(hovering ? NookTheme.graphite : NookTheme.field, radius: NookTheme.Radius.panel)
            .roundedHitShape(NookTheme.Radius.panel)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// A quiet line for a card with nothing to list.
private struct GlanceEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agents

private struct GlanceAgentsCard: View {
    let agents: [GlanceAgent]
    let open: (String?) -> Void

    private var waiting: Int { agents.filter { $0.state == .needsYou }.count }
    private var working: Int { agents.count - waiting }

    private var status: String {
        var parts: [String] = []
        if waiting > 0 { parts.append(tr("home.glance.agents.needYou", waiting)) }
        if working > 0 { parts.append(tr("home.glance.agents.working", working)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        GlanceCard(symbol: "chevron.left.forwardslash.chevron.right", title: tr("tab.agents"), status: status,
                   statusColor: waiting > 0 ? NookTheme.amber : NookTheme.textTertiary,
                   action: { open(agents.first?.id) }) {
            if agents.isEmpty {
                GlanceEmptyLine(text: tr("home.glance.agents.quiet"))
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    ForEach(agents.prefix(3)) { agent in
                        HStack(spacing: NookTheme.Spacing.sm) {
                            AgentMark(agent: agent.agent, size: 14)
                            Text(agent.title)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textStrong)
                                .lineLimit(1)
                            Spacer(minLength: NookTheme.Spacing.xs)
                            Circle()
                                .fill(agent.state == .needsYou ? NookTheme.amber : NookTheme.iris)
                                .frame(width: 6, height: 6)
                                .help(agent.state == .needsYou ? tr("agents.status.waiting") : tr("agents.status.running"))
                        }
                    }
                    if agents.count > 3 {
                        Text(tr("home.glance.more", agents.count - 3))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Agenda

private struct GlanceAgendaCard: View {
    let events: [CalEvent]
    let prepare: (CalEvent) -> Void

    private var status: String {
        guard let next = events.first else { return "" }
        let now = Date()
        if next.start <= now { return tr("app.today.now") }
        return tr("home.glance.agenda.in", AgentFormat.compactDuration(next.start.timeIntervalSince(now)))
    }

    var body: some View {
        GlanceCard(symbol: "calendar", title: tr("home.glance.agenda"), status: status,
                   statusColor: events.first.map { $0.start <= Date() } == true ? NookTheme.mint : NookTheme.textTertiary,
                   action: { if let next = events.first { prepare(next) } }) {
            if events.isEmpty {
                GlanceEmptyLine(text: tr("home.glance.agenda.free"))
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    ForEach(Array(events.prefix(3).enumerated()), id: \.element.id) { index, event in
                        HStack(spacing: NookTheme.Spacing.sm) {
                            Capsule()
                                .fill(index == 0 ? NookTheme.iris : NookTheme.line2)
                                .frame(width: 3, height: 14)
                            Text(NookDates.time(event.start))
                                .font(NookTheme.mono(11, .medium))
                                .foregroundStyle(NookTheme.textSecondary)
                            Text(event.title)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textStrong)
                                .lineLimit(1)
                        }
                    }
                    if events.count > 3 {
                        Text(tr("home.glance.more", events.count - 3))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
            }
        }
        .help(events.first.map { tr("app.today.preparePrompt", $0.title) } ?? "")
    }
}

// MARK: - Limits

private struct GlanceLimitsCard: View {
    let limits: [GlanceLimit]
    let open: () -> Void

    var body: some View {
        let fullest = limits.map(\.used).max() ?? 0
        GlanceCard(symbol: "gauge.with.dots.needle.50percent", title: tr("home.glance.limits"),
                   status: UsageTone.level(used: fullest) == .calm ? "" : tr("home.glance.limits.high"),
                   statusColor: UsageTone.text(used: fullest), action: open) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                ForEach(limits.prefix(3)) { limit in
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            Text("\(limit.name) · \(limit.window)")
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textStrong)
                                .lineLimit(1)
                            Spacer(minLength: NookTheme.Spacing.xs)
                            Text("\(limit.used)%")
                                .font(NookTheme.mono(11, .medium))
                                .foregroundStyle(UsageTone.text(used: limit.used))
                        }
                        Bar(fraction: Double(limit.used) / 100, color: UsageTone.fill(used: limit.used, calm: NookTheme.textSecondary),
                            track: NookTheme.line, minFill: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Music

private struct GlanceMusicCard: View {
    let track: NowPlayingInfo
    let open: () -> Void
    let playPause: () -> Void

    var body: some View {
        GlanceCard(symbol: "music.note", title: tr("home.glance.music"),
                   status: track.isPlaying ? tr("home.glance.music.playing") : tr("home.glance.music.paused"),
                   statusColor: track.isPlaying ? NookTheme.mint : NookTheme.textTertiary, action: open) {
            HStack(spacing: NookTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(track.title)
                        .font(NookTheme.TextStyle.detail.weight(.medium))
                        .foregroundStyle(NookTheme.textStrong)
                        .lineLimit(1)
                    Text([track.artist, track.app].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.xs)
                NookIconButton(systemName: track.isPlaying ? "pause.fill" : "play.fill",
                               label: track.isPlaying ? tr("home.glance.music.pause") : tr("home.glance.music.play"),
                               size: 28, action: playPause)
            }
        }
    }
}
