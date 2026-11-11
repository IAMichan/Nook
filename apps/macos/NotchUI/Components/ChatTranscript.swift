import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// A conversation as bubbles, oldest at the top: theirs on the left, yours on the right, the way a chat app shows it.
/// A line marks where a new day starts; messages one person sends in a row sit close together under their name (each
/// person in a group in a color of their own); links open; a message of only emoji shows large; a long message folds
/// open with "Read more". More than fits scrolls back through the history, starting at the newest message. Each
/// message's text can be selected, and a drag from one message to others picks them all to ask Nook about
/// (`TranscriptSelection`); right-click a bubble for the same menu its chevron opens. A message that answers another
/// quotes it at its top, and the emoji people put on it sit under it. Where the chat can be answered, the pointer on a
/// bubble shows a button to answer that message and one to react with an emoji. Used by the chat card in the notch and
/// by the Chats tab.
struct ChatTranscript: View, Equatable {
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
    /// Sending a message on to other chats. Nil where the host has no chats to send it to: no "Forward".
    var onForward: ((ChatBubble) -> Void)? = nil
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
    /// The oldest message drawn once you scrolled (nil: the newest `page`), or every message once older ones were
    /// fetched. A chat opens with only its newest messages laid out, so opening or switching chats stays quick however
    /// long the chat is; scrolling back to the top draws the ones before them.
    @State private var drawnFrom: String?
    @State private var drawsAll = false
    /// The oldest message before the app sent older ones: once they are in, the next page above it is drawn.
    @State private var olderAnchor: String?
    /// Older messages were just drawn above and the chat is being put back where you were: reaching the top again in
    /// the same moment does not draw another page at once.
    @State private var drawingOlder = false
    /// The day lines and runs of what is drawn, worked out again only when the messages change.
    @State private var timeline = TranscriptTimelineMemo()
    /// Your fingers or the wheel move the chat (or it still glides from that): nothing else moves it meanwhile.
    /// Read only by the handlers: as state, each start and stop of a scroll drew every message again.
    @State private var interacting = Unobserved(false)
    /// When this chat was opened: what comes in the first moments (its newest messages, its pictures) is simply there,
    /// without the chat sliding past everything to reach it.
    @State private var openedAt = Date()
    /// Where the messages are and which ones a drag picked, for asking Nook about them (`TranscriptSelection`).
    @StateObject private var selection = TranscriptSelection()

    /// The end of the chat, under its last message and whoever is typing: where the chat stays while you are there.
    private static let bottomID = "\u{1}bottom"
    /// How long after opening a chat what comes in does not glide in.
    private static let settling: TimeInterval = 2

    /// How many messages a chat lays out when it opens: a little more than the tallest window shows, so the chat is
    /// built in the frame it opens in. Scrolling up draws the ones before them (`olderPage`).
    static let page = 30
    /// How many more it lays out each time you reach the top: a small step, so reaching the top never stalls the chat.
    static let olderPage = 30

    /// Drawn again only when what it shows changed: the chat around it redraws for every key you type in its field.
    /// The actions only count by whether they are there: they do the same for the same messages.
    static func == (a: ChatTranscript, b: ChatTranscript) -> Bool {
        a.bubbles == b.bubbles && a.contact == b.contact && a.fills == b.fills && a.typing == b.typing
            && a.newFrom == b.newFrom && (a.onReply == nil) == (b.onReply == nil) && (a.onReact == nil) == (b.onReact == nil)
            && (a.onEdit == nil) == (b.onEdit == nil) && (a.onDelete == nil) == (b.onDelete == nil)
            && (a.onVote == nil) == (b.onVote == nil) && (a.onLoadOlder == nil) == (b.onLoadOlder == nil)
            && (a.onForward == nil) == (b.onForward == nil)
    }

    /// The messages laid out: the newest `page` (from the first new one, when that is further back), or from `drawnFrom`.
    /// A card, which does not scroll back, draws them all.
    private var drawn: [ChatBubble] {
        guard fills, !drawsAll else { return bubbles }
        if let drawnFrom, let index = bubbles.firstIndex(where: { $0.id == drawnFrom }) { return Array(bubbles[index...]) }
        var start = max(bubbles.count - Self.page, 0)
        if let newFrom, let index = bubbles.firstIndex(where: { $0.id == newFrom }) { start = min(start, max(index - 3, 0)) }
        return start == 0 ? bubbles : Array(bubbles[start...])
    }

    /// You moved the chat: what is drawn stays put from now on, so a new message does not push the oldest one out above
    /// what you read.
    private func userScrolled() {
        // Called on every step of scrolling up: state is written only when it changes, so scrolling redraws nothing.
        if !scrolledByUser { scrolledByUser = true }
        if drawnFrom == nil, !drawsAll, fills { drawnFrom = drawn.first?.id }
    }

