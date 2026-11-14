import SwiftUI

// What the Music tab shows above the player bar: lyrics, Up Next and a search, over the full width. Home is in
// MusicHome.swift, the statistics in MusicStats.swift.

// MARK: Lyrics

struct MusicLyricsView: View {
    let info: NowPlayingInfo
    @ObservedObject var lyrics: LyricsService
    let onSeek: (Double) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        switch lyrics.trackKey == info.trackKey ? lyrics.state : .loading {
        case .idle, .loading:
            WSEmptyState(symbol: "quote.bubble", title: tr("music.lyrics.loading"), loading: true)
        case .notFound:
            WSEmptyState(symbol: "text.badge.xmark", title: tr("music.lyrics.notFound"), message: tr("music.lyrics.notFoundDetail")) {
                SmallGhostButton(title: tr("music.lyrics.retry")) { lyrics.load(for: info, force: true) }
            }
        case .offline:
            WSEmptyState(symbol: "network.slash", title: tr("music.lyrics.offline"), message: tr("music.lyrics.offlineDetail")) {
                SmallGhostButton(title: tr("music.lyrics.turnOn")) {
                    settings.onlineLyrics = true
                    lyrics.load(for: info, force: true)
                }
            }
        case .found(let found):
            if found.instrumental {
                WSEmptyState(symbol: "pianokeys", title: tr("music.lyrics.instrumental"))
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
                VStack(spacing: NookTheme.Spacing.md) {
                    Color.clear.frame(height: 80)
                    ForEach(lines) { line in
                        LyricRow(line: line, state: state(of: line)) {
                            if let time = line.time { onSeek(time) }
                        }
                        .id(line.id)
                    }
                    Color.clear.frame(height: 120)
                }
                // Room for the current line's larger scale: on a narrow stage it stays inside instead of cut at the edges.
                .containerRelativeFrame(.horizontal) { width, _ in width / LyricRow.currentScale }
                .frame(maxWidth: .infinity)
            }
            .mask(fade)
            .clipped()
            .contentShape(Rectangle())
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
            withAnimation(NookTheme.scroll) { proxy.scrollTo(active, anchor: anchor) }
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
    /// The current line, a step larger than the rest.
    static let currentScale: CGFloat = 1.16
    let line: LyricLine
    let state: State
    let action: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(NookTheme.TextStyle.heading)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Narrow enough that the enlarged current line still fits the stage.
                .frame(maxWidth: 540)
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.xs)
                .roundedBackground(hovering && state != .current ? NookTheme.rowHover : Color.clear, radius: NookTheme.Radius.card)
                .scaleEffect(state == .current ? Self.currentScale : 1)
                .padding(.vertical, state == .current ? NookTheme.Spacing.xs : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.open, value: state)
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.lyrics.seekHint"))
    }

    /// The current line bright, what comes still readable, what passed further back.
    private var color: Color {
        if hovering && state != .current { return NookTheme.textStrong }
        switch state {
        case .current: return NookTheme.paper
        case .past: return NookTheme.paper.opacity(0.24)
        case .upcoming: return NookTheme.paper.opacity(0.42)
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
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textStrong)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560)
                }
            }
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
            .padding(.vertical, NookTheme.Spacing.lg)
        }
        .clipped()
        .contentShape(Rectangle())
    }
}

// MARK: Up Next (playlists are in MusicPlaylists.swift)

