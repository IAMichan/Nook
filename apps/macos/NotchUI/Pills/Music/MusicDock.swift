import SwiftUI

/// The player at the bottom of the Music tab. Folded, it is a compact transport bar under the lyrics; unfolded, the
/// same element grows over the stage into the full player, without a tile of its own, so it fades into the panel.
struct MusicDock: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let expanded: Bool
    let onExpand: () -> Void
    /// "Show all" under the full player: fold and open that section.
    let onShowAll: (MusicSection) -> Void

    static let barHeight: CGFloat = 64

    var body: some View {
        ZStack {
            if expanded {
                MusicFullPlayer(info: info, service: service, onShowAll: onShowAll)
                    .transition(.opacity.animation(NookTheme.reveal.delay(0.08)))
            } else {
                MusicBar(info: info, service: service, onExpand: onExpand)
                    .transition(.opacity.animation(NookTheme.reveal))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : Self.barHeight)
        .frame(height: expanded ? nil : Self.barHeight)
        .background {
            // The composer's box on the other tabs: the same surface, corner and hairline.
            let shape = RoundedRectangle(cornerRadius: NookTheme.Radius.composer, style: .continuous)
            shape
                .fill(NookTheme.surface)
                .overlay(shape.strokeBorder(NookTheme.fieldStroke, lineWidth: 1))
                .opacity(expanded ? 0 : 1)
        }
        // The position and volume shown here need the player polled every couple of seconds; nothing else does.
        .onAppear { service.addViewer() }
        .onDisappear { service.removeViewer() }
    }
}

// MARK: Bar

/// Folded: the track on the left (click it to unfold), transport and progress in the middle, volume and the rest right.
private struct MusicBar: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let onExpand: () -> Void
    @State private var hoveringTrack = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xl) {
            Button(action: onExpand) {
                HStack(spacing: NookTheme.Spacing.lg) {
                    MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: NookTheme.Radius.control)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(info.title)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(NookTheme.Spacing.xs)
                .padding(.trailing, NookTheme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
                    .fill(NookTheme.rowFill(selected: false, hovering: hoveringTrack, rest: .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringTrack = $0 }
            .help(tr("music.expand"))
            .accessibilityLabel("\(info.title), \(subtitle)")
            .accessibilityHint(tr("music.expand"))
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                MusicTransport(info: info, service: service)
                MusicScrubBar(info: info, style: .inline) { service.seek(to: $0) }
            }
            // Narrower in a narrow tab (split view), so the track and the buttons beside it stay on screen.
            .frame(minWidth: 180, idealWidth: 320, maxWidth: 320)

            HStack(spacing: NookTheme.Spacing.xs) {
                if let volume = info.volume {
                    MusicVolumeControl(volume: volume, width: 72) { service.setVolume($0) }
                        .padding(.trailing, NookTheme.Spacing.sm)
                }
                MusicAddToPlaylistButton(track: service.currentTrack, service: service)
                NookIconButton(systemName: "chevron.up", label: tr("music.expand"), size: 30, action: onExpand)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // The cover sits as far from the box's edge as from its top, so the box's corner runs around it.
        .padding(.leading, NookTheme.Spacing.sm)
        .padding(.trailing, NookTheme.Spacing.lg)
        .animation(NookTheme.hover, value: hoveringTrack)
    }

    private var subtitle: String { musicSubtitle(info) }
}

// MARK: Full player

/// Unfolded: a large cover with its colours glowing softly behind it, the track, transport and volume beside it,
/// centred together on the page, and what comes next (Up Next in Music, Recent for Spotify) along the bottom. Folding
/// it is in the page's header band, beside the tabs or the title.
private struct MusicFullPlayer: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let onShowAll: (MusicSection) -> Void

    /// The track's column reads best at this width; the pair is centred on a wider page.
    private static let detailsWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // By the height, and in a narrow tab by the width too, so the details beside it keep their room.
                let side = min(280, max(110, geo.size.height - NookTheme.Spacing.xxl), max(88, geo.size.width * 0.34))
                HStack(spacing: NookTheme.Spacing.xxxl) {
                    cover(side: side)
                    details
                        .frame(maxWidth: Self.detailsWidth)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            MusicUpcomingStrip(info: info, service: service, onShowAll: onShowAll)
        }
    }

    private func cover(side: CGFloat) -> some View {
        MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: NookTheme.Radius.panel)
            .frame(width: side, height: side)
            .scaleEffect(info.isPlaying ? 1 : 0.96)
            .animation(NookTheme.open, value: info.isPlaying)
            .background {
                // The cover's colours bleed into the panel and fade out on every side: no edge, no tile.
                MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: 0, showsSymbol: false)
                    .frame(width: side * 2.4, height: side * 2.4)
                    .blur(radius: 80, opaque: true)
                    .saturation(1.2)
                    .opacity(0.4)
                    // Opaque blur, so the image's own edge never shows: only this falloff shapes the glow.
                    .mask(RadialGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.8), location: 0.3),
                        .init(color: .black.opacity(0.45), location: 0.55),
                        .init(color: .black.opacity(0.15), location: 0.8),
                        .init(color: .clear, location: 1),
                    ], center: .center, startRadius: 0, endRadius: side * 1.1))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                EqualizerBars(color: NookTheme.music, height: 10, isPlaying: info.isPlaying)
                    .scaleEffect(0.8, anchor: .leading)
                    .frame(width: 26, alignment: .leading)
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
            subtitleText
                .font(NookTheme.TextStyle.body)
                .lineLimit(1)
                .padding(.top, NookTheme.Spacing.xs)
            MusicScrubBar(info: info, style: .stacked) { service.seek(to: $0) }
                .padding(.top, NookTheme.Spacing.xxl)
            // The volume beside the transport while there is room; in a narrow tab the large transport alone, then the
            // small one.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NookTheme.Spacing.lg) {
                    MusicTransport(info: info, service: service, large: true)
                    Spacer(minLength: NookTheme.Spacing.md)
                    if let volume = info.volume {
                        MusicVolumeControl(volume: volume, width: 80) { service.setVolume($0) }
                    }
                }
                MusicTransport(info: info, service: service, large: true)
                MusicTransport(info: info, service: service)
            }
            .padding(.top, NookTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitleText: Text {
        let artist = Text(info.artist).foregroundStyle(NookTheme.textStrong)
        let album = Text(info.album).foregroundStyle(NookTheme.textSecondary)
        switch (info.artist.isEmpty, info.album.isEmpty) {
        case (false, false): return artist + Text(" · ").foregroundStyle(NookTheme.textSecondary) + album
        case (false, true): return artist
        case (true, false): return album
        case (true, true): return Text(musicPlayerName(info)).foregroundStyle(NookTheme.textSecondary)
        }
    }
}

