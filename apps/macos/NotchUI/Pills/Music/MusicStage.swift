import SwiftUI

// What the Music tab shows above the player bar: lyrics, Up Next, playlists or recent tracks, over the full width.

// MARK: Lyrics

struct MusicLyricsView: View {
    let info: NowPlayingInfo
    @ObservedObject var lyrics: LyricsService
    let onSeek: (Double) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        switch lyrics.trackKey == info.trackKey ? lyrics.state : .loading {
        case .idle, .loading:
            MusicPlaceholder(symbol: "quote.bubble", title: tr("music.lyrics.loading"), loading: true)
        case .notFound:
            MusicPlaceholder(symbol: "text.badge.xmark", title: tr("music.lyrics.notFound"), detail: tr("music.lyrics.notFoundDetail")) {
                SmallGhostButton(title: tr("music.lyrics.retry")) { lyrics.load(for: info, force: true) }
            }
        case .offline:
            MusicPlaceholder(symbol: "network.slash", title: tr("music.lyrics.offline"), detail: tr("music.lyrics.offlineDetail")) {
                SmallGhostButton(title: tr("music.lyrics.turnOn")) {
                    settings.onlineLyrics = true
                    lyrics.load(for: info, force: true)
                }
            }
        case .found(let found):
            if found.instrumental {
                MusicPlaceholder(symbol: "pianokeys", title: tr("music.lyrics.instrumental"))
            } else if found.isSynced {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    SyncedLyrics(lines: found.lines, active: found.activeIndex(at: info.estimatedPosition(at: context.date) + 0.2), onSeek: onSeek)
                }
            } else {
                PlainLyrics(lines: found.lines)
            }
        }
    }

    /// Where the lyrics come from, for the section bar; `nil` while there are none to show.
    @MainActor static func source(of lyrics: LyricsService, for info: NowPlayingInfo) -> String? {
        guard lyrics.trackKey == info.trackKey, case .found(let found) = lyrics.state, !found.instrumental else { return nil }
        let source = found.source == .lrclib ? tr("music.lyrics.sourceLrclib") : tr("music.lyrics.sourcePlayer")
        return found.isSynced ? source : source + " · " + tr("music.lyrics.unsynced")
    }
}

/// Synced lyrics, centred over the full width: the current line larger and bright, held a little above the middle;
/// click a line to jump there.
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    let active: Int?
    let onSeek: (Double) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    Color.clear.frame(height: 80)
                    ForEach(lines) { line in
                        LyricRow(line: line, state: state(of: line)) {
                            if let time = line.time { onSeek(time) }
                        }
                        .id(line.id)
                    }
                    Color.clear.frame(height: 120)
                }
                .frame(maxWidth: .infinity)
            }
            .mask(fade)
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: active) { scroll(proxy, animated: true) }
        }
    }

    private func state(of line: LyricLine) -> LyricRow.State {
        guard let active else { return .upcoming }
        if line.id == active { return .current }
        return line.id < active ? .past : .upcoming
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let active else { return }
        let anchor = UnitPoint(x: 0.5, y: 0.42)
        if animated {
            withAnimation(.spring(duration: 0.5, bounce: 0.08)) { proxy.scrollTo(active, anchor: anchor) }
        } else {
            proxy.scrollTo(active, anchor: anchor)
        }
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.22),
            .init(color: .black, location: 0.7),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

private struct LyricRow: View {
    enum State { case past, current, upcoming }
    let line: LyricLine
    let state: State
    let action: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(NookTheme.font(18, state == .current ? .bold : .semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Narrow enough that the enlarged current line still fits the stage.
                .frame(maxWidth: 520)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card).fill(Color.white.opacity(hovering && state != .current ? 0.04 : 0)))
                .scaleEffect(state == .current ? 1.24 : 1)
                .padding(.vertical, state == .current ? 5 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.45, bounce: 0.1), value: state)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(tr("music.lyrics.seekHint"))
    }

    private var color: Color {
        if hovering && state != .current { return NookTheme.paper.opacity(0.75) }
        switch state {
        case .current: return NookTheme.paper
        case .past: return NookTheme.paper.opacity(0.14)
        case .upcoming: return NookTheme.paper.opacity(0.28)
        }
    }
}

private struct PlainLyrics: View {
    let lines: [LyricLine]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 7) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(NookTheme.font(15, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560)
                }
            }
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
            .padding(.vertical, 12)
        }
    }
}

// MARK: Up Next, playlists, recent

