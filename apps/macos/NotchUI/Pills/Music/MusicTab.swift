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
    case home, nowPlaying, search, playlists, stats
    var id: String { rawValue }

    /// Where the page and the sidebar keep what shows.
    static let storageKey = "musicPage"
    static let fold = NookTheme.open

    var symbol: String {
        switch self {
        case .home: return "house"
        case .nowPlaying: return "play.circle"
        case .search: return "magnifyingglass"
        case .playlists: return "music.note.list"
        case .stats: return "chart.bar"
        }
    }

    var title: String {
        switch self {
        case .home: return tr("music.section.home")
        case .nowPlaying: return tr("music.section.nowPlaying")
        case .search: return tr("music.section.search")
        case .playlists: return tr("music.section.playlists")
        case .stats: return tr("music.section.stats")
        }
    }

    /// Now Playing is about the playing track, so it is there while there is one.
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
    /// The header band's own height, as `PanelListHeader` on the other pages.
    static let bandHeight: CGFloat = 30
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
    @AppStorage("musicStatsPeriod") private var storedPeriod = MusicStatsPeriod.week.rawValue
    /// In the main window the sections are in the sidebar (`MusicSidebar`), so the page has no tabs of its own.
    @Environment(\.panelSidebar) private var sidebar

    private var sections: [MusicSection] { MusicSection.available(playing: info != nil) }
    private var section: MusicSection {
        let stored = MusicSection(rawValue: storedSection) ?? .home
        return sections.contains(stored) ? stored : .home
    }
    private var period: MusicStatsPeriod { MusicStatsPeriod(rawValue: storedPeriod) ?? .week }
    /// Now Playing is the player itself: the bar would only say the same twice.
    private var showsBar: Bool { info != nil && section != .nowPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            band
            ZStack(alignment: .bottom) {
                stage
                    .id(section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.bottom, showsBar ? MusicDock.barHeight + NookTheme.Spacing.lg : 0)
                    .clipped()
                    .contentShape(Rectangle())
                    .transition(.opacity)
                if showsBar, let info {
                    MusicDock(info: info, service: service) { select(.nowPlaying) }
                        .padding(.horizontal, MusicLayout.edge)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageColumn()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(MusicSection.fold, value: showsBar)
        .task(id: "\(info?.trackKey ?? "")|\(section.rawValue)") { load() }
        // The playlists back "Add to playlist" everywhere in the tab, so they load with the page, not with their section.
        .task(id: service.playlistSourceApp) { service.refreshPlaylists() }
        .onChange(of: info?.shuffle) { if section == .home || section == .nowPlaying { service.refreshUpNext() } }
    }

    private func load() {
        switch section {
        case .home, .nowPlaying:
            // Home's player card shows the current line and what comes next, as Now Playing does in full.
            if let info {
                lyrics.load(for: info)
                service.refreshUpNext()
            }
            if section == .home { service.refreshPlayerStats() }
        case .playlists:
            service.refreshPlaylists()
            service.reloadPlaylistDetail()
        case .stats: service.refreshPlayerStats()
        case .search: break
        }
    }

    /// Picking Playlists again while one is open goes back to all of them.
    private func select(_ item: MusicSection) {
        if item == .playlists, section == .playlists, service.playlistDetail != nil {
            service.closePlaylist()
            return
        }
        withAnimation(MusicSection.fold) { storedSection = item.rawValue }
    }

    @ViewBuilder
    private var stage: some View {
        switch section {
        case .home: MusicHomeView(info: info, service: service, lyrics: lyrics, onOpen: { select($0) })
        case .nowPlaying:
            if let info { MusicNowPlayingView(info: info, service: service, lyrics: lyrics) }
        case .search: MusicSearchView(service: service)
        case .playlists: MusicPlaylistsView(service: service)
        case .stats: MusicStatsView(service: service)
        }
    }

    // MARK: Header band

    /// In the main window (`sidebar != nil`) the band sits in the title bar's row like the header of every other page:
    /// where you are ("Music › Statistics") on the left, the page's own controls on the right, and a hairline under it.
    /// In the notch or split view it holds the section tabs.
    private var band: some View {
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.md) {
                if showsOpenPlaylist {
                    NookIconButton(systemName: "chevron.left", label: tr("music.playlists.back"), size: 26) { service.closePlaylist() }
                        .transition(.opacity)
                }
                if sidebar == nil {
                    NookTabBar(items: sections.map { NookTabBar<MusicSection>.Item(value: $0, title: $0.title) },
                               selected: section) { select($0) }
                } else {
                    crumbs
                }
                Spacer(minLength: NookTheme.Spacing.md)
                trailing
            }
            .frame(height: MusicLayout.bandHeight)
            .padding(.horizontal, MusicLayout.edge)
            if sidebar != nil {
                NookDivider()
                    .padding(.top, NookTheme.Spacing.md)
            }
        }
        .conversationHeaderBackground()
        .animation(NookTheme.reveal, value: showsOpenPlaylist)
        .animation(NookTheme.reveal, value: section)
    }

    /// "Music › Good morning": Home greets, the rest names what shows.
    private var crumbs: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(tr("tab.music"))
                .foregroundStyle(NookTheme.textTertiary)
            Image(icon: "chevron.right")
                .font(NookTheme.font(10, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
                .accessibilityHidden(true)
            Text(section == .home ? musicGreeting() : section.title)
                .foregroundStyle(NookTheme.paper)
                .contentTransition(.opacity)
        }
        .font(NookTheme.TextStyle.title)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var showsOpenPlaylist: Bool { section == .playlists && service.playlistDetail != nil }

    @ViewBuilder
    private var trailing: some View {
        switch section {
        case .playlists:
            if sidebar != nil, service.playlistDetail == nil, !service.playlists.isEmpty {
                SmallGhostButton(title: "+ " + tr("music.playlists.new")) {
                    service.playlistPrompt = .create(adding: nil)
                }
                .help(tr("music.playlists.new"))
            }
            searchLauncher
        case .stats:
            if sidebar != nil {
                NookTabBar(items: MusicStatsPeriod.allCases.map { .init(value: $0, title: MusicStatsView.title(of: $0)) },
                           selected: period, onSelect: { storedPeriod = $0.rawValue }, segmented: true)
            }
        case .home, .nowPlaying:
            searchLauncher
        case .search:
            EmptyView()
        }
    }

    /// Search is one click from every page: the field in the band opens it.
    @ViewBuilder
    private var searchLauncher: some View {
        if sidebar != nil {
            NookSearchLauncher(prompt: service.searchApp == "Spotify" ? tr("music.search.promptSpotify") : tr("music.search.promptMusic"),
                               height: 28) { select(.search) }
                .frame(maxWidth: 260)
        }
    }
}
