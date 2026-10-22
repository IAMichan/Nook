import SwiftUI
import AVKit

/// A conversation as bubbles, oldest at the top: theirs on the left, yours on the right, the way a chat app shows it.
/// A line marks where a new day starts; messages one person sends in a row sit close together under their name (each
/// person in a group in a color of their own); links open; a message of only emoji shows large; a long message folds
/// open with "Read more". More than fits scrolls back through the history, starting at the newest message. Each
/// message's text can be selected; right-click a bubble to copy the message or the whole chat. A message that answers
/// another quotes it at its top, and the emoji people put on it sit under it. Where the chat can be answered, the pointer
/// on a bubble shows a button to answer that message and one to react with an emoji. Used by the chat card in the notch
/// and by the Chats tab.
struct ChatTranscript: View {
    let bubbles: [ChatBubble]
    /// Who the chat is with, for the copied chat's lines in a private chat.
    let contact: String
    /// Takes all the room it gets and scrolls inside it (the Chats tab), instead of growing with the messages up to
    /// the card's height.
    var fills = false
    var onOpen: (ChatBubble) -> Void = { _ in }
    var onZoom: (ChatBubble) -> Void = { _ in }
    /// Answering one message (the field then quotes it). Nil where the chat cannot be answered: no reply button.
    var onReply: ((ChatBubble) -> Void)? = nil
    /// Putting an emoji on a message; the one you already put there takes it back. Nil where the chat cannot be answered.
    var onReact: ((ChatBubble, String) -> Void)? = nil
    /// Voting on a poll with your new choice. Nil where the chat's app cannot take a vote from Nook: the poll then
    /// shows its counts and says to vote in the app.
    var onVote: ((ChatBubble, [String]) -> Void)? = nil

