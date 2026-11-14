import SwiftUI

/// The passages of an answer picked to go with the next message ("Quote" / "Ask about this" on a selection), as chips
/// in the tray above the composer: a quote mark, your note on it or else the start of the passage, a pencil to write that
/// note and a cross that lets it go. The whole passage shows under the pointer, and a click on the chip goes back to
/// where it was quoted from in the conversation. They go out as Markdown quotes, each with its note under it, in front of
/// what you type (`ComposerQuotes`).
struct ComposerQuoteChips: View {
    let quotes: [ComposerQuotes.Quote]
    let remove: (UUID) -> Void
    var setNote: ((UUID, String) -> Void)? = nil
    /// Scrolls to the quote's source; nil when the conversation cannot.
    var jump: ((ComposerQuotes.Quote) -> Void)? = nil

    var body: some View {
        ChipFlow(spacing: NookTheme.Spacing.xs) {
            ForEach(quotes) { quote in
                QuoteChip(quote: quote, remove: { remove(quote.id) },
                          setNote: setNote.map { set in { set(quote.id, $0) } },
                          jump: jump.map { go in { go(quote) } })
            }
        }
        .padding(.vertical, NookTheme.Spacing.xxs)
    }
}

private struct QuoteChip: View {
    let quote: ComposerQuotes.Quote
    let remove: () -> Void
    let setNote: ((String) -> Void)?
    let jump: (() -> Void)?
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            Button { jump?() } label: {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    Image(icon: quote.note.isEmpty ? "text.quote" : "text.bubble")
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(quote.title)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(hovering && jump != nil ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .disabled(jump == nil)
            .onHover { hovering = $0 }
            .help(quote.note.isEmpty ? quote.text : "\(quote.text)\n\n\(quote.note)")
            .accessibilityLabel(quote.title)
            .accessibilityHint(jump == nil ? "" : tr("compose.quote.jump"))
            if setNote != nil {
                ToolbarIconButton("pencil", quote.note.isEmpty ? tr("compose.quote.note") : tr("compose.quote.editNote"),
                                  height: 18, width: 18) {
                    draft = quote.note
                    editing = true
                }
                .popover(isPresented: $editing, arrowEdge: .top) { noteEditor }
            }
            ToolbarIconButton("xmark", tr("compose.quote.remove"), height: 18, width: 18) { remove() }
        }
        .padding(.leading, NookTheme.Spacing.sm)
        .padding(.trailing, NookTheme.Spacing.xxs)
        .padding(.vertical, NookTheme.Spacing.xxs)
        .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.smoke))
    }

    /// The passage, quiet, and a field for what you say about it; Return keeps it, Escape leaves it as it was.
    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(quote.text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(4)
                .padding(.leading, NookTheme.Spacing.md)
                .overlay(alignment: .leading) { Rectangle().fill(NookTheme.line2).frame(width: 2) }
            TextField("", text: $draft, prompt: Text(tr("compose.quote.notePrompt")), axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...5)
                .padding(NookTheme.Spacing.md)
                .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
                .onSubmit(save)
            HStack {
                Spacer()
                NookGhostButton(title: tr("button.cancel")) { editing = false }
                SmallPrimaryButton(title: tr("button.save"), action: save)
            }
        }
        .padding(NookTheme.Spacing.lg)
        .frame(width: 320)
    }

    private func save() {
        setNote?(draft)
        editing = false
    }
}
