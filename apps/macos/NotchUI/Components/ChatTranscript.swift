import SwiftUI
import AVKit

/// A conversation as bubbles, oldest at the top: theirs on the left, yours on the right, the way a chat app shows it.
/// A line marks where a new day starts; messages one person sends in a row sit close together under their name (each
/// person in a group in a color of their own); links open; a message of only emoji shows large; a long message folds
/// open with "Read more". More than fits scrolls back through the history, starting at the newest message. Each
/// message's text can be selected; right-click a bubble to copy the message or the whole chat. Used by the chat card in
/// the notch and by the Chats tab.
struct ChatTranscript: View {
    let bubbles: [ChatBubble]
    /// Who the chat is with, for the copied chat's lines in a private chat.
    let contact: String
    /// Takes all the room it gets and scrolls inside it (the Chats tab), instead of growing with the messages up to
    /// the card's height.
    var fills = false
    var onOpen: (ChatBubble) -> Void = { _ in }
    var onZoom: (ChatBubble) -> Void = { _ in }

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
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
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
                                       onOpen: { onOpen(bubble) }, onZoom: { onZoom(bubble) })
                            .contextMenu {
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

    private struct Row: Identifiable {
        let id: String
        let entry: ChatTimeline.Entry
    }
}

/// Where a new day starts in a chat: "Today", "Yesterday", "Monday", "12 Oct".
private struct ChatDayDivider: View {
    let label: String

    var body: some View {
        Text(label)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textSecondary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, 3)
            .background(Capsule().fill(NookTheme.smoke))
            .frame(maxWidth: .infinity)
            .padding(.top, NookTheme.Spacing.lg)
            .padding(.bottom, NookTheme.Spacing.xs)
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
    @State private var expanded = false

    /// Each person in a group writes in a color of their own, the same every time.
    private static let senderColors: [Color] = [NookTheme.mint, NookTheme.blue, NookTheme.violet, NookTheme.music]
    /// Lines a long message shows until "Read more".
    private static let foldedLines = 12

    private var emojiOnly: Bool { bubble.attachment == nil && ChatTimeline.isEmojiOnly(bubble.text) }
    private var long: Bool { bubble.text.count > 700 || bubble.text.filter { $0 == "\n" }.count >= Self.foldedLines }

    var body: some View {
        HStack(spacing: 0) {
            if bubble.fromMe { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 2) {
                if first, !bubble.sender.isEmpty {
                    Text(bubble.sender)
                        .font(NookTheme.font(11.5, .semibold))
                        .foregroundStyle(Self.senderColors[ChatTimeline.colorIndex(for: bubble.sender, count: Self.senderColors.count)])
                        .lineLimit(1)
                }
                if let attachment = bubble.attachment {
                    switch bubble.media {
                    case .photo where bubble.image != nil:
                        PhotoButton(image: bubble.image!, name: attachment, action: onZoom)
                    case .video(let url):
                        VideoTile(url: url, poster: bubble.image, name: attachment)
                    default:
                        AttachmentButton(name: attachment, preview: bubble.image, action: onOpen)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    if !bubble.text.isEmpty {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                            Text(ChatLinks.attributed(bubble.text))
                                .font(emojiOnly ? NookTheme.font(34) : NookTheme.font(14, newest ? .medium : .regular))
                                .foregroundStyle(NookTheme.paper)
                                .tint(NookTheme.blue)
                                .lineLimit(long && !expanded ? Self.foldedLines : nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if long {
                                Button(expanded ? tr("chat.showLess") : tr("chat.readMore")) {
                                    withAnimation(NookTheme.swap) { expanded.toggle() }
                                }
                                .buttonStyle(.plain)
                                .font(NookTheme.TextStyle.label)
                                .foregroundStyle(NookTheme.blue)
                            }
                        }
                    } else {
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 3) {
                        Text(bubble.time)
                            .font(NookTheme.font(10.5))
                            .foregroundStyle(NookTheme.textTertiary)
                        if let ticks = bubble.ticks { TicksView(ticks: ticks) }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, emojiOnly ? NookTheme.Spacing.xs : 12)
            .padding(.vertical, emojiOnly ? NookTheme.Spacing.xxs : 7)
            .background(shape.fill(emojiOnly ? Color.clear : (bubble.fromMe ? NookTheme.mint.opacity(0.16) : NookTheme.smoke)))
            if !bubble.fromMe { Spacer(minLength: 70) }
        }
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
/// server, two on their phone, two blue ones once read, a red mark when it could not be sent.
private struct TicksView: View {
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

/// A photo in a chat bubble, as it came: a click enlarges it in the card.
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
            HStack(spacing: 8) {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "doc.fill")
                        .font(NookTheme.font(14))
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
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("card.attachment.view"))
        .accessibilityLabel("\(tr("card.attachment.view")): \(name)")
    }
}
