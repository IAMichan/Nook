import SwiftUI
import AVKit

/// The fixed structure of each card: context, one sentence, at most one detail line, and at most two buttons.
struct CardView: View {
    let card: NookCard
    let onAction: (CardAction) -> Void
    let onVoice: () -> Void
    var onReply: (String) -> Void = { _ in }
    /// "@nook …" in a chat card's field: the message Nook writes for what was asked, put in the field to read first.
    var onDraft: (String) async throws -> String = { _ in throw NookError(tr("chats.draft.failed")) }
    var onChoose: (String, [String]) -> Void = { _, _ in }
    /// A chat bubble's attachment was clicked: the card stays open while the file opens.
    var onOpen: (ChatBubble) -> Void = { _ in }
    /// The field's text as an answer to one message of a message card's chat (the field quoted it).
    var onReplyTo: (String, ChatBubble) -> Void = { _, _ in }
    /// An emoji put on a message of a message card's chat (the one already yours takes it back).
    var onReact: (ChatBubble, String) -> Void = { _, _ in }
    /// The pointer is on the notch: a notice's countdown holds.
    var paused: Bool = false
    /// A compact card's height as its field grows with the text, so the notch can follow it.
    var onHeight: (CGFloat) -> Void = { _ in }

    @State private var reply = ""
    @FocusState private var replyFocused: Bool
    /// `@` in the follow-up field: people from your chats by name.
    @StateObject private var mentionModel = ComposerModel()
    /// What the chat field says about Nook writing a message ("@nook …").
    @State private var chatNotice: String?
    /// A chat bubble's photo shown big over the card, until it is clicked or Escape is pressed.
    @State private var zoomed: ChatBubble?
    /// The message the chat field answers, quoted above it until it is sent or let go.
    @State private var replyingTo: ChatBubble?

    var body: some View {
        Group {
            if card.compact {
                // Only the field, level with Nook: the card asks one thing and waits for the answer.
                inputField.padding(.top, NookTheme.Spacing.xs)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            } else {
                fullCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if let zoomed, case .photo(let url) = zoomed.media, let image = zoomed.image {
                ChatPhotoZoom(url: url, preview: image, name: zoomed.attachment ?? "",
                              onClose: { withAnimation(NookTheme.reveal) { self.zoomed = nil } },
                              onOpen: { self.zoomed = nil; onOpen(zoomed) })
                    .transition(.opacity)
            }
        }
        .onChange(of: card.id) { _, _ in zoomed = nil; chatNotice = nil; replyingTo = nil }
        .onExitCommand {
            // Escape first shrinks an enlarged photo back and lets go of a quoted message; only then does it close the card.
            if zoomed != nil { withAnimation(NookTheme.reveal) { zoomed = nil }; return }
            if replyingTo != nil { withAnimation(NookTheme.reveal) { replyingTo = nil }; return }
            onAction(card.escape ?? card.primary)
        }
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            header

            if card.input, card.title.count > 140 {
                // Long answers scroll and can be selected; they are never truncated.
                ScrollView(showsIndicators: false) {
                    titleText.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, NookTheme.Spacing.sm)
            } else {
                titleText.padding(.top, NookTheme.Spacing.sm)
            }

            detail
                .padding(.top, Self.isChat(card.detail) ? NookTheme.Spacing.md : NookTheme.Spacing.lg)

            Spacer(minLength: NookTheme.Spacing.lg)

            if !card.offers.isEmpty { offerChips.padding(.bottom, NookTheme.Spacing.md) }

            if let notice = card.notice, !notice.isEmpty {
                Text(notice)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .padding(.bottom, NookTheme.Spacing.sm)
            }

            if card.input { inputField.padding(.bottom, NookTheme.Spacing.md) }

            // Buttons stay on one line each; when they do not fit side by side, they tighten up instead of wrapping.
            if card.acknowledge != nil {
                ViewThatFits(in: .horizontal) {
                    noticeRow(compact: false)
                    noticeRow(compact: true)
                }
            } else {
                actionRow
            }
        }
    }