struct MusicUpNextView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    /// In line with the card's tabs in Now Playing; with the page's edge on the Up next page.
    var inset: CGFloat = NookTheme.Spacing.lg

    /// The player's own queue: Music's playlist order, or Spotify's queue when Spotify is connected in Settings.
    private var showsPlayerQueue: Bool { info.app == "Music" || SpotifySignIn.shared.isSignedIn }

    var body: some View {
        let queued = service.playQueue.entries
        let upcoming = showsPlayerQueue ? service.upNext?.tracks ?? [] : []
        if !queued.isEmpty || !upcoming.isEmpty {
            // A queue is an order, so it reads as a numbered list, as in an open playlist.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxxl) {
                    if !queued.isEmpty {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                            MusicGroupTitle(title: tr("music.queue.count", queued.count), detail: tr("music.queue.note"),
                                            trailing: (tr("music.queue.clear"), { service.clearQueue() }))
                            LazyVStack(spacing: 0) {
                                ForEach(Array(queued.enumerated()), id: \.element.id) { index, entry in
                                    MusicTrackRow(number: index + 1, track: entry.track, playing: false, service: service,
                                                  onRemove: { service.removeFromQueue(entry.id) }, removeLabel: tr("music.queue.remove"),
                                                  queues: false) {
                                        service.playFromQueue(entry.id)
                                    }
                                }
                            }
                            .musicRowBleed()
                        }
                    }
                    if !upcoming.isEmpty, let queue = service.upNext {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                            MusicGroupTitle(title: queue.playlist.isEmpty ? tr("music.section.upNext") : tr("music.upNext.from", queue.playlist),
                                            detail: info.shuffle ? tr("music.upNext.shuffleNote") : nil)
                            LazyVStack(spacing: 0) {
                                ForEach(Array(upcoming.enumerated()), id: \.offset) { index, track in
                                    MusicTrackRow(number: index + 1, track: track, playing: false, service: service) {
                                        service.play(track, fromQueue: true)
                                    }
                                }
                            }
                            .musicRowBleed()
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.bottom, NookTheme.Spacing.xl)
            }
        } else if showsPlayerQueue, service.upNext == nil, service.libraryLoading {
            WSEmptyState(symbol: "list.bullet", title: tr("music.upNext.loading"), loading: true)
        } else if showsPlayerQueue {
            WSEmptyState(symbol: "checkmark.circle", title: tr("music.upNext.empty"), message: tr("music.queue.emptyDetail"))
        } else {
            WSEmptyState(symbol: "text.line.last.and.arrowtriangle.forward", title: tr("music.queue.empty"),
                         message: tr("music.queue.emptyDetail") + " " + tr("music.queue.connectSpotify", tr("settings.section.connections")))
        }
    }
}

/// The Up next page: what plays after this track, in order, to play from, take out of or clear. With nothing playing it
/// says how to fill it.
struct MusicQueuePage: View {
    let info: NowPlayingInfo?
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if let info {
            MusicUpNextView(info: info, service: service, inset: MusicLayout.edge)
        } else if !service.playQueue.entries.isEmpty {
            // Queued while nothing plays: the first one starts it all.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    MusicGroupTitle(title: tr("music.queue.count", service.playQueue.entries.count), detail: tr("music.queue.note"),
                                    trailing: (tr("music.queue.clear"), { service.clearQueue() }))
                    LazyVStack(spacing: 0) {
                        ForEach(Array(service.playQueue.entries.enumerated()), id: \.element.id) { index, entry in
                            MusicTrackRow(number: index + 1, track: entry.track, playing: false, service: service,
                                          onRemove: { service.removeFromQueue(entry.id) }, removeLabel: tr("music.queue.remove"),
                                          queues: false) {
                                service.playFromQueue(entry.id)
                            }
                        }
                    }
                    .musicRowBleed()
                }
                .padding(.horizontal, MusicLayout.edge)
                .padding(.bottom, NookTheme.Spacing.xl)
            }
        } else {
            WSEmptyState(symbol: "list.bullet", title: tr("music.queue.empty"), message: tr("music.queue.howTo")) {
                SmallPrimaryButton(title: tr("music.section.search"), systemName: "magnifyingglass") { MusicSection.show(.search) }
            }
        }
    }
}

/// Search the player: Music's library, or Spotify once it is connected. In the main window the field is in the page's
/// header (`MusicPageView`), so a search starts from every page; beside another tab it stands here. Before typing it
/// shows what was searched and played last. A list reads quicker than covers here: the best match on top, Return plays
/// it, a click plays any row and the rest of the list after it, and every row says what else it can do.
struct MusicSearchView: View {
    @ObservedObject var service: NowPlayingService
    /// The field stands on the page itself: in the notch and beside another tab, where the header holds the tabs.
    var showsField = true
    @ObservedObject private var search = MusicSearchModel.shared
    @EnvironmentObject private var app: AppModel
    @FocusState private var focused: Bool

