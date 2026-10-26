import SwiftUI

/// The passages of an answer picked to go with the next message ("Quote" / "Ask about this" on a selection), as chips
/// in the tray above the composer: a quote mark, the start of the passage, and a cross that lets it go. The whole
/// passage shows under the pointer. They go out as Markdown quotes in front of what you type (`ComposerQuotes`).
struct ComposerQuoteChips: View {
    let quotes: [ComposerQuotes.Quote]
    let remove: (UUID) -> Void

    var body: some View {
        ChipFlow(spacing: NookTheme.Spacing.xs) {
            ForEach(quotes) { quote in
                HStack(spacing: NookTheme.Spacing.xxs) {
                    Image(systemName: "text.quote")
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(quote.title)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .help(quote.text)
                    ToolbarIconButton("xmark", tr("compose.quote.remove"), height: 18, width: 18) { remove(quote.id) }
                }
                .padding(.leading, NookTheme.Spacing.sm)
                .padding(.trailing, NookTheme.Spacing.xxs)
                .padding(.vertical, NookTheme.Spacing.xxs)
                .background(Capsule().fill(NookTheme.smoke))
            }
        }
        .padding(.vertical, NookTheme.Spacing.xxs)
    }
}
