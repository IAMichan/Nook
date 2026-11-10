import SwiftUI

// The Music tab's first page: what plays now as a card in its cover's colours, your week, a surprise, where you left off,
// your playlists and the artists you play most, each one click from playing.

struct MusicHomeView: View {
    let info: NowPlayingInfo?
    @ObservedObject var service: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject private var spotify = SpotifySignIn.shared
    let onOpen: (MusicSection) -> Void

    var body: some View {
        MusicHomeContent(info: info, service: service, lyrics: lyrics, spotifyConnected: spotify.isSignedIn, onOpen: onOpen)
    }
}

struct MusicHomeContent: View {
    let info: NowPlayingInfo?
    @ObservedObject var service: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @EnvironmentObject private var app: AppModel
    let spotifyConnected: Bool
    let onOpen: (MusicSection) -> Void
    @State private var week: MusicStats?
    @State private var allRecent = false
    @Environment(\.panelSidebar) private var sidebar

    private static let quickCount = 8

    /// Only for someone who has Spotify: Music needs no connection.
    private var showsConnect: Bool {
        !spotifyConnected && info?.app != "Music"
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: NowPlayingService.bundleID(of: "Spotify")) != nil
    }

    private var currentID: String? { info?.trackID }
    private var recent: [MusicTrack] { service.recent.tracks }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxxl) {
                if sidebar == nil {
                    // Beside another tab the band holds the tabs, so the greeting stands here.
                    Text(musicGreeting())
                        .font(NookTheme.TextStyle.display)
                        .foregroundStyle(NookTheme.paper)
                        .padding(.bottom, -NookTheme.Spacing.lg)
                }
                if let info {
                    MusicPlayingCard(info: info, service: service, lyrics: lyrics) { onOpen(.nowPlaying) }
                }
                if showsConnect { connectCard }
                weekRow
                if !recent.isEmpty { recentGroup }
                if !service.playlists.isEmpty { playlistsGroup }
                if let week, week.topArtists.count >= 3 { artistsGroup(week) }
                if recent.isEmpty, service.playlists.isEmpty, info == nil { emptyHint }
            }
            .padding(.horizontal, MusicLayout.edge)
            .padding(.bottom, NookTheme.Spacing.xl)
        }
        // The sums go over thousands of plays: off the main thread, and only when a play was added.
        .task(id: service.history.plays.count) {
            let plays = service.history.plays
            let stats = await Task.detached(priority: .utility) { MusicStats(plays: plays, period: .week) }.value
            if week != stats { week = stats }
        }
    }

    // MARK: Week and surprise

    /// Your week beside "Surprise me", each where there is something to show.
    @ViewBuilder
    private var weekRow: some View {
        let showsWeek = AppSettings.shared.musicHistory && (week.map { !$0.isEmpty } ?? false)
        let showsSurprise = !service.playlists.isEmpty
        if showsWeek || showsSurprise {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                    if showsWeek, let week { MusicWeekCard(stats: week) { onOpen(.stats) }.frame(minWidth: 440) }
                    if showsSurprise { MusicSurpriseCard(service: service).frame(minWidth: 220, maxWidth: showsWeek ? 320 : .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: NookTheme.Spacing.md) {
                    if showsWeek, let week { MusicWeekCard(stats: week) { onOpen(.stats) } }
                    if showsSurprise { MusicSurpriseCard(service: service) }
                }
            }
        }
    }

    /// Spotify's playlists, search and background playing need it connected: said once, where it helps.
    private var connectCard: some View {
        AdaptiveActionRow(spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.lg) {
                Image(icon: "link")
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(tr("music.home.connectTitle"))
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    Text(tr("music.home.connectDetail"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            SmallGhostButton(title: tr("music.playlists.openConnections")) { app.openSettings(section: .connections) }
        }
        .padding(NookTheme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.surface))
    }

    // MARK: Groups

    private var recentGroup: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            MusicGroupTitle(title: tr("music.home.continue"),
                            showAll: !allRecent && recent.count > Self.quickCount ? { withAnimation(NookTheme.reveal) { allRecent = true } } : nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: NookTheme.Spacing.md)], spacing: NookTheme.Spacing.md) {
                ForEach(Array(recent.prefix(allRecent ? recent.count : Self.quickCount).enumerated()), id: \.offset) { index, track in
                    MusicTrackTile(track: track, playing: track.id == currentID, filled: true,
                                   secondary: track.id.isEmpty ? nil : (tr("music.queue.add"), { service.enqueue(track) }), service: service) {
                        service.play(track, fromQueue: false, following: Array(recent.dropFirst(index + 1).prefix(SpotifyResponses.playTrackLimit - 1)))
                    }
                }
            }
        }
    }

    private var playlistsGroup: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            MusicGroupTitle(title: tr("music.home.yourPlaylists"), showAll: { onOpen(.playlists) })
            MusicCoverRow(items: service.playlists.prefix(12).map { playlist in
                MusicCoverItem(
                    id: playlist.id, title: playlist.name, subtitle: tr("music.playlists.count", playlist.trackCount),
                    artworkURL: playlist.artworkURL, symbol: "music.note.list", help: tr("music.playlists.play", playlist.name),
                    menu: [.init(symbol: "list.bullet", label: tr("music.playlists.open", playlist.name)) {
                        service.open(playlist)
                        onOpen(.playlists)
                    }]
                ) { service.play(playlist) }
            }, service: service)
        }
    }

    /// The artists you played most this week, round like a face; a click searches for them.
    private func artistsGroup(_ week: MusicStats) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            MusicGroupTitle(title: tr("music.home.artistsWeek"), showAll: { onOpen(.stats) })
            MusicCoverRow(items: week.topArtists.map { rank in
                MusicCoverItem(
                    id: rank.id, title: rank.name, subtitle: musicListeningTime(rank.seconds), artworkURL: rank.artworkURL,
                    symbol: "music.mic", help: tr("music.home.searchArtist", rank.name), hoverSymbol: "magnifyingglass", round: true
                ) {
                    service.search(for: rank.name)
                    onOpen(.search)
                }
            }, service: service)
        }
    }

    private var emptyHint: some View {
        MusicPlaceholder(symbol: "music.note", title: tr("music.nothingPlayingTitle"), detail: tr("music.home.emptyDetail")) {
            SmallGhostButton(title: tr("music.section.search")) { onOpen(.search) }
        }
        .frame(minHeight: 180)
    }
}

