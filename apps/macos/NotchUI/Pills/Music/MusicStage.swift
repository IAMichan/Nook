import SwiftUI

// What the Music tab shows above the player bar: lyrics, Up Next, playlists, recent tracks or a search, over the full
// width.

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
                // Paused, the position stands still: so does the timeline. Each tick only redraws the lyrics when the
                // current line changed (`SyncedLyrics` is equatable).
                TimelineView(.animation(minimumInterval: 0.25, paused: !info.isPlaying)) { context in
                    SyncedLyrics(lines: found.lines, active: found.activeIndex(at: info.estimatedPosition(at: context.date) + 0.2), onSeek: onSeek)
                        .equatable()
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
private struct SyncedLyrics: View, Equatable {
    let lines: [LyricLine]
    let active: Int?
    let onSeek: (Double) -> Void

    /// The seek action is the same for every tick of the timeline; only the lines and the current one change what shows.
    static func == (lhs: SyncedLyrics, rhs: SyncedLyrics) -> Bool {
        lhs.active == rhs.active && lhs.lines == rhs.lines
    }

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
                // Room for the current line's 1.24 scale: on a narrow stage it stays inside instead of cut at the edges.
                .containerRelativeFrame(.horizontal) { width, _ in width / 1.24 }
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
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card).fill(NookTheme.paper.opacity(hovering && state != .current ? 0.04 : 0)))
                .scaleEffect(state == .current ? 1.24 : 1)
                .padding(.vertical, state == .current ? 5 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.45, bounce: 0.1), value: state)
        .animation(NookTheme.hover, value: hovering)
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
            VStack(spacing: NookTheme.Spacing.sm) {
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
            .padding(.vertical, NookTheme.Spacing.lg)
        }
    }
}

// MARK: Up Next, playlists, recent

struct MusicUpNextView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService

    /// The player's own queue: Music's playlist order, or Spotify's queue when Spotify is connected in Settings.
    private var showsPlayerQueue: Bool { info.app == "Music" || SpotifySignIn.shared.isSignedIn }

    var body: some View {
        let queued = queuedSection
        if let queue = service.upNext, showsPlayerQueue, !queue.tracks.isEmpty {
            MusicShelf(sections: (queued.map { [$0] } ?? []) + [MusicShelf.Section(
                id: "upNext", note: note(queue), noteSymbol: info.shuffle ? "shuffle" : nil, items: items(queue)
            )])
        } else if let queued {
            MusicShelf(sections: [queued])
        } else if showsPlayerQueue, service.upNext == nil, service.libraryLoading {
            MusicPlaceholder(symbol: "list.bullet", title: tr("music.upNext.loading"), loading: true)
        } else if showsPlayerQueue {
            MusicPlaceholder(symbol: "checkmark.circle", title: tr("music.upNext.empty"), detail: tr("music.queue.emptyDetail"))
        } else {
            MusicPlaceholder(symbol: "text.line.last.and.arrowtriangle.forward", title: tr("music.queue.empty"),
                             detail: tr("music.queue.emptyDetail") + " " + tr("music.queue.connectSpotify", tr("settings.section.connections")))
        }
    }

    /// What the user queued in Nook, ahead of the player's own Up Next.
    private var queuedSection: MusicShelf.Section? {
        guard !service.playQueue.isEmpty else { return nil }
        let items = service.playQueue.entries.enumerated().map { index, entry in
            MusicCoverItem(
                id: entry.id.uuidString, title: entry.track.title, subtitle: entry.track.artist,
                artworkURL: entry.track.artworkURL, number: index + 1, help: tr("music.play"),
                secondary: .init(symbol: "minus", label: tr("music.queue.remove")) { service.removeFromQueue(entry.id) }
            ) { service.playFromQueue(entry.id) }
        }
        return MusicShelf.Section(
            id: "queue", note: tr("music.queue.note"), noteSymbol: "text.line.last.and.arrowtriangle.forward",
            items: items, trailing: .init(title: tr("music.queue.clear")) { service.clearQueue() }
        )
    }

    private func items(_ queue: MusicQueue) -> [MusicCoverItem] {
        queue.tracks.enumerated().map { index, track in
            MusicCoverItem(
                id: "\(index)|\(track.id)|\(track.title)", title: track.title, subtitle: track.artist,
                artworkURL: track.artworkURL, number: index + 1, help: tr("music.play"),
                secondary: .enqueue(track, in: service)
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
            MusicShelf(sections: [.init(id: "playlists", note: tr("music.playlists.hint"), items: items)])
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
                artworkURL: track.artworkURL, help: tr("music.play"),
                secondary: .enqueue(track, in: service)
            ) { service.play(track, fromQueue: false) }
        }
    }

    var body: some View {
        if service.recent.tracks.isEmpty {
            MusicPlaceholder(
                symbol: "clock.arrow.circlepath", title: tr("music.recent.empty"),
                detail: info.app == "Spotify" ? tr("music.spotifyNote", tr("settings.section.connections")) : nil
            )
        } else {
            MusicShelf(sections: [.init(
                id: "recent",
                note: info.app == "Spotify" ? tr("music.spotifyNote", tr("settings.section.connections")) : tr("music.recent.hint"),
                noteSymbol: info.app == "Spotify" ? "info.circle" : nil,
                items: items
            )])
        }
    }
}

