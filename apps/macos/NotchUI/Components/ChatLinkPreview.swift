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

    private var host: String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: { card }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(NookTheme.hover, value: hovering)
            .help(url.absoluteString)
            .accessibilityLabel((preview?.title).map { "\($0), \(host)" } ?? host)
            .task(id: url) { preview = await ChatLinkPreviews.shared.preview(url) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            picture
            caption
        }
        .frame(width: Self.width)
        .background(NookTheme.ink.opacity(hovering ? 0.45 : 0.32))
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
            .strokeBorder(NookTheme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    /// The page's picture, 16:9, with a play mark for a video page.
    @ViewBuilder
    private var picture: some View {
        if let image = preview?.image {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: Self.width * 9 / 16)
                    .clipped()
                if ChatFormat.isVideoPage(url) { playMark }
            }
        }
    }

    private var playMark: some View {
        Image(systemName: "play.fill")
            .font(NookTheme.font(16, .semibold))
            .foregroundStyle(NookTheme.paper)
            .frame(width: 42, height: 42)
            .background(Circle().fill(NookTheme.ink.opacity(0.55)))
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
                            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
                        if hovering || enlarged {
                            ChatPictureSizeBadge(enlarged: enlarged)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .fill(NookTheme.ink.opacity(0.3))
                    .frame(width: PhotoButton.maxWidth, height: PhotoButton.maxHeight * 0.75)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            file = await ChatLinkPreviews.shared.file(url)
            failed = file == nil
        }
    }
}

/// What Nook knows of the links in chats: each page's title and picture, and the pictures links point at, fetched once
/// and kept for as long as Nook runs (the pictures in its caches folder). Only addresses that are in a message you see
/// are asked, one time each.
@MainActor
final class ChatLinkPreviews {
    static let shared = ChatLinkPreviews()

    struct Preview {
        var title: String?
        var image: NSImage?
    }

    private var previews: [URL: Preview] = [:]
    private var loading: [URL: Task<Preview, Never>] = [:]
    private var files: [URL: URL] = [:]
    private var fetching: [URL: Task<URL?, Never>] = [:]

    /// The largest picture a link may bring in.
    nonisolated private static let maxBytes = 12_000_000

    func preview(_ url: URL) async -> Preview {
        if let known = previews[url] { return known }
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
        previews[url] = preview
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
                continuation.resume(returning: data.flatMap(NSImage.init(data:)))
            }
        }
    }
}

/// A frame of a video and how long it lasts, read once per video: a video whose app sent no picture of it still shows
/// what it is.
@MainActor
enum ChatVideoStills {
    struct Still {
        var image: NSImage?
        var seconds: Double?
    }

    private static var stills: [URL: Still] = [:]

    static func still(_ url: URL) async -> Still {
        if let known = stills[url] { return known }
        let asset = AVURLAsset(url: url)
        let seconds = try? await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let at = CMTime(seconds: min(0.5, (seconds ?? 1) / 2), preferredTimescale: 600)
        let image = (try? await generator.image(at: at).image).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        let still = Still(image: image, seconds: seconds.flatMap { $0.isFinite ? $0 : nil })
        stills[url] = still
        return still
    }
}