    private var isSpotify: Bool { service.searchApp == "Spotify" }
    private var query: String { search.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if showsField {
                NookSearchField(prompt: isSpotify ? tr("music.search.promptSpotify") : tr("music.search.promptMusic"),
                                text: $search.text, focus: $focused, onSubmit: { Self.playBest(service: service, text: search.text) })
                    .focusOnAppear($focused)
                    .padding(.horizontal, MusicLayout.edge)
            }
            Group {
                if query.isEmpty { idle } else { results }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Return plays the best match, once the list on screen belongs to what was typed.
    static func playBest(service: NowPlayingService, text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = service.searchResult
        guard result.query == query, result.state == .done, !result.tracks.isEmpty else {
            service.search(for: text)
            return
        }
        play(0, of: result, service: service)
    }

    private static func play(_ index: Int, of result: MusicSearchResult, service: NowPlayingService) {
        service.rememberSearch(result.query)
        service.play(result.tracks[index], fromQueue: false,
                     following: Array(result.tracks.dropFirst(index + 1).prefix(SpotifyResponses.playTrackLimit - 1)))
    }

    private func play(_ index: Int, of result: MusicSearchResult) { Self.play(index, of: result, service: service) }

    // MARK: Before typing

    @ViewBuilder
    private var idle: some View {
        let searches = service.history.searches
        let recent = service.recent.tracks
        if searches.isEmpty, recent.isEmpty {
            WSEmptyState(symbol: "magnifyingglass", title: isSpotify ? tr("music.search.idleSpotify") : tr("music.search.idleMusic"),
                         message: tr("music.search.idleDetail"))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                    if !searches.isEmpty {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                            MusicGroupTitle(title: tr("music.search.recent"))
                            FlowingChips(searches: searches, onPick: { search.text = $0 }, onForget: { service.forgetSearch($0) })
                        }
                    }
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                            MusicGroupTitle(title: tr("music.recent.title"))
                            LazyVStack(spacing: 0) {
                                ForEach(Array(recent.enumerated()), id: \.offset) { index, track in
                                    MusicTrackRow(track: track, playing: service.current?.trackID == track.id, service: service) {
                                        service.play(track, fromQueue: false, following: Array(recent.dropFirst(index + 1).prefix(SpotifyResponses.playTrackLimit - 1)))
                                    }
                                }
                            }
                            .musicRowBleed()
                        }
                    }
                }
                .padding(.horizontal, MusicLayout.edge)
                .padding(.bottom, NookTheme.Spacing.xl)
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        let result = service.searchResult
        switch result.state {
        case .idle:
            WSEmptyState(symbol: "magnifyingglass", title: tr("music.search.loading"), loading: true)
        case .connectSpotify, .reconnectSpotify:
            WSEmptyState(symbol: "link", title: tr("music.search.connectSpotify"),
                         message: tr("music.search.connectSpotifyDetail", tr("settings.section.connections"))) {
                SmallPrimaryButton(title: tr("music.playlists.openConnections")) { app.openSettings(section: .connections) }
            }
        case .failed(let message):
            WSEmptyState(loadFailed: tr("music.search.failed"), message: message, retryTitle: tr("music.search.retry")) {
                service.search(for: "")
                service.search(for: search.text)
            }
        case .loading where result.tracks.isEmpty:
            WSEmptyState(symbol: "magnifyingglass", title: tr("music.search.loading"), loading: true)
        case .loading, .done:
            if result.tracks.isEmpty {
                WSEmptyState(symbol: "music.note", title: tr("music.search.empty", result.query),
                             message: isSpotify ? nil : tr("music.search.emptyMusicDetail"))
            } else {
                list(result)
                    .opacity(result.state == .loading ? 0.6 : 1)
                    .animation(NookTheme.hover, value: result.state)
            }
        }
    }

    private func list(_ result: MusicSearchResult) -> some View {
        let artists = Self.artists(in: result.tracks, query: result.query)
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                MusicGroupTitle(title: tr("music.search.best"))
                MusicBestMatch(track: result.tracks[0], playing: service.current?.trackID == result.tracks[0].id, service: service) {
                    play(0, of: result)
                }
                .musicRowBleed()
                if !artists.isEmpty {
                    MusicGroupTitle(title: tr("music.search.artists")).padding(.top, NookTheme.Spacing.lg)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            ForEach(artists, id: \.self) { artist in
                                MusicArtistChip(name: artist) { search.find(artist) }
                            }
                        }
                    }
                }
                if result.tracks.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                        MusicGroupTitle(title: note(result))
                        SmallGhostButton(title: tr("music.search.playAll")) { play(0, of: result) }
                            .padding(.trailing, -NookTheme.Spacing.md)
                    }
                    .padding(.top, NookTheme.Spacing.xl)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(result.tracks.enumerated().dropFirst()), id: \.offset) { index, track in
                            MusicTrackRow(track: track, playing: service.current?.trackID == track.id, service: service) {
                                play(index, of: result)
                            }
                        }
                    }
                    .musicRowBleed()
                }
            }
            .padding(.horizontal, MusicLayout.edge)
            .padding(.bottom, NookTheme.Spacing.xl)
        }
    }

    /// The artists among the results, most found first, to search for on their own: not the one already searched for.
    static func artists(in tracks: [MusicTrack], query: String) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for track in tracks {
            // "Artist A, Artist B" and "A & B" are several people: the first is the one the track is by.
            guard let name = MusicTrackMenuItems.artist(of: track) else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let typed = query.lowercased()
        return order.filter { $0.lowercased() != typed }
            .sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
            .prefix(8)
            .map { $0 }
    }

    private func note(_ result: MusicSearchResult) -> String {
        let count = result.tracks.count
        return isSpotify ? tr("music.search.countSpotify", count) : tr("music.search.countMusic", count)
    }
}

