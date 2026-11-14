import SwiftUI
import AVKit
import LinkPresentation
import UniformTypeIdentifiers

/// A web address in a chat message, shown under its text the way chat apps show one, the same in every app: a picture
/// or a GIF as itself, a video that plays in the bubble, a sound file with its player, and any other page as a card with
/// its picture, title and site (with a play mark for a YouTube, Vimeo, TikTok or Instagram reel link). A click on a card
/// opens the page. While its preview loads, and when there is none, a slim line with the site stands in.
struct ChatLinkPreview: View {
    let url: URL
    let fromMe: Bool

    var body: some View {
        switch ChatFormat.linkKind(url) {
        case .image: ChatRemotePicture(url: url)
        case .video: VideoTile(url: url, poster: nil, name: url.lastPathComponent)
        case .audio: ChatAudioView(url: url, seconds: nil, name: url.lastPathComponent, fromMe: fromMe)
        case .page: ChatLinkCard(url: url)
        }
    }
}

/// A page's card: its picture on top, then its site and its title.
private struct ChatLinkCard: View {
    static let width: CGFloat = 280

    let url: URL
    @State private var preview: ChatLinkPreviews.Preview?
    @State private var hovering = false
    @Environment(\.chatMediaLive) private var live

    private var host: String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: { card }
            .buttonStyle(.nookPlain)
            .onHover { hovering = $0 }
            .animation(NookTheme.hover, value: hovering)
            .help(url.absoluteString)
            .accessibilityLabel((preview?.title).map { "\($0), \(host)" } ?? host)
            // Fetched once its message comes near view, not for every link in the history at once.
            .task(id: live ? url : nil) {
                guard live, preview == nil else { return }
                preview = await ChatLinkPreviews.shared.preview(url)
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            picture
            caption
        }
        // Its usual width, narrower in a narrow chat so it stays inside its bubble.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minWidth: 0, idealWidth: Self.width, maxWidth: Self.width)
        .background(NookTheme.ink.opacity(hovering ? 0.45 : 0.32))
        .roundedClip(NookTheme.Radius.card)
        .roundedStrokeBorder(NookTheme.hairline, radius: NookTheme.Radius.card)
        .contentShape(Rectangle())
    }

    /// The page's picture, 16:9, with a play mark for a video page.
    @ViewBuilder
    private var picture: some View {
        if let image = preview?.image {
            ZStack {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                if ChatFormat.isVideoPage(url) { playMark }
            }
        }
    }

    private var playMark: some View {
        MediaOverlayGlyph("play.fill", size: .play)
            .accessibilityHidden(true)
    }

    /// The site with its icon, and the page's title under it.
    private var caption: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            HStack(spacing: NookTheme.Spacing.xs) {
                SiteIcon(domain: url.host, fallback: "link", tint: NookTheme.textTertiary, size: 12)
                Text(host)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            if let title = preview?.title, !title.isEmpty {
                Text(title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A picture a message links to, fetched once into Nook's caches and then shown as a photo (or a GIF that plays); a
/// click enlarges it and a second click shrinks it back to its normal size. A slim line with its site stands in while
/// it loads and when it cannot be fetched.
private struct ChatRemotePicture: View {
    let url: URL
    @State private var file: URL?
    @State private var failed = false
    @State private var enlarged = false
    @State private var hovering = false
    @Environment(\.chatMediaLive) private var live

    private var label: String {
        enlarged ? tr("button.shrink") : tr("button.enlarge")
    }

    private func normalSize(for image: NSImage) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: PhotoButton.maxWidth, height: PhotoButton.maxHeight)
        }
        let scale = min(PhotoButton.maxWidth / image.size.width, PhotoButton.maxHeight / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    var body: some View {
        Group {
            if let file, ChatMediaImages.isAnimated(file) {
                ChatGIFView(url: file, name: url.lastPathComponent)
            } else if let file, let image = ChatMediaImages.image(file) {
                let size = enlarged
                    ? ImageAttachment.enlargedSize(for: image, maxWidth: 520, maxHeight: 420, minEdge: 380)
                    : normalSize(for: image)
                Button {
                    withAnimation(NookTheme.reveal) { enlarged.toggle() }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: size.width, maxHeight: size.height)
                            .roundedClip(NookTheme.Radius.card)
                        if hovering || enlarged {
                            ChatPictureSizeBadge(enlarged: enlarged)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .onHover { hovering = $0 }
                .contextMenu {
                    Button {
                        withAnimation(NookTheme.reveal) { enlarged.toggle() }
                    } label: {
                        Label(label, systemImage: enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label(tr("card.attachment.open"), systemImage: "arrow.up.forward.app")
                    }
                }
                .help(label)
                .accessibilityLabel("\(label): \(url.lastPathComponent)")
            } else if failed {
                ChatLinkCard(url: url)
            } else {
                NookTheme.shape(NookTheme.Radius.card)
                    .fill(NookTheme.ink.opacity(0.3))
                    .fittedMedia(CGSize(width: PhotoButton.maxWidth, height: PhotoButton.maxHeight * 0.75))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: live ? url : nil) {
            guard live, file == nil, !failed else { return }
            file = await ChatLinkPreviews.shared.file(url)
            failed = file == nil
        }
    }
}

/// What Nook knows of the links in chats: each page's title and picture, and the pictures links point at, fetched once
/// (the pictures in its caches folder). Only addresses that are in a message you see are asked. The previews stay in
/// memory up to `previewBytes` of pictures, decoded at the card's size, and go when macOS runs low on memory; a card
/// whose preview went fetches it again when it comes into view.
@MainActor
final class ChatLinkPreviews {
    static let shared = ChatLinkPreviews()

    struct Preview {
        var title: String?
        var image: NSImage?
    }

    private final class Box {
        let preview: Preview
        init(_ preview: Preview) { self.preview = preview }
    }

    /// The pictures of the cards, at most this many bytes decoded.
    private static let previewBytes = 24 * 1024 * 1024
    /// A card's picture in pixels on its longest side: twice the card's width, for a Retina screen.
    nonisolated private static let previewPixels: CGFloat = 560

    private let previews: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.totalCostLimit = previewBytes
        return cache
    }()
    private var loading: [URL: Task<Preview, Never>] = [:]
    private var files: [URL: URL] = [:]
    private var fetching: [URL: Task<URL?, Never>] = [:]

    /// The largest picture a link may bring in.
    nonisolated private static let maxBytes = 12_000_000

    private init() {
        MemoryPressure.shared.register("chatLinkPreviews", emptying: previews)
    }

    func preview(_ url: URL) async -> Preview {
        if let known = previews.object(forKey: url as NSURL) { return known.preview }
        if let running = loading[url] { return await running.value }
        let task = Task<Preview, Never> {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return Preview() }
            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            var image: NSImage?
            if let provider = metadata.imageProvider ?? metadata.iconProvider {
                image = await Self.image(from: provider)
            }
            return Preview(title: title, image: image)
        }
        loading[url] = task
        let preview = await task.value
        loading[url] = nil
        previews.setObject(Box(preview), forKey: url as NSURL, cost: preview.image.map(DecodedImage.cost) ?? 0)
        return preview
    }

    /// The picture a link points at, as a file on this Mac; nil when it cannot be fetched or is too large.
    func file(_ url: URL) async -> URL? {
        if let known = files[url], FileManager.default.fileExists(atPath: known.path) { return known }
        if let running = fetching[url] { return await running.value }
        let destination = ChatMedia.destination(key: "link-" + String(url.absoluteString.hashValue.magnitude),
                                                name: url.lastPathComponent.isEmpty ? "picture" : url.lastPathComponent)
        let task = Task<URL?, Never>.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: destination.path) { return destination }
            guard let (data, response) = try? await ConnectorHTTP.session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  data.count <= Self.maxBytes, NSImage(data: data) != nil else { return nil }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? data.write(to: destination)) == nil ? nil : destination
        }
        fetching[url] = task
        let file = await task.value
        fetching[url] = nil
        if let file { files[url] = file }
        return file
    }

    private static func image(from provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { DecodedImage.image($0, maxPixel: previewPixels) })
            }
        }
    }
}

