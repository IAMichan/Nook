import SwiftUI

// Now Playing: the playing track as the whole page. The cover large with its colours glowing behind it, the track and
// its controls under it, and beside it one card with the lyrics, what comes next and a little about the track.

/// The tabs of the card beside the player.
enum MusicNowPlayingTab: String, CaseIterable, Identifiable {
    case lyrics, upNext, about
    var id: String { rawValue }

    static let storageKey = "musicNowPlayingTab"

    var title: String {
        switch self {
        case .lyrics: return tr("music.section.lyrics")
        case .upNext: return tr("music.section.upNext")
        case .about: return tr("music.about.title")
        }
    }
}

struct MusicNowPlayingView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @AppStorage(MusicNowPlayingTab.storageKey) private var storedTab = MusicNowPlayingTab.lyrics.rawValue
    @ObservedObject private var outputs = MusicOutputService.shared
    @State private var width: Double = 0

    /// Side by side from this width; under each other below it.
    private static let sideBySide: Double = 720
    private var tab: MusicNowPlayingTab { MusicNowPlayingTab(rawValue: storedTab) ?? .lyrics }
    private var wide: Bool { width == 0 || width >= Self.sideBySide }

    var body: some View {
        GeometryReader { geo in
            Group {
                if wide {
                    HStack(alignment: .top, spacing: NookTheme.Spacing.xxxl) {
                        player(cover: min(320, geo.size.width * 0.34, max(140, geo.size.height - 250)))
                            .frame(width: min(320, geo.size.width * 0.34))
                        card
                    }
                } else {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                        HStack(alignment: .top, spacing: NookTheme.Spacing.xl) {
                            cover(side: min(132, geo.size.width * 0.3))
                            details
                        }
                        card
                    }
                }
            }
            .padding(.horizontal, MusicLayout.edge)
            .padding(.bottom, NookTheme.Spacing.lg)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background {
            // The cover's colours over the whole page, brightest behind the cover.
            MusicArtworkGlow(url: info.artworkURL, seed: info.title, opacity: 0.5,
                             center: wide ? UnitPoint(x: 0.2, y: 0.3) : UnitPoint(x: 0.15, y: 0.1), reach: 0.7)
        }
        .onLayoutWidthChange { width = $0 }
        // The position and volume shown here need the player polled every couple of seconds, as under the bar.
        .onAppear { service.addViewer() }
        .onDisappear { service.removeViewer() }
    }

    // MARK: Player

    private func player(cover side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
            cover(side: side)
            details
        }
    }

    private func cover(side: CGFloat) -> some View {
        MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: NookTheme.Radius.sheet)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            .scaleEffect(info.isPlaying ? 1 : 0.95)
            .animation(NookTheme.open, value: info.isPlaying)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                EqualizerBars(color: NookTheme.music, height: 10, isPlaying: info.isPlaying)
                    .scaleEffect(0.8, anchor: .leading)
                    .frame(width: 22, alignment: .leading)
                Text(tr("music.playingIn", musicPlayerName(info)))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.md)
                MusicAddToPlaylistButton(track: service.currentTrack, service: service, size: 28)
                NookIconButton(systemName: "arrow.up.forward.app", label: tr("music.openPlayer", musicPlayerName(info)), size: 28) {
                    openMusicPlayer(info)
                }
            }
            Text(info.title)
                .font(NookTheme.TextStyle.display)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(info.title)
                .padding(.top, NookTheme.Spacing.md)
            Text(musicSubtitle(info))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textStrong)
                .lineLimit(1)
                .padding(.top, NookTheme.Spacing.xs)
            MusicScrubBar(info: info, style: .stacked) { service.seek(to: $0) }
                .padding(.top, NookTheme.Spacing.xl)
            ViewThatFits(in: .horizontal) {
                MusicTransport(info: info, service: service, large: true)
                MusicTransport(info: info, service: service)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, NookTheme.Spacing.md)
            // Where it plays beside how loud: the two things one changes about the sound.
            HStack(spacing: NookTheme.Spacing.md) {
                MusicOutputButton(info: info, outputs: outputs)
                if let volume = info.volume {
                    MusicVolumeControl(volume: volume, width: 110) { service.setVolume($0) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, NookTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Card

    private var card: some View {
        let shape = NookTheme.shape(NookTheme.Radius.sheet)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                NookTabBar(items: MusicNowPlayingTab.allCases.map { .init(value: $0, title: $0.title) },
                           selected: tab, onSelect: { picked in withAnimation(NookTheme.swap) { storedTab = picked.rawValue } },
                           segmented: true)
                Spacer(minLength: NookTheme.Spacing.md)
                if tab == .lyrics, let source = MusicLyricsView.source(of: lyrics, for: info) {
                    Text(source)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.top, NookTheme.Spacing.lg)
            Group {
                switch tab {
                case .lyrics: MusicLyricsView(info: info, lyrics: lyrics) { service.seek(to: $0) }
                case .upNext: MusicUpNextView(info: info, service: service)
                case .about: MusicTrackAbout(info: info, service: service)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(NookTheme.surface.opacity(0.78)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(NookTheme.border, lineWidth: 1))
    }
}

// MARK: About

/// A little about the playing track from Nook's own history: how often you played it, since when, and how much of its
/// artist you listen to.
private struct MusicTrackAbout: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    @State private var facts: Facts?

    struct Facts: Equatable {
        var plays = 0
        var playsThisWeek = 0
        var firstPlayed: Date?
        var artistSeconds = 0
        var artistRank: Int?
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                if let facts {
                    if facts.plays == 0 {
                        fact("sparkle", title: tr("music.about.firstTime"), detail: tr("music.about.firstTimeDetail"))
                    } else {
                        fact("repeat", title: tr("music.about.plays", facts.plays),
                             detail: tr("music.about.playsThisWeek", facts.playsThisWeek))
                    }
                    if let first = facts.firstPlayed {
                        fact("calendar", title: NookDates.formatter("d MMMM yyyy", locale: NookDates.appLocale).string(from: first),
                             detail: tr("music.about.firstPlayed"))
                    }
                    if !info.artist.isEmpty, facts.artistSeconds > 0 {
                        fact("music.mic", title: info.artist,
                             detail: facts.artistRank.map { tr("music.about.artistRank", $0, musicListeningTime(facts.artistSeconds)) }
                                ?? tr("music.about.artistTime", musicListeningTime(facts.artistSeconds)))
                    }
                }
                chips
            }
            .padding(NookTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: info.trackKey) {
            let plays = service.history.plays
            let title = info.title, artist = info.artist
            facts = await Task.detached(priority: .utility) { Self.facts(plays: plays, title: title, artist: artist) }.value
        }
    }

    private var chips: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if !info.album.isEmpty { chip(info.album) }
            if info.duration > 0 { chip(musicClock(Double(info.duration))) }
            chip(musicPlayerName(info))
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textStrong)
            .lineLimit(1)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.xs)
            .background(NookTheme.shape(NookTheme.Radius.chip).strokeBorder(NookTheme.separator, lineWidth: 1))
    }

    private func fact(_ symbol: String, title: String, detail: String) -> some View {
        MusicFactRow(symbol: symbol, title: title, detail: detail)
    }

    nonisolated static func facts(plays: [MusicPlay], title: String, artist: String, now: Date = Date()) -> Facts {
        var facts = Facts()
        let weekStart = MusicStatsPeriod.week.start(now: now, calendar: .current) ?? now
        var artists: [String: Int] = [:]
        for play in plays {
            if !play.artist.isEmpty { artists[play.artist, default: 0] += play.listened }
            guard play.title == title, play.artist == artist else { continue }
            facts.plays += 1
            if play.playedAt >= weekStart { facts.playsThisWeek += 1 }
            if facts.firstPlayed == nil { facts.firstPlayed = play.playedAt }
        }
        facts.artistSeconds = artists[artist] ?? 0
        if facts.artistSeconds > 0 {
            let rank = artists.values.count(where: { $0 > facts.artistSeconds }) + 1
            facts.artistRank = rank <= 10 ? rank : nil
        }
        return facts
    }
}

/// A fact about your listening: a symbol in a soft tile, a title and a line under it.
struct MusicFactRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            Image(icon: symbol)
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.music)
                .frame(width: 32, height: 32)
                .roundedBackground(NookTheme.music.opacity(0.14), radius: NookTheme.Radius.control)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper).lineLimit(1)
                Text(detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
