import SwiftUI

/// Bewegende muziekbalkjes.
struct EqualizerBars: View {
    var color: Color
    var height: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = abs(sin(t * 3.1 + Double(i) * 0.9))
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + (height - 4) * CGFloat(wave))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