    /// Who and where on the left, the card's state on the right: the context gives way first, so the state is always
    /// readable at a glance instead of trailing off at the end of one long line. What Nook looked at follows the
    /// context as one quiet line ("· Calendar, GitHub"), not a row of chips that competes with the status.
    private var header: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let source = card.appIcon { CardAppIcon(source: source) }
            Text(card.context)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !card.sources.isEmpty {
                Text("· " + card.sources.prefix(5).joined(separator: ", "))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .help(card.sources.joined(separator: ", "))
            }
            Spacer(minLength: NookTheme.Spacing.md)
            if let changes = card.changes { CardLineChanges(changes: changes) }
            if let status = card.status { CardStatusPill(status: status) }
        }
    }

    /// The card's buttons, in the row every notification shares.
    private var actionRow: some View {
        let act = { (action: CardAction) -> NookNoticeAction in NookNoticeAction(action.label, symbol: action.symbol) { onAction(action) } }
        return NookNoticeActions(primary: act(card.primary),
                                 secondary: card.secondary.label.isEmpty ? nil : act(card.secondary),
                                 extra: card.extra.map(act),
                                 more: card.more.map(act),
                                 onVoice: onVoice)
    }

    /// A notice (a card with an OK): its actions in one bar, and the shared end of every notice (`NookNoticeEnd`): OK
    /// as the white main button with the countdown of the card closing by itself.
    private func noticeRow(compact: Bool) -> some View {
        let actions = ([card.primary, card.secondary] + card.extra + card.more).filter { !$0.label.isEmpty }
        let acknowledge = card.acknowledge
        let ok: (() -> Void)? = acknowledge == nil ? nil : { if let acknowledge { onAction(acknowledge) } }
        return NookNoticeEnd(title: card.acknowledge?.label ?? tr("button.ok"), countdown: card.countdown, paused: paused,
                             restart: card.id, compact: compact,
                             spacing: compact ? NookTheme.Spacing.md : NookTheme.Spacing.lg, onOK: ok) {
            NookActionBar(actions: actions, compact: compact, onAction: onAction)
        }
    }

    private static func isChat(_ detail: CardDetail) -> Bool {
        if case .chat = detail { return true }
        return false
    }

    /// Short sentences as the card's heading; longer answers in reading text with room between the lines, with
    /// **bold**, *italic*, and links.
    private var titleText: some View {
        let long = card.title.count > 140
        return Text(Self.rich(card.title))
            .font(long ? NookTheme.TextStyle.body : NookTheme.TextStyle.heading)
            .lineSpacing(long ? 4 : 1)
            .foregroundStyle(NookTheme.paper)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private static func rich(_ text: String) -> AttributedString {
        MarkdownBlock.inline(MarkdownBlock.clean(text))
    }

    /// What Nook can do next: one click and it gets to work.
    private var offerChips: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            ForEach(card.offers, id: \.self) { offer in
                OfferChip(title: offer) { onReply(offer) }
            }
            Spacer(minLength: 0)
        }
    }

    /// The card's field: the compact card's one line, else the Chats tab's answer field, so a message card and a follow-up
    /// to Nook type the same way. A draft from the model (text put back after a failed send) fills it.
    private var inputField: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            // The answer field has its own `@` menu ("@nook"); the compact field offers people from your chats.
            if card.compact {
                MentionSuggestions(model: mentionModel, text: $reply, config: mentionConfig, focus: $replyFocused)
                promptField
            } else {
                chatField
            }
        }
        .onAppear {
            if let draft = card.draft { reply = draft }
            // Wait briefly for the panel to acquire keyboard focus.
            guard card.focusesInput else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { replyFocused = true }
        }
        // The panel can take the keyboard after the card appeared (a double tap from another app): the field asks again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard card.focusesInput, note.object is NotchPanel, !replyFocused else { return }
            replyFocused = true
        }
        .onChange(of: card.draft) { _, draft in
            guard let draft else { return }
            reply = draft
            replyFocused = true
        }
    }

    /// Every full card answers as the Chats tab does: Cmd+Return sends, "@" opens the menu, "@nook …" lets Nook write the
    /// message into the field.
    private var chatField: some View {
        ChatReplyField(text: $reply, notice: $chatNotice, focus: $replyFocused,
                       placeholder: card.inputPrompt ?? tr("chat.followupPrompt"),
                       sendSymbol: card.replyCopiesTo == nil ? "arrow.up" : "doc.on.doc",
                       sendLabel: card.replyCopiesTo.map { tr("chats.reply.copy", $0) } ?? tr("card.send"),
                       readyNotice: card.replyCopiesTo.map { tr("chats.draft.readyCopy", $0) } ?? tr("chats.draft.ready"),
                       outgoing: card.sending.map { ChatSending(text: $0) },
                       recipient: card.chatReply ? card.title : nil,
                       quote: replyingTo?.quote(contact: card.title),
                       cancelQuote: { withAnimation(NookTheme.reveal) { replyingTo = nil } },
                       draft: onDraft, send: submitReply)
    }

    /// The compact card's one field: Return or the arrow inside the field sends, Escape closes the card. A long
    /// message wraps and the field grows with it (the notch follows through `onHeight`), so all of it stays readable.
    private var promptField: some View {
        let ready = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: NookTheme.Spacing.sm) {
            TextField("", text: $reply, prompt: Text(card.inputPrompt ?? tr("chat.followupPrompt")).foregroundStyle(NookTheme.textTertiary),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...6)
                // One line sits level with the send button; each further line makes the field (and the notch) taller.
                .frame(minHeight: 28)
                .focused($replyFocused)
                .onSubmit { if !mentionModel.isOpen { submitReply() } }
                .onChange(of: reply) { _, new in NookPresence.shared.typed(count: new.count) }
                .mentions(mentionModel, text: $reply, config: mentionConfig)
                // In the non-activating notch panel the binding can lag behind the field until Return commits it,
                // which left the send arrow looking disabled; take every keystroke straight from the field itself.
                .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification)) { note in
                    guard replyFocused, let field = note.object as? NSTextField, field.window is NotchPanel,
                          field.stringValue != reply else { return }
                    reply = field.stringValue
                }
            NookIconButton(systemName: "arrow.up", label: tr("card.send"), filled: true, size: 28, action: submitReply)
                .disabled(!ready)
                .opacity(ready ? 1 : 0.4)
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
    }

    private var mentionConfig: ComposerConfig { .mentions() }

    private func submitReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        if card.chatReply, let quoted = replyingTo {
            replyingTo = nil
            onReplyTo(text, quoted)
        } else {
            onReply(text)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch card.detail {
        case .none:
            EmptyView()
        case .event(let top, let big, let line, let subline):
            EventDetail(top: top, big: big, line: line, subline: subline)
        case .command(let command, let note):
            CommandDetail(command: command, note: note)
        case .waveform:
            WaveformDetail()
        case .steps(let steps):
            StepsDetail(steps: steps)
        case .choices(let set):
            ChoicesDetail(set: set) { labels in onChoose(set.id, labels) }
                .id(set.id)   // new question, new choices
        case .diff(let title, let lines, let note):
            DiffDetail(title: title, lines: lines, note: note)
        case .facts(let facts):
            FactsDetail(facts: facts)
        case .note(let text, let label):
            NoteDetail(text: text, label: label)
        case .chat(let bubbles):
            // A message card's chat can be answered: each message can be quoted in the field, or get an emoji.
            ChatTranscript(bubbles: bubbles, contact: card.title, onOpen: onOpen,
                           onZoom: { bubble in withAnimation(NookTheme.reveal) { zoomed = bubble } },
                           onReply: quoteAction, onReact: card.chatReply && card.replyCopiesTo == nil ? onReact : nil)
        }
    }

    /// Quotes a message of a message card's chat in its field; nil for any other card.
    private var quoteAction: ((ChatBubble) -> Void)? {
        guard card.chatReply, card.replyCopiesTo == nil else { return nil }
        return { bubble in
            withAnimation(NookTheme.reveal) { replyingTo = bubble }
            replyFocused = true
        }
    }
}