/// An artist found in a search: a click searches for all of their music.
private struct MusicArtistChip: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: "music.mic").font(NookTheme.font(11, .semibold))
                Text(name).font(NookTheme.TextStyle.label).lineLimit(1)
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 28)
            .roundedBackground(hovering ? NookTheme.graphite : NookTheme.surface, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.home.searchArtist", name))
        .accessibilityLabel(tr("music.home.searchArtist", name))
    }
}

/// The name of a group on a Music page: a title, a line under it when it needs one, and on the right "Show all" or a
/// small action (Clear).
struct MusicGroupTitle: View {
    let title: String
    var detail: String? = nil
    var showAll: (() -> Void)? = nil
    var trailing: (title: String, action: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title)
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .help(detail)
                }
            }
            Spacer(minLength: NookTheme.Spacing.md)
            if let showAll { MusicShowAllButton(action: showAll) }
            if let trailing {
                SmallGhostButton(title: trailing.title, action: trailing.action)
                    .padding(.trailing, -NookTheme.Spacing.md)
            }
        }
    }
}

/// Recent searches: click to search again, the cross to forget one.
private struct FlowingChips: View {
    let searches: [String]
    let onPick: (String) -> Void
    let onForget: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ForEach(searches, id: \.self) { search in
                    RecentSearchChip(text: search, onPick: { onPick(search) }, onForget: { onForget(search) })
                }
            }
        }
    }
}

private struct RecentSearchChip: View {
    let text: String
    let onPick: () -> Void
    let onForget: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Button(action: onPick) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: "clock.arrow.circlepath").font(NookTheme.font(10, .semibold))
                    Text(text).font(NookTheme.TextStyle.label).lineLimit(1)
                }
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            ToolbarIconButton("xmark", tr("music.search.forget"), height: 18, width: 18, onForget)
                .opacity(hovering ? 1 : 0.4)
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        .background(NookTheme.shape(NookTheme.Radius.control).fill(hovering ? NookTheme.graphite : NookTheme.surface))
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// The search's best match: a large row with its own play button.
private struct MusicBestMatch: View {
    let track: MusicTrack
    let playing: Bool
    @ObservedObject var service: NowPlayingService
    let action: () -> Void

    var body: some View {
        // Its buttons beside the part that plays, not inside it, so adding it somewhere never starts it.
        HStack(spacing: NookTheme.Spacing.md) {
            Button(action: action) {
                HStack(spacing: NookTheme.Spacing.xl) {
                    MusicArtwork(url: track.artworkURL, seed: track.title, cornerRadius: NookTheme.Radius.control)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                        Text(track.title)
                            .font(NookTheme.TextStyle.heading)
                            .foregroundStyle(playing ? NookTheme.music : NookTheme.paper)
                            .lineLimit(1)
                        Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(tr("music.play"))
            .accessibilityLabel(track.artist.isEmpty ? track.title : "\(track.title), \(track.artist)")
            .accessibilityHint(tr("music.play"))
            ToolbarIconButton("text.line.last.and.arrowtriangle.forward", tr("music.queue.add"), height: 32, width: 32, symbolSize: 13) {
                service.enqueue(track)
            }
            MusicAddToPlaylistButton(track: track, service: service, size: 32)
            Button(action: action) {
                Image(icon: "play.fill")
                    .font(NookTheme.font(13, .bold))
                    .foregroundStyle(NookTheme.onPaper)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(NookTheme.paper))
            }
            .buttonStyle(.nookPlain)
            .help(tr("music.play"))
            .accessibilityLabel(tr("music.play"))
            .padding(.trailing, NookTheme.Spacing.md)
        }
        .padding(MusicLayout.rowBleed)
        .hoverRowFill(radius: NookTheme.Radius.panel)
        .roundedHitShape(NookTheme.Radius.panel)
        .contextMenu {
            MusicTrackMenuItems(track: track, service: service, play: action)
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
    let help: String
    /// What the cover shows under the pointer: what a click does.
    var hoverSymbol = "play.fill"
    /// A second thing to do with the item (queue it, take it out of the queue): a small button on the cover while the
    /// pointer is over it, and the item's context menu.
    var secondary: Secondary? = nil
    /// More things to do with the item, in its context menu only.
    var menu: [Secondary] = []
    /// A destructive one, last in the context menu.
    var destructive: Secondary? = nil
    /// The track the item is, for "Add to playlist" in its context menu.
    var track: MusicTrack? = nil
    /// This is what plays now.
    var playing = false
    /// A person (an artist): a round picture.
    var round = false
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

/// Covers in a grid that wraps to the page's width, under a short note, and scrolls when there are more.
struct MusicShelf: View {
    let note: String
    let items: [MusicCoverItem]
    /// For "Add to playlist" in the context menu of the tracks.
    var service: NowPlayingService? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                Text(note)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: MusicLayout.cover), spacing: NookTheme.Spacing.xl, alignment: .top)],
                          alignment: .leading, spacing: NookTheme.Spacing.xxl) {
                    ForEach(items) { MusicCoverCard(item: $0, service: service) }
                }
            }
            .padding(.horizontal, MusicLayout.edge)
            .padding(.bottom, NookTheme.Spacing.xl)
        }
    }
}

