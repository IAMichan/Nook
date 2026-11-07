import SwiftUI

/// Music tab: Home, search, playlists, lyrics, Up Next and statistics over the full width, with the playing track in Spotify or
/// Music as a transport bar along the bottom that unfolds into the full player.
struct MusicTab: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        MusicTabContent(service: app.nowPlaying)
            .musicPlaylistPrompts(app.nowPlaying)
    }
}

/// One page, with or without something playing: Home, search, playlists and statistics always work, and start music
/// without the player coming up. Only when Nook may not talk to the player does it say so first.
private struct MusicTabContent: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if service.current == nil, service.permissionDenied {
            denied
        } else {
            MusicPageView(info: service.current, service: service)
        }
    }

    /// Nook may not ask the player what plays: why, and the one button that fixes it.
    private var denied: some View {
        WSEmptyState(
            symbol: "lock.shield",
            title: tr("music.deniedTitle"),
            message: tr("music.deniedDetail"),
            action: (tr("button.openAutomation"), {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            })
        )
    }
}

/// What the page shows above the player bar.
enum MusicSection: String, CaseIterable, Identifiable {
    case home, search, playlists, lyrics, upNext, stats
    var id: String { rawValue }

    /// Where the page and the sidebar keep what shows.
    static let storageKey = "musicPage"
    static let expandedKey = "musicPlayerExpanded"
    static let fold = NookTheme.open

    var symbol: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .playlists: return "music.note.list"
        case .lyrics: return "quote.bubble"
        case .upNext: return "text.line.last.and.arrowtriangle.forward"
        case .stats: return "chart.bar"
        }
    }

    var title: String {
        switch self {
        case .home: return tr("music.section.home")
        case .search: return tr("music.section.search")
        case .playlists: return tr("music.section.playlists")
        case .lyrics: return tr("music.section.lyrics")
        case .upNext: return tr("music.section.upNext")
        case .stats: return tr("music.section.stats")
        }
    }

    /// Lyrics and Up Next are about the playing track, so they are there while there is one.
    static func available(playing: Bool) -> [MusicSection] {
        playing ? allCases : [.home, .search, .playlists, .stats]
    }
}

/// The one grid of the Music pages, so the header, what scrolls and the player bar keep the same two edges.
enum MusicLayout {
    /// From the page's column to the titles, covers and the player bar.
    static let edge = NookTheme.Spacing.md
    /// How far a flat row's hover fill reaches past that edge, so its cover and text stay on it at rest.
    static let rowBleed = NookTheme.Spacing.sm
    /// The narrowest a cover gets, in a shelf and in a row on Home.
    static let cover: CGFloat = 132
    /// A cover in a row of tracks.
    static let rowArtwork: CGFloat = 36
    /// The height of a rank (a track or an artist) on the statistics page.
    static let rowHeight: CGFloat = 44
}

extension View {
    /// A flat row of a Music list: its hover fill runs past the page's edge, what it shows stays on it.
    func musicRowBleed() -> some View { padding(.horizontal, -MusicLayout.rowBleed) }
}

struct MusicPageView: View {
    let info: NowPlayingInfo?
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var lyrics = LyricsService.shared
    @AppStorage(MusicSection.storageKey) private var storedSection = MusicSection.home.rawValue
    /// The player is unfolded over the stage. Remembered, like the section.
    @AppStorage(MusicSection.expandedKey) private var expanded = false
    @AppStorage("musicStatsPeriod") private var storedPeriod = MusicStatsPeriod.week.rawValue
    /// In the main window the sections are in the sidebar (`MusicSidebar`), so the page has no tabs of its own.
    @Environment(\.panelSidebar) private var sidebar