struct MusicUpNextView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if let queue = service.upNext {
            if queue.tracks.isEmpty {
                MusicPlaceholder(symbol: "checkmark.circle", title: tr("music.upNext.empty"))
            } else {
                MusicShelf(note: note(queue), noteSymbol: info.shuffle ? "shuffle" : nil, items: items(queue))
            }
        } else if service.libraryLoading {
            MusicPlaceholder(symbol: "list.bullet", title: tr("music.upNext.loading"), loading: true)
        } else {
            MusicPlaceholder(symbol: "list.bullet", title: tr("music.upNext.empty"))
        }
    }

    private func items(_ queue: MusicQueue) -> [MusicCoverItem] {
        queue.tracks.enumerated().map { index, track in
            MusicCoverItem(
                id: "\(index)|\(track.id)|\(track.title)", title: track.title, subtitle: track.artist,
                artworkURL: track.artworkURL, number: index + 1, help: tr("music.play")
            ) { service.play(track, fromQueue: true) }
        }
    }

    private func note(_ queue: MusicQueue) -> String {
        let from = queue.playlist.isEmpty ? tr("music.section.upNext") : tr("music.upNext.from", queue.playlist)
        return info.shuffle ? from + " · " + tr("music.upNext.shuffleNote") : from
    }
}

struct MusicPlaylistsView: View {
    @ObservedObject var service: NowPlayingService

    private var items: [MusicCoverItem] {
        service.playlists.map { playlist in
            MusicCoverItem(
                id: playlist.id, title: playlist.name, subtitle: tr("music.playlists.count", playlist.trackCount),
                symbol: "music.note.list", help: tr("music.playlists.play", playlist.name)
            ) { service.play(playlist) }
        }
    }

    var body: some View {
        if service.playlists.isEmpty {
            if service.libraryLoading {
                MusicPlaceholder(symbol: "music.note.list", title: tr("music.upNext.loading"), loading: true)
            } else {
                MusicPlaceholder(symbol: "music.note.list", title: tr("music.playlists.empty"))
            }
        } else {
            MusicShelf(note: tr("music.playlists.hint"), items: items)
        }
    }
}

struct MusicRecentView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService

    private var items: [MusicCoverItem] {
        service.recent.tracks.enumerated().map { index, track in
            MusicCoverItem(
                id: "\(index)|\(track.id)|\(track.title)", title: track.title, subtitle: track.artist,
                artworkURL: track.artworkURL, help: tr("music.play")
            ) { service.play(track, fromQueue: false) }
        }
    }

    var body: some View {
        if service.recent.tracks.isEmpty {
            MusicPlaceholder(
                symbol: "clock.arrow.circlepath", title: tr("music.recent.empty"),
                detail: info.app == "Spotify" ? tr("music.spotifyNote") : nil
            )
        } else {
            MusicShelf(
                note: info.app == "Spotify" ? tr("music.spotifyNote") : tr("music.recent.hint"),
                noteSymbol: info.app == "Spotify" ? "info.circle" : nil,
                items: items
            )
        }
    }
}

/// One cover in a shelf: a track or a playlist.
struct MusicCoverItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    var artworkURL: URL? = nil
    var symbol = "music.note"
    /// The position in Up Next.
    var number: Int? = nil
    let help: String
    let action: () -> Void
}

/// A short note over a grid of covers that wraps to the stage's width and scrolls when there are more.
private struct MusicShelf: View {
    let note: String
    var noteSymbol: String? = nil
    let items: [MusicCoverItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let noteSymbol {
                    Image(systemName: noteSymbol).font(NookTheme.font(10.5, .semibold))
                }
                Text(note).lineLimit(1).truncationMode(.tail)
            }
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textTertiary)
            .help(note)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 136), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(items) { MusicCoverCard(item: $0) }
                }
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
        .padding(.horizontal, 4)
    }
}

private struct MusicCoverCard: View {
    let item: MusicCoverItem
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        MusicArtwork(url: item.artworkURL, seed: item.title, symbol: item.symbol, cornerRadius: NookTheme.Radius.panel)
                    }
                    .overlay(alignment: .topLeading) {
                        if let number = item.number {
                            Text("\(number)")
                                .font(NookTheme.font(10.5, .bold).monospacedDigit())
                                .foregroundStyle(NookTheme.paper)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                                .padding(8)
                        }
                    }
                    .overlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(Color.black.opacity(0.35))
                            Image(systemName: "play.fill")
                                .font(NookTheme.font(14, .bold))
                                .foregroundStyle(NookTheme.ink)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(NookTheme.paper))
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                    .offset(y: hovering ? -3 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NookTheme.font(12.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25, bounce: 0.15), value: hovering)
        .help(item.help)
        .accessibilityLabel(item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
        .accessibilityHint(item.help)
    }
}

/// An empty, loading or unavailable state, centred in the section.
struct MusicPlaceholder<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var loading = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(NookTheme.font(22, .medium))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            Text(title)
                .font(NookTheme.font(13.5, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MusicPlaceholder where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, loading: Bool = false) {
        self.init(symbol: symbol, title: title, detail: detail, loading: loading) { EmptyView() }
    }
}
