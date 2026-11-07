import SwiftUI

// The Music tab's playlists, in Music and on Spotify: a shelf of them to filter, open or play, and an open playlist as a
// list of its tracks to play, shuffle, add to or take out of. "Add to playlist" in the bar, the full player and every
// track's context menu adds to the same playlists. See `NowPlayingService+Playlists`.

struct MusicPlaylistsView: View {
    @ObservedObject var service: NowPlayingService
    @EnvironmentObject private var app: AppModel
    @Environment(\.panelSidebar) private var sidebar
    @State private var filter = ""
    @State private var deleting: MusicPlaylist?

    var body: some View {
        Group {
            if let detail = service.playlistDetail {
                MusicPlaylistDetailView(detail: detail, service: service, onDelete: { deleting = $0 })
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                overview
                    .transition(.opacity)
            }
        }
        .animation(NookTheme.swap, value: service.playlistDetail?.playlist.id)
        .confirmDelete($deleting, question: { tr("music.playlists.deleteQuestion", $0.name) },
                       detail: service.playlistsApp == "Spotify" ? tr("music.playlists.deleteDetailSpotify") : tr("music.playlists.deleteDetailMusic"),
                       confirmTitle: tr("music.playlists.delete")) { service.delete($0) }
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        switch service.playlistsState {
        case .connectSpotify:
            MusicPlaceholder(symbol: "link", title: tr("music.playlists.connectSpotify"),
                             detail: tr("music.playlists.connectSpotifyDetail", tr("settings.section.connections"))) {
                SmallPrimaryButton(title: tr("music.playlists.openConnections")) { app.openSettings(section: .connections) }
            }
        case .reconnectSpotify:
            MusicPlaceholder(symbol: "arrow.triangle.2.circlepath", title: tr("music.playlists.reconnect"),
                             detail: tr("music.playlists.reconnectDetail", tr("settings.section.connections"))) {
                SmallPrimaryButton(title: tr("music.playlists.openConnections")) { app.openSettings(section: .connections) }
            }
        case .failed(let message) where service.playlists.isEmpty:
            MusicPlaceholder(symbol: "exclamationmark.triangle", title: tr("music.playlists.loadFailed"), detail: message) {
                SmallGhostButton(title: tr("music.lyrics.retry")) { service.refreshPlaylists() }
            }
        case .idle, .loading where service.playlists.isEmpty:
            PatientSpinner()
        default:
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                if service.playlists.count > 6 || sidebar == nil {
                    toolbar
                }
                if service.playlists.isEmpty {
                    MusicPlaceholder(symbol: "music.note.list", title: tr("music.playlists.empty"), detail: tr("music.playlists.emptyDetail")) {
                        SmallPrimaryButton(title: tr("music.playlists.new")) { service.playlistPrompt = .create(adding: nil) }
                    }
                } else if shown.isEmpty {
                    MusicPlaceholder(symbol: "magnifyingglass", title: tr("music.search.empty", filter))
                } else {
                    MusicShelf(sections: [.init(id: "playlists", note: note, items: shown.map(item))], service: service)
                }
            }
        }
    }

    /// Filter on the left (once there are enough to look for one), a new playlist on the right when not already in the page header.
    private var toolbar: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if service.playlists.count > 6 {
                NookSearchField(prompt: tr("music.playlists.filter"), text: $filter)
                    .frame(maxWidth: 280)
            }
            Spacer(minLength: 0)
            if sidebar == nil {
                SmallGhostButton(title: "+ " + tr("music.playlists.new")) { service.playlistPrompt = .create(adding: nil) }
                    .help(tr("music.playlists.new"))
            }
        }
        .padding(.horizontal, NookTheme.Spacing.xs)
    }

    private var shown: [MusicPlaylist] {
        let words = filter.lowercased().split(separator: " ")
        guard !words.isEmpty else { return service.playlists }
        return service.playlists.filter { playlist in words.allSatisfy { playlist.name.lowercased().contains($0) } }
    }

    private var note: String {
        let source = service.playlistsApp == "Spotify" ? "Spotify" : tr("tab.music")
        return tr("music.playlists.hintFrom", service.playlists.count, source)
    }

    private func item(_ playlist: MusicPlaylist) -> MusicCoverItem {
        var subtitle = tr("music.playlists.count", playlist.trackCount)
        if !playlist.owner.isEmpty { subtitle += " · " + playlist.owner }
        var menu: [MusicCoverItem.Secondary] = [
            .init(symbol: "play.fill", label: tr("music.play")) { service.play(playlist, shuffled: false) },
            .init(symbol: "shuffle", label: tr("music.playlists.shuffle")) { service.play(playlist, shuffled: true) },
        ]
        if playlist.editable {
            menu.append(.init(symbol: "pencil", label: tr("music.playlists.rename")) { service.playlistPrompt = .rename(playlist) })
        }
        return MusicCoverItem(
            id: playlist.id, title: playlist.name, subtitle: subtitle, artworkURL: playlist.artworkURL,
            symbol: "music.note.list", help: tr("music.playlists.open", playlist.name), hoverSymbol: "list.bullet",
            secondary: .init(symbol: "play.fill", label: tr("music.playlists.play", playlist.name)) { service.play(playlist) },
            menu: menu,
            destructive: .init(symbol: "trash", label: tr("music.playlists.delete")) { deleting = playlist }
        ) { service.open(playlist) }
    }
}

