import SwiftUI

/// Music tab: the playing track in Spotify or Music with playback controls on the left, and lyrics, Up Next, playlists
/// and recently played tracks on the right.
struct MusicTab: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let info = app.nowPlaying.current {
            MusicPlayerView(info: info, service: app.nowPlaying)
        } else {
            idle
        }
    }

    @ViewBuilder
    private var idle: some View {
        if app.nowPlaying.permissionDenied { denied } else { nothingPlaying }
    }

    private var denied: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("music.deniedTitle"))
                .font(NookTheme.font(17, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("music.deniedDetail"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
            Button(tr("button.openAutomation")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(NookTheme.font(12, .semibold))
            .foregroundStyle(NookTheme.paper)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nothingPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("music.nothingPlayingTitle"))
                .font(NookTheme.font(17, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("music.nothingPlayingDetail"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
            Text(tr("music.permissionNote"))
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the right side of the Music tab shows.
private enum MusicSection: String, CaseIterable, Identifiable {
    case lyrics, upNext, playlists, recent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: return tr("music.section.lyrics")
        case .upNext: return tr("music.section.upNext")
        case .playlists: return tr("music.section.playlists")
        case .recent: return tr("music.section.recent")
        }
    }

    var symbol: String {
        switch self {
        case .lyrics: return "quote.bubble"
        case .upNext: return "list.bullet"
        case .playlists: return "music.note.list"
        case .recent: return "clock.arrow.circlepath"
        }
    }

    /// Spotify's AppleScript has no queue or playlists.
    static func available(for app: String) -> [MusicSection] {
        app == "Music" ? allCases : [.lyrics, .recent]
    }
}

private struct MusicPlayerView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var lyrics = LyricsService.shared
    @AppStorage("musicSection") private var storedSection = MusicSection.lyrics.rawValue

    private var sections: [MusicSection] { MusicSection.available(for: info.app) }
    private var section: MusicSection {
        let stored = MusicSection(rawValue: storedSection) ?? .lyrics
        return sections.contains(stored) ? stored : .lyrics
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            controls
                .frame(width: 244)
            VStack(alignment: .leading, spacing: 12) {
                sectionPicker
                Group {
                    switch section {
                    case .lyrics: MusicLyricsView(info: info, lyrics: lyrics) { service.seek(to: $0) }
                    case .upNext: MusicUpNextView(info: info, service: service)
                    case .playlists: MusicPlaylistsView(service: service)
                    case .recent: MusicRecentView(info: info, service: service)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: "\(info.trackKey)|\(section.rawValue)") { load() }
        .onChange(of: info.shuffle) { if section == .upNext { service.refreshUpNext() } }
    }

    private func load() {
        switch section {
        case .lyrics: lyrics.load(for: info)
        case .upNext: service.refreshUpNext()
        case .playlists: service.refreshPlaylists()
        case .recent: break
        }
    }

    // MARK: Player

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(NookTheme.font(16, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .help(info.title)
                Text(subtitle)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                    .help(subtitle)
            }
            MusicScrubBar(info: info) { seconds in service.seek(to: seconds) }
            HStack(spacing: 2) {
                MusicToggleButton(systemName: "shuffle", label: tr("music.shuffle"), isOn: info.shuffle) {
                    service.setShuffle(!info.shuffle)
                }
                Spacer(minLength: 0)
                NookIconButton(systemName: "backward.fill", label: tr("music.previous")) { service.control(.previous) }
                NookIconButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", label: info.isPlaying ? tr("music.pause") : tr("music.play"), filled: true, size: 40) {
                    service.control(.playPause)
                }
                NookIconButton(systemName: "forward.fill", label: tr("music.next")) { service.control(.next) }
                Spacer(minLength: 0)
                MusicToggleButton(systemName: "repeat", label: tr("music.repeat"), isOn: info.repeating) {
                    service.setRepeat(!info.repeating)
                }
            }
            HStack(spacing: 8) {
                if let volume = info.volume {
                    MusicVolumeControl(volume: volume) { service.setVolume($0) }
                }
                Spacer(minLength: 0)
                NookIconButton(systemName: "arrow.up.forward.app", label: tr("music.openPlayer", appName), size: 30) { openPlayer() }
                    .help(tr("music.openPlayer", appName))
            }
        }
    }

    private var appName: String { info.app == "Music" ? tr("tab.music") : info.app }

    private var subtitle: String {
        [info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " · ").nonEmpty ?? appName
    }

    private func openPlayer() {
        let bundleID = info.app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16).fill(NookTheme.music)
            if let url = info.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(NookTheme.ink.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            EqualizerBars(color: info.artworkURL == nil ? NookTheme.ink : NookTheme.paper, isPlaying: info.isPlaying)
                .padding(12)
                .shadow(color: .black.opacity(info.artworkURL == nil ? 0 : 0.5), radius: 4)
        }
        .frame(width: 168, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .frame(maxWidth: .infinity)
    }

    // MARK: Sections

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(sections) { item in
                MusicSectionPill(section: item, selected: item == section) { storedSection = item.rawValue }
            }
            Spacer(minLength: 8)
            if info.app == "Spotify" {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .help(tr("music.spotifyNote"))
                    .accessibilityLabel(tr("music.spotifyNote"))
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private struct MusicSectionPill: View {
    let section: MusicSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: section.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(section.title).font(NookTheme.font(12, .medium))
            }
            .foregroundStyle(selected ? NookTheme.ink : (hovering ? NookTheme.paper : NookTheme.textSecondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? NookTheme.paper : (hovering ? NookTheme.smoke : NookTheme.graphite)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Lyrics

private struct MusicLyricsView: View {
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
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if found.isSynced {
                        TimelineView(.periodic(from: .now, by: 0.25)) { context in
                            SyncedLyrics(lines: found.lines, active: found.activeIndex(at: info.estimatedPosition(at: context.date) + 0.2), onSeek: onSeek)
                        }
                    } else {
                        PlainLyrics(lines: found.lines)
                    }
                    Text(footer(found))
                        .font(NookTheme.font(10.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
        }
    }

    private func footer(_ found: Lyrics) -> String {
        let source = found.source == .lrclib ? tr("music.lyrics.sourceLrclib") : tr("music.lyrics.sourcePlayer")
        return found.isSynced ? source : source + " · " + tr("music.lyrics.unsynced")
    }
}

/// Synced lyrics: the current line large and bright, kept in the middle; click a line to jump there.
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    let active: Int?
    let onSeek: (Double) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear.frame(height: 60)
                    ForEach(lines) { line in
                        LyricRow(line: line, state: state(of: line)) {
                            if let time = line.time { onSeek(time) }
                        }
                        .id(line.id)
                    }
                    Color.clear.frame(height: 90)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        if animated {
            withAnimation(.spring(duration: 0.45, bounce: 0.1)) { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.38)) }
        } else {
            proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.38))
        }
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.14),
            .init(color: .black, location: 0.82),
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
                .font(NookTheme.font(state == .current ? 19 : 16, state == .current ? .bold : .semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: state)
        .help(tr("music.lyrics.seekHint"))
    }

    private var color: Color {
        if hovering && state != .current { return NookTheme.paper.opacity(0.85) }
        switch state {
        case .current: return NookTheme.paper
        case .past: return NookTheme.textTertiary.opacity(0.8)
        case .upcoming: return NookTheme.textSecondary.opacity(0.75)
        }
    }
}

private struct PlainLyrics: View {
    let lines: [LyricLine]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(NookTheme.font(14.5, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(.bottom, 12)
        }
    }
}

// MARK: Up Next, playlists, recent

private struct MusicUpNextView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if let queue = service.upNext {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(queue.playlist.isEmpty ? tr("music.section.upNext") : tr("music.upNext.from", queue.playlist))
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                    if info.shuffle {
                        Image(systemName: "shuffle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NookTheme.music)
                            .help(tr("music.upNext.shuffleNote"))
                    }
                }
                if queue.tracks.isEmpty {
                    MusicPlaceholder(symbol: "checkmark.circle", title: tr("music.upNext.empty"))
                } else {
                    MusicTrackList(tracks: queue.tracks, numbered: true) { service.play($0, fromQueue: true) }
                }
            }
        } else if service.libraryLoading {
            MusicPlaceholder(symbol: "list.bullet", title: tr("music.upNext.loading"), loading: true)
        } else {
            MusicPlaceholder(symbol: "list.bullet", title: tr("music.upNext.empty"))
        }
    }
}

