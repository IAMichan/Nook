import SwiftUI

/// A chat message's text as its app shows it, the same in every chat: bold, italic, strikethrough and `code` in their
/// style, code blocks in a box, quotes behind a bar, lists with their markers, and links that open. `ChatFormat` reads
/// the markup; `ChatTranscript` puts this in every bubble. Never draw a message's text by hand.
struct ChatMessageText: View {
    let text: String
    var weight: Font.Weight = .regular
    /// Lines a paragraph shows at most (a folded long message); nil shows all.
    var lineLimit: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            ForEach(Array(ChatFormat.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let spans):
                    Text(Self.attributed(spans))
                        .lineLimit(lineLimit)
                case .quote(let spans):
                    HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
                        Capsule()
                            .fill(NookTheme.textTertiary)
                            .frame(width: 3)
                        Text(Self.attributed(spans))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(lineLimit)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .item(let marker, let spans):
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                        Text(marker)
                            .foregroundStyle(NookTheme.textSecondary)
                            .monospacedDigit()
                        Text(Self.attributed(spans))
                            .lineLimit(lineLimit)
                    }
                case .code(let code):
                    Text(code)
                        .font(NookTheme.TextStyle.code)
                        .lineLimit(lineLimit)
                        .padding(.horizontal, NookTheme.Spacing.sm)
                        .padding(.vertical, NookTheme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                            .fill(NookTheme.ink.opacity(0.4)))
                }
            }
        }
        // Body size with a little air between lines: a chat is read in long runs.
        .font(weight == .regular ? NookTheme.TextStyle.body : NookTheme.font(13.5, weight))
        .lineSpacing(NookTheme.Spacing.xxs)
        .foregroundStyle(NookTheme.paper)
        .tint(NookTheme.blue)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    /// The pieces of a line in their style, with the web and mail addresses in them as links.
    static func attributed(_ spans: [ChatFormat.Span]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = span.code ? AttributedString(span.text) : ChatLinks.attributed(span.text)
            var intent: InlinePresentationIntent = []
            if span.bold { intent.insert(.stronglyEmphasized) }
            if span.italic { intent.insert(.emphasized) }
            if span.strike { intent.insert(.strikethrough) }
            if span.code { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if span.code { piece.backgroundColor = NookTheme.ink.opacity(0.4) }
            result += piece
        }
        return result
    }
}
