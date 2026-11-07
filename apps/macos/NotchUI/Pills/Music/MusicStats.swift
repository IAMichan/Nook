import Charts
import SwiftUI

// The Music tab's statistics: how much, what and when you listen, measured by Nook on this Mac (`MusicStats`), and the
// player's own top lists under it (`MusicPlayerStats`). One series each, in the Music color.

struct MusicStatsView: View {
    @ObservedObject var service: NowPlayingService
    @EnvironmentObject private var app: AppModel
    @Environment(\.panelSidebar) private var sidebar
    @AppStorage("musicStatsPeriod") private var storedPeriod = MusicStatsPeriod.week.rawValue
    @State private var stats: MusicStats?

    private var period: MusicStatsPeriod { MusicStatsPeriod(rawValue: storedPeriod) ?? .week }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                if sidebar == nil {
                    NookTabBar(items: MusicStatsPeriod.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
                               selected: period, onSelect: { storedPeriod = $0.rawValue }, segmented: true)
                }
                if !AppSettings.shared.musicHistory {
                    MusicPlaceholder(symbol: "chart.bar", title: tr("music.stats.off"), detail: tr("music.stats.offDetail", tr("settings.section.connections")))
                        .frame(minHeight: 160)
                } else if let stats {
                    if stats.isEmpty {
                        MusicPlaceholder(symbol: "chart.bar", title: tr("music.stats.empty"), detail: tr("music.stats.emptyDetail"))
                            .frame(minHeight: 160)
                    } else {
                        content(stats)
                    }
                }
                playerSection
            }
            .padding(.horizontal, MusicLayout.edge)
            .padding(.bottom, NookTheme.Spacing.xl)
        }
        // Off the main thread, and only when the period or the plays changed.
        .task(id: "\(storedPeriod)|\(service.history.plays.count)") {
            let plays = service.history.plays
            let period = period
            let fresh = await Task.detached(priority: .utility) { MusicStats(plays: plays, period: period) }.value
            if stats != fresh { stats = fresh }
        }
    }

    static func title(of period: MusicStatsPeriod) -> String {
        switch period {
        case .week: return tr("music.stats.week")
        case .month: return tr("music.stats.month")
        case .year: return tr("music.stats.year")
        case .all: return tr("music.stats.all")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ stats: MusicStats) -> some View {
        // Four across on a page, two in a narrow tab: never a row with a hole in it.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: NookTheme.Spacing.md)], spacing: NookTheme.Spacing.md) {
            NookStatTile(title: tr("music.stats.time"), value: musicListeningTime(stats.seconds), detail: changeText(stats), symbol: "headphones")
            NookStatTile(title: tr("music.stats.plays"), value: stats.plays.formatted(),
                         detail: tr("music.stats.uniqueTracks", stats.uniqueTracks), symbol: "play.circle")
            NookStatTile(title: tr("music.stats.artists"), value: stats.uniqueArtists.formatted(),
                         detail: stats.topArtists.first?.name ?? "", symbol: "music.mic")
            NookStatTile(title: tr("music.stats.streak"), value: tr("music.stats.days", stats.streak),
                         detail: stats.streak > 1 ? tr("music.stats.streakDetail") : tr("music.stats.streakStart"), symbol: "flame")
        }
        MusicStatsCard(title: tr("music.stats.overTime")) {
            MusicBars(bars: stats.buckets.map { bucket in
                .init(id: Self.label(bucket.start, byDay: stats.period.byDay, count: stats.buckets.count),
                      detail: Self.fullLabel(bucket.start, byDay: stats.period.byDay), seconds: bucket.seconds)
            })
        }
        MusicStatsPairs {
            MusicStatsCard(title: tr("music.stats.topArtists")) {
                VStack(spacing: 0) {
                    let most = max(1, stats.topArtists.first?.seconds ?? 1)
                    ForEach(Array(stats.topArtists.prefix(5).enumerated()), id: \.element.id) { index, rank in
                        MusicArtistRow(number: index + 1, name: rank.name, artworkURL: rank.artworkURL, note: musicListeningTime(rank.seconds),
                                       share: Double(rank.seconds) / Double(most))
                    }
                }
            }
            MusicStatsCard(title: tr("music.stats.topTracks")) {
                VStack(spacing: 0) {
                    ForEach(Array(stats.topTracks.prefix(5).enumerated()), id: \.element.id) { index, rank in
                        MusicTrackRow(number: index + 1, track: rank.track, playing: service.current?.trackID == rank.track.id,
                                      service: service, note: tr("music.stats.timesPlayed", rank.plays)) {
                            service.play(rank.track, fromQueue: false)
                        }
                        .musicRowBleed()
                    }
                }
            }
        } second: {
            MusicStatsCard(title: tr("music.stats.whenTitle")) {
                MusicBars(bars: stats.hours.indices.map { hour in
                    .init(id: String(format: "%02d", hour), detail: String(format: "%02d:00", hour), seconds: stats.hours[hour])
                }, height: 150, labelEvery: 6)
            }
            MusicStatsCard(title: tr("music.stats.factsTitle")) {
                facts(stats)
            }
        }
    }

    private func changeText(_ stats: MusicStats) -> String {
        guard let change = stats.change else { return Self.title(of: stats.period) }
        if change == 0 { return tr("music.stats.same") }
        return change > 0 ? tr("music.stats.up", change) : tr("music.stats.down", abs(change))
    }

    @ViewBuilder
    private func facts(_ stats: MusicStats) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if let type = stats.listenerType {
                fact("sparkles", title: listener(type).0, detail: listener(type).1)
            }
            if let hour = stats.peakHour {
                fact("clock", title: tr("music.stats.peakHour", String(format: "%02d:00", hour)), detail: tr("music.stats.peakHourDetail"))
            }
            if let day = stats.bestDay {
                fact("calendar", title: Self.fullLabel(day.start, byDay: true), detail: tr("music.stats.bestDay", musicListeningTime(day.seconds)))
            }
            if let track = stats.topTracks.first, track.plays > 1 {
                fact("repeat", title: track.track.title, detail: tr("music.stats.onRepeat", track.plays))
            }
        }
    }

    private func listener(_ type: MusicListenerType) -> (String, String) {
        switch type {
        case .morning: return (tr("music.stats.morning"), tr("music.stats.morningDetail"))
        case .afternoon: return (tr("music.stats.afternoon"), tr("music.stats.afternoonDetail"))
        case .evening: return (tr("music.stats.evening"), tr("music.stats.eveningDetail"))
        case .night: return (tr("music.stats.night"), tr("music.stats.nightDetail"))
        }
    }

    private func fact(_ symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            Image(systemName: symbol)
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper).lineLimit(1)
                Text(detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(2)
            }
        }
    }

    // MARK: From the player

    @ViewBuilder
    private var playerSection: some View {
        let top = service.playerStats
        switch top.state {
        case .done where !top.tracks.isEmpty || !top.artists.isEmpty:
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                MusicGroupTitle(title: top.app == "Spotify" ? tr("music.stats.fromSpotify") : tr("music.stats.fromMusic"))
                    .padding(.top, NookTheme.Spacing.lg)
                MusicStatsPairs {
                    MusicStatsCard(title: tr("music.stats.topArtists")) {
                        VStack(spacing: 0) {
                            ForEach(Array(top.artists.prefix(5).enumerated()), id: \.element.id) { index, artist in
                                MusicArtistRow(number: index + 1, name: artist.name, artworkURL: artist.artworkURL,
                                               note: artist.plays.map { tr("music.stats.timesPlayed", $0) })
                            }
                        }
                    }
                    MusicStatsCard(title: tr("music.stats.topTracks")) {
                        VStack(spacing: 0) {
                            ForEach(Array(top.tracks.prefix(5).enumerated()), id: \.element.id) { index, track in
                                MusicTrackRow(number: index + 1, track: track, playing: service.current?.trackID == track.id, service: service,
                                              note: top.plays[track.id].map { tr("music.stats.timesPlayed", $0) }) {
                                    service.play(track, fromQueue: false, app: top.app)
                                }
                                .musicRowBleed()
                            }
                        }
                    }
                }
            }
        case .reconnectSpotify:
            playerNotice(tr("music.stats.reconnect"), detail: tr("music.stats.reconnectDetail", tr("settings.section.connections")))
        case .connectSpotify:
            playerNotice(tr("music.stats.connect"), detail: tr("music.home.connectDetail"))
        default:
            EmptyView()
        }
    }

    private func playerNotice(_ title: String, detail: String) -> some View {
        AdaptiveActionRow(spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Text(detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            SmallGhostButton(title: tr("music.playlists.openConnections")) { app.openSettings(section: .connections) }
        }
        .padding(NookTheme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.surface))
    }

    // MARK: Dates

    /// Short enough for the axis, and unique: past a year a month's name comes back, so it carries its year.
    private static func label(_ date: Date, byDay: Bool, count: Int) -> String {
        let format = byDay ? (count > 7 ? "d/M" : "EEE") : (count > 12 ? "MMM yy" : "MMM")
        return NookDates.formatter(format, locale: NookDates.appLocale).string(from: date)
    }

    private static func fullLabel(_ date: Date, byDay: Bool) -> String {
        NookDates.formatter(byDay ? "EEEE d MMMM" : "MMMM yyyy", locale: NookDates.appLocale).string(from: date)
    }
}

