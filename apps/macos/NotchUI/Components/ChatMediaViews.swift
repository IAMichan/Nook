import SwiftUI
import AppKit
import AVKit
import Combine
import ImageIO

// What a chat message's file looks like in a bubble, the same in every chat (the notch card and the Chats tab, for
// WhatsApp, Messages, Telegram, Slack, Signal…): a sticker as itself without a bubble, a GIF that plays by itself in a
// loop, an audio or voice message with a play button and how far it got. Photos, videos and other files are drawn by
// `ChatTranscript` itself. A bridge only has to fill `InboxMessage.media`; `ChatBubble.init(_:time:)` does the rest.

extension ChatBubble {
    /// A chat's newest `last` messages (all when nil) as bubbles, each answer quoting the message it answers the same
    /// way in every app, as WhatsApp's do: who wrote it ("You" for your own, the chat's name in a private chat) and its
    /// text, found among all of the chat's messages.
    static func bubbles(_ thread: InboxThread, last: Int? = nil, time: (Date) -> String) -> [ChatBubble] {
        let byID = Dictionary(thread.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Every message of yours has its ticks, also the older ones its app says nothing of.
        let receipts = ChatReceipts.filled(thread.messages.map { ($0.isMine, $0.receipt) }, private: thread.isPrivate)
        let all = zip(thread.messages, receipts).map { original, receipt in
            var message = original
            message.receipt = receipt
            return message
        }
        let shown = last.map { Array(all.suffix($0)) } ?? all
        var bubbles = shown.map { message in
            var bubble = ChatBubble(message, time: time(message.date), members: thread.members ?? [],
                                    person: thread.isPrivate ? thread.name : nil)
            bubble.quote = message.quote.flatMap { quote(of: $0, in: byID, chat: thread.name) }
            return bubble
        }
        fillReaders(&bubbles)
        return bubbles
    }

    /// Your messages' info with what later ones say: who read a later message read the earlier ones too
    /// (`ChatReceipts.filledReaders`). The same for every chat app, WhatsApp's bubbles included.
    static func fillReaders(_ bubbles: inout [ChatBubble]) {
        let filled = ChatReceipts.filledReaders(bubbles.map { $0.fromMe ? $0.readers : [] },
                                                  speakers: bubbles.map { $0.fromMe ? nil : ($0.sender, $0.date) })
        for index in bubbles.indices where bubbles[index].fromMe && filled[index] != bubbles[index].readers {
            bubbles[index].readers = filled[index]
        }
    }

    /// What an answer quotes: the answered message as the chat has it, else what its app quoted of it. Nil when
    /// neither says anything.
    static func quote(of quote: InboxQuote, in byID: [String: InboxMessage], chat: String) -> BubbleQuote? {
        if let id = quote.id, let answered = byID[id] {
            let sender = answered.isMine ? tr("chat.you") : (answered.sender.isEmpty ? chat : answered.sender)
            return BubbleQuote(sender: sender, text: answered.summary, mine: answered.isMine)
        }
        let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return BubbleQuote(sender: quote.mine ? tr("chat.you") : quote.sender, text: text, mine: quote.mine)
    }

    /// A message of any chat app as a bubble: its text, and its file as the chat shows it. While the file is not on this
    /// Mac the bubble names it (a button that opens the chat's app); once it is, it shows as itself.
    /// `members`: the group's other people, so your message's info also lists who does not have it yet. `person`: the
    /// other person of a private chat, whom your message's info names.
    init(_ message: InboxMessage, time: String, members: [String] = [], person: String? = nil) {
        self.init(id: message.id, text: message.text, time: time, date: message.date, sender: message.sender,
                  fromMe: message.isMine)
        poll = message.poll
        reactions = (message.reactions ?? []).map { BubbleReaction(emoji: $0.emoji, count: $0.count, mine: $0.mine) }
        if message.isMine {
            ticks = message.receipt.map(BubbleTicks.init)
            if let person {
                self.readers = ChatReceipts.person(person, receipt: message.receipt, date: message.readers?.first?.date)
            } else if let readers = message.readers, ticks != nil {
                self.readers = ChatReceipts.everyone(readers, members: members)
            }
        }
        guard let file = message.media else { return }
        // A song or a sound file goes by its own name ("track.mp3"); a voice message, a photo or a video by its kind.
        attachment = file.kind == .audio ? (file.name.flatMap { $0.isEmpty ? nil : $0 } ?? file.label) : file.label
        guard let url = file.url else { return }
        self.file = url
        switch file.kind {
        case .photo:
            image = ChatMediaImages.image(url)
            media = image == nil ? .file : .photo(url)
        case .video:
            media = .video(url)
        case .gif:
            media = .gif(url)
        case .sticker:
            media = .sticker(url)
        case .audio, .voice:
            media = .audio(url, seconds: file.seconds)
        case .file:
            break
        }
    }
}

/// Pictures of files on this Mac, decoded once at a size a bubble needs, so a redraw of a chat costs nothing.
enum ChatMediaImages {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: URL, side: CGFloat = 480) -> NSImage? {
        let key = "\(url.path)#\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// How many frames each file holds, read once: a sticker or GIF asks on every redraw of its chat.
    private static let frames = NSCache<NSString, NSNumber>()

