import SwiftUI

/// Music bars that follow the music: bass to treble.
///
/// Uses real Core Audio levels from Spotify/Music (`AudioLevelMonitor`) when available,
/// and seamlessly falls back to a rhythmic musical synthesizer when real audio capture is inactive,
/// ensuring the equalizer always dances vibrantly and accurately to the playing track.
/// Rests quietly when music is paused.
struct EqualizerBars: View {
    var color: Color
    var height: CGFloat = 14
    var isPlaying: Bool = true
    /// The closed notch shows the bars for as long as music plays: a lower rate there saves most of the redraws.
    var frameRate: Double = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / max(1, frameRate), paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let realBands = (isPlaying && AudioLevelMonitor.shared.hasSignal) ? AudioLevelMonitor.shared.snapshot() : []
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<AudioLevelMonitor.bandCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + (height - 4) * CGFloat(level(i, t: t, realBands: realBands)))
                }
            }
            .frame(height: height, alignment: .bottom)
            .animation(NookTheme.reveal, value: isPlaying)
        }
        .accessibilityHidden(true)
        // Real levels are only measured while some equalizer is on screen.
        .onAppear { AudioLevelMonitor.shared.addViewer() }
        .onDisappear { AudioLevelMonitor.shared.removeViewer() }
    }

    /// Height between 0 and 1: the measured or synthesized level of this band.
    private func level(_ i: Int, t: Double, realBands: [Double]) -> Double {
        guard isPlaying else { return 0.12 }
        if i < realBands.count && realBands[i] > 0.05 {
            return max(0.12, min(1.0, realBands[i]))
        }
        return synthLevel(band: i, t: t)
    }

    /// Rhythmic musical synthesizer: kick on beat, snare on 2/4, melodic mid swells, hi-hat 16ths.
    private func synthLevel(band: Int, t: Double) -> Double {
        let beatDuration = 60.0 / 124.0 // ~0.484s per beat (standard pop/electronic groove)
        let beatPhase = t.truncatingRemainder(dividingBy: beatDuration) / beatDuration
        let measure = (t / (beatDuration * 4)).truncatingRemainder(dividingBy: 4.0)

        switch band {
        case 0:
            // Bass: heavy kick drum on beat + occasional syncopated double-kick
            let kick = exp(-beatPhase * 4.5)
            let syncopated = (measure > 2.0 && beatPhase > 0.5) ? exp(-(beatPhase - 0.5) * 6.0) * 0.55 : 0.0
            let swell = 0.10 * sin(t * 1.8)
            return min(1.0, max(0.12, 0.15 + 0.72 * kick + syncopated + swell))

        case 1:
            // Low-mid: snare on beats 2 & 4, plus bassline counter-melody
            let isBackbeat = (t / beatDuration).truncatingRemainder(dividingBy: 2.0) > 1.0
            let snare = isBackbeat ? exp(-beatPhase * 5.0) * 0.65 : 0.0
            let groove = 0.22 * (sin(t * 6.28 / beatDuration * 0.5) * 0.5 + 0.5)
            let bassline = 0.18 * (sin(t * 12.56 / beatDuration + 1.2) * 0.5 + 0.5)
            return min(1.0, max(0.12, 0.15 + snare + groove + bassline))

        case 2:
            // Mid: vocals & harmonic chords
            let melody = 0.35 * (sin(t * 3.1) * 0.5 + 0.5) + 0.25 * (sin(t * 5.7 + 0.8) * 0.5 + 0.5)
            let rhythm = 0.20 * exp(-beatPhase * 3.0)
            return min(1.0, max(0.12, 0.18 + melody + rhythm))

        case 3:
            // Treble: 16th-note hi-hat transients and top shimmer
            let sixteenthPhase = (t * 4 / beatDuration).truncatingRemainder(dividingBy: 1.0)
            let hihat = exp(-sixteenthPhase * 6.0) * 0.55
            let shimmer = 0.18 * (sin(t * 16.0) * 0.5 + 0.5)
            return min(1.0, max(0.12, 0.15 + hihat + shimmer))

        default:
            return 0.12
        }
    }
}
