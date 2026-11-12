import SwiftUI

// "Plays on": where the music sounds now, and one click to send it somewhere else. The Mac's own speakers and
// headphones for both players, Music's AirPlay devices and Spotify Connect's (a phone, a speaker, a TV) beside them.
// See `MusicOutputService`.

/// The place the music plays, as a button in the player bar and the full player; a click lists where else it can go.
struct MusicOutputButton: View {
    let info: NowPlayingInfo
    @ObservedObject var outputs: MusicOutputService
    /// Only the icon, where the bar is narrow.
    var compact = false
    @EnvironmentObject private var app: AppModel
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let current = outputs.current
        let away = current.map { !$0.isOnThisMac } ?? false
        Button { open.toggle() } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: current?.symbol ?? "speaker.wave.2")
                    .font(NookTheme.font(12, .medium))
                    .frame(width: 16)
                if !compact, let current {
                    Text(current.name)
                        .font(NookTheme.TextStyle.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                }
                Image(icon: "chevron.up")
                    .font(NookTheme.font(7.5, .bold))
                    .opacity(0.5)
                    .accessibilityHidden(true)
            }
            // Somewhere else than this Mac stands out in the Music colour, as AirPlay does in the players.
            .foregroundStyle(away ? NookTheme.music : (hovering || open ? NookTheme.paper : NookTheme.textSecondary))
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 30)
            .roundedBackground(hovering || open ? NookTheme.graphite : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("music.output.help"))
        .accessibilityLabel(current.map { tr("music.output.playsOn", $0.name) } ?? tr("music.output.title"))
        .accessibilityHint(tr("music.output.help"))
        .popover(isPresented: $open, arrowEdge: .top) {
            MusicOutputList(player: info.app, outputs: outputs, onConnect: {
                open = false
                app.openSettings(section: .connections)
            }) { open = false }
        }
        .task(id: info.app) { outputs.follow(app: info.app) }
    }
}

/// Where the music can play, grouped as the user thinks of it: on this Mac, or elsewhere in the house.
struct MusicOutputList: View {
    let player: String
    @ObservedObject var outputs: MusicOutputService
    let onConnect: () -> Void
    let onDone: () -> Void

    private var elsewhereTitle: String {
        player == "Spotify" ? tr("music.output.spotifyDevices") : tr("music.output.airPlay")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("music.output.title"))
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                Text(tr("music.output.detail"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group(tr("music.output.thisMac"), outputs.mac)
            elsewhere
        }
        .padding(NookTheme.Spacing.xl)
        .frame(width: 320, alignment: .leading)
        .onAppear { outputs.refresh(app: player) }
    }

    @ViewBuilder
    private var elsewhere: some View {
        if !outputs.elsewhere.isEmpty {
            group(elsewhereTitle, outputs.elsewhere)
        } else if outputs.needsSpotify {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                label(elsewhereTitle)
                Text(tr("music.output.connectSpotify"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SmallGhostButton(title: tr("music.playlists.openConnections"), action: onConnect)
                    .padding(.leading, -NookTheme.Spacing.md)
            }
        } else if outputs.loading {
            HStack(spacing: NookTheme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text(tr("music.output.looking"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
            }
        } else {
            Text(player == "Spotify" ? tr("music.output.noneSpotify") : tr("music.output.noneAirPlay"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [MusicOutput]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                label(title)
                VStack(spacing: NookTheme.Spacing.xxs) {
                    ForEach(items) { output in
                        MusicOutputRow(output: output, chosen: chosen(output)) {
                            outputs.select(output, app: player)
                            onDone()
                        }
                    }
                }
                .padding(.horizontal, -NookTheme.Spacing.md)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }

    /// The one it is switching to, until the player or the Mac says so; else where it plays now.
    private func chosen(_ output: MusicOutput) -> Bool {
        if let switching = outputs.switching { return switching == output.id }
        return outputs.current?.id == output.id
    }
}

private struct MusicOutputRow: View {
    let output: MusicOutput
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.lg) {
                Image(icon: output.symbol)
                    .font(NookTheme.font(14, .medium))
                    .foregroundStyle(chosen ? NookTheme.music : NookTheme.textSecondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(output.name)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: NookTheme.Spacing.md)
                if chosen {
                    Image(icon: "checkmark")
                        .font(NookTheme.font(12, .bold))
                        .foregroundStyle(NookTheme.music)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 38)
            .roundedBackground(NookTheme.rowFill(selected: chosen, hovering: hovering, rest: .clear), radius: NookTheme.Radius.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityLabel(output.name)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

/// "Playing on Living room": said once, quietly, where the playing track shows (Home's card, the full player).
struct MusicOutputLine: View {
    @ObservedObject var outputs: MusicOutputService

    var body: some View {
        if let current = outputs.current {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: current.symbol)
                    .font(NookTheme.font(11, .medium))
                    .accessibilityHidden(true)
                Text(tr("music.output.playsOn", current.name))
                    .font(NookTheme.TextStyle.label)
                    .lineLimit(1)
            }
            .foregroundStyle(current.isOnThisMac ? NookTheme.textSecondary : NookTheme.music)
            .accessibilityElement(children: .combine)
        }
    }
}
