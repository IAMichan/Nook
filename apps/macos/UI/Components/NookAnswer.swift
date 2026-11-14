import SwiftUI

// An answer from Nook, the same wherever it shows: in the Nook chat (`ChatMessageView`) and in the notch's card for a
// question asked with Double Tap or from a notice (`CardDetail.answer`). Its Markdown reads as in the chat (headings,
// lists, tables), its citations are small raised numbers that open their source, the sources it cites are chips under
// it, and what Nook can do next is a row of chips that asks it.

/// Nook's answer with the sources it can cite and what it offers to do next.
struct NookAnswer: Equatable {
    var text: String
    /// The numbered sources the text cites as `[1]`, `[2, 3]`.
    var references: [SourceReference] = []
    /// What Nook can do next ("Add to my calendar"); a click asks it.
    var offers: [String] = []

    /// The sources the text cites, in their own order; the ones it does not cite are left out.
    var cited: [SourceReference] {
        let used = Citations.used(in: text)
        return references.filter { used.contains($0.number) }
    }
}

/// Marks a citation's raised number in an answer's text (the source's number; 0 for the comma between two), so the
/// AppKit text (`SelectableProse`) sizes and raises it the way SwiftUI's `Text` does.
enum CitationMark: AttributedStringKey {
    typealias Value = Int
    static let name = "NookCitationMark"
}

private struct AnswerReferencesKey: EnvironmentKey {
    static let defaultValue: [SourceReference] = []
}

extension EnvironmentValues {
    /// The sources of the answer drawn here: with them, its `[2]` becomes a raised number that opens source 2
    /// (`MarkdownBlock.inline(citations:)`). Empty everywhere else (an agent's transcript, a file), so `[2]` there stays
    /// as written.
    var answerReferences: [SourceReference] {
        get { self[AnswerReferencesKey.self] }
        set { self[AnswerReferencesKey.self] = newValue }
    }
}

extension View {
    /// The sources an answer cites, for its citations to open (see `answerReferences`).
    func answerReferences(_ references: [SourceReference]) -> some View {
        environment(\.answerReferences, references)
    }
}

extension SourceReference {
    /// The source's name without the app before it ("Bright" for "WhatsApp: Bright"), for a chip.
    var shortTitle: String {
        guard let colon = title.range(of: ": "), title.distance(from: title.startIndex, to: colon.lowerBound) <= 20 else { return title }
        return String(title[colon.upperBound...])
    }

    /// Where the source is from ("WhatsApp", "Mail"), with its detail: the line under its name in a hover.
    var origin: String {
        let app = title.range(of: ": ").map { String(title[..<$0.lowerBound]) } ?? SourceCatalog.title(sourceID)
        return ([app] + (detail.isEmpty ? [] : [detail])).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum AnswerCitation {
    /// Opens source `number` of an answer, when it has one that opens (`AppModel.openReference`).
    @MainActor
    static func open(_ number: Int, in references: [SourceReference]) {
        guard let reference = references.first(where: { $0.number == number }) else { return }
        AppModel.shared.openReference(reference)
    }

    /// What a citation's hover says: the source's name and where it is from.
    static func help(_ number: Int, in references: [SourceReference]) -> String? {
        guard let reference = references.first(where: { $0.number == number }) else { return nil }
        return reference.origin.isEmpty ? reference.title : "\(reference.shortTitle) — \(reference.origin)"
    }
}

/// Nook's answer as one view: its Markdown with citations that open their source, the cited sources as chips, and what
/// Nook can do next. The notch's card for a question asked with Double Tap shows it; the Nook chat draws the same text
/// with the same citations (`TranscriptReply` with `answerReferences`) and the same offer chips.
struct NookAnswerView: View {
    let answer: NookAnswer
    var size: CGFloat = TranscriptStyle.textSize
    /// A question at the end of the answer, and an offer under it: what was picked is asked.
    var onAsk: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            MarkdownView(text: answer.text, size: size, onChoose: onAsk)
                .answerReferences(answer.references)
            let cited = answer.cited
            if !cited.isEmpty {
                AnswerSourceChips(references: cited)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sources an answer cites, as small chips that wrap: the number its citations show, the source's name, and a
/// click that opens it (a chat in the Chats tab, a mail in Mail, a page in the browser).
struct AnswerSourceChips: View {
    let references: [SourceReference]

    var body: some View {
        ChipFlow(spacing: NookTheme.Spacing.xs) {
            ForEach(references) { reference in
                AnswerSourceChip(reference: reference)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One cited source: its number in a small circle, then its name. Grey at rest; it lifts under the pointer when it opens.
struct AnswerSourceChip: View {
    let reference: SourceReference
    @State private var hovering = false

    private var openable: Bool { SourceReference.isOpenable(reference.url) }

    var body: some View {
        Button { AppModel.shared.openReference(reference) } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text("\(reference.number)")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Circle().fill(NookTheme.smoke))
                Text(reference.shortTitle)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(hovering && openable ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, NookTheme.Spacing.xs)
            .padding(.trailing, NookTheme.Spacing.md)
            .frame(height: 24)
            .frame(maxWidth: 220, alignment: .leading)
            .background(NookTheme.shape(NookTheme.Radius.control).fill(hovering && openable ? NookTheme.smoke : NookTheme.field))
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.nookPlain)
        .disabled(!openable)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(AnswerCitation.help(reference.number, in: [reference]) ?? reference.title)
        .accessibilityLabel(reference.title)
    }
}

/// A next step Nook offers under its answer ("Add to my calendar"): one click asks it. The same chip in the chat and in
/// the notch's card.
struct AnswerOfferChip: View {
    let text: String
    /// The chip's symbol: the arrow of a next step by default, or what the request does (the Double Tap field's chips).
    var symbol: String = "arrow.turn.down.right"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: symbol)
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                Text(text)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                    .lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(height: 28)
            .background(NookTheme.shape(NookTheme.Radius.control).fill(hovering ? NookTheme.smoke : NookTheme.field))
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityLabel("Nook: \(text)")
    }
}

/// What Nook can do next, side by side, or stacked when they do not fit, so a long offer is never cut off.
struct AnswerOfferChips: View {
    let offers: [String]
    let onAsk: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NookTheme.Spacing.sm) { chips }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(offers, id: \.self) { offer in
            AnswerOfferChip(text: offer) { onAsk(offer) }
        }
    }
}
