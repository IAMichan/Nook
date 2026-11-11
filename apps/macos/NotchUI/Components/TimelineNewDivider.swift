import SwiftUI

/// The line in a session's conversation above what came in since you last looked at it: a hairline on either side of
/// a quiet "New since your last visit". Where it goes is `TimelineLanding.firstNew`, decided once as the conversation
/// opens, so it stays put while you read on. With a `label` of its own it marks another turning point of the
/// conversation (where `/clear` started a new one).
struct TimelineNewDivider: View {
    var label = tr("timeline.newSince")

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookDivider()
            Text(label)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize()
            NookDivider()
        }
        .padding(.vertical, NookTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// At the top of a long conversation that opened with only its latest turns (`HistoryWindow`): "Show earlier messages"
/// between two hairlines, as a button that draws the turns before them.
struct TimelineEarlierRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                NookDivider()
                Label(tr("ws.timeline.showEarlier"), systemImage: "arrow.up")
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .fixedSize()
                NookDivider()
            }
            .padding(.vertical, NookTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tr("ws.timeline.showEarlier"))
    }
}
