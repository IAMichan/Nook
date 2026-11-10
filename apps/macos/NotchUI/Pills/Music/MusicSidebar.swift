import SwiftUI

// The Music tab's part of the main window's sidebar: where to go in Music, and the playlists one click from open or
// playing. The notch has no sidebar, and neither has Music shown beside another tab: there the page keeps its own tabs.

struct MusicSidebar: View {
    @ObservedObject var service: NowPlayingService
    @AppStorage(MusicSection.storageKey) private var storedSection = MusicSection.home.rawValue

    private var sections: [MusicSection] { MusicSection.available(playing: service.current != nil) }
    private var section: MusicSection {
        let stored = MusicSection(rawValue: storedSection) ?? .home
        return sections.contains(stored) ? stored : .home
    }
    /// Nook may not talk to the player: the page says so, and there is nowhere to go yet.
    private var blocked: Bool { service.current == nil && service.permissionDenied }

    var body: some View {
        if !blocked {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                    VStack(spacing: NookTheme.Spacing.xxs) {
                        ForEach(sections) { item in
                            MusicSidebarRow(title: item.title, symbol: item.symbol,
                                            selected: item == section && !(item == .playlists && service.playlistDetail != nil),
                                            playing: item == .nowPlaying && service.current?.isPlaying == true) {
                                open(item)
                            }
                        }
                    }
                    if service.playlistsApp != nil, !service.playlists.isEmpty { playlists }
                }
            }
        }
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            PanelListHeader(tr("music.section.playlists"), sidebarTitle: tr("music.section.playlists")) {
                ToolbarIconButton("plus", tr("music.playlists.new"), height: 20, width: 20) {
                    service.playlistPrompt = .create(adding: nil)
                }
            }
            LazyVStack(spacing: NookTheme.Spacing.xxs) {
                ForEach(service.playlists) { playlist in
                    MusicSidebarPlaylistRow(
                        playlist: playlist, service: service,
                        selected: section == .playlists && service.playlistDetail?.playlist.id == playlist.id
                    ) {
                        service.open(playlist)
                        show(.playlists)
                    }
                }
            }
        }
    }

    /// Always the overview of a section: the playlists in the list below are what opens a single one.
    private func open(_ item: MusicSection) {
        if item == .playlists { service.closePlaylist() }
        show(item)
    }

    private func show(_ item: MusicSection) {
        withAnimation(MusicSection.fold) { storedSection = item.rawValue }
    }
}

private struct MusicSidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    /// Now Playing while music plays: a still waveform in the Music colour, so the row says it without an animation.
    var playing = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: symbol)
                    .font(NookTheme.font(13, .medium))
                    .foregroundStyle(selected ? NookTheme.paper : NookTheme.textTertiary)
                    .frame(width: PanelSidebarMetrics.mark)
                    .accessibilityHidden(true)
                Text(title)
                    .font(NookTheme.TextStyle.control)
                    .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if playing {
                    Image(icon: "waveform")
                        .font(NookTheme.font(11, .semibold))
                        .foregroundStyle(NookTheme.music)
                        .accessibilityLabel(tr("music.playingNow"))
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: PanelSidebarMetrics.row)
            .roundedBackground(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear), radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A playlist: click to open it in the page, the button under the pointer plays it.
private struct MusicSidebarPlaylistRow: View {
    let playlist: MusicPlaylist
    @ObservedObject var service: NowPlayingService
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                MusicArtwork(url: playlist.artworkURL, seed: playlist.name, symbol: "music.note.list", cornerRadius: NookTheme.Radius.chip)
                    .frame(width: 22, height: 22)
                Text(playlist.name)
                    .font(NookTheme.TextStyle.control)
                    .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                NookIconButton(systemName: "play.fill", label: tr("music.playlists.play", playlist.name), size: 22) {
                    service.play(playlist)
                }
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: PanelSidebarMetrics.row)
            .roundedBackground(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear), radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.playlists.open", playlist.name))
        .contextMenu {
            Button(tr("music.play")) { service.play(playlist, shuffled: false) }
            Button(tr("music.playlists.shuffle")) { service.play(playlist, shuffled: true) }
            if playlist.editable {
                Button(tr("music.playlists.rename")) { service.playlistPrompt = .rename(playlist) }
            }
        }
        .accessibilityLabel(playlist.name)
        .accessibilityHint(tr("music.playlists.open", playlist.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
