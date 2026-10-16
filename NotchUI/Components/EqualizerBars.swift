import SwiftUI

/// Music bars that follow the real sound: bass to treble, measured from the player's audio output
/// (`AudioLevelMonitor`). Nothing is simulated: when no audio arrives (paused, or no permission to listen) the bars rest.
struct EqualizerBars: View {
    var color: Color
    var height: CGFloat = 14
    var isPlaying: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: !isPlaying)) { context in
            let _ = context.date
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<AudioLevelMonitor.bandCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + (height - 4) * CGFloat(level(i)))
                }
            }
            .frame(height: height, alignment: .bottom)
            .animation(.easeOut(duration: 0.25), value: isPlaying)
        }
        .accessibilityHidden(true)
    }

    /// Height between 0 and 1: the measured level of this band. Small fixed height when paused or silent.
    private func level(_ i: Int) -> Double {
        guard isPlaying else { return 0.12 }
        return max(0.1, min(1, AudioLevelMonitor.shared.level(i)))
    }
}