// MARK: Open playlist

private struct MusicPlaylistDetailView: View {
    let detail: MusicPlaylistDetail
    @ObservedObject var service: NowPlayingService
    let onDelete: (MusicPlaylist) -> Void
    @State private var filter = ""

    private var playlist: MusicPlaylist { detail.playlist }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: playlist.id) { filter = "" }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NookTheme.Spacing.lg) {
            NookIconButton(systemName: "chevron.left", label: tr("music.playlists.back"), size: 30) { service.closePlaylist() }
            MusicArtwork(url: playlist.artworkURL ?? detail.tracks.first?.artworkURL, seed: playlist.name,
                         symbol: "music.note.list", cornerRadius: NookTheme.Radius.card)
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(playlist.name)
                    .font(NookTheme.TextStyle.heading)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text(summary)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NookTheme.Spacing.sm) {
                if detail.tracks.count > 10 {
                    NookSearchField(prompt: tr("music.playlists.filterTracks"), text: $filter)
                        .frame(width: 170)
                }
                if playlist.editable, let track = service.currentTrack, service.playlistsAccepting(track).contains(where: { $0.id == playlist.id }) {
                    NookIconButton(systemName: "plus", label: tr("music.playlists.addCurrent", track.title), size: 30) {
                        service.add(track, to: playlist)
                    }
                }
                NookIconButton(systemName: "shuffle", label: tr("music.playlists.shuffle"), size: 30) {
                    service.play(playlist, shuffled: true)
                }
                NookIconButton(systemName: "play.fill", label: tr("music.playlists.play", playlist.name), filled: true, size: 34) {
                    service.play(playlist, shuffled: false)
                }
                if playlist.editable {
                    Menu {
                        Button(tr("music.playlists.rename")) { service.playlistPrompt = .rename(playlist) }
                        Button(tr("music.playlists.reload")) { service.reloadPlaylistDetail() }
                        Divider()
                        Button(tr("music.playlists.delete"), role: .destructive) { onDelete(playlist) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(NookTheme.font(13, .semibold))
                            .foregroundStyle(NookTheme.textSecondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(tr("music.playlists.more"))
                    .accessibilityLabel(tr("music.playlists.more"))
                }
            }
        }
        .padding(NookTheme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.surface))
        .padding(.horizontal, NookTheme.Spacing.xs)
    }

    private var summary: String {
        var parts = [tr("music.playlists.count", detail.tracks.isEmpty ? playlist.trackCount : detail.tracks.count)]
        if detail.duration > 0 { parts.append(tr("music.playlists.minutes", max(1, detail.duration / 60))) }
        if !playlist.owner.isEmpty { parts.append(tr("music.playlists.by", playlist.owner)) }
        if !playlist.editable { parts.append(playlist.owner.isEmpty ? tr("music.playlists.smart") : tr("music.playlists.readOnly")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch detail.state {
        case .loading where detail.tracks.isEmpty, .idle:
            PatientSpinner()
        case .reconnectSpotify:
            MusicPlaceholder(symbol: "arrow.triangle.2.circlepath", title: tr("music.playlists.reconnect"),
                             detail: tr("music.playlists.reconnectDetail", tr("settings.section.connections")))
        case .failed(let message) where detail.tracks.isEmpty:
            MusicPlaceholder(symbol: "exclamationmark.triangle", title: tr("music.playlists.loadFailed"), detail: message) {
                SmallGhostButton(title: tr("music.lyrics.retry")) { service.reloadPlaylistDetail() }
            }
        default:
            if detail.tracks.isEmpty {
                MusicPlaceholder(symbol: "music.note", title: tr("music.playlists.emptyPlaylist"),
                                 detail: playlist.editable ? tr("music.playlists.emptyPlaylistDetail") : nil)
            } else {
                let rows = detail.tracks(matching: filter)
                if rows.isEmpty {
                    MusicPlaceholder(symbol: "magnifyingglass", title: tr("music.search.empty", filter))
                } else {
                    trackList(rows)
                }
            }
        }
    }

    private func trackList(_ rows: [MusicPlaylistDetail.Row]) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                    if position > 0 { NookDivider(inset: 78) }
                    MusicTrackRow(
                        number: row.index + 1, track: row.track, playing: isPlaying(row.track),
                        service: service,
                        onRemove: playlist.editable ? { service.removeFromOpenPlaylist(at: row.index) } : nil
                    ) { service.play(row.track, in: playlist) }
                }
            }
            .panelCard()
            .padding(.bottom, NookTheme.Spacing.xl)
        }
        .padding(.horizontal, NookTheme.Spacing.xs)
    }

    private func isPlaying(_ track: MusicTrack) -> Bool {
        guard let info = service.current else { return false }
        return info.trackID == track.id
    }
}