    var body: some View {
        if fills {
            scroller
        } else {
            ViewThatFits(in: .vertical) {
                stack
                scroller
            }
        }
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) { stack }
                .defaultScrollAnchor(.bottom)
                .onChange(of: bubbles.last?.id) { _, last in
                    // A new message (or one you just sent) scrolls into view.
                    guard let last else { return }
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(last, anchor: .bottom) }
                }
        }
    }

    private var entries: [ChatTimeline.Entry] {
        let items = bubbles.map { ChatTimeline.Item(id: $0.id, author: $0.fromMe ? "\u{1}me" : $0.sender, date: $0.date) }
        return ChatTimeline.entries(items, locale: Locale(identifier: I18n.shared.currentLanguage.rawValue))
    }

    private var stack: some View {
        let byID = Dictionary(bubbles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = entries.map { Row(id: ChatTimeline.id(of: $0), entry: $0) }
        let top = rows.first?.id
        return VStack(spacing: 0) {
            ForEach(rows) { row in
                switch row.entry {
                case .day(_, let label):
                    ChatDayDivider(label: label)
                case .message(_, let first, _):
                    if let bubble = byID[row.id] {
                        ChatBubbleView(bubble: bubble, first: first, newest: bubble.id == bubbles.last?.id,
                                       onOpen: { onOpen(bubble) }, onZoom: { onZoom(bubble) },
                                       onReply: replyAction(bubble), onReact: reactAction(bubble),
                                       onVote: voteAction(bubble))
                            .contextMenu {
                                if let onReply {
                                    Button(tr("chat.reply")) { onReply(bubble) }
                                }
                                if let onReact {
                                    Menu(tr("chat.react")) {
                                        ForEach(ChatReactions.quick, id: \.self) { emoji in
                                            Button(emoji) { onReact(bubble, emoji) }
                                        }
                                    }
                                }
                                if !bubble.copyText.isEmpty {
                                    Button(tr("whatsapp.copy.message")) { Pasteboard.copy(bubble.copyText) }
                                }
                                Button(tr("whatsapp.copy.chat")) { Pasteboard.copy(ChatBubble.transcript(bubbles, contact: contact)) }
                            }
                            // A new run starts with room above it; the messages of one run sit close together.
                            .padding(.top, row.id == top ? 0 : (first ? NookTheme.Spacing.md : NookTheme.Spacing.xxs))
                            .id(bubble.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func replyAction(_ bubble: ChatBubble) -> (() -> Void)? {
        guard let onReply else { return nil }
        return { onReply(bubble) }
    }

    private func voteAction(_ bubble: ChatBubble) -> (([String]) -> Void)? {
        guard let onVote, bubble.poll != nil else { return nil }
        return { onVote(bubble, $0) }
    }

    private func reactAction(_ bubble: ChatBubble) -> ((String) -> Void)? {
        guard let onReact else { return nil }
        return { onReact(bubble, $0) }
    }

    private struct Row: Identifiable {
        let id: String
        let entry: ChatTimeline.Entry
    }
}

/// Where a new day starts in a chat: "Today", "Yesterday", "Monday", "12 Oct". Just the quiet word, centered, with room
/// around it: the space marks the break, no pill needed.
private struct ChatDayDivider: View {
    let label: String

    var body: some View {
        Text(label)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, NookTheme.Spacing.xl)
            .padding(.bottom, NookTheme.Spacing.sm)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ChatBubbleView: View {
    let bubble: ChatBubble
    /// The first of a run by one person: their name above it (in a group) and the bubble's corner points at them.
    let first: Bool
    let newest: Bool
    let onOpen: () -> Void
    let onZoom: () -> Void
    let onReply: (() -> Void)?
    let onReact: ((String) -> Void)?
    let onVote: (([String]) -> Void)?
    @State private var expanded = false
    @State private var hovering = false
    /// The emoji to react with are open beside the bubble.
    @State private var picking = false

    /// Each person in a group writes in a color of their own, the same every time.
    private static let senderColors: [Color] = [NookTheme.mint, NookTheme.blue, NookTheme.violet, NookTheme.music]
    /// Lines a long message shows until "Read more".
    private static let foldedLines = 12

    private var emojiOnly: Bool { bubble.attachment == nil && ChatTimeline.isEmojiOnly(bubble.text) }
    /// A sticker stands on its own, as an emoji does: no bubble around it.
    private var bare: Bool {
        if case .sticker = bubble.media, bubble.text.isEmpty { return true }
        return emojiOnly
    }
    private var long: Bool { bubble.text.count > 700 || bubble.text.filter { $0 == "\n" }.count >= Self.foldedLines }
    /// The start of a long message while it is folded: its first lines, its first 700 characters.
    private var folded: String {
        String(bubble.text.components(separatedBy: "\n").prefix(Self.foldedLines).joined(separator: "\n").prefix(700))
    }

    /// When it was sent, and for your own how far it got.
    private var stamp: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text(bubble.time)
                .font(NookTheme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(NookTheme.textTertiary)
            if let ticks = bubble.ticks { TicksView(ticks: ticks) }
        }
        .fixedSize()
    }

    /// The file that came with the message, as itself once Nook has it, else a button that opens it.
    @ViewBuilder
    private func media(_ attachment: String) -> some View {
        switch bubble.media {
        case .photo where bubble.image != nil:
            PhotoButton(image: bubble.image!, name: attachment, action: onZoom)
        case .video(let url):
            VideoTile(url: url, poster: bubble.image, name: attachment)
        case .gif(let url):
            ChatGIFView(url: url, name: attachment)
        case .sticker(let url):
            ChatStickerView(url: url, name: attachment)
        case .audio(let url, let seconds):
            ChatAudioView(url: url, seconds: seconds, name: attachment, fromMe: bubble.fromMe)
        default:
            AttachmentButton(name: attachment, preview: bubble.image, action: onOpen)
        }
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if bubble.fromMe {
                Spacer(minLength: 70)
                actions
            }
            VStack(alignment: bubble.fromMe ? .trailing : .leading, spacing: NookTheme.Spacing.xxs) {
                content
                if !bubble.reactions.isEmpty {
                    ReactionChips(reactions: bubble.reactions, onReact: onReact)
                        .padding(.horizontal, NookTheme.Spacing.sm)
                }
            }
            if !bubble.fromMe {
                actions
                Spacer(minLength: 70)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Answer this message and react to it: shown while the pointer is on the bubble, where the chat can be answered.
    @ViewBuilder
    private var actions: some View {
        if onReply != nil || onReact != nil {
            let shown = hovering || picking
            HStack(spacing: NookTheme.Spacing.xxs) {
                if let onReact {
                    BubbleActionButton(symbol: "face.smiling", label: tr("chat.react")) { picking = true }
                        .popover(isPresented: $picking, arrowEdge: .top) {
                            ReactionPicker(mine: bubble.reactions.first(where: \.mine)?.emoji) { emoji in
                                picking = false
                                onReact(emoji)
                            }
                        }
                }
                if let onReply {
                    BubbleActionButton(symbol: "arrowshape.turn.up.left", label: tr("chat.reply"), action: onReply)
                }
            }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(NookTheme.hover, value: shown)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            if first, !bubble.sender.isEmpty {
                Text(bubble.sender)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(Self.senderColors[ChatTimeline.colorIndex(for: bubble.sender, count: Self.senderColors.count)])
                    .lineLimit(1)
            }
            if let quote = bubble.quote {
                QuotedMessage(quote: quote)
                    .padding(.bottom, NookTheme.Spacing.xxs)
            }
            if let poll = bubble.poll {
                ChatPollView(poll: poll, onVote: onVote)
            }
            if let attachment = bubble.attachment {
                if bubble.text.isEmpty {
                    // Without text the time sits under the file, inside its width: the bubble is as wide as the file.
                    VStack(alignment: .trailing, spacing: NookTheme.Spacing.xs) {
                        media(attachment)
                        stamp
                    }
                } else {
                    media(attachment)
                }
            }
            if !bubble.text.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: NookTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                        if emojiOnly {
                            Text(bubble.text)
                                .font(NookTheme.font(34))
                                .textSelection(.enabled)
                        } else {
                            ChatMessageText(text: long && !expanded ? folded : bubble.text,
                                            lineLimit: long && !expanded ? Self.foldedLines : nil)
                        }
                        if long {
                            Button(expanded ? tr("chat.showLess") : tr("chat.readMore")) {
                                withAnimation(NookTheme.swap) { expanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(NookTheme.blue)
                        }
                    }
                    stamp
                }
            } else if bubble.attachment == nil {
                // A poll or an empty message: the time under it, on the right.
                stamp.frame(maxWidth: bubble.poll == nil ? nil : CGFloat.infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, bare ? NookTheme.Spacing.xs : NookTheme.Spacing.lg)
        .padding(.vertical, bare ? NookTheme.Spacing.xxs : NookTheme.Spacing.md)
        .background(shape.fill(bare ? Color.clear : (bubble.fromMe ? NookTheme.mint.opacity(0.13) : NookTheme.smoke)))
    }

    /// Round, with the first bubble of a run pointing at its writer the way a chat app's tail does.
    private var shape: UnevenRoundedRectangle {
        let round = NookTheme.Radius.sheet
        let tail = NookTheme.Radius.chip
        return UnevenRoundedRectangle(topLeadingRadius: first && !bubble.fromMe ? tail : round, bottomLeadingRadius: round,
                                      bottomTrailingRadius: round, topTrailingRadius: first && bubble.fromMe ? tail : round,
                                      style: .continuous)
    }
}

/// The emoji the reaction buttons offer, as WhatsApp's own quick row.
enum ChatReactions {
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
}

/// The message a bubble answers, at the bubble's top: a bar, who wrote it and the start of its text.
private struct QuotedMessage: View {
    let quote: BubbleQuote

    private var tint: Color { quote.mine ? NookTheme.mint : NookTheme.blue }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                if !quote.sender.isEmpty {
                    Text(quote.sender)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(quote.text)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, NookTheme.Spacing.xs)
        .padding(.leading, NookTheme.Spacing.lg)
        .padding(.trailing, NookTheme.Spacing.md)
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, NookTheme.Spacing.xs).padding(.leading, NookTheme.Spacing.xs)
        }
        .frame(maxWidth: PhotoButton.maxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.paper.opacity(0.05)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("chat.quote", quote.sender.isEmpty ? quote.text : "\(quote.sender): \(quote.text)"))
    }
}

/// The emoji under a bubble, one chip each with how many put it there; yours is tinted, and a click on one puts that
/// emoji there too, or takes yours back.
private struct ReactionChips: View {
    let reactions: [BubbleReaction]
    let onReact: ((String) -> Void)?

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ForEach(reactions) { reaction in
                Button { onReact?(reaction.emoji) } label: {
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        Text(reaction.emoji).font(NookTheme.font(12.5))
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(NookTheme.TextStyle.caption)
                                .monospacedDigit()
                                .foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    // Yours is tinted; the others are a plain soft chip, no edge, so a row of them stays quiet.
                    .background(Capsule().fill(reaction.mine ? NookTheme.mint.opacity(0.18) : NookTheme.graphite))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(onReact == nil)
                .help(reaction.mine ? tr("chat.react.takeBack") : tr("chat.react"))
                .accessibilityLabel(tr("chat.reactions", reaction.emoji, reaction.count))
            }
        }
    }
}

/// A small round button beside a bubble: answer it, react to it.
private struct BubbleActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(NookTheme.smoke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverLift(hovering, scale: 1.03)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The emoji to react with, in a row, and "+" for every other emoji; the one you already put there is marked, and
/// choosing it again takes it back.
private struct ReactionPicker: View {
    let mine: String?
    let choose: (String) -> Void
    /// "+" was clicked: every emoji, with a search.
    @State private var browsing = false

    var body: some View {
        if browsing {
            EmojiBrowser(chosen: mine, choose: choose)
        } else {
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(ChatReactions.quick, id: \.self) { emoji in
                    ReactionPickerButton(emoji: emoji, chosen: emoji == mine) { choose(emoji) }
                }
                // A reaction outside the quick row is marked here too, so it can be taken back.
                if let mine, !ChatReactions.quick.contains(mine) {
                    ReactionPickerButton(emoji: mine, chosen: true) { choose(mine) }
                }
                MoreEmojiButton { browsing = true }
            }
            .padding(NookTheme.Spacing.sm)
        }
    }
}

/// "+" after the quick row: opens every emoji.
private struct MoreEmojiButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(NookTheme.smoke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverLift(hovering, scale: 1.03)
        .help(tr("chat.react.more"))
        .accessibilityLabel(tr("chat.react.more"))
    }
}

private struct ReactionPickerButton: View {
    let emoji: String
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(NookTheme.font(22))
                .frame(width: 36, height: 36)
                .background(Circle().fill(chosen ? NookTheme.mint.opacity(0.2) : (hovering ? NookTheme.smoke : Color.clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverLift(hovering, scale: 1.06)
        .help(chosen ? tr("chat.react.takeBack") : emoji)
        .accessibilityLabel(emoji)
    }
}

/// Web addresses and mail addresses in a message as links you can click, as a chat app shows them.
enum ChatLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        // Most messages have no address at all: skip the detector for them.
        guard text.contains("."), let detector else { return attributed }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: attributed) else { continue }
            attributed[range].link = url
            attributed[range].underlineStyle = .single
        }
        return attributed
    }
}

/// Your own message's ticks after its time, as WhatsApp draws them: a clock while it goes out, one grey tick on the
/// server, two on their phone, two blue ones once read, a red mark when it could not be sent. Also in front of a chat's
/// newest message in the Chats tab's list, when that message is yours.
struct TicksView: View {
    let ticks: BubbleTicks

    var body: some View {
        Group {
            switch ticks {
            case .pending:
                Image(systemName: "clock").font(NookTheme.font(9, .semibold))
            case .sent:
                check
            case .delivered, .read:
                // The second tick overlaps the first, as on the phone.
                ZStack(alignment: .leading) {
                    check
                    check.padding(.leading, 4)
                }
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(NookTheme.font(10, .semibold))
            }
        }
        .foregroundStyle(color)
        .accessibilityElement()
        .accessibilityLabel(tr(label))
    }

    private var check: some View {
        Image(systemName: "checkmark").font(NookTheme.font(9, .bold))
    }

    private var color: Color {
        switch ticks {
        case .read: return NookTheme.blue
        case .failed: return NookTheme.coral
        case .pending, .sent, .delivered: return NookTheme.textTertiary
        }
    }

    private var label: String {
        switch ticks {
        case .pending: return "whatsapp.ticks.pending"
        case .sent: return "whatsapp.ticks.sent"
        case .delivered: return "whatsapp.ticks.delivered"
        case .read: return "whatsapp.ticks.read"
        case .failed: return "whatsapp.ticks.failed"
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
                            .font(NookTheme.font(18, .semibold))
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
                        .font(NookTheme.font(11, .semibold))
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
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
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

/// A chat bubble's photo enlarged over the whole card or chat, inside Nook: the bubble's picture at once, then the photo
/// itself sharp from the file on this Mac. A click anywhere (or Escape) shrinks it back; the open button shows it in
/// Quick Look. Used by the chat card in the notch and by the Chats tab.
struct ChatPhotoZoom: View {
    let url: URL
    let preview: NSImage
    let name: String
    let onClose: () -> Void
    let onOpen: () -> Void
    @State private var sharp: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onClose) {
                ZStack {
                    Color.black.opacity(0.94)
                    Image(nsImage: sharp ?? preview)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous))
                        .padding(8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("button.close"))
            .accessibilityLabel("\(tr("button.close")): \(name)")

            HStack(spacing: 6) {
                zoomButton("arrow.up.forward.app", label: tr("card.attachment.open"), action: onOpen)
                zoomButton("xmark", label: tr("button.close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous))
        .task(id: url) {
            let url = self.url
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            sharp = data.flatMap { WhatsAppLink.thumbnail($0, side: 2400) }
        }
    }

    private func zoomButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A photo in a chat bubble, as it came: a click enlarges it in the card or chat.
private struct PhotoButton: View {
    static let maxWidth: CGFloat = 240
    static let maxHeight: CGFloat = 180

    let image: NSImage
    let name: String
    let action: () -> Void
    @State private var hovering = false

    /// The photo whole, fitted in 240 × 180: exactly its own size, so the bubble is no wider than the photo.
    private var size: CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return CGSize(width: Self.maxWidth, height: Self.maxHeight) }
        let scale = min(Self.maxWidth / image.size.width, Self.maxHeight / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    var body: some View {
        Button(action: action) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
                .opacity(hovering ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("card.video.enlarge"))
        .accessibilityLabel("\(tr("card.video.enlarge")): \(name)")
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
            HStack(spacing: NookTheme.Spacing.md) {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "doc.fill")
                        .font(NookTheme.font(14))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                Text(name)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Text(tr("card.attachment.view"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            }
            .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.paper.opacity(hovering ? 0.09 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("card.attachment.view"))
        .accessibilityLabel("\(tr("card.attachment.view")): \(name)")
    }
}