// MARK: Header

/// The card's state as a tinted pill with its mark: "✓ Done" in mint, "Needs approval" in amber, "! Stuck" in coral.
private struct CardStatusPill: View {
    let status: CardStatus

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(systemName: status.tone.symbol)
                .font(NookTheme.font(9.5, .bold))
            Text(status.text)
                .font(NookTheme.TextStyle.label)
                .lineLimit(1)
        }
        .foregroundStyle(status.tone.color)
        .padding(.horizontal, NookTheme.Spacing.md)
        .frame(height: 20)
        .background(Capsule().fill(status.tone.color.opacity(0.12)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.text)
    }
}

/// The lines an agent added and removed, in the colors a diff uses.
private struct CardLineChanges: View {
    let changes: LineChanges

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text("+\(changes.added)").foregroundStyle(NookTheme.mint)
            Text("−\(changes.removed)").foregroundStyle(NookTheme.coral)
        }
        .font(NookTheme.mono(11, .medium))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("card.changes", changes.added, changes.removed))
    }
}

// MARK: Detail lines

/// The real icon of the app a card comes from (WhatsApp, Mail…), before the context line; its symbol while the app is not on this Mac.
private struct CardAppIcon: View {
    let source: String
    @ObservedObject private var favicons = FaviconStore.shared

