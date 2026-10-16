import SwiftUI

/// Music bars that follow the real sound: bass to treble, measured from the player's audio output
/// (`AudioLevelMonitor`). Nothing is simulated: when no audio arrives (paused, or no permission to listen) the bars rest.
struct EqualizerBars: View {
    var color: Color
    var height: CGFloat = 14
    var isPlaying: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let _ = context.date
            let bands = isPlaying ? AudioLevelMonitor.shared.snapshot() : []
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<AudioLevelMonitor.bandCount, id: \.self) { i in
                    let raw = i < bands.count ? max(0.1, min(1.0, bands[i])) : 0.12
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + (height - 4) * CGFloat(raw))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
