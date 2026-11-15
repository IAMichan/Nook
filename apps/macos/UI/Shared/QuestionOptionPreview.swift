import SwiftUI

/// The preview a question's option carries (a mock-up, a code snippet, an ASCII layout; `QuestionPreview` on the Mac),
/// under its option in every question view: the session's question panel, the question of an agent in a terminal, the
/// card in the notch, and the phone. In the code font as the agent laid it out, in a quiet well indented to the
/// option's words; a wide one scrolls sideways instead of wrapping its layout, a tall one stops after `lineLimit` lines.
/// It sits outside the option's button, so its text can be selected without choosing the option.
struct QuestionOptionPreview: View {
    let text: String
    /// How far the well sits in, to line up with the option's label after its number or symbol.
    var indent: CGFloat = 0
    var lineLimit = 14

    var body: some View {
        if !text.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(NookTheme.textFont(11.5, design: .monospaced))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineSpacing(2)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, NookTheme.Spacing.md)
                    .padding(.vertical, NookTheme.Spacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedBackground(NookTheme.well, radius: NookTheme.Radius.control)
            .padding(.leading, indent)
            .accessibilityLabel(Text(verbatim: text))
        }
    }
}