/// Along the bottom of the full player: the next few tracks, one click to play, and "Show all" to the full section.
private struct MusicUpcomingStrip: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let onShowAll: (MusicSection) -> Void

    private static let count = 4

    /// One chip: a track the user queued in Nook (`entry`), or one from the player's Up Next or Recent.
    private struct Chip {
        let track: MusicTrack
        var entry: MusicPlayQueue.Entry.ID? = nil
    }

    /// What Nook queued itself comes first, then the player's own queue. Spotify only shares its queue once it is
    /// connected in Settings; until then, with nothing queued, the strip shows what played before instead.
    private var showsQueue: Bool { info.app == "Music" || service.upNext != nil || !service.playQueue.isEmpty }
    private var chipsToShow: [Chip] {
        let queued = service.playQueue.entries.map { Chip(track: $0.track, entry: $0.id) }
        if let upNext = service.upNext { return queued + upNext.tracks.map { Chip(track: $0) } }
        if info.app == "Music" || !queued.isEmpty { return queued }
        return service.recent.tracks.filter { $0.id != info.trackID }.map { Chip(track: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                // A group's name, as everywhere else in the panel: no capitals, no tracking.
                Text(showsQueue ? tr("music.section.upNext") : tr("music.recent.title"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                if !service.playQueue.isEmpty {
                    Text(tr("music.queue.count", service.playQueue.entries.count))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                } else if info.app == "Music", let playlist = service.upNext?.playlist, !playlist.isEmpty {
                    Text(tr("music.upNext.from", playlist))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                if info.app == "Music" && info.shuffle {
                    Image(systemName: "shuffle")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .help(tr("music.upNext.shuffleNote"))
                        .accessibilityLabel(tr("music.upNext.shuffleNote"))
                }
                Spacer(minLength: NookTheme.Spacing.md)
                if !chipsToShow.isEmpty {
                    MusicShowAllButton { onShowAll(showsQueue ? .upNext : .home) }
                }
            }
            Group {
                if chipsToShow.isEmpty {
                    Text(emptyText)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Four in a row, fewer in a narrow tab, so each keeps room for its title.
                    ViewThatFits(in: .horizontal) {
                        chips(Self.count)
                        chips(3)
                        chips(2)
                        chips(1)
                    }
                }
            }
            .frame(height: 52)
        }
        .padding(.top, NookTheme.Spacing.xl)
        .overlay(alignment: .top) { NookDivider() }
    }

    /// `count` columns, each at least wide enough for a title; empty columns keep them even with fewer tracks.
    private func chips(_ count: Int) -> some View {
        let shown = chipsToShow
        return HStack(spacing: NookTheme.Spacing.md) {
            ForEach(Array(shown.prefix(count).enumerated()), id: \.offset) { _, chip in
                chipView(chip)
                    .frame(maxWidth: .infinity)
            }
            ForEach(0..<max(0, count - shown.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
        .frame(minWidth: CGFloat(count) * 150)
        .musicRowBleed()
    }

    private func chipView(_ chip: Chip) -> some View {
        if let entry = chip.entry {
            return MusicTrackTile(track: chip.track, queued: true,
                                  secondary: (tr("music.queue.remove"), { service.removeFromQueue(entry) }), service: service) {
                service.playFromQueue(entry)
            }
        }
        let fromQueue = info.app == "Music"
        return MusicTrackTile(track: chip.track, secondary: chip.track.id.isEmpty ? nil : (tr("music.queue.add"), { service.enqueue(chip.track) }),
                              service: service) {
            service.play(chip.track, fromQueue: fromQueue)
        }
    }

    private var emptyText: String {
        if showsQueue { return service.upNext == nil && service.libraryLoading ? tr("music.upNext.loading") : tr("music.upNext.empty") }
        return tr("music.recent.empty")
    }
}

struct MusicShowAllButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(tr("music.showAll")).font(NookTheme.TextStyle.label)
                Image(systemName: "chevron.right").font(NookTheme.font(9, .bold))
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        // Its text lines up with the page's edge at rest.
        .padding(.trailing, -NookTheme.Spacing.md)
    }
}

/// Artist and album, or the player's name when the track has neither.
func musicSubtitle(_ info: NowPlayingInfo) -> String {
    let parts = [info.artist, info.album].filter { !$0.isEmpty }
    return parts.isEmpty ? musicPlayerName(info) : parts.joined(separator: " · ")
}
