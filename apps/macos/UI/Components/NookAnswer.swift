import SwiftUI

// An answer from Nook, the same wherever it shows: in the Nook chat (`ChatMessageView`) and in the notch's card for a
// question asked with Double Tap or from a notice (`CardDetail.answer`). Its Markdown reads as in the chat (headings,
// lists, tables), each citation is a small label with the source's icon and name beside the fact it backs (a hover shows
// what the source says, a click opens it), and what Nook can do next is a row of chips that asks it.

/// Nook's answer with the sources it can cite and what it offers to do next.
struct NookAnswer: Equatable {
    var text: String
    /// The numbered sources the text cites as `[1]`, `[2, 3]`.
    var references: [SourceReference] = []
    /// What Nook can do next ("Add to my calendar"); a click asks it.
    var offers: [String] = []
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

    /// The sources a citation of `numbers` names, each once, in the order it names them.
    static func references(_ numbers: [Int], in references: [SourceReference]) -> [SourceReference] {
        var seen = Set<Int>()
        return numbers.compactMap { number in
            guard seen.insert(number).inserted else { return nil }
            return references.first { $0.number == number }
        }
    }

    /// The longest name a citation's label shows before it is cut with "…".
    static let labelLength = 22

    /// A citation's label: the first source's short name (a mail's sender, which says more than a long subject), cut to `labelLength`, and "+2" for two more.
    static func label(_ references: [SourceReference]) -> String {
        guard let first = references.first else { return "" }
        var name = (first.sender ?? first.shortTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = SourceCatalog.title(first.sourceID) }
        if name.count > labelLength { name = String(name.prefix(labelLength - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        return references.count > 1 ? "\(name) +\(references.count - 1)" : name
    }

    /// The symbol for a source with no app or site icon on this Mac.
    @MainActor
    static func symbol(_ reference: SourceReference) -> String {
        AppModel.shared.connectors.source(id: reference.sourceID)?.symbol ?? SourcesDisclosure.symbol(reference.sourceID)
    }

    /// The source's icon for a citation's label in the text: its app's icon, its site's, or its symbol in grey.
    @MainActor
    static func icon(_ reference: SourceReference, size: CGFloat) -> NSImage? {
        let domain = AppModel.shared.connectors.source(id: reference.sourceID)?.iconDomain
        if let image = SourceBrand.menuImage(for: reference.sourceID, domain: domain, size: size) { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(NookTheme.textSecondary)]))
        return NookIcon.nsImage(symbol(reference))?.withSymbolConfiguration(configuration)
    }
}

/// Nook's answer as one view: its Markdown with a label beside each fact naming its source (`CitationPreview` on hover,
/// the source on a click), and what Nook can do next. The notch's card for a question asked with Double Tap shows it; the
/// Nook chat draws the same text with the same labels (`TranscriptReply` with `answerReferences`) and the same offer chips.
struct NookAnswerView: View {
    let answer: NookAnswer
    var size: CGFloat = TranscriptStyle.textSize
    /// A question at the end of the answer, and an offer under it: what was picked is asked.
    var onAsk: ((String) -> Void)? = nil

    var body: some View {
        MarkdownView(text: Citations.shown(answer.text), size: size, onChoose: onAsk)
            .answerReferences(answer.references)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a citation rests on, shown when the pointer rests on its label: per source its icon, where it is from, its name,
/// and the lines of it that match the sentence (`SourcePassage`), the matching ones bright with an accent bar, plus a
/// button that opens the original. The same card in the chat, the notch's card, and the sources list under an answer.
struct CitationPreview: View {
    let references: [SourceReference]
    /// The sentence the citation backs, to find the lines it took from the source.
    var claim: String = ""

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ForEach(Array(references.prefix(3).enumerated()), id: \.element.id) { index, reference in
                if index > 0 { NookDivider() }
                source(reference)
            }
            if references.count > 3 {
                Text(tr("chat.citation.more", references.count - 3))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .padding(NookTheme.Spacing.lg)
        .frame(width: Self.width, alignment: .leading)
    }

    private func source(_ reference: SourceReference) -> some View {
        let openable = SourceReference.isOpenable(reference.url)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                SiteIcon(domain: AppModel.shared.connectors.source(id: reference.sourceID)?.iconDomain,
                         fallback: AnswerCitation.symbol(reference), tint: NookTheme.textSecondary, size: 14, source: reference.sourceID)
                Text(reference.origin.isEmpty ? SourceCatalog.title(reference.sourceID) : reference.origin)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.sm)
                if openable {
                    SmallGhostButton(title: tr("chat.citation.open")) { AppModel.shared.openReference(reference) }
                        .nookTip(tr("chat.references.open"))
                }
            }
            Text(reference.shortTitle)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            passage(reference)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func passage(_ reference: SourceReference) -> some View {
        let lines = reference.excerpt.map { SourcePassage.pick($0, claim: claim, title: reference.shortTitle) } ?? []
        if lines.isEmpty {
            Text(tr("chat.citation.noExcerpt"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(line.relevant ? NookTheme.textStrong : NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, NookTheme.Spacing.md)
                        .overlay(alignment: .leading) {
                            Capsule().fill(line.relevant ? NookTheme.iris : NookTheme.line2).frame(width: 2)
                        }
                }
            }
            .textSelection(.enabled)
        }
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
