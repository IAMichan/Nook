import SwiftUI
import AppKit
import AVKit
import Combine
import ImageIO
import QuickLookThumbnailing

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
            bubble.senderFace = thread.face(of: message)
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
        edited = message.isEdited
        deleted = message.isDeleted
        poll = message.poll
        membership = message.membership
        groupChange = message.groupChange
        reactions = (message.reactions ?? []).map {
            BubbleReaction(emoji: $0.emoji, count: $0.count, mine: $0.mine, people: $0.people ?? [])
        }
        if message.isMine {
            ticks = message.receipt.map(BubbleTicks.init)
            if let person {
                self.readers = ChatReceipts.person(person, receipt: message.receipt, date: message.readers?.first?.date)
            } else if let readers = message.readers, ticks != nil {
                self.readers = ChatReceipts.everyone(readers, members: members)
            }
        }
        guard let file = message.media else { return }
        // A photo sent as a document shows as a photo, in every app (`ChatMedia.shownKind`).
        let kind = file.shownKind
        // A song or a sound file goes by its own name ("track.mp3"); a voice message, a photo or a video by its kind.
        attachment = kind == .audio ? (file.name.flatMap { $0.isEmpty ? nil : $0 } ?? file.label) : file.label
        guard let url = file.url else {
            // A picture its app still fetches: a photo-shaped tile until it is here, not a file row.
            if file.isPictureComing { media = .photoComing }
            return
        }
        self.file = url
        switch kind {
        case .photo:
            // Only a photo decoded before: the bubble decodes the others in the background (`ChatPhotoLoader`), so
            // making a chat's bubbles never waits on its pictures.
            image = ChatMediaImages.cached(url)
            media = .photo(url)
        case .video:
            media = .video(url)
            // Its first frame when made before; the bubble makes it once it comes into view (`VideoTile`).
            image = ChatFileThumbnails.shared.cached(url)
        case .gif:
            media = .gif(url)
        case .sticker:
            media = .sticker(url)
        case .audio, .voice:
            media = .audio(url, seconds: file.seconds)
        case .file:
            // A document shows its first page when made before; the bubble makes it once it comes into view.
            image = ChatFileThumbnails.shared.cached(url)
        }
    }
}

/// Pictures of files on this Mac that show more than their name, for every app's bubbles: a video's first frame and a
/// document's first page, made once each in the background. A bubble asks for its picture only while it is in or near
/// view (`chatMediaLive`), so scrolling back through a long chat never makes the pictures of all its files at once.
final class ChatFileThumbnails: @unchecked Sendable {
    static let shared = ChatFileThumbnails()

    /// Up to 32 MB of pictures (a 960-pixel frame is about 3.7 MB); one that went is read back from disk.
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        MemoryPressure.shared.register("chatFileThumbnails", emptying: cache)
        return cache
    }()
    private let lock = NSLock()
    /// The files whose picture could not be made, and when: they are tried again a while later (a video may still
    /// have been coming in).
    private var failed: [String: Date] = [:]
    private static let retry: TimeInterval = 60

    /// The picture when it was made before; nil otherwise, without making it.
    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// The picture of a video or a document, made now when it was not before; nil for any other file and for one whose
    /// picture cannot be made.
    func image(_ url: URL, kind: ChatMedia.Kind) async -> NSImage? {
        guard kind == .video || kind == .file else { return nil }
        if let image = cached(url) { return image }
        guard !lock.withLock({ failed[url.path].map { Date().timeIntervalSince($0) < Self.retry } ?? false }) else { return nil }
        // Made before, also on an earlier launch: read back from disk, which is far quicker than making it again.
        if let stored = ChatPictureDisk.key(url, variant: kind == .video ? "frame-960" : "page", always: true),
           let image = await Task.detached(priority: .userInitiated, operation: { ChatPictureDisk.image(stored) }).value {
            cache.setObject(image, forKey: url.path as NSString, cost: DecodedImage.cost(image))
            return image
        }
        guard let image = await Self.make(url, kind: kind) else {
            lock.withLock { failed[url.path] = Date() }
            return nil
        }
        cache.setObject(image, forKey: url.path as NSString, cost: DecodedImage.cost(image))
        // Filed under the file as it is now: a video may have grown while it was waited for.
        if let settled = ChatPictureDisk.key(url, variant: kind == .video ? "frame-960" : "page", always: true) {
            ChatPictureDisk.store(image, key: settled)
        }
        return image
    }

    /// A video's first frame, a document's first page.
    private static func make(_ url: URL, kind: ChatMedia.Kind) async -> NSImage? {
        switch kind {
        case .video:
            guard let asset = await ChatVideoAsset.load(url, waits: [0, 1, 3]) else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            guard let frame = try? await generator.image(at: .zero).image else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        case .file:
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 128), scale: 2,
                                                       representationTypes: .thumbnail)
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        default:
            return nil
        }
    }
}