/// A titled card on the statistics page.
private struct MusicStatsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.textStrong)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(NookTheme.Spacing.xl)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.surface))
    }
}

/// Cards two by two, each pair as tall as its taller card; one under the other in a narrow tab.
private struct MusicStatsPairs<First: View, Second: View>: View {
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    init(@ViewBuilder _ first: @escaping () -> First, @ViewBuilder second: @escaping () -> Second = { EmptyView() }) {
        self.first = first
        self.second = second
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Grid(horizontalSpacing: NookTheme.Spacing.md, verticalSpacing: NookTheme.Spacing.md) {
                GridRow { first() }
                if Second.self != EmptyView.self { GridRow { second() } }
            }
            .frame(minWidth: 620)
            VStack(spacing: NookTheme.Spacing.md) {
                first()
                second()
            }
        }
    }
}

/// An artist in a top list, as tall as a track's row beside it: number, picture, name, and how much, with a thin bar
/// for its share of the first when there is one.
private struct MusicArtistRow: View {
    let number: Int
    let name: String
    let artworkURL: URL?
    let note: String?
    var share: Double? = nil

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Text("\(number)")
                .font(NookTheme.font(11, .medium).monospacedDigit())
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 22)
            MusicArtwork(url: artworkURL, seed: name, symbol: "music.mic", cornerRadius: MusicLayout.rowArtwork / 2)
                .frame(width: MusicLayout.rowArtwork, height: MusicLayout.rowArtwork)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(name).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper).lineLimit(1)
                    Spacer(minLength: 0)
                    if let note {
                        Text(note)
                            .font(NookTheme.font(11, .medium).monospacedDigit())
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                if let share {
                    GeometryReader { geo in
                        Capsule()
                            .fill(NookTheme.music.opacity(0.85))
                            .frame(width: max(4, geo.size.width * share))
                    }
                    .frame(height: 3)
                }
            }
        }
        .frame(height: MusicLayout.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.map { "\(name), \($0)" } ?? name)
    }
}

