import SwiftUI

/// Music bars that follow the music: bass to treble.
///
/// Shows only real Core Audio levels from Spotify/Music (`AudioLevelMonitor`): nothing is made up, so the bars
/// drop at the end of a track and rise with the next one. Rests quietly when music is paused, silent, or when
/// audio capture is unavailable.
struct EqualizerBars: View {
    var color: Color
    var height: CGFloat = 14
    var isPlaying: Bool = true
    /// The closed notch shows the bars for as long as music plays: a lower rate there saves most of the redraws.
    var frameRate: Double = 30
    /// Published only when the plan changes: caps the rate where the pointer is not.
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended

    private static let totalWidth: CGFloat = CGFloat(AudioLevelMonitor.bandCount * 3 + (AudioLevelMonitor.bandCount - 1) * 3)

    var body: some View {
        // Set straight on layers (`LayerLevelBars`), a few times a second: no SwiftUI update, and no layout of the notch or the
        // window around it, per frame, for as long as music plays.
        LayerLevelBars(count: AudioLevelMonitor.bandCount, barWidth: 3, spacing: 3, color: color,
                  fps: isPlaying && !energy.plan.nobodyLooks ? energy.plan.frameRate(frameRate, attended: attended) : 0) { [isPlaying, height] in
            let realBands = isPlaying ? AudioLevelMonitor.shared.snapshot() : []
            return (0..<AudioLevelMonitor.bandCount).map { i in
                (4 + (height - 4) * CGFloat(Self.level(i, realBands: realBands, isPlaying: isPlaying))) / height
            }
        }
        .frame(width: Self.totalWidth, height: height, alignment: .bottom)
        .animation(NookTheme.reveal, value: isPlaying)
        .accessibilityHidden(true)
        // Real levels are only measured while some equalizer is on screen.
        .onAppear { AudioLevelMonitor.shared.addViewer() }
        .onDisappear { AudioLevelMonitor.shared.removeViewer() }
    }

    /// Height between 0 and 1: the measured level of this band. Silence (a gap between tracks) rests the bar.
    private static func level(_ i: Int, realBands: [Double], isPlaying: Bool) -> Double {
        guard isPlaying, i < realBands.count else { return 0.12 }
        return max(0.12, min(1.0, realBands[i]))
    }
}