    var body: some View {
        Group {
            if let image = SourceBrand.appIcon(for: source)
                ?? SourceBrand.domain(for: source).flatMap({ favicons.image(for: $0) }) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// An offer from Nook as a button, preceded by a sparkle.
private struct OfferChip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(NookTheme.font(10.5, .semibold))
                    .foregroundStyle(NookTheme.iris)
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                    .lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? NookTheme.smoke : NookTheme.field))
            .contentShape(Capsule())
            .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Nook: \(title)")
    }
}

private struct EventDetail: View {
    let top: String
    let big: String
    let line: String
    let subline: String

    var body: some View {
        // A calendar leaf (month over day) on a soft tile, then what and when.
        HStack(spacing: NookTheme.Spacing.lg) {
            VStack(spacing: 0) {
                Text(top)
                    .font(NookTheme.font(9, .semibold))
                    .foregroundStyle(NookTheme.coralSoft)
                Text(big)
                    .font(NookTheme.rounded(15, .semibold))
                    .foregroundStyle(NookTheme.paper)
            }
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.smoke))

            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(line)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(2)
                Text(subline)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct CommandDetail: View {
    let command: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            // The whole command, never cut off: what you approve is exactly what runs. Long commands scroll. It sits in
            // a sunken well, so it reads as code apart from the words around it.
            ScrollView(.vertical) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("$ ").foregroundStyle(NookTheme.textTertiary)
                    Text(command).foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: command.count > 140 ? 120 : nil)
            .font(NookTheme.mono(13))
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.well))

            Text(note)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
        }
    }
}

/// Your voice as it comes in: every bar is the loudness a moment ago, so new sound appears on the right and
/// scrolls left. Silence leaves the bars flat instead of showing made-up movement.
private struct WaveformDetail: View {
    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 4
    private static let step: TimeInterval = 1.0 / 30.0

    @State private var history = VoiceHistory(count: 200)