struct MusicCoverCard: View {
    let item: MusicCoverItem
    let service: NowPlayingService?
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if item.round {
                            MusicArtwork(url: item.artworkURL, seed: item.title, symbol: item.symbol, cornerRadius: 0)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(NookTheme.paper.opacity(0.08), lineWidth: 1))
                        } else {
                            MusicArtwork(url: item.artworkURL, seed: item.title, symbol: item.symbol, cornerRadius: NookTheme.Radius.card)
                        }
                    }
                    .shadow(color: .black.opacity(hovering ? 0.45 : 0.3), radius: hovering ? 14 : 8, y: hovering ? 8 : 4)
                    .overlay(alignment: .bottomLeading) {
                        if item.playing {
                            EqualizerBars(color: NookTheme.music, height: 10, isPlaying: service?.current?.isPlaying ?? false)
                                .scaleEffect(0.7, anchor: .leading)
                                .padding(NookTheme.Spacing.sm)
                                .background(NookTheme.shape(NookTheme.Radius.chip).fill(Color.black.opacity(0.6)))
                                .padding(NookTheme.Spacing.sm)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay {
                        // Under the pointer: a soft shade and what a click does, in the corner.
                        (item.round ? AnyShape(Circle()) : AnyShape(NookTheme.shape(NookTheme.Radius.card)))
                            .fill(Color.black.opacity(0.25))
                            .overlay(alignment: item.round ? .center : .bottomTrailing) {
                                Image(icon: item.hoverSymbol)
                                    .font(NookTheme.font(13, .bold))
                                    .foregroundStyle(NookTheme.onPaper)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(item.hoverSymbol == "play.fill" ? NookTheme.music : NookTheme.paper))
                                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                                    .offset(y: hovering ? 0 : 6)
                                    .padding(NookTheme.Spacing.md)
                            }
                            .opacity(hovering ? 1 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let secondary = item.secondary {
                            NookIconButton(systemName: secondary.symbol, label: secondary.label, size: 26, action: secondary.action)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                                .padding(NookTheme.Spacing.sm)
                                .opacity(hovering ? 1 : 0)
                        }
                    }
                // Under a round face the name is centred, as under a person; under a cover it starts at its edge.
                VStack(alignment: item.round ? .center : .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(item.title)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(item.playing ? NookTheme.music : NookTheme.paper)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: item.round ? .center : .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(item.help)
        .contextMenu {
            Button(item.help, action: item.action)
            if let secondary = item.secondary, !item.menu.contains(where: { $0.label == secondary.label }) {
                Button(secondary.label, action: secondary.action)
            }
            ForEach(Array(item.menu.enumerated()), id: \.offset) { _, entry in
                Button(entry.label, action: entry.action)
            }
            if let track = item.track, let service {
                MusicAddToPlaylistMenu(track: track, service: service)
            }
            if let destructive = item.destructive {
                Divider()
                Button(destructive.label, role: .destructive, action: destructive.action)
            }
        }
        .accessibilityLabel(item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
        .accessibilityHint(item.help)
    }
}
