import SwiftUI

/// The player at the bottom of the Music tab. Folded, it is a compact transport bar under the lyrics; unfolded, the
/// same element grows over the stage into the full player, without a tile of its own, so it fades into the panel.
struct MusicDock: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let expanded: Bool
    let onExpand: () -> Void
    let onCollapse: () -> Void
    /// "Show all" under the full player: fold and open that section.
    let onShowAll: (MusicSection) -> Void

    static let barHeight: CGFloat = 74

    var body: some View {
        ZStack {
            if expanded {
                MusicFullPlayer(info: info, service: service, onCollapse: onCollapse, onShowAll: onShowAll)
                    .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.08)))
            } else {
                MusicBar(info: info, service: service, onExpand: onExpand)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : Self.barHeight)
        .frame(height: expanded ? nil : Self.barHeight)
        .background {
            RoundedRectangle(cornerRadius: NookTheme.Radius.pill, style: .continuous)
                .fill(NookTheme.graphite)
                .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.pill, style: .continuous).strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
                .opacity(expanded ? 0 : 1)
        }
        // The position and volume shown here need the player polled every couple of seconds; nothing else does.
        .onAppear { service.addViewer() }
        .onDisappear { service.removeViewer() }
    }
}

// MARK: Bar

/// Folded: the track on the left (click it to unfold), transport and progress in the middle, volume and buttons right.
private struct MusicBar: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let onExpand: () -> Void
    @State private var hoveringTrack = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onExpand) {
                HStack(spacing: 11) {
                    MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: NookTheme.Radius.card)
                        .frame(width: 50, height: 50)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title)
                            .font(NookTheme.font(13.5, .semibold))
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(NookTheme.font(11.5))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous).fill(Color.white.opacity(hoveringTrack ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringTrack = $0 }
            .help(tr("music.expand"))
            .accessibilityLabel("\(info.title), \(subtitle)")
            .accessibilityHint(tr("music.expand"))
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                MusicTransport(info: info, service: service)
                MusicScrubBar(info: info, style: .inline) { service.seek(to: $0) }
            }
            .frame(width: 330)

            HStack(spacing: 4) {
                if let volume = info.volume {
                    MusicVolumeControl(volume: volume, width: 70) { service.setVolume($0) }
                    Rectangle()
                        .fill(NookTheme.line2)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 6)
                }
                NookIconButton(systemName: "arrow.up.forward.app", label: tr("music.openPlayer", musicPlayerName(info)), size: 30) {
                    openMusicPlayer(info)
                }
                .help(tr("music.openPlayer", musicPlayerName(info)))
                NookIconButton(systemName: "chevron.up", label: tr("music.expand"), size: 30, action: onExpand)
                    .help(tr("music.expand"))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .animation(NookTheme.hover, value: hoveringTrack)
    }

    private var subtitle: String { musicSubtitle(info) }
}

// MARK: Full player

/// Unfolded: a large cover with its colours glowing out into the panel, the track, transport and volume beside it, and
/// what comes next (Up Next in Music, Recent for Spotify) along the bottom.
private struct MusicFullPlayer: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let onCollapse: () -> Void
    let onShowAll: (MusicSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let side = min(216, max(110, geo.size.height - 28))
                HStack(spacing: 32) {
                    cover(side: side)
                    details
                }
                .padding(.leading, 6)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
            MusicUpcomingStrip(info: info, service: service, onShowAll: onShowAll)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                NookIconButton(systemName: "arrow.up.forward.app", label: tr("music.openPlayer", musicPlayerName(info)), size: 30) {
                    openMusicPlayer(info)
                }
                .help(tr("music.openPlayer", musicPlayerName(info)))
                NookIconButton(systemName: "chevron.down", label: tr("music.collapse"), size: 30, action: onCollapse)
                    .help(tr("music.collapse"))
            }
        }
    }

    private func cover(side: CGFloat) -> some View {
        MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: NookTheme.Radius.sheet)
            .frame(width: side, height: side)
            .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
            .scaleEffect(info.isPlaying ? 1 : 0.95)
            .animation(.spring(duration: 0.45, bounce: 0.15), value: info.isPlaying)
            .background {
                // The cover's colours bleed into the panel and fade out on every side: no edge, no tile.
                MusicArtwork(url: info.artworkURL, seed: info.title, cornerRadius: 0, showsSymbol: false)
                    .frame(width: side * 2.9, height: side * 2.5)
                    .blur(radius: 70)
                    .saturation(1.3)
                    .opacity(0.5)
                    .mask(RadialGradient(colors: [.black, .black.opacity(0.6), .clear], center: .center, startRadius: 0, endRadius: side * 1.3))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                EqualizerBars(color: NookTheme.mint, height: 10, isPlaying: info.isPlaying)
                    .scaleEffect(0.8, anchor: .leading)
                    .frame(width: 26, alignment: .leading)
                Text(tr("music.playingIn", musicPlayerName(info)).uppercased())
                    .font(NookTheme.font(10.5, .bold))
                    .tracking(0.9)
                    .foregroundStyle(NookTheme.paper.opacity(0.55))
                    .lineLimit(1)
            }
            Text(info.title)
                .font(NookTheme.font(26, .bold))
                .tracking(-0.4)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .help(info.title)
                .padding(.top, 10)
                // Clear of the open and fold buttons in the corner.
                .padding(.trailing, 72)
            subtitleText
                .font(NookTheme.font(13.5))
                .lineLimit(1)
                .padding(.top, 5)
            MusicScrubBar(info: info, style: .stacked) { service.seek(to: $0) }
                .padding(.top, 20)
            HStack(spacing: 12) {
                MusicTransport(info: info, service: service, large: true)
                Spacer(minLength: 8)
                if let volume = info.volume {
                    MusicVolumeControl(volume: volume, width: 96) { service.setVolume($0) }
                }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitleText: Text {
        let artist = Text(info.artist).fontWeight(.semibold).foregroundStyle(NookTheme.paper.opacity(0.85))
        let album = Text(info.album).foregroundStyle(NookTheme.paper.opacity(0.6))
        switch (info.artist.isEmpty, info.album.isEmpty) {
        case (false, false): return artist + Text(" · ").foregroundStyle(NookTheme.paper.opacity(0.6)) + album
        case (false, true): return artist
        case (true, false): return album
        case (true, true): return Text(musicPlayerName(info)).foregroundStyle(NookTheme.paper.opacity(0.6))
        }
    }
}

