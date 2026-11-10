import SwiftUI

/// The player at the bottom of the Music pages: the playing track, transport and volume in one floating bar, lit from
/// the left by the cover's colours. Its track (or the chevron) opens Now Playing, where the bar steps aside.
struct MusicDock: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    let onOpen: () -> Void

    static let barHeight: CGFloat = 64

    var body: some View {
        let shape = NookTheme.shape(NookTheme.Radius.composer)
        MusicBar(info: info, service: service, onExpand: onOpen)
            .frame(maxWidth: .infinity)
            .frame(height: Self.barHeight)
            .background {
                // The composer's box on the other tabs: the same surface, corner and hairline, with the cover's light.
                shape
                    .fill(NookTheme.surface)
                    .overlay(alignment: .leading) {
                        MusicArtworkGlow(url: info.artworkURL, seed: info.title, opacity: 0.35, center: .leading, reach: 0.45)
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(NookTheme.fieldStroke, lineWidth: 1))
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
                .roundedBackground(NookTheme.rowFill(selected: false, hovering: hoveringTrack, rest: .clear),
                                   radius: NookTheme.Radius.panel)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringTrack = $0 }
            .help(tr("music.openNowPlaying"))
            .accessibilityLabel("\(info.title), \(subtitle)")
            .accessibilityHint(tr("music.openNowPlaying"))
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
                NookIconButton(systemName: "chevron.up", label: tr("music.openNowPlaying"), size: 30, action: onExpand)
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

struct MusicShowAllButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(tr("music.showAll")).font(NookTheme.TextStyle.label)
                Image(icon: "chevron.right").font(NookTheme.font(9, .bold))
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
