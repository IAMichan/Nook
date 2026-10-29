import SwiftUI
import AVKit
import UniformTypeIdentifiers

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
    /// "Edit" and "Delete for everyone" on your own messages, where the chat's app takes them; nil shows neither.
    var onEdit: ((ChatBubble) -> Void)? = nil
    var onDelete: ((ChatBubble) -> Void)? = nil
    /// Voting on a poll with your new choice. Nil where the chat's app cannot take a vote from Nook: the poll then
    /// shows its counts and says to vote in the app.
    var onVote: ((ChatBubble, [String]) -> Void)? = nil
    /// Fetching the messages before the oldest shown; true when some came. Nil where the chat cannot load older ones:
    /// no button at its top.
    var onLoadOlder: (() async -> Bool)? = nil
    /// Who is typing in the chat now ("Jan is typing…"), shown under its last message; nil while no one does.
    var typing: String? = nil
    /// The first message that was new when the chat opened: a line above it says so, and it stays put while you read.
    var newFrom: String? = nil
    @State private var loadingOlder = false
    /// The pointer or fingers moved the chat: only then does reaching the top load older messages, not the first layout.
    @State private var scrolledByUser = false
    /// The last fetch brought nothing: the chat's start is shown, so reaching the top again does not ask once more.
    @State private var reachedStart = false
    /// The newest message is in view (or nearly): a new one glides in. Scrolled back to read, nothing moves the chat;
    /// a button brings you back down instead.
    @State private var atBottom = true
    /// Messages from others that came in while you were scrolled back, counted on the button.
    @State private var missed = 0

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
            // As a chat app's, the chat scrolls without a bar beside it: `.never`, because `.hidden` still shows one when
            // the system shows scroll bars always (a mouse connected).
            ScrollView {
                VStack(spacing: 0) {
                    if onLoadOlder != nil {
                        loadOlderButton { loadOlder(proxy) }
                    }
                    stack
                }
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottomTrailing) {
                if !atBottom, let last = bubbles.last?.id {
                    ChatJumpButton(missed: missed) {
                        withAnimation(NookTheme.scroll) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    .padding(NookTheme.Spacing.md)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(NookTheme.reveal, value: atBottom)
            // Scrolling up to the top loads the older messages by itself; the button stays for a click. Moving up while
            // the sizes stay the same can only be you (loading and new messages change the size), so a mouse wheel,
            // which reports no scroll phase, counts as well as the trackpad.
            .onScrollGeometryChange(for: TranscriptScrollGeometry.self) { geometry in
                TranscriptScrollGeometry(offset: geometry.contentOffset.y,
                                         container: geometry.containerSize.height,
                                         content: geometry.contentSize.height)
            } action: { old, new in
                if new.offset < old.offset - 0.5, new.content == old.content, new.container == old.container {
                    scrolledByUser = true
                }
                if new.nearTop, scrolledByUser { loadOlder(proxy, automatic: true) }
                if new.nearBottom != atBottom {
                    atBottom = new.nearBottom
                    if atBottom { missed = 0 }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { scrolledByUser = true }
            }
            .onChange(of: bubbles.last?.id) { previous, last in
                guard let last else { return }
                // A new message (or one you just sent) glides into view. Another chat, or a chat's history arriving
                // at once, is not a new message: it is simply there, at its newest, without scrolling past everything.
                let arrived = previous.map { old in bubbles.suffix(4).contains { $0.id == old } } ?? false
                if arrived {
                    // Reading back: the chat stays where you are, and the button counts what came in. Your own
                    // message always brings you down to it.
                    guard atBottom || bubbles.last?.fromMe == true else {
                        missed += 1
                        return
                    }
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(last, anchor: .bottom) }
                } else {
                    var jump = Transaction()
                    jump.disablesAnimations = true
                    withTransaction(jump) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            // Someone starts typing: their bubble comes into view under the last message.
            .onChange(of: typing != nil) { _, shown in
                guard shown else { return }
                withAnimation(NookTheme.scroll) { proxy.scrollTo(ChatTypingBubble.id, anchor: .bottom) }
            }
            // Another chat starts at its newest message again: reaching its top counts only once you scroll there.
            .onChange(of: contact) {
                scrolledByUser = false
                reachedStart = false
                atBottom = true
                missed = 0
            }
        }
    }

    /// Loads the older messages once at a time; the message that was on top stays where it was, with the older ones
    /// above it.
    private func loadOlder(_ proxy: ScrollViewProxy, automatic: Bool = false) {
        guard let onLoadOlder, !loadingOlder, !(automatic && reachedStart) else { return }
        loadingOlder = true
        let anchor = bubbles.first?.id
        Task { @MainActor in
            let loaded = await onLoadOlder()
            if loaded, let anchor { proxy.scrollTo(anchor, anchor: .top) }
            reachedStart = !loaded
            loadingOlder = false
        }
    }

    /// "Load older messages" at the top of the chat.
    private func loadOlderButton(_ load: @escaping () -> Void) -> some View {
        Button {
            load()
        } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                if loadingOlder { ProgressView().controlSize(.small) }
                Text(tr("chat.loadOlder"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.blue)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NookTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingOlder)
        .accessibilityLabel(tr("chat.loadOlder"))
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
                case .message(_, let first, let last):
                    if row.id == newFrom, row.id != top {
                        ChatNewDivider()
                            .padding(.top, NookTheme.Spacing.md)
                    }
                    if let bubble = byID[row.id] {
                        ChatBubbleView(bubble: bubble, first: first, last: last, newest: bubble.id == bubbles.last?.id,
                                       onOpen: { onOpen(bubble) }, onZoom: { onZoom(bubble) },
                                       onReply: replyAction(bubble), onReact: reactAction(bubble),
                                       onEdit: editAction(bubble), onDelete: deleteAction(bubble),
                                       onCopyChat: { Pasteboard.copy(ChatBubble.transcript(bubbles, contact: contact)) },
                                       onVote: voteAction(bubble))
                            .equatable()
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
                                if bubble.fromMe, let onEdit, !bubble.text.isEmpty, bubble.poll == nil, bubble.call == nil {
                                    Button(tr("chat.edit")) { onEdit(bubble) }
                                }
                                if !bubble.copyText.isEmpty {
                                    Button(tr("whatsapp.copy.message")) { Pasteboard.copy(bubble.copyText) }
                                }
                                Button(tr("whatsapp.copy.chat")) { Pasteboard.copy(ChatBubble.transcript(bubbles, contact: contact)) }
                                if let onDelete {
                                    Divider()
                                    Button(tr("chat.deleteMessage"), role: .destructive) { onDelete(bubble) }
                                }
                            }
                            // A new run starts with room above it; the messages of one run sit close together, so who
                            // said what reads at a glance.
                            .padding(.top, row.id == top ? 0 : (first ? NookTheme.Spacing.lg : NookTheme.Spacing.xxs))
                            .id(bubble.id)
                    }
                }
            }
            if let typing {
                ChatTypingBubble(text: typing)
                    .padding(.top, rows.isEmpty ? 0 : NookTheme.Spacing.md)
                    .id(ChatTypingBubble.id)
                    .transition(.opacity)
            }
        }
        .animation(NookTheme.reveal, value: typing)
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

    /// Deleting a message: the host asks how (for you, or for everyone where it is yours and its app takes that).
    private func deleteAction(_ bubble: ChatBubble) -> (() -> Void)? {
        guard let onDelete else { return nil }
        return { onDelete(bubble) }
    }

    /// Changing your own message's text, where its app takes that: in the message's menu.
    private func editAction(_ bubble: ChatBubble) -> (() -> Void)? {
        guard let onEdit, bubble.fromMe, !bubble.text.isEmpty, bubble.poll == nil, bubble.call == nil else { return nil }
        return { onEdit(bubble) }
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

/// Where a new day starts in a chat: "Today", "Yesterday", "Monday", "12 Oct". A small soft label in the middle with
/// room around it, as chat apps mark the day: easy to find while scrolling, quiet while reading.
private struct ChatDayDivider: View {
    let label: String

    var body: some View {
        Text(label)
            .font(NookTheme.TextStyle.caption)
            .fontWeight(.semibold)
            .foregroundStyle(NookTheme.textStrong)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.chatTheirs))
            .frame(maxWidth: .infinity)
            .padding(.top, NookTheme.Spacing.xl)
            .padding(.bottom, NookTheme.Spacing.md)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Drawn again only when what it shows changed: the chat around it redraws on every change anywhere in Nook's chats
/// (a message in another chat, a picture that came in), and fifty bubbles each parsing their text again makes scrolling
/// stutter.
private struct ChatBubbleView: View, Equatable {
    let bubble: ChatBubble
    /// The first of a run by one person: their name above it (in a group) and the bubble's corner points at them.
    let first: Bool
    /// The last of a run: it carries the time (and your ticks); the others show it under the pointer, so a run of
    /// messages reads as one calm block.
    let last: Bool
    let newest: Bool
    let onOpen: () -> Void
    let onZoom: () -> Void
    let onReply: (() -> Void)?
    let onReact: ((String) -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onCopyChat: () -> Void
    let onVote: (([String]) -> Void)?
    @State private var expanded = false
    @State private var hovering = false
    /// The emoji to react with are open beside the bubble.
    @State private var picking = false
    /// Your message's info (who read it, who has it) is open over its ticks.
    @State private var showingInfo = false

    /// Lines a long message shows until "Read more".
    private static let foldedLines = 12
    /// The widest a bubble gets: a long message wraps into lines that are easy to read, however wide the chat is.
    static let maxWidth: CGFloat = 560

    /// The actions only count by whether they are there: they do the same for the same bubble.
    static func == (a: ChatBubbleView, b: ChatBubbleView) -> Bool {
        a.bubble == b.bubble && a.first == b.first && a.last == b.last && a.newest == b.newest
            && (a.onReply == nil) == (b.onReply == nil) && (a.onReact == nil) == (b.onReact == nil)
            && (a.onEdit == nil) == (b.onEdit == nil) && (a.onDelete == nil) == (b.onDelete == nil)
            && (a.onVote == nil) == (b.onVote == nil)
    }

    private var emojiOnly: Bool { bubble.attachment == nil && ChatTimeline.isEmojiOnly(bubble.text) }
    /// A sticker stands on its own, as an emoji does: no bubble around it.
    private var bare: Bool {
        if case .sticker = bubble.media, bubble.text.isEmpty { return true }
        return emojiOnly || mediaOnly
    }

    /// A photo, video or GIF without words: it stands on its own, without a bubble around it, with its time on the
    /// picture, as chat apps show them.
    private var mediaOnly: Bool {
        guard bubble.text.isEmpty, bubble.quote == nil, bubble.poll == nil else { return false }
        switch bubble.media {
        case .photo: return true
        case .video, .gif: return true
        default: return false
        }
    }

    /// The time (and your ticks) on a picture: light on a dark capsule, so it reads on any photo.
    private var mediaStamp: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text(bubble.time)
                .font(NookTheme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(NookTheme.paper)
            if let ticks = bubble.ticks { TicksView(ticks: ticks) }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.xxs)
        .background(Capsule().fill(NookTheme.ink.opacity(0.55)))
        .padding(NookTheme.Spacing.sm)
        .allowsHitTesting(false)
    }
    private var long: Bool { bubble.text.count > 700 || bubble.text.filter { $0 == "\n" }.count >= Self.foldedLines }
    /// The start of a long message while it is folded: its first lines, its first 700 characters.
    private var folded: String {
        String(bubble.text.components(separatedBy: "\n").prefix(Self.foldedLines).joined(separator: "\n").prefix(700))
    }

    /// Whether this bubble shows its time: the last of a run, and your message that is still going out or failed (that
    /// must stay in sight). The others say it under the pointer, as a tooltip, so nothing in the chat shifts.
    private var showsStamp: Bool { true }

    /// When it was sent, and for your own how far it got.
    private var stamp: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text(bubble.time)
                .font(NookTheme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(NookTheme.chatStamp)
            if let ticks = bubble.ticks {
                if bubble.readers.isEmpty {
                    TicksView(ticks: ticks)
                } else {
                    // In a group: a click on the ticks says who read it, who has it, and who does not yet.
                    Button { showingInfo = true } label: { TicksView(ticks: ticks) }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help(tr("chat.info.title"))
                        .accessibilityLabel(tr("chat.info.title"))
                }
            }
        }
        .fixedSize()
    }

    /// The file that came with the message, as itself once Nook has it, else a button that opens it.
    @ViewBuilder
    private func media(_ attachment: String) -> some View {
        switch bubble.media {
        case .photo(let url):
            if let image = bubble.image {
                PhotoButton(image: image, name: attachment, action: onZoom)
            } else {
                ChatPhotoLoader(url: url, name: attachment, onZoom: onZoom, onOpen: onOpen)
            }
        case .video(let url):
            VideoTile(url: url, poster: bubble.image, name: attachment)
        case .gif(let url):
            ChatGIFView(url: url, name: attachment)
        case .sticker(let url):
            ChatStickerView(url: url, name: attachment)
        case .audio(let url, let seconds):
            ChatAudioView(url: url, seconds: seconds, name: attachment, fromMe: bubble.fromMe)
        default:
            AttachmentButton(name: attachment, preview: bubble.image, file: bubble.file, action: onOpen)
        }
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if bubble.fromMe {
                Spacer(minLength: 70)
                actions
            }
            CappedWidth(maximum: Self.maxWidth) {
                VStack(alignment: bubble.fromMe ? .trailing : .leading, spacing: NookTheme.Spacing.xxs) {
                    content
                        .overlay(alignment: .topTrailing) {
                            MessageMenuButton(bubble: bubble, onReply: onReply, onEdit: onEdit, onDelete: onDelete,
                                              onInfo: bubble.fromMe && bubble.ticks != nil ? { showingInfo = true } : nil,
                                              onCopyChat: onCopyChat, onPicture: bare)
                                .padding(NookTheme.Spacing.xs)
                                .opacity(hovering ? 1 : 0)
                                .allowsHitTesting(hovering)
                                .animation(NookTheme.hover, value: hovering)
                        }
                        .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                            if let ticks = bubble.ticks { MessageInfoView(ticks: ticks, readers: bubble.readers) }
                        }
                    if !bubble.reactions.isEmpty {
                        ReactionChips(reactions: bubble.reactions, onReact: onReact)
                            .padding(.horizontal, NookTheme.Spacing.sm)
                    }
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
                    // Each person in a group writes in a color of their own, the same every time.
                    .foregroundStyle(ChatPersonBadge.tint(for: bubble.sender))
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
                    if mediaOnly {
                        media(attachment)
                            .overlay(alignment: .bottomTrailing) { if showsStamp { mediaStamp } }
                    } else {
                        // Without text the time sits under the file, inside its width: the bubble is as wide as the file.
                        VStack(alignment: .trailing, spacing: NookTheme.Spacing.xs) {
                            media(attachment)
                            if showsStamp { stamp }
                        }
                    }
                } else {
                    media(attachment)
                }
            }
            if let call = bubble.call {
                // A call its app noted: what kind, who rang and how long, with the time beside it.
                HStack(alignment: .bottom, spacing: NookTheme.Spacing.md) {
                    ChatCallRow(call: call, fromMe: bubble.fromMe)
                    if showsStamp { stamp }
                }
            } else if !bubble.text.isEmpty {
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
                    if showsStamp { stamp }
                }
            }
            // A link shows what it leads to: the picture, video or sound itself, else the page's card.
            if bubble.attachment == nil, bubble.poll == nil, bubble.call == nil, let link = ChatFormat.firstLink(bubble.text) {
                ChatLinkPreview(url: link, fromMe: bubble.fromMe)
                    .padding(.top, NookTheme.Spacing.xxs)
            }
            if bubble.text.isEmpty, bubble.attachment == nil {
                // A poll or an empty message: the time under it, on the right.
                stamp.frame(maxWidth: bubble.poll == nil ? nil : CGFloat.infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, mediaOnly ? 0 : (bare ? NookTheme.Spacing.xs : NookTheme.Spacing.md + NookTheme.Spacing.xxs))
        .padding(.vertical, mediaOnly ? 0 : (bare ? NookTheme.Spacing.xxs : NookTheme.Spacing.sm))
        // Room for the tail on its side, on every bubble of the run, so their edges line up.
        .padding(bubble.fromMe ? .trailing : .leading, bare ? 0 : ChatBubbleShape.tail)
        .background(ChatBubbleShape(mine: bubble.fromMe, tailed: first, joinsBelow: !last)
            .fill(bare ? Color.clear : (bubble.fromMe ? NookTheme.chatMine : NookTheme.chatTheirs)))
    }
}