private struct MusicPlaylistsView: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if service.playlists.isEmpty {
            MusicPlaceholder(symbol: "music.note.list", title: tr("music.playlists.empty"))
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    ForEach(service.playlists) { playlist in
                        MusicRow(action: { service.play(playlist) }, help: tr("music.playlists.play", playlist.name)) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(NookTheme.smoke)
                                .frame(width: 30, height: 30)
                                .overlay(Image(systemName: "music.note.list").font(.system(size: 12, weight: .semibold)).foregroundStyle(NookTheme.music))
                            Text(playlist.name)
                                .font(NookTheme.font(13, .medium))
                                .foregroundStyle(NookTheme.paper)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(tr("music.playlists.count", playlist.trackCount))
                                .font(NookTheme.font(11.5))
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }
}

private struct MusicRecentView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if service.recent.tracks.isEmpty {
            MusicPlaceholder(symbol: "clock.arrow.circlepath", title: tr("music.recent.empty"))
        } else {
            MusicTrackList(tracks: service.recent.tracks, numbered: false) { service.play($0, fromQueue: false) }
        }
    }
}

private struct MusicTrackList: View {
    let tracks: [MusicTrack]
    let numbered: Bool
    let onPlay: (MusicTrack) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 2) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    MusicRow(action: { onPlay(track) }, help: tr("music.play")) {
                        leading(index: index, track: track)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(NookTheme.font(13, .medium))
                                .foregroundStyle(NookTheme.paper)
                                .lineLimit(1)
                            if !track.artist.isEmpty {
                                Text(track.artist)
                                    .font(NookTheme.font(11.5))
                                    .foregroundStyle(NookTheme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if track.duration > 0 {
                            Text(musicClock(Double(track.duration)))
                                .font(NookTheme.mono(11))
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func leading(index: Int, track: MusicTrack) -> some View {
        if numbered {
            Text("\(index + 1)")
                .font(NookTheme.mono(11))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 22, alignment: .trailing)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(NookTheme.smoke)
                if let url = track.artworkURL {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Image(systemName: "music.note").font(.system(size: 11, weight: .semibold)).foregroundStyle(NookTheme.textTertiary)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// A clickable list row: highlights on hover and shows a play glyph.
private struct MusicRow<Content: View>: View {
    let action: () -> Void
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                content()
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(NookTheme.paper)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// An empty, loading or unavailable state, centred in the section.
private struct MusicPlaceholder<Actions: View>: View {
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
                    .font(.system(size: 22, weight: .medium))
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

/// Mm:ss format for elapsed and remaining time.
private func musicClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Progress bar for scrubbing: click or drag. Elapsed time on the left, remaining on the right.
private struct MusicScrubBar: View {
    let info: NowPlayingInfo
    let onSeek: (Double) -> Void
    /// Scrub drag destination (0…1). `nil` when not scrubbing.
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        // Spotify and Music are polled every 2 seconds; time advances locally in between.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = Double(info.duration)
            let position = dragFraction.map { $0 * duration } ?? info.estimatedPosition(at: context.date)
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            HStack(spacing: 10) {
                Text(musicClock(position))
                    .frame(width: 40, alignment: .leading)
                bar(fraction: fraction, duration: duration)
                Text(duration > 0 ? "-" + musicClock(duration - position) : "–:––")
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .font(NookTheme.mono(11))
        .foregroundStyle(dragFraction == nil ? NookTheme.textTertiary : NookTheme.textSecondary)
    }

    private func bar(fraction: Double, duration: Double) -> some View {
        let enabled = duration > 0
        let active = enabled && (hovering || dragFraction != nil)
        let thickness: CGFloat = active ? 5 : 3
        return GeometryReader { geo in
            let width = max(1, geo.size.width)
            let filled = width * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(NookTheme.line2).frame(height: thickness)
                Capsule()
                    .fill(active ? NookTheme.music : NookTheme.paper)
                    .frame(width: filled, height: thickness)
                if active {
                    Circle()
                        .fill(NookTheme.paper)
                        .frame(width: 11, height: 11)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: min(max(0, filled - 5.5), width - 11))
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        dragFraction = Double(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { value in
                        guard enabled else { return }
                        let target = Double(min(1, max(0, value.location.x / width)))
                        onSeek(target * duration)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
        .accessibilityElement()
        .accessibilityLabel(tr("music.progress"))
        .accessibilityValue("\(musicClock(fraction * duration)) / \(musicClock(duration))")
    }
}

/// Small toggle button (shuffle, repeat). On = music color with an indicator dot below.
private struct MusicToggleButton: View {
    let systemName: String
    let label: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? NookTheme.music : (hovering ? NookTheme.paper : NookTheme.textTertiary))
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? NookTheme.smoke : Color.clear))
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(NookTheme.music)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(isOn ? 1 : 0)
                        .offset(y: -2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? tr("music.on") : tr("music.off"))
    }
}

/// Player volume: speaker icon (click to mute/unmute) and a draggable slider.
private struct MusicVolumeControl: View {
    let volume: Int
    let onChange: (Int) -> Void
    @State private var dragValue: Int?
    @State private var beforeMute = 50
    @State private var hovering = false

    private var shown: Int { dragValue ?? volume }

    private var icon: String {
        switch shown {
        case 0: return "speaker.slash.fill"
        case 1..<34: return "speaker.wave.1.fill"
        case 34..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if shown > 0 {
                    beforeMute = shown
                    onChange(0)
                } else {
                    onChange(max(10, beforeMute))
                }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 20, height: 24, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shown > 0 ? tr("music.mute") : tr("music.unmute"))
            .accessibilityLabel(shown > 0 ? tr("music.mute") : tr("music.unmute"))

            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let filled = width * CGFloat(shown) / 100
                let thickness: CGFloat = (hovering || dragValue != nil) ? 5 : 3
                ZStack(alignment: .leading) {
                    Capsule().fill(NookTheme.line2).frame(height: thickness)
                    Capsule().fill(NookTheme.paper).frame(width: filled, height: thickness)
                }
                .frame(width: width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let next = Int((min(1, max(0, value.location.x / width)) * 100).rounded())
                            if next != dragValue {
                                dragValue = next
                                onChange(next)
                            }
                        }
                        .onEnded { _ in dragValue = nil }
                )
            }
            .frame(width: 84, height: 16)
            .accessibilityElement()
            .accessibilityLabel(tr("music.volume"))
            .accessibilityValue(tr("music.percent", shown))
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
