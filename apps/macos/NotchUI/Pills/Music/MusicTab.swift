import SwiftUI

/// Music tab: lyrics, Up Next, playlists or recently played tracks over the full width, with the playing track in Spotify
/// or Music as a transport bar along the bottom that unfolds into the full player.
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
                .font(NookTheme.TextStyle.body)
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
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
            Text(tr("music.permissionNote"))
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the stage above the player bar shows.
enum MusicSection: String, CaseIterable, Identifiable {
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
    /// The player is unfolded over the stage. Remembered, like the section.
    @AppStorage("musicPlayerExpanded") private var expanded = false
    @Namespace private var sectionSelection

    private var sections: [MusicSection] { MusicSection.available(for: info.app) }
    private var section: MusicSection {
        let stored = MusicSection(rawValue: storedSection) ?? .lyrics
        return sections.contains(stored) ? stored : .lyrics
    }

    private static let fold = Animation.spring(duration: 0.45, bounce: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionBar
            ZStack(alignment: .bottom) {
                if !expanded {
                    stage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.bottom, MusicDock.barHeight + 12)
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
        .onChange(of: info.shuffle) { if section == .upNext || (expanded && info.app == "Music") { service.refreshUpNext() } }
    }

    private func load() {
        if expanded {
            // The full player shows the next few tracks; lyrics are only looked up while they are on screen.
            if info.app == "Music" { service.refreshUpNext() }
            return
        }
        switch section {
        case .lyrics: lyrics.load(for: info)
        case .upNext: service.refreshUpNext()
        case .playlists: service.refreshPlaylists()
        case .recent: break
        }
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(Self.fold) { expanded = value }
    }

    /// Picking a section while the player is unfolded folds it, so the section shows.
    private func select(_ item: MusicSection) {
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
        }
    }

    // MARK: Section bar

    /// While the player is unfolded no section is selected: the player is what shows.
    private var sectionBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(sections) { item in
                    MusicSectionPill(section: item, selected: !expanded && item == section, namespace: sectionSelection) { select(item) }
                }
            }
            .padding(3)
            .background(Capsule().fill(NookTheme.graphite))
            Spacer(minLength: 8)
            if !expanded, section == .lyrics, let source = MusicLyricsView.source(of: lyrics, for: info) {
                Text(source)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if info.app == "Spotify", !expanded, section != .recent {
                Image(systemName: "info.circle")
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .help(tr("music.spotifyNote"))
                    .accessibilityLabel(tr("music.spotifyNote"))
            }
        }
        .padding(.trailing, 4)
        .animation(NookTheme.reveal, value: expanded)
    }
}

private struct MusicSectionPill: View {
    let section: MusicSection
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(section.title)
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(selected ? NookTheme.ink : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule()
                            .fill(NookTheme.paper)
                            .matchedGeometryEffect(id: "musicSection", in: namespace)
                    } else if hovering {
                        Capsule().fill(NookTheme.smoke)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