/// Search the playing player: Music's library, or Spotify once it is connected. A found track plays on click, and goes
/// in the queue from the button on its cover or its context menu, like everywhere else in the tab.
struct MusicSearchView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    @State private var text = ""
    @FocusState private var focused: Bool

    private var isSpotify: Bool { info.app == "Spotify" }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            NookSearchField(prompt: isSpotify ? tr("music.search.promptSpotify") : tr("music.search.promptMusic"),
                            text: $text, focus: $focused, onSubmit: { service.search(for: text) })
                .focusOnAppear($focused)
                .padding(.horizontal, NookTheme.Spacing.xs)
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { text = service.searchResult.query }
        .onChange(of: text) { service.search(for: text) }
        // Another player started: what was found in the other one cannot play here.
        .onChange(of: info.app) {
            service.search(for: "")
            service.search(for: text)
        }
    }

    @ViewBuilder
    private var results: some View {
        let result = service.searchResult
        switch result.state {
        case .idle:
            MusicPlaceholder(symbol: "magnifyingglass", title: isSpotify ? tr("music.search.idleSpotify") : tr("music.search.idleMusic"),
                             detail: tr("music.search.idleDetail"))
        case .connectSpotify:
            MusicPlaceholder(symbol: "link", title: tr("music.search.connectSpotify"),
                             detail: tr("music.search.connectSpotifyDetail", tr("settings.section.connections")))
        case .failed(let message):
            MusicPlaceholder(symbol: "exclamationmark.triangle", title: tr("music.search.failed"), detail: message) {
                SmallGhostButton(title: tr("music.lyrics.retry")) {
                    service.search(for: "")
                    service.search(for: text)
                }
            }
        case .loading where result.tracks.isEmpty:
            MusicPlaceholder(symbol: "magnifyingglass", title: tr("music.search.loading"), loading: true)
        case .loading, .done:
            if result.tracks.isEmpty {
                MusicPlaceholder(symbol: "music.note", title: tr("music.search.empty", result.query),
                                 detail: isSpotify ? nil : tr("music.search.emptyMusicDetail"))
            } else {
                MusicShelf(sections: [.init(id: "search", note: note(result), noteSymbol: "magnifyingglass", items: items(result))])
                    .opacity(result.state == .loading ? 0.6 : 1)
                    .animation(NookTheme.hover, value: result.state)
            }
        }
    }

    private func note(_ result: MusicSearchResult) -> String {
        let count = result.tracks.count
        return isSpotify ? tr("music.search.countSpotify", count) : tr("music.search.countMusic", count)
    }

    private func items(_ result: MusicSearchResult) -> [MusicCoverItem] {
        result.tracks.enumerated().map { index, track in
            MusicCoverItem(
                id: "\(index)|\(track.id)", title: track.title, subtitle: track.artist,
                artworkURL: track.artworkURL, help: tr("music.play"),
                secondary: .enqueue(track, in: service)
            ) { service.play(track, fromQueue: false) }
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
    /// A second thing to do with the item (queue it, take it out of the queue): a small button on the cover while the
    /// pointer is over it, and the item's context menu.
    var secondary: Secondary? = nil
    let action: () -> Void

    struct Secondary {
        let symbol: String
        let label: String
        let action: () -> Void

        /// "Add to queue", for a track the player can play by its id.
        @MainActor static func enqueue(_ track: MusicTrack, in service: NowPlayingService) -> Secondary? {
            guard !track.id.isEmpty else { return nil }
            return Secondary(symbol: "text.line.last.and.arrowtriangle.forward", label: tr("music.queue.add")) { service.enqueue(track) }
        }
    }
}

/// One or more groups of covers, each under a short note, in a grid that wraps to the stage's width and scrolls when
/// there are more.
struct MusicShelf: View {
    struct Section: Identifiable {
        let id: String
        let note: String
        var noteSymbol: String? = nil
        let items: [MusicCoverItem]
        /// A small text button at the end of the note (Clear).
        var trailing: Trailing? = nil
    }

    struct Trailing {
        let title: String
        let action: () -> Void
    }

    let sections: [Section]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                        header(section)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 136), spacing: NookTheme.Spacing.xl, alignment: .top)],
                                  alignment: .leading, spacing: NookTheme.Spacing.xl + NookTheme.Spacing.xs) {
                            ForEach(section.items) { MusicCoverCard(item: $0) }
                        }
                    }
                }
            }
            .padding(.bottom, NookTheme.Spacing.xl)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .padding(.horizontal, NookTheme.Spacing.xs)
    }

    private func header(_ section: Section) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let symbol = section.noteSymbol {
                Image(systemName: symbol).font(NookTheme.font(10.5, .semibold))
            }
            Text(section.note).lineLimit(1).truncationMode(.tail)
            if let trailing = section.trailing {
                Spacer(minLength: NookTheme.Spacing.md)
                SmallGhostButton(title: trailing.title, action: trailing.action)
            }
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textTertiary)
        .help(section.note)
        .padding(.top, NookTheme.Spacing.xs)
    }
}

private struct MusicCoverCard: View {
    let item: MusicCoverItem
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
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
                    .overlay(alignment: .topTrailing) {
                        if let secondary = item.secondary {
                            NookIconButton(systemName: secondary.symbol, label: secondary.label, filled: true, size: 26, action: secondary.action)
                                .padding(6)
                                .opacity(hovering ? 1 : 0)
                        }
                    }
                    // A soft shadow and a small lift: the cover reads as something to press, without jumping.
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .offset(y: hovering ? -2 : 0)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(item.title)
                        .font(NookTheme.TextStyle.strong)
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
        .animation(NookTheme.hover, value: hovering)
        .help(item.help)
        .contextMenu {
            Button(item.help, action: item.action)
            if let secondary = item.secondary {
                Button(secondary.label, action: secondary.action)
            }
        }
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
        VStack(spacing: NookTheme.Spacing.md) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(NookTheme.font(22, .light))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.textSecondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(NookTheme.TextStyle.detail)
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
