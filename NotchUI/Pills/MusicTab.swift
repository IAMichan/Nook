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

    private func player(_ info: NowPlayingInfo) -> some View {
        HStack(alignment: .center, spacing: 20) {
            artwork(info)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(NookTheme.font(17, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(subtitle(info))
                        .font(NookTheme.font(13))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }

                MusicScrubBar(info: info) { seconds in app.nowPlaying.seek(to: seconds) }

                HStack(spacing: 4) {
                    MusicToggleButton(systemName: "shuffle", label: tr("music.shuffle"), isOn: info.shuffle) {
                        app.nowPlaying.setShuffle(!info.shuffle)
                    }
                    NookIconButton(systemName: "backward.fill", label: tr("music.previous")) { app.nowPlaying.control(.previous) }
                    NookIconButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", label: info.isPlaying ? tr("music.pause") : tr("music.play"), filled: true, size: 38) {
                        app.nowPlaying.control(.playPause)
                    }
                    NookIconButton(systemName: "forward.fill", label: tr("music.next")) { app.nowPlaying.control(.next) }
                    MusicToggleButton(systemName: "repeat", label: tr("music.repeat"), isOn: info.repeating) {
                        app.nowPlaying.setRepeat(!info.repeating)
                    }
                    Spacer(minLength: 12)
                    if let volume = info.volume {
                        MusicVolumeControl(volume: volume) { app.nowPlaying.setVolume($0) }
                    }
                }
            }
        }
    }

    private func subtitle(_ info: NowPlayingInfo) -> String {
        let appName = info.app == "Music" ? tr("tab.music") : info.app
        return info.artist.isEmpty ? appName : "\(info.artist) · \(appName)"
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
            EqualizerBars(color: info.artworkURL == nil ? NookTheme.ink : NookTheme.paper, isPlaying: info.isPlaying)
                .padding(12)
                .shadow(color: .black.opacity(info.artworkURL == nil ? 0 : 0.5), radius: 4)
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// Mm:ss, voor verstreken en resterende tijd.
private func musicClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Voortgangsbalk waarmee je door het nummer spoelt: klik of sleep. Links de verstreken tijd, rechts wat er nog over is.
private struct MusicScrubBar: View {
    let info: NowPlayingInfo
    let onSeek: (Double) -> Void
    /// Waar je de balk naartoe sleept (0…1). `nil` als je niet sleept.
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        // Spotify en Muziek worden elke 2 seconden uitgelezen; daartussen loopt de tijd hier zelf door.
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

/// Kleine aan/uit-knop (willekeurig, herhalen). Aan = muziekkleur met een stipje eronder.
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

/// Volume van de speler: luidsprekertje (klik = dempen of terug) en een sleepbare balk.
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