/// The small chevron in a message's top corner while the pointer is on it: its menu answers, copies, changes or deletes
/// the message and shows its info (who has it, who read it), as far as the chat's app lets Nook. The same for every app.
private struct MessageMenuButton: View {
    let bubble: ChatBubble
    let onReply: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onInfo: (() -> Void)?
    let onCopyChat: () -> Void
    /// On a photo, a sticker or an emoji (no bubble): a dark disc, so it reads on any picture.
    let onPicture: Bool
    @State private var hovering = false

    /// The bubble's own color under the chevron, so it covers the text beneath it cleanly.
    @ViewBuilder
    private var disc: some View {
        if onPicture {
            Circle().fill(NookTheme.ink.opacity(hovering ? 0.7 : 0.5))
        } else if bubble.fromMe {
            // The bubble's own color, a shade lighter under the pointer: it sits on the bubble's corner.
            ZStack {
                Circle().fill(NookTheme.chatMine)
                Circle().fill(NookTheme.paper.opacity(hovering ? 0.12 : 0))
            }
        } else {
            ZStack {
                Circle().fill(NookTheme.chatTheirs)
                Circle().fill(NookTheme.paper.opacity(hovering ? 0.1 : 0))
            }
        }
    }

    var body: some View {
        Menu {
            if let onReply {
                Button { onReply() } label: { Label(tr("chat.reply"), systemImage: "arrowshape.turn.up.left") }
            }
            if !bubble.copyText.isEmpty {
                Button { Pasteboard.copy(bubble.copyText) } label: { Label(tr("whatsapp.copy.message"), systemImage: "doc.on.doc") }
            }
            if let onEdit {
                Button { onEdit() } label: { Label(tr("chat.edit"), systemImage: "pencil") }
            }
            if let onInfo {
                Button { onInfo() } label: { Label(tr("chat.info.title"), systemImage: "info.circle") }
            }
            Button { onCopyChat() } label: { Label(tr("whatsapp.copy.chat"), systemImage: "text.bubble") }
            if let onDelete {
                Divider()
                Button(role: .destructive) { onDelete() } label: { Label(tr("chat.deleteMessage"), systemImage: "trash") }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(NookTheme.font(9, .bold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                .frame(width: 18, height: 18)
                .background(disc)
                .contentShape(Circle())
        }
        .composerMenu()
        .onHover { hovering = $0 }
        .help(tr("chat.moreActions"))
        .accessibilityLabel(tr("chat.moreActions"))
    }
}

/// Where what was new when the chat opened starts: a hairline on either side of "New messages".
private struct ChatNewDivider: View {
    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookDivider(tint: NookTheme.amber.opacity(0.35))
            Text(tr("chat.newMessages"))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.amber)
                .fixedSize()
            NookDivider(tint: NookTheme.amber.opacity(0.35))
        }
        .padding(.vertical, NookTheme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Back to the newest message, while you read further up: a round arrow, with how many came in meanwhile.
private struct ChatJumpButton: View {
    let missed: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering ? NookTheme.rowSelected : NookTheme.smoke))
                .overlay(Circle().strokeBorder(NookTheme.separator, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if missed > 0 {
                        NookCountBadge(count: missed)
                            .background(Capsule().fill(NookTheme.canvas))
                            .offset(x: NookTheme.Spacing.xs, y: -NookTheme.Spacing.xs)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("chat.jumpToNewest"))
        .accessibilityLabel(tr("chat.jumpToNewest"))
    }
}

/// Its content as wide as it wants to be, but never wider than `maximum`: unlike a frame with a largest width, a short
/// bubble keeps its own width, so the buttons beside it stay right next to it.
private struct CappedWidth: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = proposal.width.map { min($0, maximum) } ?? maximum
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Someone typing, under the chat's last message as WhatsApp shows it: three dots that come and go, and who it is.
struct ChatTypingBubble: View {
    static let id = "\u{1}typing"
    let text: String

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            ChatTypingDots()
            Text(text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .padding(.leading, ChatBubbleShape.tail)
        .background(ChatBubbleShape(mine: false, tailed: true).fill(NookTheme.chatTheirs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Three dots that light up one after the other while someone types.
struct ChatTypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: NookTheme.Spacing.xxs) {
                ForEach(0..<3, id: \.self) { dot in
                    Circle()
                        .fill(NookTheme.textSecondary)
                        .frame(width: 5, height: 5)
                        .opacity(dot == step ? 1 : 0.35)
                }
            }
            .animation(NookTheme.hover, value: step)
        }
        .accessibilityHidden(true)
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
    /// Who reacted is open under the emoji.
    @State private var showingPeople = false

    var body: some View {
        // A click shows who put which emoji there, as the chat apps do; there yours can be taken back or another added.
        Button { showingPeople = true } label: {
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(reactions) { reaction in chip(reaction) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(Self.summary(reactions))
        .accessibilityLabel(Self.summary(reactions))
        .popover(isPresented: $showingPeople, arrowEdge: .bottom) {
            ReactionPeopleView(reactions: reactions, onReact: onReact.map { react in
                { emoji in showingPeople = false; react(emoji) }
            })
        }
    }

    private func chip(_ reaction: BubbleReaction) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            Text(reaction.emoji).font(NookTheme.font(15))
            if reaction.count > 1 {
                Text("\(reaction.count)")
                    .font(NookTheme.TextStyle.label)
                    .monospacedDigit()
                    .foregroundStyle(reaction.mine ? NookTheme.mint : NookTheme.textStrong)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.xxs)
        // An edge of its own, so it reads on the chat beside any bubble; yours in mint.
        .background(Capsule().fill(reaction.mine ? NookTheme.mint.opacity(0.22) : NookTheme.smoke))
        .overlay(Capsule().strokeBorder(reaction.mine ? NookTheme.mint.opacity(0.45) : NookTheme.separator, lineWidth: 1))
    }

    /// Who put each emoji there, in one line for the tooltip: "👍 Anna, You · ❤️ Jan".
    static func summary(_ reactions: [BubbleReaction]) -> String {
        reactions.map { reaction in
            let names = ReactionPeopleView.names(reaction)
            return names.isEmpty ? "\(reaction.emoji) \(reaction.count)" : "\(reaction.emoji) " + names.joined(separator: ", ")
        }.joined(separator: " · ")
    }
}

/// Who reacted to a message, the same for every chat app: one row per person with their emoji, you first, and the
/// people the app does not name counted ("2 others"). Where the chat can be answered, your row takes your emoji back and
/// another's adds the same one from you.
private struct ReactionPeopleView: View {
    let reactions: [BubbleReaction]
    let onReact: ((String) -> Void)?

    /// The names on one emoji, you first; people the app counted but did not name are left out here.
    static func names(_ reaction: BubbleReaction) -> [String] {
        (reaction.mine ? [tr("chat.you")] : []) + reaction.people
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let emoji: String
        let mine: Bool
    }

    private var rows: [Row] {
        var rows: [Row] = []
        for reaction in reactions {
            if reaction.mine { rows.append(Row(id: "me" + reaction.emoji, name: tr("chat.you"), emoji: reaction.emoji, mine: true)) }
            for (index, person) in reaction.people.enumerated() {
                rows.append(Row(id: "\(reaction.emoji)\(index)\(person)", name: person, emoji: reaction.emoji, mine: false))
            }
            let unnamed = reaction.count - reaction.people.count - (reaction.mine ? 1 : 0)
            if unnamed > 0 {
                rows.append(Row(id: "rest" + reaction.emoji, name: tr("chat.reactions.others", unnamed), emoji: reaction.emoji, mine: false))
            }
        }
        return rows.sorted { $0.mine && !$1.mine }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("chat.reactions.title"))
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.top, NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.xs)
            ForEach(rows) { row in
                HStack(spacing: NookTheme.Spacing.md) {
                    ChatPersonBadge(name: row.name, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        if row.mine, onReact != nil {
                            Text(tr("chat.react.takeBack"))
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                    Spacer(minLength: NookTheme.Spacing.lg)
                    Text(row.emoji).font(NookTheme.font(18))
                }
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.sm)
                .contentShape(Rectangle())
                .onTapGesture { if row.mine { onReact?(row.emoji) } }
                .accessibilityElement(children: .combine)
            }
            if let onReact {
                NookDivider()
                    .padding(.top, NookTheme.Spacing.xs)
                // Add one of the emoji already there, from you too.
                HStack(spacing: NookTheme.Spacing.xs) {
                    ForEach(reactions.filter { !$0.mine }) { reaction in
                        Button { onReact(reaction.emoji) } label: {
                            Text(reaction.emoji).font(NookTheme.font(16))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(NookTheme.smoke))
                        }
                        .buttonStyle(.plain)
                        .help(tr("chat.react"))
                    }
                }
                .padding(NookTheme.Spacing.md)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
        .padding(.bottom, NookTheme.Spacing.xs)
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

/// Your own message's ticks after its time, as WhatsApp draws them, in every chat app that says how far a message got:
/// a clock while it goes out, one grey tick on the server, two on their phone, two blue ones once read, a red mark when
/// it could not be sent. Also in front of a chat's newest message in the Chats tab's list, when that message is yours.
/// In a group whose app says it per person, a click on them opens `MessageInfoView`.
struct TicksView: View {
    let ticks: BubbleTicks

    var body: some View {
        Group {
            switch ticks {
            case .pending:
                Image(systemName: "clock").font(NookTheme.font(10.5, .semibold))
            case .sent:
                check
            case .delivered, .read:
                // The second tick overlaps the first, as on the phone.
                ZStack(alignment: .leading) {
                    check
                    check.padding(.leading, 5)
                }
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(NookTheme.font(11.5, .semibold))
            }
        }
        .foregroundStyle(color)
        .help(tr(label))
        .accessibilityElement()
        .accessibilityLabel(tr(label))
    }

    private var check: some View {
        Image(systemName: "checkmark").font(NookTheme.font(10.5, .bold))
    }

    private var color: Color {
        switch ticks {
        case .read: return NookTheme.blue
        case .failed: return NookTheme.coral
        // Grey that still reads on your mint bubble; read is blue, as on the phone.
        case .pending, .sent, .delivered: return NookTheme.chatStamp
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
struct VideoTile: View {
    let url: URL
    let poster: NSImage?
    let name: String
    @State private var player: AVPlayer?
    @State private var hovering = false
    /// A frame of the video itself, when its app sent no picture of it: never a black box.
    @State private var still: ChatVideoStills.Still?

    private var picture: NSImage? { poster ?? still?.image }

    private var size: CGSize {
        guard let poster = picture, poster.size.width > 0, poster.size.height > 0 else {
            return CGSize(width: PhotoButton.maxWidth, height: PhotoButton.maxWidth * 9 / 16)
        }
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
                        if let poster = picture {
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
        .overlay(alignment: .bottomLeading) {
            // How long it lasts, on the picture, as a chat app shows it.
            if player == nil, let seconds = still?.seconds, seconds > 0 {
                Text(ChatAudioPlayer.clock(seconds))
                    .font(NookTheme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    .background(Capsule().fill(NookTheme.ink.opacity(0.6)))
                    .padding(NookTheme.Spacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
        .onHover { hovering = $0 }
        .onDisappear { player?.pause() }
        .task(id: url) { still = await ChatVideoStills.still(url) }
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
        VideoWindow.shared.show(url, title: name, at: time, aspect: picture?.size)
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
/// A photo that was not readable yet when its bubble was made (its app was still writing it, or fetching it): read
/// again in the background, a few times over a while, with a quiet placeholder meanwhile; then shown as any photo. One
/// that never becomes readable shows as a file that opens in its app.
struct ChatPhotoLoader: View {
    let url: URL
    let name: String
    let onZoom: () -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var failed = false

    private static let tries = 12
    private static let pause: Duration = .seconds(2)

    var body: some View {
        Group {
            if let image {
                PhotoButton(image: image, name: name, action: onZoom)
            } else if failed {
                AttachmentButton(name: name, file: url, action: onOpen)
            } else {
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .fill(NookTheme.ink.opacity(0.3))
                    .frame(width: PhotoButton.maxWidth, height: PhotoButton.maxHeight * 0.75)
                    .overlay {
                        Image(systemName: "photo")
                            .font(NookTheme.font(22))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    .accessibilityLabel(name)
            }
        }
        .task(id: url) {
            for attempt in 0..<Self.tries {
                let url = url
                if let loaded = await Task.detached(priority: .utility, operation: { ChatMediaImages.image(url) }).value {
                    image = loaded
                    return
                }
                if attempt < Self.tries - 1 { try? await Task.sleep(for: Self.pause) }
                if Task.isCancelled { return }
            }
            failed = true
        }
    }
}

struct PhotoButton: View {
    static let maxWidth: CGFloat = 300
    static let maxHeight: CGFloat = 260

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

/// A file in a chat bubble: its first page (else its kind's icon), its name and kind, and a click shows it.
struct AttachmentButton: View {
    let name: String
    var preview: NSImage? = nil
    /// The file on this Mac, once Nook has it: its size shows beside its kind.
    var file: URL? = nil
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
                    // The icon macOS gives this kind of file (a PDF, a spreadsheet, a zip), as Finder shows it.
                    Image(nsImage: Self.icon(for: name))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(name)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if let kind = Self.detail(of: name, file: file) {
                        Text(kind)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: NookTheme.Spacing.sm)
            }
            .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.ink.opacity(hovering ? 0.32 : 0.22)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("card.attachment.view"))
        .accessibilityLabel("\(tr("card.attachment.view")): \(name)")
    }

    /// The icon for a file of this name's kind, made once per kind.
    private static var icons: [String: NSImage] = [:]

    private static func icon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let known = icons[ext] { return known }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        icons[ext] = icon
        return icon
    }

    /// Its size and kind, as a chat app shows them under a file's name ("233 kB · pdf"); only the kind ("PDF document")
    /// while the file is not on this Mac, nil for a name without an extension and no file.
    private static func detail(of name: String, file: URL?) -> String? {
        let ext = (name as NSString).pathExtension
        if let file, let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return ext.isEmpty ? size : "\(size) · \(ext.lowercased())"
        }
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }
}

/// Where the chat is scrolled to, and how big it and its messages are: enough to tell your own scrolling apart from
/// the chat growing.
private struct TranscriptScrollGeometry: Equatable {
    var offset: Double
    var container: Double
    var content: Double

    var nearTop: Bool { offset <= 80 }
    /// The newest message is in view, give or take a line.
    var nearBottom: Bool { content <= container || offset + container >= content - 60 }
}

/// A chat app's message bubble: a rounded box with, on the first message of a run, a small tail at its top corner
/// pointing at who wrote it, as the chat apps draw them. The messages of one run stack into one block: where two of
/// them meet, the corners on the writer's side, where their edges line up, are only slightly round (`Radius.chatJoin`);
/// the other side, where bubbles of different widths end, stays fully round, so no corner sticks out. The tail sits in `tail` points of room on that side, which every
/// bubble keeps so a run's edges line up.
struct ChatBubbleShape: Shape {
    let mine: Bool
    /// The first message of a run: the tail, and a square top corner on the writer's side.
    let tailed: Bool
    /// Another message of the same run follows: its bottom edge meets it.
    var joinsBelow = false
    /// It follows another message of the same run (any but the first): its top edge meets it.
    var joinsAbove: Bool { !tailed }
    static let tail: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let radius = NookTheme.Radius.chatBubble
        let joined = NookTheme.Radius.chatJoin
        let body = CGRect(x: mine ? rect.minX : rect.minX + Self.tail, y: rect.minY,
                          width: max(0, rect.width - Self.tail), height: rect.height)
        // The writer's side: square under the tail, slightly round where it meets the message above or below. The far side
        // stays round: bubbles of a run differ in width there.
        let top: CGFloat = tailed ? 0 : (joinsAbove ? joined : radius)
        let bottom: CGFloat = joinsBelow ? joined : radius
        var path = Path(roundedRect: body, cornerRadii: RectangleCornerRadii(
            topLeading: mine ? radius : top, bottomLeading: mine ? radius : bottom,
            bottomTrailing: mine ? bottom : radius, topTrailing: mine ? top : radius), style: .continuous)
        guard tailed else { return path }
        let edge = mine ? body.maxX : body.minX
        let tip = mine ? rect.maxX : rect.minX
        let depth = min(Self.tail * 1.6, body.height)
        var tailPath = Path()
        tailPath.move(to: CGPoint(x: edge, y: body.minY))
        tailPath.addLine(to: CGPoint(x: tip - (mine ? 1 : -1), y: body.minY))
        tailPath.addQuadCurve(to: CGPoint(x: tip - (mine ? 2 : -2), y: body.minY + 2), control: CGPoint(x: tip, y: body.minY))
        tailPath.addLine(to: CGPoint(x: edge, y: body.minY + depth))
        tailPath.closeSubpath()
        path.addPath(tailPath)
        return path
    }
}
