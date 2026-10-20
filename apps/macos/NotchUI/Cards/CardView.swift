import SwiftUI
import AVKit

/// The fixed structure of each card: context, one sentence, at most one detail line, and at most two buttons.
struct CardView: View {
    let card: NookCard
    let onAction: (CardAction) -> Void
    let onVoice: () -> Void
    var onReply: (String) -> Void = { _ in }
    var onChoose: (String, [String]) -> Void = { _, _ in }
    /// A chat bubble's attachment was clicked: the card stays open while the file opens.
    var onOpen: (ChatBubble) -> Void = { _ in }

    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let source = card.appIcon { CardAppIcon(source: source) }
                Text(card.context)
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                if !card.sources.isEmpty {
                    ForEach(card.sources.prefix(5), id: \.self) { source in
                        Text(source)
                            .font(NookTheme.font(10.5, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NookTheme.smoke))
                            .lineLimit(1)
                    }
                }
            }

            if card.input, card.title.count > 140 {
                // Long answers scroll and can be selected; they are never truncated.
                ScrollView(showsIndicators: false) {
                    titleText.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            } else {
                titleText.padding(.top, 6)
            }

            detail
                .padding(.top, Self.isChat(card.detail) ? 10 : 14)

            Spacer(minLength: 12)

            if !card.offers.isEmpty { offerChips.padding(.bottom, 10) }

            if let notice = card.notice, !notice.isEmpty {
                Text(notice)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }

            if card.input { replyField.padding(.bottom, 10) }

            // Buttons stay on one line each; when they do not fit side by side, they tighten up instead of wrapping.
            ViewThatFits(in: .horizontal) {
                buttonRow(compact: false)
                buttonRow(compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand { onAction(card.escape ?? card.primary) }
    }

    private func buttonRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 0 : 4) {
            NookPrimaryButton(title: card.primary.label, symbol: card.primary.symbol) { onAction(card.primary) }
                .padding(.trailing, compact ? 4 : 0)
            if !card.secondary.label.isEmpty {
                NookGhostButton(title: card.secondary.label, symbol: card.secondary.symbol, compact: compact) {
                    onAction(card.secondary)
                }
            }
            ForEach(Array(card.extra.enumerated()), id: \.offset) { _, action in
                NookGhostButton(title: action.label, symbol: action.symbol, compact: compact) { onAction(action) }
            }
            Spacer(minLength: 4)
            if let acknowledge = card.acknowledge {
                NookAcknowledgeButton(title: acknowledge.label, compact: compact) { onAction(acknowledge) }
            }
            NookIconButton(systemName: "mic", label: tr("card.voiceAdjust"), action: onVoice)
        }
    }

    private static func isChat(_ detail: CardDetail) -> Bool {
        if case .chat = detail { return true }
        return false
    }

    /// Short sentences large; longer answers in readable text, with **bold**, *italic*, and links.
    private var titleText: some View {
        let long = card.title.count > 140
        return Text(Self.rich(card.title))
            .font(long ? NookTheme.font(15, .regular) : NookTheme.font(18, .semibold))
            .lineSpacing(long ? 3 : 0)
            .foregroundStyle(NookTheme.paper)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private static func rich(_ text: String) -> AttributedString {
        MarkdownBlock.inline(MarkdownBlock.clean(text))
    }

    /// What Nook can do next: one click and it gets to work.
    private var offerChips: some View {
        HStack(spacing: 6) {
            ForEach(card.offers, id: \.self) { offer in
                OfferChip(title: offer) { onReply(offer) }
            }
            Spacer(minLength: 0)
        }
    }

    /// Follow-up questions via text: always ready to type, Enter sends.
    private var replyField: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $reply,
                prompt: Text(card.inputPrompt ?? tr("chat.followupPrompt")).foregroundStyle(NookTheme.textTertiary)
            )
            .textFieldStyle(.plain)
            .font(NookTheme.font(14))
            .foregroundStyle(NookTheme.paper)
            .focused($replyFocused)
            .onChange(of: reply) { _, new in NookPresence.shared.typed(count: new.count) }
            // In the non-activating notch panel the binding can lag behind the field until Return commits it,
            // which left the send arrow looking disabled; take every keystroke straight from the field itself.
            .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification)) { note in
                guard replyFocused, let field = note.object as? NSTextField, field.window is NotchPanel,
                      field.stringValue != reply else { return }
                reply = field.stringValue
            }
            .onSubmit(submitReply)
            // Return sends, and so does a click on the arrow; an empty field sends nothing.
            let ready = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: submitReply) {
                Image(systemName: ready ? "arrow.up.circle.fill" : "return")
                    .font(.system(size: ready ? 18 : 11, weight: .medium))
                    .foregroundStyle(ready ? NookTheme.mint : NookTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("card.send"))
            .accessibilityLabel(tr("card.send"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(Capsule().fill(NookTheme.field))
        .onAppear {
            if let draft = card.draft { reply = draft }
            // Wait briefly for the panel to acquire keyboard focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { replyFocused = true }
        }
        .onChange(of: card.draft) { _, draft in
            guard let draft else { return }
            reply = draft
            replyFocused = true
        }
    }

    private func submitReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        onReply(text)
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
        case .chat(let bubbles):
            ChatDetail(bubbles: bubbles, onOpen: onOpen)
        }
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
                    .font(.system(size: 13))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A conversation as bubbles, oldest at the top: theirs on the left, yours on the right.
/// More than fits scrolls back through the history, starting at the newest message.
private struct ChatDetail: View {
    let bubbles: [ChatBubble]
    let onOpen: (ChatBubble) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            stack
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) { stack }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: bubbles.last?.id) { _, last in
                        // A new message (or one you just sent) scrolls into view.
                        guard let last else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
            }
        }
    }

    private var stack: some View {
        VStack(spacing: 5) {
            ForEach(bubbles) { bubble in
                ChatBubbleView(bubble: bubble, newest: bubble.id == bubbles.last?.id) { onOpen(bubble) }
                    .id(bubble.id)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChatBubbleView: View {
    let bubble: ChatBubble
    let newest: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if bubble.fromMe { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 2) {
                if !bubble.sender.isEmpty {
                    Text(bubble.sender)
                        .font(NookTheme.font(11.5, .semibold))
                        .foregroundStyle(NookTheme.mint)
                        .lineLimit(1)
                }
                if let attachment = bubble.attachment {
                    switch bubble.media {
                    case .photo where bubble.image != nil:
                        PhotoButton(image: bubble.image!, name: attachment, action: onOpen)
                    case .video(let url):
                        VideoTile(url: url, poster: bubble.image, name: attachment)
                    default:
                        AttachmentButton(name: attachment, preview: bubble.image, action: onOpen)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    if !bubble.text.isEmpty {
                        Text(bubble.text)
                            .font(NookTheme.font(14, newest ? .medium : .regular))
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(bubble.time)
                        .font(NookTheme.font(10.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(bubble.fromMe ? NookTheme.mint.opacity(0.16) : NookTheme.smoke)
            )
            if !bubble.fromMe { Spacer(minLength: 70) }
        }
    }
}

/// A video in a chat bubble: its first frame, whole, with a play button, and a click plays it right there with the
/// system's controls (pause, scrub, volume). The enlarge button opens it big in a window of its
/// own that goes full screen, carrying on where the bubble was.
private struct VideoTile: View {
    let url: URL
    let poster: NSImage?
    let name: String
    @State private var player: AVPlayer?
    @State private var hovering = false

    private var size: CGSize {
        guard let poster, poster.size.width > 0, poster.size.height > 0 else { return CGSize(width: 240, height: 135) }
        let height = min(PhotoButton.maxHeight, PhotoButton.maxWidth * poster.size.height / poster.size.width)
        return CGSize(width: height * poster.size.width / poster.size.height, height: height)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let player {
                InlinePlayer(player: player)
            } else {
                Button { play() } label: {
                    ZStack {
                        Color.black
                        if let poster {
                            Image(nsImage: poster)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        }
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(hovering ? 0.65 : 0.5)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("card.video.play"))
                .accessibilityLabel("\(tr("card.video.play")): \(name)")
            }
            if hovering || player == nil {
                Button { enlarge() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(tr("card.video.enlarge"))
                .accessibilityLabel("\(tr("card.video.enlarge")): \(name)")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onDisappear { player?.pause() }
    }

    private func play() {
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    /// The video big, from where the bubble was; the bubble stops so it never plays twice.
    private func enlarge() {
        let time = player?.currentTime() ?? .zero
        player?.pause()
        player = nil
        VideoWindow.shared.show(url, title: name, at: time, aspect: poster?.size)
    }
}

/// The system's video player in a bubble: the picture whole, never cropped, and stopped when the bubble goes away.
private struct InlinePlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        // Full screen happens in the video's own window: the notch cannot go full screen.
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// A photo in a chat bubble, as it came: a click opens it in full.
private struct PhotoButton: View {
    static let maxWidth: CGFloat = 240
    static let maxHeight: CGFloat = 180

    let image: NSImage
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.maxWidth, maxHeight: Self.maxHeight, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(hovering ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("card.attachment.view"))
        .accessibilityLabel("\(tr("card.attachment.view")): \(name)")
    }
}

/// A file in a chat bubble: its first page (else an icon) and its name, and a click shows it.
private struct AttachmentButton: View {
    let name: String
    var preview: NSImage? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(NookTheme.mint)
                }
                Text(name)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Text(tr("card.attachment.view"))
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("card.attachment.view"))
        .accessibilityLabel("\(tr("card.attachment.view")): \(name)")
    }
}

/// An offer from Nook as a button, preceded by a sparkle.
private struct OfferChip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(NookTheme.iris)
                Text(title)
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? NookTheme.smoke : NookTheme.field))
            .overlay(Capsule().stroke(hovering ? NookTheme.iris.opacity(0.3) : NookTheme.line2, lineWidth: 1))
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
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(top)
                    .font(NookTheme.font(9, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Text(big)
                    .font(NookTheme.font(14, .bold))
                    .foregroundStyle(NookTheme.paper)
            }
            .frame(width: 36, height: 36)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(NookTheme.line2, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(line)
                    .font(NookTheme.font(14, .medium))
                    .foregroundStyle(NookTheme.paper)
                Text(subline)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
    }
}

private struct CommandDetail: View {
    let command: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The whole command, never cut off: what you approve is exactly what runs. Long commands scroll.
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
            .font(NookTheme.mono(13.5))
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(NookTheme.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(NookTheme.line).frame(height: 1) }

            Text(note)
                .font(NookTheme.font(12.5))
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
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 12) {
                    Text("\(step.number)")
                        .font(NookTheme.font(11, .bold))
                        .foregroundStyle(color(step.tone))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(color(step.tone), lineWidth: 1.5))
                    Text(step.text)
                        .font(NookTheme.font(14))
                        .foregroundStyle(NookTheme.paper)
                    if !step.tag.isEmpty {
                        Text(step.tag)
                            .font(NookTheme.font(12, .medium))
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
        VStack(alignment: .leading, spacing: 6) {
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
                .padding(.top, 4)
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (checked ? "checkmark.square.fill" : "square") : "arrow.right.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(checked ? NookTheme.mint : NookTheme.textSecondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(NookTheme.font(14, .medium))
                        .foregroundStyle(NookTheme.paper)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering || checked ? NookTheme.smoke : NookTheme.field))
            .contentShape(Rectangle())
            .hoverLift(hovering, scale: 1.01)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// An edit from an agent: file name, modified lines, and a brief description.
private struct DiffDetail: View {
    let title: String
    let lines: [DiffLine]
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(NookTheme.textTertiary).padding(.bottom, 4)
                    ForEach(lines) { line in
                        Text(line.text).foregroundStyle(line.color).lineLimit(1)
                    }
                }
                .font(NookTheme.mono(11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))

            Text(note)
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.textSecondary)
        }
    }
}

/// Metrics in two columns, such as the weekly summary.
private struct FactsDetail: View {
    let facts: [Fact]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.value)
                        .font(NookTheme.font(16, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(fact.label)
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