/// Pictures of files on this Mac, decoded once at a size a bubble needs, so a redraw of a chat costs nothing.
enum ChatMediaImages {
    /// Up to 64 MB of decoded pictures (a 480-pixel photo is about 0.9 MB); one that went is read back from disk.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        MemoryPressure.shared.register("chatMediaImages", emptying: cache)
        return cache
    }()

    private static func key(_ url: URL, side: CGFloat) -> NSString { "\(url.path)#\(Int(side))" as NSString }

    /// The picture when it was decoded before, without touching the file: nil otherwise.
    static func cached(_ url: URL, side: CGFloat = 480) -> NSImage? {
        cache.object(forKey: key(url, side: side))
    }

    /// The picture at `side` pixels at most: from memory, else from the copy on disk (`ChatPictureDisk`), else decoded
    /// from the file now, completely, so drawing it later costs the main thread nothing. Called off the main thread.
    static func image(_ url: URL, side: CGFloat = 480) -> NSImage? {
        let key = key(url, side: side)
        if let cached = cache.object(forKey: key) { return cached }
        let stored = ChatPictureDisk.key(url, variant: "photo-\(Int(side))")
        if let stored, let image = ChatPictureDisk.image(stored) {
            cache.setObject(image, forKey: key, cost: DecodedImage.cost(image))
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        if let stored { ChatPictureDisk.store(image, key: stored) }
        return image
    }

    /// The decodes going on, by `key`: a bubble and the warm-up of its chat (`ChatMediaWarmup`) asking for the same
    /// photo share one decode.
    @MainActor private static var loading: [NSString: Task<NSImage?, Never>] = [:]

    /// `image(_:side:)` off the main thread, once per picture however many ask for it at the same time.
    @MainActor
    static func load(_ url: URL, side: CGFloat = 480, priority: TaskPriority = .userInitiated) async -> NSImage? {
        let key = key(url, side: side)
        if let cached = cache.object(forKey: key) { return cached }
        if let running = loading[key] { return await running.value }
        let task = Task.detached(priority: priority) { image(url, side: side) }
        loading[key] = task
        let loaded = await task.value
        loading[key] = nil
        return loaded
    }

    private static let pixelSizes = NSCache<NSString, NSValue>()
    /// Files that could not be read yet, and when to try again: a chat redraws often, and each try opened the file up to
    /// three times on the main thread.
    private static let unreadable = NSCache<NSString, NSDate>()

    /// The photo's own size in pixels, upright (EXIF orientation applied), read from its header only, once per file.
    /// Nil for a file that is no picture (a GIF that came as a video): remembered too, so a redraw does not ask again.
    static func pixelSize(_ url: URL) -> CGSize? {
        let key = url.path as NSString
        if let known = pixelSizes.object(forKey: key) { return known.sizeValue == .zero ? nil : known.sizeValue }
        if let retry = unreadable.object(forKey: key), retry.timeIntervalSinceNow > 0 { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else {
            // Not readable yet (still being written) is asked again later; only a file that is there and no picture is kept.
            if FileManager.default.fileExists(atPath: url.path), CGImageSourceCreateWithURL(url as CFURL, nil) == nil {
                pixelSizes.setObject(NSValue(size: .zero), forKey: key)
            } else {
                unreadable.setObject(NSDate(timeIntervalSinceNow: 2), forKey: key)
            }
            return nil
        }
        // Orientations 5 to 8 turn the picture a quarter, so its sides swap.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        pixelSizes.setObject(NSValue(size: size), forKey: key)
        return size
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

/// The chats' own pictures in a list (the Chats tab), by their file: decoded once at the list's size off the main
/// thread, so scrolling a long list to rows it did not show yet never decodes a picture on the main thread. Says so once
/// per moment in which pictures came in, not once per picture.
@MainActor
final class ChatAvatarImages: ObservableObject {
    static let shared = ChatAvatarImages()
    /// The pixel size a list's picture is decoded at (a 40-point avatar on a Retina screen, with room).
    static let side: CGFloat = 96
    /// How long a file that could not be read is left alone before it is tried again (it may still be coming in).
    private static let retry: TimeInterval = 30

    /// How many decoded pictures are kept (about 37 KB each at `side`).
    private static let limit = 1_000

    @Published private(set) var generation = 0
    /// The decoded pictures, held here rather than in the shared media cache: that one is emptied under memory pressure,
    /// and each time it was, every face fell back to its Contacts photo or initials until it was decoded again, which
    /// made the list flicker between the old and the real picture.
    private var images: [String: NSImage] = [:]
    /// The picture each chat showed last, kept while a new file for it decodes: a chat whose picture moved to another
    /// file keeps its face instead of blinking to the initials in between.
    private var shown: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var failed: [String: Date] = [:]
    private var announcing = false

    /// The picture when it is decoded; while it is, the picture `chat` showed before, else nil (the list shows the
    /// initials meanwhile and redraws once it is in).
    func image(_ path: String, chat: String? = nil) -> NSImage? {
        if let image = images[path] {
            if let chat, shown[chat] !== image { shown[chat] = image }
            return image
        }
        load(path)
        return chat.flatMap { shown[$0] }
    }

    private func load(_ path: String) {
        guard !loading.contains(path) else { return }
        if let at = failed[path], Date().timeIntervalSince(at) < Self.retry { return }
        loading.insert(path)
        let side = Self.side
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ChatMediaImages.image(URL(fileURLWithPath: path, isDirectory: false), side: side) != nil
            }.value
            loading.remove(path)
            guard found else {
                failed[path] = Date()
                return
            }
            failed[path] = nil
            // Gone from the media cache already (memory pressure): the next redraw asks again.
            guard let image = ChatMediaImages.cached(URL(fileURLWithPath: path, isDirectory: false), side: side) else { return }
            if images.count >= Self.limit { images.removeAll(keepingCapacity: true) }
            // The last picture per chat holds as many as there are chats ever listed: bounded the same way.
            if shown.count >= Self.limit { shown.removeAll(keepingCapacity: true) }
            images[path] = image
            announce()
        }
    }

    /// One redraw for every picture that came in this moment.
    private func announce() {
        guard !announcing else { return }
        announcing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.announcing = false
                self?.generation += 1
            }
        }
    }
}

