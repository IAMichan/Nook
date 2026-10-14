import SwiftUI

/// Muziek-tab: wat er nu speelt in Spotify of Muziek, met bediening.
struct MusicTab: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let info = app.nowPlaying.current {
            player(info)
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
            Text("Nook mag Spotify niet bedienen")
                .font(NookTheme.font(17, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text("Zet Nook aan onder Systeeminstellingen › Privacy en beveiliging › Automatisering.")
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
            Button("Open Automatisering") {
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
            Text("Er speelt nu niets")
                .font(NookTheme.font(17, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text("Start een nummer in Spotify of Muziek, dan zie je het hier.")
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
            Text("De eerste keer vraagt macOS of Nook die apps mag bedienen.")
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func player(_ info: NowPlayingInfo) -> some View {
        HStack(spacing: 20) {
            artwork(info)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(NookTheme.font(17, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text("\(info.artist) · \(info.app == "Music" ? "Muziek" : info.app)")
                        .font(NookTheme.font(13))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Text(clock(info.position))
                    GeometryReader { geo in
                        let fraction = info.duration > 0 ? min(1, Double(info.position) / Double(info.duration)) : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(NookTheme.line2)
                            Capsule().fill(NookTheme.paper).frame(width: geo.size.width * CGFloat(fraction))
                        }
                    }
                    .frame(height: 3)
                    Text(clock(info.duration))
                }
                .font(NookTheme.mono(11))
                .foregroundStyle(NookTheme.textTertiary)

                HStack(spacing: 6) {
                    NookIconButton(systemName: "backward.fill", label: "Vorige") { app.nowPlaying.control(.previous) }
                    NookIconButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", label: info.isPlaying ? "Pauze" : "Afspelen", filled: true) {
                        app.nowPlaying.control(.playPause)
                    }
                    NookIconButton(systemName: "forward.fill", label: "Volgende") { app.nowPlaying.control(.next) }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func artwork(_ info: NowPlayingInfo) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14).fill(NookTheme.music)
            if let url = info.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            EqualizerBars(color: NookTheme.ink).padding(12)
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