/// Along the bottom of the full player: the next few tracks, one click to play, and "Show all" to the full section.
private struct MusicUpcomingStrip: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let onShowAll: (MusicSection) -> Void

    private static let count = 4

    /// Spotify shares no queue, so it shows what played before instead.
    private var showsQueue: Bool { info.app == "Music" }
    private var tracks: [MusicTrack] { showsQueue ? (service.upNext?.tracks ?? []) : service.recent.tracks }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text((showsQueue ? tr("music.section.upNext") : tr("music.recent.title")).uppercased())
                    .font(NookTheme.font(10.5, .bold))
                    .tracking(0.9)
                    .foregroundStyle(NookTheme.paper.opacity(0.45))
                if showsQueue, let playlist = service.upNext?.playlist, !playlist.isEmpty {
                    Text(tr("music.upNext.from", playlist))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.paper.opacity(0.38))
                        .lineLimit(1)
                }
                if showsQueue && info.shuffle {
                    Image(systemName: "shuffle")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.music)
                        .help(tr("music.upNext.shuffleNote"))
                        .accessibilityLabel(tr("music.upNext.shuffleNote"))
                }
                Spacer(minLength: 8)
                if !tracks.isEmpty {
                    MusicShowAllButton { onShowAll(showsQueue ? .upNext : .recent) }
                }
            }
            .padding(.horizontal, 4)
            Group {
                if tracks.isEmpty {
                    Text(emptyText)
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textTertiary)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(tracks.prefix(Self.count).enumerated()), id: \.offset) { _, track in
                            MusicUpcomingChip(track: track) { service.play(track, fromQueue: showsQueue) }
                                .frame(maxWidth: .infinity)
                        }
                        // Keep the columns even when there are fewer tracks.
                        ForEach(0..<max(0, Self.count - tracks.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
            .frame(height: 50)
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.09), location: 0.2),
                    .init(color: .white.opacity(0.09), location: 0.8),
                    .init(color: .white.opacity(0), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 4)
        }
    }

    private var emptyText: String {
        if showsQueue { return service.upNext == nil && service.libraryLoading ? tr("music.upNext.loading") : tr("music.upNext.empty") }
        return tr("music.recent.empty")
    }
}

private struct MusicUpcomingChip: View {
    let track: MusicTrack
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MusicArtwork(url: track.artworkURL, seed: track.title, cornerRadius: NookTheme.Radius.control)
                    .frame(width: 38, height: 38)
                    .overlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(Color.black.opacity(0.45))
                            Image(systemName: "play.fill").font(NookTheme.font(11, .bold)).foregroundStyle(NookTheme.paper)
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(NookTheme.font(12.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.paper.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.play"))
        .accessibilityLabel(track.artist.isEmpty ? track.title : "\(track.title), \(track.artist)")
        .accessibilityHint(tr("music.play"))
    }
}

private struct MusicShowAllButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(tr("music.showAll")).font(NookTheme.font(11.5, .semibold))
                Image(systemName: "chevron.right").font(NookTheme.font(9, .bold))
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.paper.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip).fill(Color.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Artist and album, or the player's name when the track has neither.
func musicSubtitle(_ info: NowPlayingInfo) -> String {
    let parts = [info.artist, info.album].filter { !$0.isEmpty }
    return parts.isEmpty ? musicPlayerName(info) : parts.joined(separator: " · ")
}
