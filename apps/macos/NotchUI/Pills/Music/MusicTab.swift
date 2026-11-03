import SwiftUI

/// Music tab: lyrics, Up Next, playlists, recently played tracks or a search over the full width, with the playing track in Spotify
/// or Music as a transport bar along the bottom that unfolds into the full player.
struct MusicTab: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        MusicTabContent(service: app.nowPlaying)
            .musicPlaylistPrompts(app.nowPlaying)
    }
}

/// The player when something plays; otherwise why not, and the playlists to start something from.
private struct MusicTabContent: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        if let info = service.current {
            MusicPlayerView(info: info, service: service)
        } else if service.permissionDenied {
            denied
        } else if service.playlistSourceApp != nil {
            idleWithPlaylists
        } else {
            nothingPlaying
        }
    }

    /// Nothing plays, but a player runs or Spotify is connected: its playlists, one click from playing.
    private var idleWithPlaylists: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(systemName: "music.note")
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(tr("music.nothingPlayingTitle"))
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    Text(tr("music.idle.pickPlaylist"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.xs)
            MusicPlaylistsView(service: service)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: service.playlistSourceApp) { service.refreshPlaylists() }
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

    private var nothingPlaying: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("music.nothingPlayingTitle"))
                .font(NookTheme.TextStyle.heading)
                .foregroundStyle(NookTheme.paper)
            Text(tr("music.nothingPlayingDetail"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("music.permissionNote"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NookTheme.Spacing.xs)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NookTheme.Spacing.xs)
    }
}

/// What the stage above the player bar shows.
enum MusicSection: String, CaseIterable, Identifiable {
    case lyrics, upNext, playlists, recent, search
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: return tr("music.section.lyrics")
        case .upNext: return tr("music.section.upNext")
        case .playlists: return tr("music.section.playlists")
        case .recent: return tr("music.section.recent")
        case .search: return tr("music.section.search")
        }
    }

    /// Every section for both players: Spotify's queue, playlists and search come from its Web API once Spotify is
    /// connected in Settings, and say so until then.
    static func available(for app: String) -> [MusicSection] {
        allCases
    }
}

private struct MusicPlayerView: View {
    let info: NowPlayingInfo
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var lyrics = LyricsService.shared
    @AppStorage("musicSection") private var storedSection = MusicSection.lyrics.rawValue
    /// The player is unfolded over the stage. Remembered, like the section.
    @AppStorage("musicPlayerExpanded") private var expanded = false

    private var sections: [MusicSection] { MusicSection.available(for: info.app) }
    private var section: MusicSection {
        let stored = MusicSection(rawValue: storedSection) ?? .lyrics
        return sections.contains(stored) ? stored : .lyrics
    }

    private static let fold = Animation.spring(duration: 0.45, bounce: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            sectionBar
                .zIndex(1)
            ZStack(alignment: .bottom) {
                if !expanded {
                    stage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.bottom, MusicDock.barHeight + NookTheme.Spacing.lg)
                        .clipped()
                        .contentShape(Rectangle())
                        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                }
                MusicDock(
                    info: info,
                    service: service,
                    expanded: expanded,
                    onExpand: { setExpanded(true) },
                    onCollapse: { setExpanded(false) },
                    onShowAll: { select($0) }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // Esc folds the full player back into the bar.
            if expanded {
                Button("") { setExpanded(false) }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .task(id: "\(info.trackKey)|\(section.rawValue)|\(expanded)") { load() }
        // The playlists back "Add to playlist" everywhere in the tab, so they load with the player, not with their section.
        .task(id: info.app) { service.refreshPlaylists() }
        .onChange(of: info.shuffle) { if section == .upNext || (expanded && info.app == "Music") { service.refreshUpNext() } }
    }

    private func load() {
        if expanded {
            // The full player shows the next few tracks; lyrics are only looked up while they are on screen.
            service.refreshUpNext()
            return
        }
        switch section {
        case .lyrics: lyrics.load(for: info)
        case .upNext: service.refreshUpNext()
        case .playlists:
            service.refreshPlaylists()
            service.reloadPlaylistDetail()
        case .recent, .search: break
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
        case .lyrics: MusicLyricsView(info: info, lyrics: lyrics) { service.seek(to: $0) }
        case .upNext: MusicUpNextView(info: info, service: service)
        case .playlists: MusicPlaylistsView(service: service)
        case .recent: MusicRecentView(info: info, service: service)
        case .search: MusicSearchView(info: info, service: service)
        }
    }

    // MARK: Section bar

    /// The same tabs as everywhere else in the panel. While the player is unfolded no section is selected: the player is
    /// what shows.
    private var sectionBar: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookTabBar(items: sections.map { NookTabBar<MusicSection?>.Item(value: $0, title: $0.title) },
                       selected: expanded ? nil : section) { picked in
                if let picked { select(picked) }
            }
            Spacer(minLength: NookTheme.Spacing.md)
            if !expanded, section == .lyrics, let source = MusicLyricsView.source(of: lyrics, for: info) {
                Text(source)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if info.app == "Spotify", !expanded, section == .lyrics {
                Image(systemName: "info.circle")
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .help(tr("music.spotifyNote", tr("settings.section.connections")))
                    .accessibilityLabel(tr("music.spotifyNote", tr("settings.section.connections")))
            }
        }
        .padding(.trailing, NookTheme.Spacing.xs)
        .animation(NookTheme.reveal, value: expanded)
    }
}
