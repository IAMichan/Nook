import SwiftUI

/// A line that says Nook is busy: a small spinner and what it is doing ("Waiting for the browser…", "Writing the
/// description…"), the same in every panel and settings page. `font` is the text style of the line (nil keeps the
/// surrounding one, as in a settings row); `tone` how loud it is.
struct BusyLine: View {
    enum Tone {
        /// The usual status line.
        case secondary
        /// A quieter one, beside other metadata (a footer, a list that is still loading).
        case tertiary
        /// The surrounding color.
        case inherited
    }

    let text: String
    var tone: Tone = .secondary
    var font: Font? = nil

    init(_ text: String, tone: Tone = .secondary, font: Font? = nil) {
        self.text = text
        self.tone = tone
        self.font = font
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(text).modifier(BusyLineStyle(font: font, tone: tone))
        }
    }
}

private struct BusyLineStyle: ViewModifier {
    let font: Font?
    let tone: BusyLine.Tone

    func body(content: Content) -> some View {
        switch (font, tone) {
        case (let font?, .secondary): content.font(font).foregroundStyle(NookTheme.textSecondary)
        case (let font?, .tertiary): content.font(font).foregroundStyle(NookTheme.textTertiary)
        case (let font?, .inherited): content.font(font)
        case (nil, .secondary): content.foregroundStyle(NookTheme.textSecondary)
        case (nil, .tertiary): content.foregroundStyle(NookTheme.textTertiary)
        case (nil, .inherited): content
        }
    }
}

/// An error under a field or a form ("The token was not accepted"): coral, in the detail style, wrapping instead of
/// truncating, and selectable so it can be copied into a search or an issue.
struct InlineErrorText: View {
    let message: String
    var alignment: TextAlignment = .leading

    init(_ message: String, alignment: TextAlignment = .leading) {
        self.message = message
        self.alignment = alignment
    }

    var body: some View {
        Text(message)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.coralSoft)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