    var body: some View {
        GeometryReader { proxy in
            // As many bars as fit: the wave runs the full width of the card.
            let count = max(1, Int((proxy.size.width + Self.gap) / (Self.barWidth + Self.gap)))
            TimelineView(.animation(minimumInterval: Self.step)) { context in
                let levels = history.sample(at: context.date, step: Self.step).suffix(count)
                HStack(spacing: Self.gap) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                        Capsule()
                            .fill(NookTheme.mint)
                            .opacity(0.45 + 0.55 * level)
                            .frame(width: Self.barWidth, height: 4 + 24 * CGFloat(level))
                    }
                }
                .frame(width: proxy.size.width, height: 28, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

private final class VoiceHistory {
    private var levels: [Double]
    private var last = Date.distantPast

    init(count: Int) { levels = Array(repeating: 0, count: count) }

    func sample(at date: Date, step: TimeInterval) -> [Double] {
        if date.timeIntervalSince(last) >= step * 0.9 {
            last = date
            // Lift soft speech a little so quiet voices still move the bars.
            levels.removeFirst()
            levels.append(pow(VoiceLevel.shared.current, 0.7))
        }
        return levels
    }
}

private struct StepsDetail: View {
    let steps: [PlanStep]

    private func color(_ tone: StepTone) -> Color {
        switch tone {
        case .good: return NookTheme.mint
        case .neutral: return NookTheme.textSecondary
        case .caution: return NookTheme.amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ForEach(steps) { step in
                HStack(spacing: NookTheme.Spacing.lg) {
                    Text("\(step.number)")
                        .font(NookTheme.rounded(11, .semibold))
                        .foregroundStyle(color(step.tone))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(color(step.tone).opacity(0.14)))
                    Text(step.text)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.paper)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if !step.tag.isEmpty {
                        Text(step.tag)
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(color(step.tone))
                    }
                }
            }
        }
    }
}

/// Options for an agent prompt. Single choice: click to answer. Multiple choices: select checkboxes and submit.
private struct ChoicesDetail: View {
    let set: ChoiceSet
    let onChoose: ([String]) -> Void
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(set.options) { option in
                ChoiceRow(option: option, multi: set.multiSelect, checked: selected.contains(option.label)) {
                    if set.multiSelect {
                        if selected.contains(option.label) { selected.remove(option.label) } else { selected.insert(option.label) }
                    } else {
                        onChoose([option.label])
                    }
                }
            }
            if set.multiSelect {
                HStack {
                    Spacer()
                    NookPrimaryButton(title: selected.isEmpty ? tr("chat.choices.choose") : tr("chat.choices.sendCount", selected.count)) {
                        guard !selected.isEmpty else { return }
                        // Preserves the option ordering rather than the selection order.
                        onChoose(set.options.map(\.label).filter { selected.contains($0) })
                    }
                    .opacity(selected.isEmpty ? 0.5 : 1)
                }
                .padding(.top, NookTheme.Spacing.xs)
            }
        }
    }
}

private struct ChoiceRow: View {
    let option: ChoiceOption
    let multi: Bool
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                Image(systemName: multi ? (checked ? "checkmark.square.fill" : "square") : "arrow.right.circle")
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(checked ? NookTheme.mint : (hovering ? NookTheme.paper : NookTheme.textTertiary))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(option.label)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                .fill(hovering || checked ? NookTheme.smoke : NookTheme.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// An edit from an agent: file name, modified lines, and a brief description.
private struct DiffDetail: View {
    let title: String
    let lines: [DiffLine]
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(NookTheme.textTertiary).padding(.bottom, NookTheme.Spacing.xs)
                    ForEach(lines) { line in
                        Text(line.text).foregroundStyle(line.color).lineLimit(1)
                    }
                }
                .font(NookTheme.mono(11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.well))

            Text(note)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
        }
    }
}

/// A longer text, never cut off: it wraps, and a very long one scrolls. The label names it below.
private struct NoteDetail: View {
    let text: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(NookTheme.TextStyle.body)
                    .lineSpacing(3)
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Text(label)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
        }
    }
}

/// Metrics in two columns, such as the weekly summary.
private struct FactsDetail: View {
    let facts: [Fact]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  spacing: NookTheme.Spacing.md) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(fact.value)
                        .font(NookTheme.TextStyle.title)
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(fact.label)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