/// Listening time as columns on one baseline. The bar under the pointer says its own day and time above the chart, where
/// the total stands otherwise; a screen reader gets the same as text.
private struct MusicBars: View {
    struct Bar: Identifiable, Equatable {
        /// The label on the axis; unique within the chart.
        let id: String
        /// The date or hour in full.
        let detail: String
        let seconds: Int
    }

    let bars: [Bar]
    var height: CGFloat = 150
    /// Label every so many bars; `nil` picks it from the number of bars.
    var labelEvery: Int? = nil
    @State private var hovered: String?

    private var step: Int { labelEvery ?? (bars.count > 14 ? 5 : (bars.count > 12 ? 3 : 1)) }
    private var barWidth: CGFloat { bars.count <= 12 ? 24 : (bars.count <= 24 ? 10 : 7) }
    private var labelled: [String] { bars.enumerated().filter { $0.offset % step == 0 }.map(\.element.id) }
    private var peak: Bar? { bars.max { $0.seconds < $1.seconds } }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            // The value of the bar under the pointer, otherwise the highest: always one line, so nothing jumps.
            Group {
                if let bar = bars.first(where: { $0.id == hovered }) ?? peak, bar.seconds > 0 {
                    Text("\(bar.detail) · \(musicListeningTime(bar.seconds))")
                } else {
                    Text(" ")
                }
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textSecondary)
            .lineLimit(1)
            Chart(bars) { bar in
                BarMark(x: .value("Time", bar.id), y: .value("Minutes", Double(bar.seconds) / 60), width: .fixed(barWidth))
                    .cornerRadius(NookTheme.Radius.chip / 2)
                    .foregroundStyle(hovered == nil || hovered == bar.id ? NookTheme.music : NookTheme.music.opacity(0.4))
            }
            .chartXAxis {
                AxisMarks { value in
                    // A label on every 24th of the width would run together.
                    if let label = value.as(String.self), labelled.contains(label) {
                        AxisValueLabel().font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(NookTheme.separator)
                    AxisValueLabel().font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
                }
            }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = proxy.value(atX: point.x, as: String.self)
                        case .ended: hovered = nil
                        }
                    }
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(bars.filter { $0.seconds > 0 }.map { "\($0.detail): \(musicListeningTime($0.seconds))" }.joined(separator: ", "))
        }
    }
}