    private static func frameCount(_ url: URL) -> Int {
        let key = url.path as NSString
        if let known = frames.object(forKey: key) { return known.intValue }
        let count = CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
        frames.setObject(NSNumber(value: count), forKey: key)
        return count
    }

    /// Whether the file holds more than one frame (an animated GIF, WebP or PNG): it then plays as it is.
    static func isAnimated(_ url: URL) -> Bool {
        frameCount(url) > 1
    }

    /// Whether the file is a picture at all (a GIF or a sticker), rather than a video the app loops.
    static func isPicture(_ url: URL) -> Bool {
        frameCount(url) > 0
    }
}

// MARK: Sticker

/// A sticker as the chat app shows it: on its own, without a bubble, moving when it is an animated one.
struct ChatStickerView: View {
    static let side: CGFloat = 128

    let url: URL
    let name: String

    var body: some View {
        Group {
            if ChatMediaImages.isAnimated(url) {
                AnimatedPicture(url: url)
            } else if let image = ChatMediaImages.image(url, side: Self.side * 2) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "face.smiling")
                    .font(NookTheme.font(40))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        .frame(maxWidth: Self.side, maxHeight: Self.side, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(name)
    }
}

// MARK: GIF

/// A GIF in a bubble: it plays by itself, in a loop and without sound, as chat apps show them. A real GIF (or WebP) is
/// drawn frame by frame; one that came as a short video (as WhatsApp, Telegram and Slack send them) loops as a video.
struct ChatGIFView: View {
    static let maxWidth: CGFloat = 280
    static let maxHeight: CGFloat = 220

    let url: URL
    let name: String

    private var size: CGSize {
        if let image = ChatMediaImages.image(url), image.size.width > 0, image.size.height > 0 {
            let height = min(Self.maxHeight, Self.maxWidth * image.size.height / image.size.width)
            return CGSize(width: height * image.size.width / image.size.height, height: height)
        }
        return CGSize(width: Self.maxWidth, height: Self.maxHeight)
    }