/// One track in a list (an open playlist, a search, Recent, a top list): its number when the list has an order, or the
/// equalizer while it plays, cover, title and artist, album, length or a `note`, and under the pointer: add to queue and
/// take out of the playlist. Click to play it.
struct MusicTrackRow: View {
    var number: Int? = nil
    let track: MusicTrack
    let playing: Bool
    @ObservedObject var service: NowPlayingService
    var onRemove: (() -> Void)? = nil
    /// Instead of the length: how often it played.
    var note: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                if let number {
                    marker(number: number).frame(width: 26)
                }
                MusicArtwork(url: track.artworkURL, seed: track.album.isEmpty ? track.title : track.album, cornerRadius: NookTheme.Radius.chip)
                    .frame(width: 34, height: 34)
                    .overlay {
                        if number == nil, hovering || playing {
                            ZStack {
                                RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(Color.black.opacity(0.5))
                                marker(number: nil)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    Text(track.album)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                    Color.clear.frame(width: 0)
                }
                actions
                Text(note ?? (track.duration > 0 ? musicClock(Double(track.duration)) : ""))
                    .font(NookTheme.font(11, .medium).monospacedDigit())
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .padding(.vertical, NookTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(NookTheme.rowFill(selected: false, hovering: hovering, rest: .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.play"))
        .contextMenu {
            Button(tr("music.play"), action: action)
            Button(tr("music.queue.add")) { service.enqueue(track) }
            MusicAddToPlaylistMenu(track: track, service: service)
            if let onRemove {
                Divider()
                Button(tr("music.playlists.removeTrack"), role: .destructive, action: onRemove)
            }
        }
        .accessibilityLabel(track.artist.isEmpty ? track.title : "\(track.title), \(track.artist)")
        .accessibilityHint(tr("music.play"))
    }

    /// The play symbol under the pointer, the bars while it plays, otherwise the number.
    @ViewBuilder
    private func marker(number: Int?) -> some View {
        if hovering {
            Image(systemName: "play.fill")
                .font(NookTheme.font(10, .bold))
                .foregroundStyle(NookTheme.paper)
        } else if playing {
            EqualizerBars(color: NookTheme.music, height: 10, isPlaying: service.current?.isPlaying ?? false)
                .scaleEffect(0.7)
        } else if let number {
            Text("\(number)")
                .font(NookTheme.font(11, .medium).monospacedDigit())
                .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private var actions: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ToolbarIconButton("text.line.last.and.arrowtriangle.forward", tr("music.queue.add")) { service.enqueue(track) }
            if let onRemove {
                ToolbarIconButton("minus.circle", tr("music.playlists.removeTrack"), onRemove)
            }
        }
        .opacity(hovering ? 1 : 0)
    }
}

// MARK: Add to playlist

/// "Add to playlist ›" in a track's context menu: the playlists of the track's player the user may edit, and a new one.
struct MusicAddToPlaylistMenu: View {
    let track: MusicTrack
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if service.playlistsApp != nil, NowPlayingService.canPlay(track, in: service.playlistsApp) {
            Menu(tr("music.playlists.addTo")) { MusicAddToPlaylistItems(track: track, service: service) }
        }
    }
}

/// The items of an "Add to playlist" menu.
private struct MusicAddToPlaylistItems: View {
    let track: MusicTrack
    @ObservedObject var service: NowPlayingService

    var body: some View {
        Button(tr("music.playlists.newWith")) { service.playlistPrompt = .create(adding: track) }
        let targets = service.playlistsAccepting(track)
        if !targets.isEmpty {
            Divider()
            ForEach(targets) { playlist in
                Button(playlist.name) { service.add(track, to: playlist) }
            }
        }
    }
}

/// A round "Add to playlist" button for the playing track, in the bar and the full player.
struct MusicAddToPlaylistButton: View {
    let track: MusicTrack?
    @ObservedObject var service: NowPlayingService
    var size: CGFloat = 30
    @State private var hovering = false

    var body: some View {
        if let track, service.playlistsApp != nil, NowPlayingService.canPlay(track, in: service.playlistsApp) {
            Menu {
                MusicAddToPlaylistItems(track: track, service: service)
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(NookTheme.font(size * 0.42, .semibold))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(hovering ? NookTheme.smoke : Color.clear))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help(tr("music.playlists.addTo"))
            .accessibilityLabel(tr("music.playlists.addTo"))
        }
    }
}

// MARK: Name prompt

/// Asks for a playlist's name (a new one, or a new name) when `service.playlistPrompt` is set.
struct MusicPlaylistPromptHost: ViewModifier {
    @ObservedObject var service: NowPlayingService
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { service.playlistPrompt != nil }, set: { if !$0 { service.playlistPrompt = nil } }),
                   presenting: service.playlistPrompt) { prompt in
                TextField(tr("music.playlists.namePlaceholder"), text: $name)
                Button(tr("button.cancel"), role: .cancel) {}
                Button(confirmTitle(prompt)) { submit(prompt) }
                    .keyboardShortcut(.defaultAction)
            } message: { prompt in
                if case .create(let track?) = prompt { Text(tr("music.playlists.newWithDetail", track.title)) }
            }
            .onChange(of: service.playlistPrompt) {
                if case .rename(let playlist)? = service.playlistPrompt { name = playlist.name } else { name = "" }
            }
    }

    private var title: String {
        if case .rename? = service.playlistPrompt { return tr("music.playlists.rename") }
        return tr("music.playlists.new")
    }

    private func confirmTitle(_ prompt: MusicPlaylistPrompt) -> String {
        if case .rename = prompt { return tr("music.playlists.renameButton") }
        return tr("music.playlists.create")
    }

    private func submit(_ prompt: MusicPlaylistPrompt) {
        switch prompt {
        case .create(let track): service.createPlaylist(named: name, adding: track)
        case .rename(let playlist): service.rename(playlist, to: name)
        }
    }
}

extension View {
    func musicPlaylistPrompts(_ service: NowPlayingService) -> some View {
        modifier(MusicPlaylistPromptHost(service: service))
    }
}
