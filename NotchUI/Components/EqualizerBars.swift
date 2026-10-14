import SwiftUI

/// Bewegende muziekbalkjes. Elk balkje heeft een eigen ritme, zodat het op een echte equalizer lijkt
/// in plaats van één golf die van links naar rechts loopt. Als de muziek gepauzeerd is, liggen ze stil.
struct EqualizerBars: View {
    var color: Color
    var height: CGFloat = 14
    var isPlaying: Bool = true

    /// Per balkje twee frequenties en fases. Geen gemeenschappelijke deler, dus het patroon herhaalt zich niet zichtbaar.
    private static let voices: [(f1: Double, p1: Double, f2: Double, p2: Double)] = [
        (5.3, 0.0, 8.9, 1.3),
        (7.1, 2.1, 4.3, 0.4),
        (6.2, 4.0, 10.7, 2.6),
        (4.7, 1.2, 7.9, 3.9),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Self.voices.indices, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + (height - 4) * CGFloat(level(i, t)))
                }
            }
            .frame(height: height, alignment: .bottom)
            .animation(.easeOut(duration: 0.25), value: isPlaying)
        }
        .accessibilityHidden(true)
    }

    /// Hoogte tussen 0 en 1. In pauze een lage, vaste stand.
    private func level(_ i: Int, _ t: Double) -> Double {
        guard isPlaying else { return 0.15 }
        let v = Self.voices[i]
        let raw = 0.55 + 0.3 * sin(t * v.f1 + v.p1) + 0.2 * sin(t * v.f2 + v.p2)
        return min(1, max(0.1, raw))
    }
}
