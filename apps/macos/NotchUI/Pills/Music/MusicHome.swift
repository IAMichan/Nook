import SwiftUI

// The Music tab's first page: where you left off, your playlists, and what you played most, one click from playing.

struct MusicHomeView: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var spotify = SpotifySignIn.shared
    let onOpen: (MusicSection) -> Void

    var body: some View {
        MusicHomeContent(service: service, spotifyConnected: spotify.isSignedIn, onOpen: onOpen)
    }
}

struct MusicHomeContent: View {
    @ObservedObject var service: NowPlayingService
    @EnvironmentObject private var app: AppModel
    let spotifyConnected: Bool
    let onOpen: (MusicSection) -> Void
    @State private var week: MusicStats?
    @State private var allRecent = false

    private static let quickCount = 6

    /// Only for someone who has Spotify: Music needs no connection.
    private var showsConnect: Bool {
        !spotifyConnected && service.current?.app != "Music"
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: NowPlayingService.bundleID(of: "Spotify")) != nil
    }

    private var currentID: String? { service.current?.trackID }
    private var recent: [MusicTrack] { service.recent.tracks }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxl) {
                header
                if showsConnect { connectCard }
                if !recent.isEmpty { recentGroup }
                if !service.playlists.isEmpty { playlistsGroup }
                if let week, week.topTracks.count >= 3 { topGroup(week) }
                if recent.isEmpty, service.playlists.isEmpty { emptyHint }
            }
            .padding(.horizontal, NookTheme.Spacing.xs)
            .padding(.bottom, NookTheme.Spacing.xl)
        }
        // The sums go over thousands of plays: off the main thread, and only when a play was added.
        .task(id: service.history.plays.count) {
            let plays = service.history.plays
            let stats = await Task.detached(priority: .utility) { MusicStats(plays: plays, period: .week) }.value
            if week != stats { week = stats }
        }
    }

    // MARK: Header

    private var header: some View {
        Button { onOpen(.stats) } label: {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(greeting)
                    .font(NookTheme.TextStyle.display)
                    .foregroundStyle(NookTheme.paper)
                if let week, !week.isEmpty {
                    Text(tr("music.home.thisWeek", musicListeningTime(week.seconds)))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("music.section.stats"))
    }

    private var greeting: String {
        switch MusicListenerType(hour: Calendar.current.component(.hour, from: Date())) {
        case .morning: return tr("music.home.morning")
        case .afternoon: return tr("music.home.afternoon")
        case .evening: return tr("music.home.evening")
        case .night: return tr("music.home.night")
        }
    }

    /// Spotify's playlists, search and background playing need it connected: said once, where it helps.
    private var connectCard: some View {
        AdaptiveActionRow(spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.lg) {
                Image(systemName: "link")
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.music)
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
            MusicGroupTitle(title: tr("music.recent.title"),
                            showAll: !allRecent && recent.count > Self.quickCount ? { allRecent = true } : nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: NookTheme.Spacing.md)], spacing: NookTheme.Spacing.md) {
                ForEach(Array(recent.prefix(allRecent ? recent.count : Self.quickCount).enumerated()), id: \.offset) { index, track in
                    MusicQuickTile(track: track, playing: track.id == currentID, service: service) {
                        service.play(track, fromQueue: false, following: Array(recent.dropFirst(index + 1).prefix(SpotifyResponses.playTrackLimit - 1)))
                    }
                }
            }
        }
    }

    private var playlistsGroup: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            MusicGroupTitle(title: tr("music.section.playlists"), showAll: { onOpen(.playlists) })
            MusicCoverRow(items: service.playlists.prefix(12).map { playlist in
                MusicCoverItem(
                    id: playlist.id, title: playlist.name, subtitle: tr("music.playlists.count", playlist.trackCount),
                    artworkURL: playlist.artworkURL, symbol: "music.note.list", help: tr("music.playlists.open", playlist.name),
                    hoverSymbol: "list.bullet",
                    secondary: .init(symbol: "play.fill", label: tr("music.playlists.play", playlist.name)) { service.play(playlist) }
                ) {
                    service.open(playlist)
                    onOpen(.playlists)
                }
            }, service: service)
        }
    }

    private func topGroup(_ week: MusicStats) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            MusicGroupTitle(title: tr("music.home.topWeek"), showAll: { onOpen(.stats) })
            MusicCoverRow(items: week.topTracks.map { rank in
                MusicCoverItem(
                    id: rank.id, title: rank.track.title, subtitle: rank.track.artist, artworkURL: rank.track.artworkURL,
                    help: tr("music.play"), secondary: .enqueue(rank.track, in: service), track: rank.track,
                    playing: rank.track.id == currentID
                ) { service.play(rank.track, fromQueue: false) }
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

/// Covers side by side, scrolling sideways.
private struct MusicCoverRow: View {
    let items: [MusicCoverItem]
    let service: NowPlayingService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
                ForEach(items) { MusicCoverCard(item: $0, service: service).frame(width: 124) }
            }
            // Room for the cover's lift and shadow.
            .padding(.top, NookTheme.Spacing.xs)
        }
    }
}

/// A small tile for where you left off: cover and title, one click plays.
private struct MusicQuickTile: View {
    let track: MusicTrack
    let playing: Bool
    @ObservedObject var service: NowPlayingService
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                MusicArtwork(url: track.artworkURL, seed: track.title, cornerRadius: NookTheme.Radius.chip)
                    .frame(width: 40, height: 40)
                    .overlay {
                        if hovering || playing {
                            ZStack {
                                RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(Color.black.opacity(0.5))
                                if hovering {
                                    Image(systemName: "play.fill").font(NookTheme.font(12, .bold)).foregroundStyle(NookTheme.paper)
                                } else {
                                    EqualizerBars(color: NookTheme.music, height: 10, isPlaying: service.current?.isPlaying ?? false)
                                        .scaleEffect(0.7)
                                }
                            }
                        }
                    }
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
            }
            .padding(NookTheme.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(hovering ? NookTheme.graphite : NookTheme.field))
            .contentShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.play"))
        .contextMenu {
            Button(tr("music.play"), action: action)
            Button(tr("music.queue.add")) { service.enqueue(track) }
            MusicAddToPlaylistMenu(track: track, service: service)
        }
        .accessibilityLabel(track.artist.isEmpty ? track.title : "\(track.title), \(track.artist)")
        .accessibilityHint(tr("music.play"))
    }
}

/// Seconds as "12 h 40 min" or "35 min", in the app's language.
func musicListeningTime(_ seconds: Int) -> String {
    let minutes = seconds / 60
    return minutes >= 60 ? tr("music.stats.hours", minutes / 60, minutes % 60) : tr("music.stats.minutes", minutes)
}