// MARK: Playing card

/// Home's first card: the playing track in its cover's colours, the line being sung, its controls, and what comes next.
/// The cover opens Now Playing.
private struct MusicPlayingCard: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    let onOpen: () -> Void
    @State private var hoveringCover = false

    private static let cover: CGFloat = 148

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: NookTheme.Spacing.xxl) {
                coverButton
                details
                upcoming.frame(width: 260)
            }
            .frame(minWidth: 720)
            HStack(alignment: .center, spacing: NookTheme.Spacing.xl) {
                coverButton
                details
            }
        }
        .padding(NookTheme.Spacing.xl)
        .background {
            shape
                .fill(NookTheme.surface)
                .overlay { MusicArtworkGlow(url: info.artworkURL, seed: info.title, opacity: 0.6, center: .topLeading, reach: 1.1) }
                .clipShape(shape)
                .overlay(shape.strokeBorder(NookTheme.paper.opacity(0.06), lineWidth: 1))
        }
        // The position shown here needs the player polled every couple of seconds, as under the bar.
        .onAppear { service.addViewer() }
        .onDisappear { service.removeViewer() }
    }

    private var coverButton: some View {
        Button(action: onOpen) {
            MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: NookTheme.Radius.panel)
                .frame(width: Self.cover, height: Self.cover)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
                .scaleEffect(hoveringCover ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hoveringCover = $0 }
        .animation(NookTheme.hover, value: hoveringCover)
        .help(tr("music.openNowPlaying"))
        .accessibilityLabel(tr("music.openNowPlaying"))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                EqualizerBars(color: NookTheme.music, height: 10, isPlaying: info.isPlaying)
                    .scaleEffect(0.8, anchor: .leading)
                    .frame(width: 22, alignment: .leading)
                Text(tr("music.playingIn", musicPlayerName(info)))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textStrong)
                    .lineLimit(1)
            }
            Text(info.title)
                .font(NookTheme.TextStyle.display)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .help(info.title)
                .padding(.top, NookTheme.Spacing.sm)
            Text(musicSubtitle(info))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textStrong)
                .lineLimit(1)
                .padding(.top, NookTheme.Spacing.xxs)
            MusicCurrentLyric(info: info, lyrics: lyrics)
                .padding(.top, NookTheme.Spacing.md)
            MusicScrubBar(info: info, style: .inline) { service.seek(to: $0) }
                .frame(maxWidth: 420)
                .padding(.top, NookTheme.Spacing.sm)
            HStack(spacing: NookTheme.Spacing.xs) {
                MusicTransport(info: info, service: service)
                MusicAddToPlaylistButton(track: service.currentTrack, service: service)
            }
            .padding(.top, NookTheme.Spacing.xs)
            .padding(.leading, -NookTheme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The next three: what Nook queued, then the player's own queue; Spotify without a connection shares no queue, so
    /// then what played before.
    private var upcoming: some View {
        let next = musicUpcoming(info: info, service: service)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(next.isQueue ? tr("music.section.upNext") : tr("music.recent.title"))
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textStrong)
                .padding(.bottom, NookTheme.Spacing.xs)
            if next.tracks.isEmpty {
                Text(next.isQueue ? tr("music.upNext.empty") : tr("music.recent.empty"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(Array(next.tracks.prefix(3).enumerated()), id: \.offset) { _, item in
                MusicTrackTile(track: item.track, queued: item.entry != nil, service: service) {
                    if let entry = item.entry { service.playFromQueue(entry) } else { service.play(item.track, fromQueue: info.app == "Music") }
                }
            }
        }
        .musicRowBleed()
    }
}

/// What comes after the playing track: Nook's own queue first, then the player's. Spotify only shares its queue once it is
/// connected in Settings; until then, with nothing queued, what played before (`isQueue` false).
@MainActor
func musicUpcoming(info: NowPlayingInfo, service: NowPlayingService) -> (isQueue: Bool, tracks: [(track: MusicTrack, entry: MusicPlayQueue.Entry.ID?)]) {
    let queued = service.playQueue.entries.map { (track: $0.track, entry: Optional($0.id)) }
    if let upNext = service.upNext { return (true, queued + upNext.tracks.map { (track: $0, entry: nil) }) }
    if info.app == "Music" || !queued.isEmpty { return (true, queued) }
    return (false, service.recent.tracks.filter { $0.id != info.trackID }.map { (track: $0, entry: nil) })
}

/// The line being sung now, in quotes, when the lyrics are synced; nothing otherwise. Redrawn only when the line changes.
private struct MusicCurrentLyric: View {
    let info: NowPlayingInfo
    @ObservedObject var lyrics: LyricsService

    var body: some View {
        if lyrics.trackKey == info.trackKey, case .found(let found) = lyrics.state, found.isSynced, !found.instrumental {
            TimelineView(.animation(minimumInterval: 0.5, paused: !info.isPlaying)) { context in
                let index = found.activeIndex(at: info.estimatedPosition(at: context.date) + 0.2)
                MusicLyricLine(text: index.map { found.lines[$0].text } ?? "")
                    .equatable()
            }
        }
    }
}

private struct MusicLyricLine: View, Equatable {
    let text: String

    var body: some View {
        Text(text.isEmpty ? "♪" : "\u{201C}\(text)\u{201D}")
            .font(NookTheme.TextStyle.body.italic())
            .foregroundStyle(NookTheme.paper.opacity(0.9))
            .lineLimit(1)
            .id(text)
            .transition(.opacity)
            .animation(NookTheme.reveal, value: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Week

/// Your week in one card: the time you listened and how it compares, a bar per day, and your streak. Opens Statistics.
private struct MusicWeekCard: View {
    let stats: MusicStats
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: NookTheme.Spacing.xxl) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    Text(tr("music.home.thisWeekTitle"))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                    Text(musicListeningTime(stats.seconds))
                        .font(NookTheme.rounded(22, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.paper)
                    if let change = stats.change, change != 0 {
                        Text(change > 0 ? tr("music.stats.up", change) : tr("music.stats.down", abs(change)))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(change > 0 ? NookTheme.mint : NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                days
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    Text(tr("music.stats.streak"))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                    Text(tr("music.stats.days", stats.streak))
                        .font(NookTheme.rounded(22, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.paper)
                    HStack(spacing: NookTheme.Spacing.xs) {
                        ForEach(0..<7, id: \.self) { day in
                            RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 2, style: .continuous)
                                .fill(day < stats.streak ? NookTheme.music : NookTheme.smoke)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .accessibilityHidden(true)
                }
                .fixedSize()
            }
            .padding(NookTheme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(shape.fill(hovering ? NookTheme.rowHover : NookTheme.surface))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.section.stats"))
        .accessibilityLabel(tr("music.home.thisWeek", musicListeningTime(stats.seconds)) + ", " + tr("music.stats.days", stats.streak))
    }

    /// A short bar per day, today's lit.
    private var days: some View {
        let buckets = Array(stats.buckets.suffix(7))
        let most = max(1, buckets.map(\.seconds).max() ?? 1)
        return HStack(alignment: .bottom, spacing: NookTheme.Spacing.sm) {
            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                let today = index == buckets.count - 1
                VStack(spacing: NookTheme.Spacing.xs) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: NookTheme.Radius.chip / 2, style: .continuous)
                        .fill(NookTheme.music.opacity(today ? 1 : 0.7))
                        .frame(height: max(3, 34 * CGFloat(bucket.seconds) / CGFloat(most)))
                        .frame(maxWidth: 16)
                    Text(NookDates.formatter("EEEEE", locale: NookDates.appLocale).string(from: bucket.start))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(today ? NookTheme.textStrong : NookTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: Surprise

/// One of your own playlists, picked at random and shuffled.
private struct MusicSurpriseCard: View {
    @ObservedObject var service: NowPlayingService
    @State private var picked: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("music.surprise.title"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Text(picked.map { tr("music.surprise.playing", $0) } ?? tr("music.surprise.detail"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            SmallPrimaryButton(title: picked == nil ? tr("music.surprise.play") : tr("music.surprise.again"), systemName: "shuffle") {
                surprise()
            }
        }
        .padding(NookTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            shape
                .fill(NookTheme.surface)
                .overlay(LinearGradient(colors: [NookTheme.violet.opacity(0.16), NookTheme.music.opacity(0.1), .clear],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(shape)
        }
    }

    /// Never the same playlist twice in a row while there are others.
    private func surprise() {
        let others = service.playlists.filter { $0.name != picked }
        guard let playlist = (others.isEmpty ? service.playlists : others).randomElement() else { return }
        service.play(playlist, shuffled: true)
        withAnimation(NookTheme.reveal) { picked = playlist.name }
    }
}

/// Covers side by side that fit the page exactly and scroll sideways a whole cover at a time, so none is cut off at the edge.
private struct MusicCoverRow: View {
    let items: [MusicCoverItem]
    let service: NowPlayingService

    private static let gap = NookTheme.Spacing.xl

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Self.gap) {
                ForEach(items) { item in
                    MusicCoverCard(item: item, service: service)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            // One cover in a very narrow pane, so it never gets smaller than intended.
                            let count = max(1, ((width + Self.gap) / (MusicLayout.cover + Self.gap)).rounded(.down))
                            return (width - Self.gap * (count - 1)) / count
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

/// A track in a small tile, where you left off and what comes next: cover and title, one click plays.
struct MusicTrackTile: View {
    let track: MusicTrack
    var playing = false
    /// A tile of its own on the page (Home's "Continue listening"), not a row in a list.
    var filled = false
    /// Queued in Nook: marked with the queue symbol.
    var queued = false
    /// Add to or remove from the queue, in the context menu.
    var secondary: (label: String, action: () -> Void)? = nil
    @ObservedObject var service: NowPlayingService
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.lg) {
                MusicArtwork(url: track.artworkURL, seed: track.title, cornerRadius: NookTheme.Radius.chip)
                    .frame(width: 44, height: 44)
                    .overlay { MusicArtworkState(hovering: hovering, playing: playing, isPlaying: service.current?.isPlaying ?? false) }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(track.title)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(playing ? NookTheme.music : NookTheme.paper)
                        .lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if queued {
                    Image(icon: "text.line.last.and.arrowtriangle.forward")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .help(tr("music.queue.queued"))
                        .accessibilityLabel(tr("music.queue.queued"))
                }
            }
            .padding(.horizontal, MusicLayout.rowBleed)
            .padding(.vertical, filled ? MusicLayout.rowBleed : NookTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                .fill(NookTheme.rowFill(selected: false, hovering: hovering, rest: filled ? NookTheme.surface : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.play"))
        .contextMenu {
            Button(tr("music.play"), action: action)
            if let secondary {
                Button(secondary.label, action: secondary.action)
            }
            MusicAddToPlaylistMenu(track: track, service: service)
        }
        .accessibilityLabel(track.artist.isEmpty ? track.title : "\(track.title), \(track.artist)")
        .accessibilityHint(tr("music.play"))
    }
}

/// Home's greeting, by the hour.
func musicGreeting() -> String {
    switch MusicListenerType(hour: Calendar.current.component(.hour, from: Date())) {
    case .morning: return tr("music.home.morning")
    case .afternoon: return tr("music.home.afternoon")
    case .evening: return tr("music.home.evening")
    case .night: return tr("music.home.night")
    }
}

/// Seconds as "12 h 40 min" or "35 min", in the app's language.
func musicListeningTime(_ seconds: Int) -> String {
    let minutes = seconds / 60
    return minutes >= 60 ? tr("music.stats.hours", minutes / 60, minutes % 60) : tr("music.stats.minutes", minutes)
}