// MARK: In view

extension EnvironmentValues {
    /// Whether the chat message around a view is in view or close to it (`ChatBubbleView`): only then does its media
    /// decode, play, animate or fetch its preview. Messages far up in a long chat's history stay a still placeholder of
    /// the same size, so scrolling through them stays smooth. True outside a chat.
    @Entry var chatMediaLive = true
    /// Asks the chat's app for a message's file Nook does not have yet, by the message's id (`AppModel.fetchChatFile`).
    /// Nil where no chat is around it.
    @Entry var chatFetchFile: ChatFileFetch? = nil
}

/// How a chat asks its app for a message's file (`chatFetchFile`). Equal per chat, so setting it again on a redraw of
/// the same chat does not redraw every message that reads it.
struct ChatFileFetch: Equatable {
    /// The chat it asks for.
    let chat: String
    let fetch: @MainActor (String) async -> Void

    static func == (a: ChatFileFetch, b: ChatFileFetch) -> Bool { a.chat == b.chat }
}

extension View {
    /// Sets `near` to whether this view is in its scroll view's visible part or within a screen of it, so its media is
    /// ready before it scrolls into view; always true outside a scroll view.
    func chatNearView(_ near: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            guard let visible = proxy.bounds(of: .scrollView) else { return true }
            let margin = max(visible.height, 400)
            return visible.insetBy(dx: 0, dy: -margin).intersects(CGRect(origin: .zero, size: proxy.size))
        } action: { near.wrappedValue = $0 }
    }
}

