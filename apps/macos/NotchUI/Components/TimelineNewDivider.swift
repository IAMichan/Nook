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