    var body: some View {
        Group {
            if ChatMediaImages.isPicture(url) {
                AnimatedPicture(url: url)
                    .frame(width: size.width, height: size.height)
            } else {
                LoopingVideo(url: url)
                    .frame(width: Self.maxWidth, height: Self.maxHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text(tr("chat.media.gif"))
                .font(NookTheme.font(9.5, .bold))
                .foregroundStyle(NookTheme.paper)
                .padding(.horizontal, NookTheme.Spacing.xs)
                .padding(.vertical, 2)
                .background(Capsule().fill(NookTheme.ink.opacity(0.6)))
                .padding(NookTheme.Spacing.xs)
        }
        .accessibilityElement()
        .accessibilityLabel(name)
    }
}

/// A picture that moves when it has frames (GIF, WebP, APNG), drawn whole by AppKit.
struct AnimatedPicture: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

/// A short video that plays by itself, silent and in a loop, without controls: a GIF as a video.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        coordinator.looper = nil
        view.player = nil
    }
}

// MARK: Audio

/// An audio or voice message in a bubble: a play button, how far it got and how long it lasts. Plays right in the
/// bubble; one that macOS cannot play opens in the app the Mac uses for it.
struct ChatAudioView: View {
    let url: URL
    /// How long it lasts, when the chat app says so; else it is read from the file once it plays.
    let seconds: Double?
    let name: String
    let fromMe: Bool
    @StateObject private var player = ChatAudioPlayer()

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Button { toggle() } label: {
                Image(systemName: player.failed ? "arrow.up.forward.app" : (player.playing ? "pause.fill" : "play.fill"))
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.ink)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(fromMe ? NookTheme.mint : NookTheme.paper))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.failed ? tr("card.attachment.open") : (player.playing ? tr("chat.media.pause") : tr("chat.media.play")))
            .accessibilityLabel("\(player.playing ? tr("chat.media.pause") : tr("chat.media.play")): \(name)")
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                // A sound file (an mp3, a song) says which; a voice message needs no name.
                if !(name as NSString).pathExtension.isEmpty {
                    Text(name)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NookTheme.line2)
                        Capsule().fill(fromMe ? NookTheme.mint : NookTheme.paper)
                            .frame(width: geometry.size.width * player.progress)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                        player.seek(to: max(0, min(1, drag.location.x / max(1, geometry.size.width))))
                    })
                }
                .frame(height: 4)
                Text(ChatAudioPlayer.clock(player.playing || player.elapsed > 0 ? player.elapsed : (player.duration ?? seconds ?? 0)))
                    .font(NookTheme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .frame(width: 150)
        }
        .padding(.vertical, 2)
        .onDisappear { player.stop() }
    }

    private func toggle() {
        if player.failed {
            NSWorkspace.shared.open(url)
        } else {
            player.toggle(url)
        }
    }
}

/// Plays one audio message and says how far it got.
@MainActor
final class ChatAudioPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double?
    /// macOS cannot play this file (an unknown format): the button opens it in another app instead.
    @Published private(set) var failed = false

    private var player: AVPlayer?
    private var observer: Any?
    private var ended: AnyCancellable?
    private var status: AnyCancellable?

    var progress: CGFloat {
        guard let duration, duration > 0 else { return 0 }
        return CGFloat(min(1, elapsed / duration))
    }

    func toggle(_ url: URL) {
        if player == nil { load(url) }
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            if let duration, elapsed >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
        playing.toggle()
    }

    func seek(to fraction: CGFloat) {
        guard let player, let duration, duration > 0 else { return }
        let time = CMTime(seconds: duration * Double(fraction), preferredTimescale: 600)
        player.seek(to: time)
        elapsed = time.seconds
    }

    /// The bubble went away: stop, and let the player go (a next play starts it anew).
    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        ended = nil
        status = nil
        player = nil
        playing = false
        elapsed = 0
    }

    private func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 { self.duration = length }
            }
        }
        ended = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.playing = false
                if let duration = self?.duration { self?.elapsed = duration }
            }
        status = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                self?.failed = true
                self?.playing = false
            }
    }

    /// "0:42", "12:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A call in a chat, the same for every app: a round mark with its kind (an arrow in or out, a camera for video, a
/// hung-up phone in coral for one you missed), what it was ("Missed voice call") and under it who rang and how long it
/// lasted ("Incoming · 2:13").
struct ChatCallRow: View {
    let call: ChatCall
    let fromMe: Bool

    private var mine: Bool { call.outgoing ?? fromMe }
    /// A call you did not answer stands out; one nobody picked up at the other end does not.
    private var missedHere: Bool { call.missed && !mine }

    private var symbol: String {
        if missedHere { return call.video ? "video.slash.fill" : "phone.down.fill" }
        if call.video { return "video.fill" }
        return mine ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill"
    }

    private var tint: Color { missedHere ? NookTheme.coral : (call.missed ? NookTheme.textSecondary : NookTheme.mint) }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: symbol)
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(call.title(mine: fromMe))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(missedHere ? NookTheme.coral : NookTheme.paper)
                    .lineLimit(1)
                Text(call.detail(mine: fromMe))
                    .font(NookTheme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
