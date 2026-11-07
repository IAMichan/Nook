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
        .clipped()
        .contentShape(Rectangle())
    }
}

// MARK: Up Next (playlists are in MusicPlaylists.swift)

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
            )], service: service)
        } else if let queued {
            MusicShelf(sections: [queued], service: service)
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
                secondary: .init(symbol: "minus", label: tr("music.queue.remove")) { service.removeFromQueue(entry.id) },
                track: entry.track
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
                secondary: .enqueue(track, in: service), track: track
            ) { service.play(track, fromQueue: true) }
        }
    }

    private func note(_ queue: MusicQueue) -> String {
        let from = queue.playlist.isEmpty ? tr("music.section.upNext") : tr("music.upNext.from", queue.playlist)
        return info.shuffle ? from + " · " + tr("music.upNext.shuffleNote") : from
    }
}

/// Search the player: Music's library, or Spotify once it is connected. Before typing it shows what was searched and
/// played last. A list reads quicker than covers here: the best match on top, Return plays it, a click plays any row
/// and the rest of the list after it.
struct MusicSearchView: View {
    @ObservedObject var service: NowPlayingService
    @EnvironmentObject private var app: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var isSpotify: Bool { service.searchApp == "Spotify" }
    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            NookSearchField(prompt: isSpotify ? tr("music.search.promptSpotify") : tr("music.search.promptMusic"),
                            text: $text, focus: $focused, onSubmit: submit)
                .focusOnAppear($focused)
                .padding(.horizontal, NookTheme.Spacing.xs)
            Group {
                if query.isEmpty { idle } else { results }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { text = service.searchResult.query }
        .onChange(of: text) { service.search(for: text) }
        // Another player started: what was found in the other one cannot play here.
        .onChange(of: service.searchApp) {
            service.search(for: "")
            service.search(for: text)
        }
    }

    /// Return plays the best match, once the list on screen belongs to what was typed.
    private func submit() {
        let result = service.searchResult
        guard result.query == query, result.state == .done, !result.tracks.isEmpty else {
            service.search(for: text)
            return
        }
        play(0, of: result)
    }

    private func play(_ index: Int, of result: MusicSearchResult) {
        service.rememberSearch(result.query)
        service.play(result.tracks[index], fromQueue: false, following: Array(result.tracks.dropFirst(index + 1).prefix(SpotifyResponses.playTrackLimit - 1)))
    }

    // MARK: Before typing

    @ViewBuilder
    private var idle: some View {
        let searches = service.history.searches
        let recent = service.recent.tracks
        if searches.isEmpty, recent.isEmpty {
            MusicPlaceholder(symbol: "magnifyingglass", title: isSpotify ? tr("music.search.idleSpotify") : tr("music.search.idleMusic"),
                             detail: tr("music.search.idleDetail"))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                    if !searches.isEmpty {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                            MusicGroupTitle(title: tr("music.search.recent"))
                            FlowingChips(searches: searches, onPick: { text = $0 }, onForget: { service.forgetSearch($0) })
                        }
                    }
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                            MusicGroupTitle(title: tr("music.recent.title"))
                            LazyVStack(spacing: 0) {
                                ForEach(Array(recent.enumerated()), id: \.offset) { index, track in
                                    if index > 0 { NookDivider(inset: 52) }
                                    MusicTrackRow(track: track, playing: service.current?.trackID == track.id, service: service) {
                                        service.play(track, fromQueue: false, following: Array(recent.dropFirst(index + 1).prefix(SpotifyResponses.playTrackLimit - 1)))
                                    }
                                }
                            }
                            .panelCard()
                        }
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
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
            MusicPlaceholder(symbol: "magnifyingglass", title: tr("music.search.loading"), loading: true)
        case .connectSpotify, .reconnectSpotify:
            MusicPlaceholder(symbol: "link", title: tr("music.search.connectSpotify"),
                             detail: tr("music.search.connectSpotifyDetail", tr("settings.section.connections"))) {
                SmallPrimaryButton(title: tr("music.playlists.openConnections")) { app.openSettings(section: .connections) }
            }
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
                list(result)
                    .opacity(result.state == .loading ? 0.6 : 1)
                    .animation(NookTheme.hover, value: result.state)
            }
        }
    }

    private func list(_ result: MusicSearchResult) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                MusicGroupTitle(title: tr("music.search.best"))
                MusicBestMatch(track: result.tracks[0], playing: service.current?.trackID == result.tracks[0].id, service: service) {
                    play(0, of: result)
                }
                if result.tracks.count > 1 {
                    MusicGroupTitle(title: note(result)).padding(.top, NookTheme.Spacing.md)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(result.tracks.enumerated().dropFirst()), id: \.offset) { index, track in
                            if index > 1 { NookDivider(inset: 52) }
                            MusicTrackRow(track: track, playing: service.current?.trackID == track.id, service: service) {
                                play(index, of: result)
                            }
                        }
                    }
                    .panelCard()
                }
            }
            .padding(.horizontal, NookTheme.Spacing.xs)
            .padding(.bottom, NookTheme.Spacing.xl)
        }
    }

    private func note(_ result: MusicSearchResult) -> String {
        let count = result.tracks.count
        return isSpotify ? tr("music.search.countSpotify", count) : tr("music.search.countMusic", count)
    }
}

/// The name of a group on the Music page: quiet and balanced beneath the page's top header.
struct MusicGroupTitle: View {
    let title: String
    var showAll: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: NookTheme.Spacing.md)
            if let showAll { MusicShowAllButton(action: showAll) }
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
                    Image(systemName: "clock.arrow.circlepath").font(NookTheme.font(10, .semibold))
                    Text(text).font(NookTheme.TextStyle.label).lineLimit(1)
                }
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ToolbarIconButton("xmark", tr("music.search.forget"), height: 18, width: 18, onForget)
                .opacity(hovering ? 1 : 0.4)
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        .background(Capsule().fill(hovering ? NookTheme.graphite : NookTheme.surface))
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xl) {
                MusicArtwork(url: track.artworkURL, seed: track.title, cornerRadius: NookTheme.Radius.card)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
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
                Image(systemName: "play.fill")
                    .font(NookTheme.font(13, .bold))
                    .foregroundStyle(NookTheme.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(NookTheme.paper))
                    .opacity(hovering ? 1 : 0.85)
            }
            .padding(NookTheme.Spacing.lg)
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
    /// For "Add to playlist" in the context menu of the tracks.
    var service: NowPlayingService? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                        header(section)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 136), spacing: NookTheme.Spacing.xl, alignment: .top)],
                                  alignment: .leading, spacing: NookTheme.Spacing.xl + NookTheme.Spacing.xs) {
                            ForEach(section.items) { MusicCoverCard(item: $0, service: service) }
                        }
                    }
                }
            }
            .padding(.bottom, NookTheme.Spacing.xl)
        }
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

struct MusicCoverCard: View {
    let item: MusicCoverItem
    let service: NowPlayingService?
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
                    .overlay(alignment: .bottomLeading) {
                        if item.playing {
                            EqualizerBars(color: NookTheme.music, height: 10, isPlaying: service?.current?.isPlaying ?? false)
                                .scaleEffect(0.7, anchor: .leading)
                                .padding(NookTheme.Spacing.sm)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                                .padding(NookTheme.Spacing.sm)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(Color.black.opacity(0.35))
                            Image(systemName: item.hoverSymbol)
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
                        .foregroundStyle(item.playing ? NookTheme.music : NookTheme.paper)
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
