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
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("music.deniedTitle"))
                .font(NookTheme.TextStyle.heading)
                .foregroundStyle(NookTheme.paper)
            Text(tr("music.deniedDetail"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SmallPrimaryButton(title: tr("button.openAutomation")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .padding(.top, NookTheme.Spacing.sm)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NookTheme.Spacing.xs)
    }
}

/// What the page shows above the player bar.
enum MusicSection: String, CaseIterable, Identifiable {
    case home, search, playlists, lyrics, upNext, stats
    var id: String { rawValue }

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

private struct MusicPageView: View {
    let info: NowPlayingInfo?
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var lyrics = LyricsService.shared
    @AppStorage("musicPage") private var storedSection = MusicSection.home.rawValue
    /// The player is unfolded over the stage. Remembered, like the section.
    @AppStorage("musicPlayerExpanded") private var expanded = false

    private var sections: [MusicSection] { MusicSection.available(playing: info != nil) }
    private var section: MusicSection {
        let stored = MusicSection(rawValue: storedSection) ?? .home
        return sections.contains(stored) ? stored : .home
    }
    private var showsFullPlayer: Bool { expanded && info != nil }

    private static let fold = Animation.spring(duration: 0.45, bounce: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            sectionBar
                .zIndex(1)
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
                        onCollapse: { setExpanded(false) },
                        onShowAll: { select($0) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Self.fold, value: info == nil)
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
        withAnimation(Self.fold) { expanded = value }
    }

    /// Picking a section while the player is unfolded folds it, so the section shows. Picking Playlists again while
    /// one is open goes back to all of them.
    private func select(_ item: MusicSection) {
        if item == .playlists, section == .playlists, !expanded, service.playlistDetail != nil {
            service.closePlaylist()
            return
        }
        withAnimation(Self.fold) {
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

    /// The same tabs as everywhere else in the panel. While the player is unfolded no section is selected: the player is
    /// what shows.
    private var sectionBar: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookTabBar(items: sections.map { NookTabBar<MusicSection?>.Item(value: $0, title: $0.title) },
                       selected: showsFullPlayer ? nil : section) { picked in
                if let picked { select(picked) }
            }
            Spacer(minLength: NookTheme.Spacing.md)
            if !showsFullPlayer, section == .lyrics, let info, let source = MusicLyricsView.source(of: lyrics, for: info) {
                Text(source)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if info?.app == "Spotify", !showsFullPlayer, section == .lyrics {
                Image(systemName: "info.circle")
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .help(tr("music.spotifyNote", tr("settings.section.connections")))
                    .accessibilityLabel(tr("music.spotifyNote", tr("settings.section.connections")))
            }
        }
        .padding(.trailing, NookTheme.Spacing.xs)
        .animation(NookTheme.reveal, value: showsFullPlayer)
    }
}