    private var sections: [MusicSection] { MusicSection.available(playing: info != nil) }
    private var section: MusicSection {
        let stored = MusicSection(rawValue: storedSection) ?? .home
        return sections.contains(stored) ? stored : .home
    }
    private var period: MusicStatsPeriod { MusicStatsPeriod(rawValue: storedPeriod) ?? .week }
    private var showsFullPlayer: Bool { expanded && info != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            sectionBar
                .padding(.horizontal, MusicLayout.edge)
                .conversationHeaderBackground()
            ZStack(alignment: .bottom) {
                if !showsFullPlayer {
                    stage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.bottom, info == nil ? 0 : MusicDock.barHeight + NookTheme.Spacing.lg)
                        .clipped()
                        .contentShape(Rectangle())
                        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                }
                if let info {
                    MusicDock(
                        info: info,
                        service: service,
                        expanded: expanded,
                        onExpand: { setExpanded(true) },
                        onShowAll: { select($0) }
                    )
                    .padding(.horizontal, MusicLayout.edge)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The full player's glow stops at the page: it never runs into the sidebar.
            .clipped()
        }
        .pageColumn()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(MusicSection.fold, value: info == nil)
        .background {
            // Esc folds the full player back into the bar.
            if showsFullPlayer {
                Button("") { setExpanded(false) }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .task(id: "\(info?.trackKey ?? "")|\(section.rawValue)|\(showsFullPlayer)") { load() }
        // The playlists back "Add to playlist" everywhere in the tab, so they load with the page, not with their section.
        .task(id: service.playlistSourceApp) { service.refreshPlaylists() }
        .onChange(of: info?.shuffle) { if section == .upNext || (showsFullPlayer && info?.app == "Music") { service.refreshUpNext() } }
    }

    private func load() {
        if showsFullPlayer {
            // The full player shows the next few tracks; lyrics are only looked up while they are on screen.
            service.refreshUpNext()
            return
        }
        switch section {
        case .lyrics: if let info { lyrics.load(for: info) }
        case .upNext: service.refreshUpNext()
        case .playlists:
            service.refreshPlaylists()
            service.reloadPlaylistDetail()
        case .home, .stats: service.refreshPlayerStats()
        case .search: break
        }
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(MusicSection.fold) { expanded = value }
    }

    /// Picking a section while the player is unfolded folds it, so the section shows. Picking Playlists again while
    /// one is open goes back to all of them.
    private func select(_ item: MusicSection) {
        if item == .playlists, section == .playlists, !expanded, service.playlistDetail != nil {
            service.closePlaylist()
            return
        }
        withAnimation(MusicSection.fold) {
            storedSection = item.rawValue
            expanded = false
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch section {
        case .home: MusicHomeView(service: service, onOpen: { select($0) })
        case .search: MusicSearchView(service: service)
        case .playlists: MusicPlaylistsView(service: service)
        case .stats: MusicStatsView(service: service)
        case .lyrics:
            if let info { MusicLyricsView(info: info, lyrics: lyrics) { service.seek(to: $0) } }
        case .upNext:
            if let info { MusicUpNextView(info: info, service: service) }
        }
    }

    // MARK: Section bar

    /// In the main window (`sidebar != nil`), the 30pt header sits in the title bar band like `PanelListHeader` on
    /// every other page; in the notch or split view, it holds the section tabs.
    private var sectionBar: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if showsOpenPlaylist {
                NookIconButton(systemName: "chevron.left", label: tr("music.playlists.back"), size: 26) { service.closePlaylist() }
                    .transition(.opacity)
            }
            if sidebar == nil {
                NookTabBar(items: sections.map { NookTabBar<MusicSection?>.Item(value: $0, title: $0.title) },
                           selected: showsFullPlayer ? nil : section) { picked in
                    if let picked { select(picked) }
                }
            } else {
                Text(bandTitle)
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.md)
            sectionTrailing
        }
        .frame(height: 30)
        .animation(NookTheme.reveal, value: showsFullPlayer)
        .animation(NookTheme.reveal, value: showsOpenPlaylist)
    }

    private var showsOpenPlaylist: Bool { !showsFullPlayer && section == .playlists && service.playlistDetail != nil }

    /// The one title of the page: Home greets, the rest names what shows.
    private var bandTitle: String {
        if showsFullPlayer { return tr("tab.music") }
        return section == .home ? musicGreeting() : section.title
    }

    @ViewBuilder
    private var sectionTrailing: some View {
        if showsFullPlayer {
            NookIconButton(systemName: "chevron.down", label: tr("music.collapse"), size: 30) { setExpanded(false) }
        } else {
            switch section {
            case .lyrics:
                if let info, let source = MusicLyricsView.source(of: lyrics, for: info) {
                    Text(source)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                if info?.app == "Spotify" {
                    Image(systemName: "info.circle")
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textTertiary)
                        .help(tr("music.spotifyNote", tr("settings.section.connections")))
                        .accessibilityLabel(tr("music.spotifyNote", tr("settings.section.connections")))
                }
            case .playlists:
                if sidebar != nil, service.playlistDetail == nil, !service.playlists.isEmpty {
                    SmallGhostButton(title: "+ " + tr("music.playlists.new")) {
                        service.playlistPrompt = .create(adding: nil)
                    }
                    .help(tr("music.playlists.new"))
                }
            case .stats:
                if sidebar != nil {
                    NookTabBar(items: MusicStatsPeriod.allCases.map { .init(value: $0, title: MusicStatsView.title(of: $0)) },
                               selected: period, onSelect: { storedPeriod = $0.rawValue }, segmented: true)
                }
            case .home, .search, .upNext:
                EmptyView()
            }
        }
    }
}