/// A picture's place while its message is far from view: a quiet tile, or nothing for a sticker, at the same size.
private struct ChatMediaStandIn: View {
    var clear = false

    var body: some View {
        NookTheme.shape(NookTheme.Radius.card)
            .fill(clear ? Color.clear : NookTheme.ink.opacity(0.3))
            .accessibilityHidden(true)
    }
}

// MARK: Sticker

/// A sticker as the chat app shows it: on its own, without a bubble, moving when it is an animated one.
struct ChatStickerView: View {
    static let side: CGFloat = 128

    let url: URL
    let name: String
    @Environment(\.chatMediaLive) private var live
    /// Decoded off the main thread once its message comes into view: decoding it in the redraw stalled scrolling for
    /// each sticker that came in.
    @State private var decoded: NSImage?
    /// The decode ran (and found no picture when `decoded` stays nil).
    @State private var tried = false

    /// The sticker decoded, when its message is in view or it was decoded before.
    private var still: NSImage? {
        ChatMediaImages.cached(url, side: Self.side * 2) ?? decoded
    }

    var body: some View {
        Group {
            if ChatMediaImages.isAnimated(url) {
                if live {
                    AnimatedPicture(url: url)
                } else {
                    ChatMediaStandIn(clear: true)
                        .aspectRatio(ChatMediaImages.pixelSize(url) ?? CGSize(width: 1, height: 1), contentMode: .fit)
                }
            } else if let image = still {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if !live || !tried {
                ChatMediaStandIn(clear: true)
                    .aspectRatio(ChatMediaImages.pixelSize(url) ?? CGSize(width: 1, height: 1), contentMode: .fit)
            } else {
                Image(icon: "face.smiling")
                    .font(NookTheme.font(40))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        .task(id: live) {
            guard live, still == nil, !ChatMediaImages.isAnimated(url) else { return }
            let image = await ChatMediaImages.load(url, side: Self.side * 2)
            guard !Task.isCancelled else { return }
            decoded = image
            tried = true
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
    @Environment(\.chatMediaLive) private var live

    private var size: CGSize {
        // From the file's header: drawing a chat does not decode its GIFs.
        if let pixels = ChatMediaImages.pixelSize(url) {
            let height = min(Self.maxHeight, Self.maxWidth * pixels.height / pixels.width)
            return CGSize(width: height * pixels.width / pixels.height, height: height)
        }
        return CGSize(width: Self.maxWidth, height: Self.maxHeight)
    }

    var body: some View {
        Group {
            // Far from view it neither moves nor plays: a long chat's GIFs do not all run at once.
            if ChatMediaImages.isPicture(url) {
                Group {
                    if live { AnimatedPicture(url: url) } else { ChatMediaStandIn() }
                }
                .frame(width: size.width, height: size.height)
            } else {
                Group {
                    if live { LoopingVideo(url: url) } else { ChatMediaStandIn() }
                }
                .frame(width: Self.maxWidth, height: Self.maxHeight)
            }
        }
        .roundedClip(NookTheme.Radius.card)
        .overlay(alignment: .bottomLeading) {
            Text(tr("chat.media.gif"))
                .font(NookTheme.font(9.5, .bold))
                .foregroundStyle(NookTheme.paper)
                .padding(.horizontal, NookTheme.Spacing.xs)
                .padding(.vertical, 2)
                .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.ink.opacity(0.6)))
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
        // Read off the main thread: the whole file at once stalled scrolling for each moving sticker or GIF that came in.
        let url = url
        Task { @MainActor [weak view] in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard let data, let view else { return }
            view.image = NSImage(data: data)
        }
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

/// A short video that plays by itself, silent and in a loop, without controls: a GIF as a video.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var looper: AVPlayerLooper?
        var loading: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let player = AVQueuePlayer()
        player.isMuted = true
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        // It loops once its file is complete and playable (`ChatVideoAsset`), not on a file still coming in.
        let coordinator = context.coordinator
        coordinator.loading = Task { @MainActor [url] in
            guard let asset = await ChatVideoAsset.load(url), !Task.isCancelled else { return }
            coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
            player.play()
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.loading?.cancel()
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
                Image(icon: player.failed ? "arrow.up.forward.app" : (player.playing ? "pause.fill" : "play.fill"))
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.onPaper)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(fromMe ? NookTheme.mint : NookTheme.paper))
                    .contentShape(Circle())
            }
            .buttonStyle(.nookPlain)
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

/// The controls over a video playing in a chat bubble, small enough for a narrow bubble: a play button in the middle
/// while it is paused, and along the bottom on a soft shade the time it is at, a bar to scrub and how long it lasts.
/// They show while the pointer is on the video or it is paused, and step aside while it plays.
struct ChatVideoControls: View {
    @ObservedObject var playback: ChatVideoPlayback
    let hovering: Bool
    let name: String
    @State private var scrubbing = false

    private var visible: Bool { hovering || !playback.playing || scrubbing }
    private var label: String { tr(playback.playing ? "chat.media.pause" : "chat.media.play") }

    var body: some View {
        ZStack {
            if !playback.playing {
                MediaOverlayButton("play.fill", label: label, size: .play, detail: name, action: playback.toggle)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bar
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(NookTheme.hover, value: visible)
    }

    private var bar: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Button(action: playback.toggle) {
                Image(icon: playback.playing ? "pause.fill" : "play.fill")
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(label)
            .accessibilityLabel("\(label): \(name)")
            Text(ChatAudioPlayer.clock(playback.elapsed))
                .font(NookTheme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(.white)
                .fixedSize()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                    Capsule().fill(Color.white)
                        .frame(width: geometry.size.width * playback.progress)
                }
                .frame(height: scrubbing ? 5 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        scrubbing = true
                        playback.seek(to: drag.location.x / max(1, geometry.size.width))
                    }
                    .onEnded { _ in scrubbing = false })
            }
            .frame(height: 14)
            if let duration = playback.duration {
                Text(ChatAudioPlayer.clock(duration))
                    .font(NookTheme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize()
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.top, NookTheme.Spacing.lg)
        .padding(.bottom, NookTheme.Spacing.sm)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
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
            Image(icon: symbol)
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

/// A line about the group in the middle of the chat, as the apps show it: someone coming in or going ("Ruben added
/// David", `ChatMembership`), or the group itself changing ("Anna changed the group name to …", `ChatGroupChange`), the
/// same for every app. Its time shows on hover.
struct ChatNoticeLine: View {
    let text: String
    let time: String

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.xs)
            .roundedBackground(NookTheme.chatTheirs, radius: NookTheme.Radius.control)
            .help(time)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, NookTheme.Spacing.xl)
            .textSelection(.enabled)
    }
}