/// A frame of a video and how long it lasts, read once per video: a video whose app sent no picture of it still shows
/// what it is. A file still coming in is waited for (`ChatVideoAsset`); one that still gave no frame is asked again a
/// while later rather than never, so a video that came in late gets its picture too.
@MainActor
enum ChatVideoStills {
    struct Still {
        var image: NSImage?
        var seconds: Double?
    }

    /// How long a video that gave no frame is left alone before it is tried again.
    private static let retry: TimeInterval = 30

    private final class Box {
        let still: Still
        init(_ still: Still) { self.still = still }
    }

    /// The stills made, up to 32 MB of pictures (a 640-pixel still is about 1.6 MB); one that went is read back from disk.
    private static let stills: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.totalCostLimit = 32 * 1024 * 1024
        MemoryPressure.shared.register("chatVideoStills", emptying: cache)
        return cache
    }()
    private static var failed: [URL: Date] = [:]
    /// The stills being made, by video: the bubble and the warm-up of its chat (`ChatMediaWarmup`) share one.
    private static var making: [URL: Task<Still, Never>] = [:]

    /// The still when it was made before, without making it: a bubble shows it in its first frame.
    static func cached(_ url: URL) -> Still? { stills.object(forKey: url as NSURL)?.still }

    static func still(_ url: URL) async -> Still {
        if let known = cached(url) { return known }
        if let running = making[url] { return await running.value }
        if let at = failed[url], Date().timeIntervalSince(at) < retry { return Still() }
        let task = Task { await make(url) }
        making[url] = task
        let still = await task.value
        making[url] = nil
        if still.image == nil {
            if !Task.isCancelled { failed[url] = Date() }
        } else {
            stills.setObject(Box(still), forKey: url as NSURL, cost: still.image.map(DecodedImage.cost) ?? 0)
            failed[url] = nil
        }
        return still
    }

    /// The still from disk when it was made on an earlier launch (`ChatPictureDisk`), else from the video itself.
    private static func make(_ url: URL) async -> Still {
        let stored = ChatPictureDisk.key(url, variant: "still-640", always: true)
        if let stored, let image = await Task.detached(priority: .userInitiated, operation: { ChatPictureDisk.image(stored) }).value {
            return Still(image: image, seconds: ChatPictureDisk.seconds(stored))
        }
        guard let asset = await ChatVideoAsset.load(url) else { return Still() }
        let seconds = try? await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let at = CMTime(seconds: min(0.5, (seconds ?? 1) / 2), preferredTimescale: 600)
        let image = (try? await generator.image(at: at).image).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        let still = Still(image: image, seconds: seconds.flatMap { $0.isFinite ? $0 : nil })
        // Filed under the file as it is now: it may have grown while it was waited for.
        if let image, let settled = ChatPictureDisk.key(url, variant: "still-640", always: true) {
            ChatPictureDisk.store(image, key: settled, seconds: still.seconds)
        }
        return still
    }
}