    /// Draws the `page` messages before the oldest drawn one, keeping that one where it was. False when all are drawn.
    /// `toEnd`: the chat did not fill its room yet, so it stays at its newest message instead of on the old top one.
    private func drawOlder(_ proxy: ScrollViewProxy, toEnd: Bool = false) -> Bool {
        let shown = drawn
        guard shown.count < bubbles.count, let top = shown.first?.id,
              let index = bubbles.firstIndex(where: { $0.id == top }) else { return false }
        drawnFrom = bubbles[max(index - Self.olderPage, 0)].id
        drawingOlder = true
        DispatchQueue.main.async {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                if toEnd { proxy.scrollTo(Self.bottomID, anchor: .bottom) } else { proxy.scrollTo(top, anchor: .top) }
            }
            drawingOlder = false
        }
        return true
    }

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
                    if onLoadOlder != nil || drawn.count < bubbles.count {
                        loadOlderButton { loadOlder(proxy) }
                    }
                    stack
                    Color.clear
                        .frame(height: 0)
                        .id(Self.bottomID)
                }
            }
            .scrollIndicators(.never)
            // The messages stay inside the transcript: unclipped, a bubble scrolled past the top was drawn over the
            // chat's header above it.
            .clipped()
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // A chat shorter than its room sits at the bottom, over the field, as in a chat app: not at the top with
            // empty space under it.
            .defaultScrollAnchor(.bottom, for: .alignment)
            // At the newest message a chat that grows keeps its bottom where it is; reading back, a picture that
            // loads below (or a link's card) leaves what you read where it is.
            .defaultScrollAnchor(atBottom ? .bottom : nil, for: .sizeChanges)
            .overlay(alignment: .bottomTrailing) {
                // The button's own animation: on the scroll view it animated whatever else changed in that moment.
                ZStack {
                    if !atBottom, let last = bubbles.last?.id {
                        ChatJumpButton(missed: missed) {
                            withAnimation(NookTheme.scroll) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                        .padding(NookTheme.Spacing.md)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(NookTheme.reveal, value: atBottom)
            }
            // Scrolling up to the top loads the older messages by itself; the button stays for a click. Moving up while
            // the sizes stay the same can only be you (loading and new messages change the size), so a mouse wheel,
            // which reports no scroll phase, counts as well as the trackpad.
            .onScrollGeometryChange(for: TranscriptScrollGeometry.self) { geometry in
                TranscriptScrollGeometry(offset: geometry.contentOffset.y,
                                         container: geometry.containerSize.height,
                                         content: geometry.contentSize.height)
            } action: { old, new in
                // The chat grew while you were at its newest message (pictures appearing, a chat's history or a new
                // message arriving), or its room shrank (the field grows with a longer message): it stays at the newest
                // at once, so the messages move up with the field instead of slipping under it. `atBottom` counts as
                // well as where the last frame was: in the first layouts of a chat that just opened (its history and
                // its read mark coming in together) that frame may not have reached the bottom yet, and the chat then
                // stayed up in its history.
                if new.content != old.content || new.container != old.container, old.nearBottom || atBottom, !interacting.value,
                   !loadingOlder, !drawingOlder {
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    return
                }
                if new.offset < old.offset - 0.5, new.content == old.content, new.container == old.container {
                    userScrolled()
                }
                if new.nearTop, scrolledByUser { loadOlder(proxy, automatic: true) }
                // Too few messages to scroll: there is no top to reach, so the older ones come in until the chat fills
                // its room (or its start is there).
                if fills, !scrolledByUser, new.container > 0, new.content < new.container - 1 {
                    loadOlder(proxy, automatic: true, toEnd: true)
                }
                // Only you scroll away from the newest message: a message that came in and made the chat taller is
                // not you reading back, so it does not stop the chat from following it down.
                let moved = new.content == old.content && new.container == old.container
                if new.nearBottom, !atBottom {
                    atBottom = true
                    missed = 0
                } else if !new.nearBottom, atBottom, moved {
                    atBottom = false
                }
            }
            .onScrollPhaseChange { _, phase in
                let moving = phase == .interacting || phase == .decelerating
                interacting.value = moving
                if phase == .interacting || phase == .decelerating, !scrolledByUser { userScrolled() }
            }
            .onChange(of: bubbles.last?.id) { previous, last in
                guard let last else { return }
                // A new message (or one you just sent) glides into view. Another chat, or a chat's history arriving
                // at once, is not a new message: it is simply there, at its newest, without scrolling past everything.
                let arrived = previous.map { old in bubbles.suffix(4).contains { $0.id == old } } ?? false
                // Just opened: the newest messages its app sends now are part of opening it, not news to glide to.
                let settling = !scrolledByUser && Date().timeIntervalSince(openedAt) < Self.settling
                // Reading back, several messages at once (a bridge's read, an answer of yours replaced by the app's own,
                // a message hidden) are no reason to pull you down either: only a chat still opening jumps to its newest.
                if !arrived, scrolledByUser, !atBottom {
                    if let newest = bubbles.last, !newest.fromMe, newest.notice == nil { missed += 1 }
                    return
                }
                if arrived, !settling {
                    // Reading back: the chat stays where you are, and the button counts what came in. Your own
                    // message always brings you down to it.
                    guard atBottom || bubbles.last?.fromMe == true else {
                        missed += 1
                        return
                    }
                    // Once the new message is laid out: scrolled to in the same update, it is not there yet and the
                    // chat stays where it was.
                    DispatchQueue.main.async {
                        withAnimation(NookTheme.scroll) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                } else {
                    var jump = Transaction()
                    jump.disablesAnimations = true
                    withTransaction(jump) { proxy.scrollTo(last, anchor: .bottom) }
                    DispatchQueue.main.async { withTransaction(jump) { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            // A chat opens at its newest message, also when its first layout took more than one pass.
            .onAppear {
                guard fills else { return }
                var jump = Transaction()
                jump.disablesAnimations = true
                DispatchQueue.main.async { withTransaction(jump) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            // Older messages from the app are in: the page above what was the oldest is drawn, and it stays in its place.
            .onChange(of: bubbles.first?.id) { _, _ in
                guard let anchor = olderAnchor, let index = bubbles.firstIndex(where: { $0.id == anchor }) else { return }
                olderAnchor = nil
                drawnFrom = bubbles[max(index - Self.olderPage, 0)].id
                var still = Transaction()
                still.disablesAnimations = true
                DispatchQueue.main.async { withTransaction(still) { proxy.scrollTo(anchor, anchor: .top) } }
            }
            // Someone starts typing: their bubble comes into view under the last message.
            .onChange(of: typing != nil) { _, shown in
                // Only while you are at the newest message: reading back, someone typing does not pull you down.
                guard shown, atBottom, !interacting.value else { return }
                withAnimation(NookTheme.scroll) { proxy.scrollTo(ChatTypingBubble.id, anchor: .bottom) }
            }
            // Another chat starts at its newest message again: reaching its top counts only once you scroll there. The
            // Chats tab makes a new transcript for each chat, so a change of the name there is the same chat renamed
            // (a contact's name came in), which keeps where you are.
            .onChange(of: contact) {
                guard !fills else { return }
                openedAt = Date()
                interacting.value = false
                scrolledByUser = false
                reachedStart = false
                atBottom = true
                missed = 0
                drawnFrom = nil
                drawsAll = false
            }
        }
    }

    /// Loads the older messages once at a time; the message that was on top stays where it was, with the older ones
    /// above it.
    /// `toEnd`: loaded to fill a chat too short to scroll, which stays at its newest message.
    private func loadOlder(_ proxy: ScrollViewProxy, automatic: Bool = false, toEnd: Bool = false) {
        guard !loadingOlder, !drawingOlder else { return }
        // What this Mac already has is drawn first; only then is the chat's app asked for more.
        if drawOlder(proxy, toEnd: toEnd) { return }
        guard let onLoadOlder, !(automatic && reachedStart) else { return }
        loadingOlder = true
        let anchor = bubbles.first?.id
        // Drawn a page at a time from here, as the rest of the chat is: drawing every message at once made a long chat
        // slow to scroll after its first fetch. Set before asking, so the messages are drawn as soon as they are in.
        if fills, !toEnd { olderAnchor = anchor }
        Task { @MainActor in
            let loaded = await onLoadOlder()
            if loaded {
                // A host that draws every message (a card) draws these too.
                if !fills || anchor == nil { drawsAll = true }
                if toEnd {
                    // Every message: all were drawn and short, and drawn from the old top the fetched ones stayed out.
                    drawnFrom = bubbles.first?.id
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                } else if let anchor {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            } else {
                olderAnchor = nil
            }
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

    private func entries(_ bubbles: [ChatBubble]) -> [ChatTimeline.Entry] {
        // A change in who is in the group stands on its own: the messages around it are runs of their own.
        let items = bubbles.map { bubble in
            ChatTimeline.Item(id: bubble.id, author: bubble.notice != nil ? "\u{2}" + bubble.id : (bubble.fromMe ? "\u{1}me" : bubble.sender),
                              date: bubble.date)
        }
        return timeline.entries(items, language: I18n.shared.currentLanguage)
    }

    private var stack: some View {
        let shown = drawn
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = entries(shown).map { Row(id: ChatTimeline.id(of: $0), entry: $0) }
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
                    if let bubble = byID[row.id], let notice = bubble.notice {
                        ChatNoticeLine(text: notice, time: bubble.time)
                            .padding(.vertical, NookTheme.Spacing.md)
                            .id(bubble.id)
                    } else if let bubble = byID[row.id] {
                        ChatBubbleView(bubble: bubble, first: first, last: last, newest: bubble.id == bubbles.last?.id,
                                       onOpen: { onOpen(bubble) }, onZoom: { onZoom(bubble) },
                                       onReply: replyAction(bubble), onReact: reactAction(bubble),
                                       onEdit: editAction(bubble), onDelete: deleteAction(bubble),
                                       onForward: forwardAction(bubble),
                                       onCopyChat: { Pasteboard.copy(ChatBubble.transcript(bubbles, contact: contact)) },
                                       onVote: voteAction(bubble))
                            .equatable()
                            .background(TranscriptPickMark(selection: selection, id: bubble.id))
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptSelection.space)) } action: {
                                selection.place(bubble.id, at: $0)
                            }
                            .onDisappear { selection.place(bubble.id, at: nil) }
                            // A new run starts with room above it; the messages of one run sit close together, so who
                            // said what reads at a glance.
                            .padding(.top, row.id == top ? 0 : (first ? NookTheme.Spacing.lg : NookTheme.Spacing.xxs))
                            .id(bubble.id)
                    }
                }
            }
            // The typing line animates on its own: on the whole chat it animated every bubble that came in with it.
            VStack(spacing: 0) {
                if let typing {
                    ChatTypingBubble(text: typing)
                        .padding(.top, rows.isEmpty ? 0 : NookTheme.Spacing.md)
                        .id(ChatTypingBubble.id)
                        .transition(.opacity)
                }
            }
            .animation(NookTheme.reveal, value: typing)
        }
        .frame(maxWidth: .infinity)
        .coordinateSpace(.named(TranscriptSelection.space))
        .background(TranscriptSelectionAnchor(selection: selection, bubbles: bubbles, contact: contact))
    }

    // A message still on its way (`ChatBubble.local`) has nothing to answer, react to, change or delete yet.

    private func replyAction(_ bubble: ChatBubble) -> (() -> Void)? {
        guard let onReply, !bubble.local, !bubble.deleted else { return nil }
        return { onReply(bubble) }
    }

    private func voteAction(_ bubble: ChatBubble) -> (([String]) -> Void)? {
        guard let onVote, bubble.poll != nil, !bubble.local, !bubble.deleted else { return nil }
        return { onVote(bubble, $0) }
    }

    /// Deleting a message: the host asks how (for you, or for everyone where it is yours and its app takes that).
    private func deleteAction(_ bubble: ChatBubble) -> (() -> Void)? {
        guard let onDelete, !bubble.local else { return nil }
        return { onDelete(bubble) }
    }

    /// Sending the message on to other chats: a message that has arrived, not a poll or a call (those belong to their chat).
    private func forwardAction(_ bubble: ChatBubble) -> (() -> Void)? {
        guard let onForward, !bubble.local, !bubble.deleted, bubble.poll == nil, bubble.call == nil else { return nil }
        return { onForward(bubble) }
    }

    /// Changing your own message's text, where its app takes that: in the message's menu.
    private func editAction(_ bubble: ChatBubble) -> (() -> Void)? {
        guard let onEdit, bubble.fromMe, !bubble.local, !bubble.deleted, !bubble.text.isEmpty, bubble.poll == nil, bubble.call == nil else { return nil }
        return { onEdit(bubble) }
    }

    private func reactAction(_ bubble: ChatBubble) -> ((String) -> Void)? {
        guard let onReact, !bubble.local, !bubble.deleted else { return nil }
        return { onReact(bubble, $0) }
    }

    private struct Row: Identifiable {
        let id: String
        let entry: ChatTimeline.Entry
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
    let onForward: (() -> Void)?
    let onCopyChat: () -> Void
    let onVote: (([String]) -> Void)?
    @State private var expanded = false
    @State private var hovering = false
    /// The emoji to react with are open beside the bubble.
    @State private var picking = false
    /// Your message's info (who read it, who has it) is open over its ticks.
    @State private var showingInfo = false
    /// The bubble is in view or close to it: only then does its media load, play or move (`chatMediaLive`).
    @State private var near = false
    /// The pointer came onto the bubble since it came near view: only then are its menu button and its react and reply
    /// buttons made. Built for every message, hidden, each one's AppKit menu, popovers and tooltips were moved along
    /// with every step of scrolling. Kept once made, so a menu or picker that took the pointer away stays open.
    @State private var armed = false
    @Environment(\.chatFetchFile) private var fetchFile
    /// A document's first page, made once the bubble comes near view.
    @State private var filePreview: NSImage?
    /// Pictures whose app did not hand them over after every ask, by message: the bubble names them instead of keeping
    /// an empty tile, also when it scrolled away and is made again.
    private static var unfetchedPictures: Set<String> = []
    private var pictureNeverCame: Bool { gaveUpOnPicture || Self.unfetchedPictures.contains(bubble.id) }
    @State private var gaveUpOnPicture = false

    /// Lines a long message shows until "Read more".
    private static let foldedLines = 12
    /// The widest a bubble gets: a long message wraps into lines that are easy to read, however wide the chat is.
    static let maxWidth: CGFloat = 560
    /// The sender's face beside a group message.
    static let faceSize: CGFloat = 28

    /// The actions only count by whether they are there: they do the same for the same bubble.
    static func == (a: ChatBubbleView, b: ChatBubbleView) -> Bool {
        a.bubble == b.bubble && a.first == b.first && a.last == b.last && a.newest == b.newest
            && (a.onReply == nil) == (b.onReply == nil) && (a.onReact == nil) == (b.onReact == nil)
            && (a.onEdit == nil) == (b.onEdit == nil) && (a.onDelete == nil) == (b.onDelete == nil)
            && (a.onVote == nil) == (b.onVote == nil) && (a.onForward == nil) == (b.onForward == nil)
    }

    /// What the chevron's menu and a right-click on the bubble offer: one menu, so both always show the same.
    private var menuItems: MessageMenuItems {
        MessageMenuItems(bubble: bubble, onReply: onReply, onReact: onReact, onForward: onForward, onEdit: onEdit,
                         onDelete: onDelete, onInfo: bubble.fromMe && bubble.ticks != nil ? { showingInfo = true } : nil,
                         onCopyChat: onCopyChat)
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
        case .photoComing: return !pictureNeverCame
        case .photo, .video, .gif: return true
        default: return false
        }
    }

    /// The time (and your ticks) on a picture: light on a dark capsule, so it reads on any photo.
    private var mediaStamp: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if bubble.keepsDeleted {
                DeletedMark(color: NookTheme.paper)
            } else if bubble.edited {
                Text(tr("chat.message.edited"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.paper)
            }
            Text(bubble.time)
                .font(NookTheme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(NookTheme.paper)
            if let ticks = bubble.ticks { MessageTicksMark(ticks: ticks) }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.xxs)
        .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.ink.opacity(0.55)))
        .padding(NookTheme.Spacing.sm)
        .allowsHitTesting(false)
    }
    /// Read once per draw (`content`). Bytes first: a text of at most 700 bytes has at most 700 characters, and
    /// counting newline bytes needs no grapheme breaking.
    private var long: Bool {
        let bytes = bubble.text.utf8
        if bytes.count > 700, bubble.text.count > 700 { return true }
        var lines = 0
        for byte in bytes where byte == 0x0A {
            lines += 1
            if lines >= Self.foldedLines { return true }
        }
        return false
    }
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
            if bubble.keepsDeleted {
                DeletedMark(color: NookTheme.chatStamp)
            } else if bubble.edited {
                Text(tr("chat.message.edited"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.chatStamp)
            }
            Text(bubble.time)
                .font(NookTheme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(NookTheme.chatStamp)
            if let ticks = bubble.ticks {
                if bubble.readers.isEmpty {
                    MessageTicksMark(ticks: ticks)
                } else {
                    // In a group: a click on the ticks says who read it, who has it, and who does not yet.
                    Button { showingInfo = true } label: { MessageTicksMark(ticks: ticks) }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help(tr("chat.info.title"))
                        .accessibilityLabel(tr("chat.info.title"))
                }
            }
        }
        .fixedSize()
    }

    /// Room for the time where it falls in the bubble's flow: the stamp itself is drawn over it at the bubble's right
    /// edge (`placedStamp`), so it always sits bottom right, however wide a quote, name or card makes the bubble.
    private var stampSlot: some View {
        stamp.hidden()
            .accessibilityHidden(true)
            .anchorPreference(key: ChatStampSlot.self, value: .bounds) { $0 }
    }

    /// The time on the slot's line, against the bubble's right edge.
    private func placedStamp(_ slot: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            if let slot {
                stamp
                    .padding(.bottom, max(0, proxy.size.height - proxy[slot].maxY))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
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
        case .photoComing:
            if pictureNeverCame {
                AttachmentButton(name: attachment, action: onOpen)
            } else {
                Button(action: onOpen) { ChatPhotoPlaceholder(name: attachment) }
                    .buttonStyle(.plain)
                    .help(tr("card.attachment.view"))
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
            AttachmentButton(name: attachment, preview: bubble.image ?? filePreview, file: bubble.file, action: onOpen)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            if bubble.fromMe { Spacer(minLength: 70) }
            // In a group, who wrote it shows beside each of their messages: their photo from Contacts, else their initials.
            if !bubble.fromMe, !bubble.sender.isEmpty {
                ChatSenderFace(name: bubble.sender, size: Self.faceSize)
            }
            CappedWidth(maximum: Self.maxWidth) {
                VStack(alignment: bubble.fromMe ? .trailing : .leading, spacing: NookTheme.Spacing.xxs) {
                    content
                        // A right-click anywhere on the bubble (not the empty room beside it) opens the chevron's own
                        // menu, also on its selectable text, whose system menu would win from a `.contextMenu`.
                        // Watched while the bubble is in view, so a right-click without moving the mouse first works.
                        // Words selected in the bubble come first in it, as Copy.
                        .onRightClickMenu(enabled: near, copiesSelection: true) { menuItems.entries }
                        .overlay(alignment: .topTrailing) {
                            if armed {
                                MessageMenuButton(bubble: bubble, items: menuItems, onPicture: bare)
                                    .padding(NookTheme.Spacing.xs)
                                    .opacity(hovering ? 1 : 0)
                                    .allowsHitTesting(hovering)
                                    .animation(NookTheme.hover, value: hovering)
                            }
                        }
                        .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                            if let ticks = bubble.ticks { MessageInfoView(ticks: ticks, readers: bubble.readers) }
                        }
                    if !bubble.reactions.isEmpty {
                        // Under the bubble at its leading side, in its own room, so it never covers the message's
                        // text or time and the next message does not run into it.
                        ReactionChips(reactions: bubble.reactions, onReact: onReact)
                            .padding(.leading, NookTheme.Spacing.md)
                    }
                }
            }
            // Beside the bubble, in the room the spacer keeps free, not in its row: the bubble is as wide once it has
            // arrived (and has these) as while it was on its way (without them), so its text does not wrap anew.
            .outside(bubble.fromMe ? .leading : .trailing, spacing: NookTheme.Spacing.sm) { actions }
            if !bubble.fromMe { Spacer(minLength: 70) }
        }
        .onHover { inside in
            hovering = inside
            if inside, !armed {
                OpenMenus.watch()
                armed = true
            }
        }
        // VoiceOver and the keyboard reach the same steps as the menu, the react button and the reply button, also on
        // a bubble the pointer never came onto (its buttons are made only then).
        .accessibilityActions {
            ForEach(Array(menuItems.entries.enumerated()), id: \.offset) { _, entry in
                if let action = entry.action { Button(entry.title, action: action) }
            }
            if onReact != nil {
                Button(tr("chat.react")) {
                    armed = true
                    picking = true
                }
            }
        }
        .environment(\.chatMediaLive, near)
        .chatNearView($near)
        // Far from view again: its buttons go, until the pointer comes back onto it. Not while its menu, its emoji or
        // its info is open: that would take the open menu's button away under it.
        .onChange(of: near) { _, near in
            if !near, armed, !picking, !showingInfo, !OpenMenus.tracking { armed = false }
        }
        // A file the chat names but Nook does not have yet (it came in while the chat was open, or fetching it failed)
        // is asked of its app as the bubble comes into view, and again a few times while it stays there.
        .task(id: near && bubble.file == nil && bubble.attachment != nil ? bubble.id : nil) {
            guard near, bubble.file == nil, bubble.attachment != nil, let fetchFile else { return }
            for wait in [0.0, 2, 6, 15, 30] {
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                await fetchFile(bubble.id)
            }
            // The same for every app: a picture its app cannot give (expired, removed, too large) is named, and opens there.
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, bubble.media == .photoComing {
                Self.unfetchedPictures.insert(bubble.id)
                gaveUpOnPicture = true
            }
        }
        .task(id: near ? bubble.file : nil) {
            guard near, case .file = bubble.media, let file = bubble.file, bubble.image == nil, filePreview == nil else { return }
            filePreview = await ChatFileThumbnails.shared.image(file, kind: .file)
        }
    }

    /// Answer this message and react to it: shown while the pointer is on the bubble, where the chat can be answered.
    @ViewBuilder
    private var actions: some View {
        if armed, onReply != nil || onReact != nil {
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

    /// The link a text message shows a preview of.
    private var link: URL? {
        guard bubble.attachment == nil, bubble.poll == nil, bubble.call == nil else { return nil }
        return ChatFormat.firstLink(bubble.text)
    }

    private var content: some View {
        // Each read once per draw: they are read in several places below.
        let link = self.link
        let long = !bubble.text.isEmpty && self.long
        return VStack(alignment: .leading, spacing: 2) {
            if first, !bubble.sender.isEmpty {
                Text(bubble.sender)
                    .font(NookTheme.TextStyle.label)
                    // Each person in a group writes in a color of their own, the same every time.
                    .foregroundStyle(ChatPersonBadge.tint(for: bubble.sender))
                    .lineLimit(1)
            }
            if bubble.deleted, !bubble.keepsDeleted {
                // Deleted for everyone: where it was, what became of it, with its time beside it.
                HStack(alignment: .lastTextBaseline, spacing: NookTheme.Spacing.md) {
                    Label(bubble.deletedLine, systemImage: "nosign")
                        .font(NookTheme.TextStyle.body.italic())
                        .foregroundStyle(NookTheme.chatStamp)
                    if showsStamp { stampSlot }
                }
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
                            if showsStamp { stampSlot }
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
                    if showsStamp { stampSlot }
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
                    if showsStamp, link == nil { stampSlot }
                }
            }
            // A link shows what it leads to: the picture, video or sound itself, else the page's card, with the time
            // under it.
            if let link {
                ChatLinkPreview(url: link, fromMe: bubble.fromMe)
                    .padding(.top, NookTheme.Spacing.xxs)
                if showsStamp { stampSlot }
            }
            if bubble.text.isEmpty, bubble.attachment == nil, !bubble.deleted || bubble.keepsDeleted {
                // A poll or an empty message: the time under it, on the right.
                stampSlot
            }
        }
        .overlayPreferenceValue(ChatStampSlot.self) { placedStamp($0) }
        .padding(.horizontal, mediaOnly ? 0 : (bare ? NookTheme.Spacing.xs : NookTheme.Spacing.md + NookTheme.Spacing.xxs))
        .padding(.vertical, mediaOnly ? 0 : (bare ? NookTheme.Spacing.xxs : NookTheme.Spacing.sm))
        // Room for the tail on its side, on every bubble of the run, so their edges line up.
        .padding(bubble.fromMe ? .trailing : .leading, bare ? 0 : ChatBubbleShape.tail)
        .background(ChatBubbleShape(mine: bubble.fromMe, tailed: first, joinsBelow: !last)
            .fill(bare ? Color.clear : (bubble.fromMe ? NookTheme.chatMine : NookTheme.chatTheirs)))
    }
}

/// Whether a menu is open anywhere in Nook (a bubble's chevron menu among them): SwiftUI does not say when a `Menu`
/// opens, AppKit does for every menu it tracks.
@MainActor
private enum OpenMenus {
    private(set) static var tracking = false
    private static var observers: [NSObjectProtocol] = []

    /// Starts listening, once.
    static func watch() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { tracking = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { tracking = false }
            },
        ]
    }
}

/// Where a bubble's time falls in its flow, so the time itself can be drawn at the bubble's right edge.
private struct ChatStampSlot: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// "Copy link" and "Copy email address" for each web and mail address in a message, so only that address is copied.
/// With more than one of a kind, each item says which one it copies. Every chat's message menu has them (the bubbles'
/// `MessageMenuItems` and a mail's menu in `MailThreadView`).
enum ChatAddressMenu {
    /// The most addresses a message's menu offers to copy one by one.
    static let limit = 5

    static func entries(for text: String) -> [NookMenuEntry] {
        let addresses = ChatFormat.addresses(text).prefix(limit)
        let links = addresses.filter { $0.kind == .link }.count
        let mails = addresses.count - links
        return addresses.map { address in
            let text = address.text
            let shown = text.count > 40 ? String(text.prefix(39)) + "…" : text
            switch address.kind {
            case .link:
                return NookMenuEntry(title: links > 1 ? tr("chat.copyLinkOf", shown) : tr("link.copy"), symbol: "link",
                                     action: { Pasteboard.copy(text) })
            case .email:
                return NookMenuEntry(title: mails > 1 ? tr("chat.copyEmailOf", shown) : tr("chat.copyEmail"),
                                     symbol: "envelope", action: { Pasteboard.copy(text) })
            }
        }
    }
}

/// What can be done with one message, as far as the chat's app lets Nook: answer, react, forward, copy, change, see
/// its info, copy the chat, delete. The same for every app, and the same in the chevron's menu and on a right-click.
private struct MessageMenuItems: View {
    let bubble: ChatBubble
    let onReply: (() -> Void)?
    let onReact: ((String) -> Void)?
    let onForward: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onInfo: (() -> Void)?
    let onCopyChat: () -> Void

    /// The picture file a bubble shows (a photo, a sticker or a still GIF), for "Copy image"; nil for anything else.
    private var picture: URL? {
        switch bubble.media {
        case .photo(let url), .sticker(let url): return url
        case .gif(let url): return ChatMediaImages.isPicture(url) ? url : nil
        case .file, .photoComing, .video, .audio: return nil
        }
    }

    /// The menu as one list: drawn by the chevron (`body`) and by a right-click (`.onRightClickMenu`).
    var entries: [NookMenuEntry] {
        var entries: [NookMenuEntry] = []
        if let onReply {
            entries.append(NookMenuEntry(title: tr("chat.reply"), symbol: "arrowshape.turn.up.left", action: onReply))
        }
        if let onReact {
            entries.append(NookMenuEntry(title: tr("chat.react"), symbol: "face.smiling",
                                         children: ChatReactions.quick.map { emoji in
                                             NookMenuEntry(title: emoji, action: { onReact(emoji) })
                                         }))
        }
        if let onForward {
            entries.append(NookMenuEntry(title: tr("chat.forward"), symbol: "arrowshape.turn.up.right", action: onForward))
        }
        if !bubble.copyText.isEmpty {
            let text = bubble.copyText
            entries.append(NookMenuEntry(title: tr("whatsapp.copy.message"), symbol: "doc.on.doc",
                                         action: { Pasteboard.copy(text) }))
        }
        entries += ChatAddressMenu.entries(for: bubble.text)
        if let picture {
            let image = bubble.image
            entries.append(NookMenuEntry(title: tr("chat.copyImage"), symbol: "photo.on.rectangle",
                                         action: { Pasteboard.copyImage(picture, fallback: image) }))
        }
        if let onEdit {
            entries.append(NookMenuEntry(title: tr("chat.edit"), symbol: "pencil", action: onEdit))
        }
        if let onInfo {
            entries.append(NookMenuEntry(title: tr("chat.info.title"), symbol: "info.circle", action: onInfo))
        }
        entries.append(NookMenuEntry(title: tr("whatsapp.copy.chat"), symbol: "text.bubble", action: onCopyChat))
        if let onDelete {
            entries.append(NookMenuEntry(title: tr("chat.deleteMessage"), symbol: "trash", destructive: true, separated: true,
                                         action: onDelete))
        }
        return entries
    }

    var body: some View {
        NookMenuItems(entries: entries)
    }
}

/// The small chevron in a message's top corner while the pointer is on it: it opens the message's menu
/// (`MessageMenuItems`), which a right-click on the message opens too.
private struct MessageMenuButton: View {
    let bubble: ChatBubble
    let items: MessageMenuItems
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
            items
        } label: {
            Image(icon: "chevron.down")
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
            Image(icon: "chevron.down")
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering ? NookTheme.rowSelected : NookTheme.smoke))
                .overlay(Circle().strokeBorder(NookTheme.separator, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if missed > 0 {
                        NookCountBadge(count: missed)
                            .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.canvas))
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
        let size = content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        // Never wider than offered: one bubble that cannot shrink must not widen the whole chat past the window's edge.
        return CGSize(width: min(size.width, width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A photo or video at its own size, narrower in a chat narrower than it (its shape kept), so a picture never pushes the
/// chat and its field past the window's edge.
struct FittedMedia: Layout {
    let size: CGSize

    private func fitted(_ proposal: ProposedViewSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let width = min(proposal.width ?? size.width, size.width)
        return CGSize(width: width, height: width * size.height / size.width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { fitted(proposal) }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    /// At `size`, or narrower with its shape kept when the chat is narrower (`FittedMedia`).
    func fittedMedia(_ size: CGSize) -> some View {
        FittedMedia(size: size) { frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}



/// The emoji the reaction buttons offer, as WhatsApp's own quick row.
enum ChatReactions {
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
}

/// The message a bubble answers, at the bubble's top: a bar, who wrote it and the start of its text.
struct QuotedMessage: View {
    let quote: BubbleQuote

    var body: some View {
        ChatQuote(sender: quote.sender, text: quote.text, mine: quote.mine, maxWidth: PhotoButton.maxWidth)
            .accessibilityLabel(tr("chat.quote", quote.sender.isEmpty ? quote.text : "\(quote.sender): \(quote.text)"))
    }
}

/// The emoji on a message as one pill under the bubble: the emoji, the
/// most used first, and how many reacted in all. Tinted when one is yours; a click shows who put which emoji there.
private struct ReactionChips: View {
    let reactions: [BubbleReaction]
    let onReact: ((String) -> Void)?
    /// Who reacted is open under the emoji.
    @State private var showingPeople = false

    /// The most emoji the pill shows; the rest are in the count and in the list of who reacted.
    private static let shown = 3

    private var mine: Bool { reactions.contains(where: \.mine) }
    private var total: Int { reactions.reduce(0) { $0 + max($1.count, 1) } }

    var body: some View {
        // A click shows who put which emoji there, as the chat apps do; there yours can be taken back or another added.
        Button { showingPeople = true } label: { pill }
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

    private var pill: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            HStack(spacing: 0) {
                ForEach(reactions.prefix(Self.shown)) { reaction in
                    Text(reaction.emoji).font(NookTheme.font(13))
                }
            }
            if total > 1 {
                Text("\(total)")
                    .font(NookTheme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(mine ? NookTheme.mint : NookTheme.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.xxs)
        .background {
            NookTheme.shape(NookTheme.Radius.chip)
                .fill(NookTheme.chatTheirs)
                .overlay(NookTheme.shape(NookTheme.Radius.chip).fill(mine ? NookTheme.mint.opacity(0.18) : .clear))
        }
        .contentShape(NookTheme.shape(NookTheme.Radius.chip))
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
            Image(icon: symbol)
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
            Image(icon: "plus")
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

    /// Kept per text: the detector is the costly part of drawing a bubble, and bubbles are drawn again often.
    private static let cache: NSCache<NSString, ChatFormat.Kept<AttributedString>> = {
        let cache = NSCache<NSString, ChatFormat.Kept<AttributedString>>()
        cache.countLimit = 2_000
        return cache
    }()

    static func attributed(_ text: String) -> AttributedString {
        // Most messages have no address at all: skip the detector for them.
        guard text.contains("."), let detector else { return AttributedString(text) }
        let key = text as NSString
        if let kept = cache.object(forKey: key) { return kept.value }
        var attributed = AttributedString(text)
        defer { cache.setObject(ChatFormat.Kept(attributed), forKey: key) }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: attributed) else { continue }
            attributed[range].link = url
            attributed[range].underlineStyle = .single
        }
        return attributed
    }
}


/// A video in a chat bubble: its first frame, whole, with a play button, and a click plays it right there with Nook's own
/// small controls (`ChatVideoControls`: play and pause, a bar to scrub, the time), which fit even a narrow bubble where
/// the system's would crowd over the picture. The enlarge button carries on where the bubble was: in the main window over
/// all of the window (`ChatMediaStage`), so split with another app it fills only Nook's part of the screen; in the notch
/// big in a window of its own that goes full screen.
struct VideoTile: View {
    let url: URL
    let poster: NSImage?
    let name: String
    /// How tall it may be: a chat bubble's height, or taller where a video stands on its own (a file the agent made).
    var maxHeight = PhotoButton.maxHeight
    /// The video playing in the bubble, once you clicked it: it waits for a file still coming in and says so when it
    /// cannot be played (`ChatVideoPlayback`).
    @State private var playback: ChatVideoPlayback?
    @State private var hovering = false
    @State private var isPaused = false
    /// A frame of the video itself, when its app sent no picture of it: never a black box.
    @State private var still: ChatVideoStills.Still?
    @Environment(\.chatMediaLive) private var live
    @Environment(\.chatMediaStage) private var stage

    /// The still made before (the chat's warm-up, an earlier visit) shows in the first frame, without a black box first.
    private var shownStill: ChatVideoStills.Still? { still ?? ChatVideoStills.cached(url) }
    private var picture: NSImage? { poster ?? shownStill?.image }
    private var enlargeLabel: String { tr(videoStage == nil ? "card.video.enlarge" : "card.video.fullScreen") }
    /// The stage, where it plays videos: the notch's shows only pictures.
    private var videoStage: ChatMediaStage? { stage?.playsVideos == true ? stage : nil }
    private var showEnlarge: Bool { hovering || playback == nil || isPaused }

    private var size: CGSize {
        guard let poster = picture, poster.size.width > 0, poster.size.height > 0 else {
            return CGSize(width: PhotoButton.maxWidth, height: PhotoButton.maxWidth * 9 / 16)
        }
        let height = min(maxHeight, PhotoButton.maxWidth * poster.size.height / poster.size.width)
        return CGSize(width: height * poster.size.width / poster.size.height, height: height)
    }

    var body: some View {
        ZStack {
            if let playback {
                ChatVideoPlaybackView(playback: playback, poster: picture, hovering: hovering, name: name,
                                      onHover: { hovering = $0 }, onPaused: { isPaused = $0 }, onDoubleClick: enlarge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        Image(icon: "play.fill")
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
        }
        .overlay(alignment: .topTrailing) {
            if showEnlarge {
                Button { enlarge() } label: {
                    Image(icon: "arrow.up.left.and.arrow.down.right")
                        .font(NookTheme.font(11, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(enlargeLabel)
                .accessibilityLabel("\(enlargeLabel): \(name)")
            }
        }
        .overlay(alignment: .bottomLeading) {
            // How long it lasts, on the picture, as a chat app shows it.
            if playback == nil, let seconds = shownStill?.seconds, seconds > 0 {
                Text(ChatAudioPlayer.clock(seconds))
                    .font(NookTheme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.ink.opacity(0.6)))
                    .padding(NookTheme.Spacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .fittedMedia(size)
        .roundedClip(NookTheme.Radius.card)
        .onHover { hovering = $0 }
        .onDisappear { playback?.pause() }
        // Its frame is read once its message comes near view, not for every video in the history at once.
        .task(id: live ? url : nil) {
            guard live, shownStill == nil else { return }
            still = await ChatVideoStills.still(url)
        }
    }

    private func play() {
        let playback = ChatVideoPlayback(url: url)
        self.playback = playback
        isPaused = false
        playback.start()
    }

    /// The video big, from where the bubble was; the bubble stops so it never plays twice.
    private func enlarge() {
        let time = playback?.currentTime ?? .zero
        playback?.stop()
        playback = nil
        isPaused = false
        if let videoStage {
            videoStage.show(url, name: name, at: time)
        } else {
            VideoWindow.shared.show(url, title: name, at: time, aspect: picture?.size)
        }
    }
}

/// A bubble's video once you clicked it: its picture with a spinner while its file is still coming in, then the
/// video with Nook's own small controls over it (`ChatVideoControls`), or why it cannot be played with a way to try
/// again or open it elsewhere.
private struct ChatVideoPlaybackView: View {
    @ObservedObject var playback: ChatVideoPlayback
    let poster: NSImage?
    let hovering: Bool
    let name: String
    var onHover: ((Bool) -> Void)?
    var onPaused: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?

    var body: some View {
        switch playback.phase {
        case .ready:
            ZStack {
                InlinePlayer(player: playback.player, controls: false, onHover: onHover, onPaused: onPaused,
                             onClick: playback.toggle, onDoubleClick: onDoubleClick)
                ChatVideoControls(playback: playback, hovering: hovering, name: name)
            }
        case .loading, .failed:
            ZStack {
                Color.black
                if let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
                if playback.phase == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .accessibilityLabel(tr("card.video.loading"))
                } else {
                    ChatVideoFailure(url: playback.url, retry: playback.retry)
                }
            }
        }
    }
}

/// The system's video player in a bubble or a panel: the picture whole, never cropped, and stopped when it goes away.
struct InlinePlayer: NSViewRepresentable {
    let player: AVPlayer
    /// Its own full-screen button; in a bubble full screen happens in the video's own window instead.
    var fullScreen = false
    /// The system's controls; off where the view draws its own over it (`ChatVideoControls`).
    var controls = true
    var onHover: ((Bool) -> Void)?
    var onPaused: ((Bool) -> Void)?
    /// One click on the picture; a double click is `onDoubleClick`.
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaused: onPaused)
    }

    func makeNSView(context: Context) -> InlineAVPlayerView {
        let view = InlineAVPlayerView()
        view.controlsStyle = controls ? .floating : .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = fullScreen
        view.player = player
        view.onHover = onHover
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        context.coordinator.attach(player: player)
        return view
    }

    func updateNSView(_ view: InlineAVPlayerView, context: Context) {
        view.onHover = onHover
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        if view.player !== player {
            view.player = player
            context.coordinator.attach(player: player)
        }
    }

    static func dismantleNSView(_ view: InlineAVPlayerView, coordinator: Coordinator) {
        coordinator.detach()
        view.player?.pause()
        view.player = nil
    }

    final class Coordinator: NSObject {
        var onPaused: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        init(onPaused: ((Bool) -> Void)?) {
            self.onPaused = onPaused
        }

        func attach(player: AVPlayer) {
            observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let paused = player.timeControlStatus == .paused
                DispatchQueue.main.async {
                    self?.onPaused?(paused)
                }
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
        }
    }
}

final class InlineAVPlayerView: AVPlayerView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area

        checkHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            checkHover()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let window else {
            onHover?(false)
            return
        }
        let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(pt) {
            onHover?(false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 1 {
            onClick?()
        } else if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    private func checkHover() {
        guard let window else { return }
        let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(pt) {
            onHover?(true)
        }
    }
}

/// A photo in a chat bubble that was not decoded yet: read in the background (again a few times over a while when its
/// app is still writing it), with a quiet placeholder meanwhile; then shown as any photo. One that never becomes
/// readable shows as a file that opens in its app. Every photo comes in this way, so making a chat's bubbles never
/// decodes a picture and opening or scrolling a chat full of photos stays smooth. The placeholder already has the
/// photo's own size (read from its header), so nothing in the chat moves when the photo appears.
struct ChatPhotoLoader: View {
    let url: URL
    let name: String
    let onZoom: () -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var failed = false
    @Environment(\.chatMediaLive) private var live

    init(url: URL, name: String, onZoom: @escaping () -> Void, onOpen: @escaping () -> Void) {
        self.url = url
        self.name = name
        self.onZoom = onZoom
        self.onOpen = onOpen
        // A photo decoded before (scrolled past, or the chat opened lately) shows at once, without a placeholder first.
        _image = State(initialValue: ChatMediaImages.cached(url))
    }

    /// The waits between tries while its app may still be writing it: about a minute and a half in all, and often at
    /// first, so a photo that just settled (`ChatMedia.isSettled`) shows then and not at the next long wait.
    private static let waits: [Double] = [0, 0.2, 0.3, 0.5, 0.5, 0.5, 1, 2, 3, 5, 8, 13, 20, 30]

    var body: some View {
        Group {
            if let image {
                PhotoButton(image: image, name: name, action: onZoom)
            } else if failed {
                AttachmentButton(name: name, file: url, action: onOpen)
            } else {
                ChatPhotoPlaceholder(name: name, size: ChatMediaImages.pixelSize(url))
            }
        }
        // Decoded once its message comes near view: scrolling back does not decode the whole history's photos.
        // One that failed before is tried again each time it comes back into view: its file may be whole by now.
        .task(id: live ? url : nil) {
            guard live, image == nil else { return }
            for wait in Self.waits {
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                // A file still being written is not decoded yet: a half photo would be cached and shown as it is.
                guard ChatMedia.isSettled(url) else { continue }
                // At the priority of what you look at, shared with the warm-up of the chat that may decode it already.
                if let loaded = await ChatMediaImages.load(url) {
                    image = loaded
                    failed = false
                    return
                }
            }
            failed = true
        }
    }
}

/// Where a photo goes while it is not drawn yet: a quiet tile with a photo mark, at the photo's own size when that is
/// known. Also a photo its app has not given Nook yet, which a click opens in the app.
struct ChatPhotoPlaceholder: View {
    let name: String
    /// The photo's size in pixels; nil when not known (a tile of a usual photo's shape).
    var size: CGSize? = nil

    var body: some View {
        let shown = size.map(PhotoButton.fittedSize(for:))
            ?? CGSize(width: PhotoButton.maxWidth, height: PhotoButton.maxHeight * 0.75)
        NookTheme.shape(NookTheme.Radius.card)
            .fill(NookTheme.ink.opacity(0.3))
            .fittedMedia(shown)
            .overlay {
                Image(icon: "photo")
                    .font(NookTheme.font(22))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(name)
    }
}

struct PhotoButton: View {
    static let maxWidth: CGFloat = 300
    static let maxHeight: CGFloat = 260

    let image: NSImage
    let name: String
    let action: () -> Void
    @State private var hovering = false

    /// The photo whole, fitted in `maxWidth × maxHeight`: exactly its own size, so the bubble is no wider than the photo.
    private var size: CGSize { Self.fittedSize(for: image.size) }

    static func fittedSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let scale = min(maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    var body: some View {
        Button(action: action) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .fittedMedia(size)
                .roundedClip(NookTheme.Radius.card)
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
    /// The file's size in bytes, read from disk once per file and not on every hover.
    @State private var bytes: Int?

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 46)
                        .roundedClip(4)
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
                    if let kind = Self.detail(of: name, bytes: bytes) {
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
            .roundedBackground(NookTheme.ink.opacity(hovering ? 0.32 : 0.22), radius: NookTheme.Radius.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: file) {
            guard let file else { bytes = nil; return }
            bytes = await Task.detached(priority: .utility) {
                (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            }.value
        }
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
    private static func detail(of name: String, bytes: Int?) -> String? {
        let ext = (name as NSString).pathExtension
        if let bytes {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return ext.isEmpty ? size : "\(size) · \(ext.lowercased())"
        }
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }
}

/// `ChatTimeline.entries` of what a chat draws, kept while its messages, the day and the language stay the same: the
/// transcript's body runs again on every change anywhere in Nook's chats and while you scroll.
@MainActor
private final class TranscriptTimelineMemo {
    private var items: [ChatTimeline.Item]?
    private var day: Date?
    private var language: AppLanguage?
    private var kept: [ChatTimeline.Entry] = []

    func entries(_ items: [ChatTimeline.Item], language: AppLanguage) -> [ChatTimeline.Entry] {
        // "Today" and "Yesterday" move on at midnight.
        let day = Calendar.current.startOfDay(for: Date())
        if items == self.items, day == self.day, language == self.language { return kept }
        kept = ChatTimeline.entries(items, locale: Locale(identifier: language.rawValue))
        self.items = items
        self.day = day
        self.language = language
        return kept
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

/// "Deleted" beside the time of a message its writer deleted for everyone that still shows what it said, as "Edited"
/// sits there for a changed one.
private struct DeletedMark: View {
    let color: Color

    var body: some View {
        Label(tr("chat.message.deletedTag"), systemImage: "nosign")
            .labelStyle(.titleAndIcon)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(color)
            .help(tr("chat.message.deletedKept"))
    }
}
