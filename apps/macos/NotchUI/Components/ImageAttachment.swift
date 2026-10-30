import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A picture added to a message by dragging, pasting or choosing it. Big pictures are scaled down first, so a screenshot
/// of a Retina screen stays small enough for a model and for the chat.
struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let data: Data
    let mediaType: String

    /// The longest side a model needs; more only costs tokens.
    static let maxEdge: CGFloat = 1568

    var base64: String { data.base64EncodedString() }
    /// Decoded once per picture, at thumbnail size: the strip above the composer redraws on every keystroke and a sent
    /// message on every redraw of the chat, and decoding the full picture (up to 1568 pixels) each time was the cost.
    var thumbnail: NSImage? {
        let key = id as NSUUID
        if let known = Self.thumbnails.object(forKey: key) { return known }
        guard let made = Self.makeThumbnail(data) else { return nil }
        Self.thumbnails.setObject(made, forKey: key)
        return made
    }

    /// Decoded once at full size when a sent picture is enlarged in the chat.
    var fullImage: NSImage? {
        let key = id as NSUUID
        if let known = Self.fullImages.object(forKey: key) { return known }
        guard let made = NSImage(data: data) else { return nil }
        Self.fullImages.setObject(made, forKey: key)
        return made
    }

    /// Proportional size for an enlarged chat picture: uncropped, fitted inside `maxWidth × maxHeight`, and at least
    /// `minEdge` on its longest side so even a small picture visibly grows when clicked.
    static func enlargedSize(
        for image: NSImage,
        maxWidth: CGFloat = 520,
        maxHeight: CGFloat = 420,
        minEdge: CGFloat = 240
    ) -> CGSize {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let maxScale = min(maxWidth / width, maxHeight / height)
        let minScale = minEdge / max(width, height)
        let scale = min(maxScale, max(1, minScale))
        return CGSize(width: max(1, round(width * scale)), height: max(1, round(height * scale)))
    }

    private static let thumbnails: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    private static let fullImages: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 40
        return cache
    }()

    /// At most 256 pixels on the longest side: sharp at the 96-point size of a sent picture on a Retina screen.
    private static func makeThumbnail(_ data: Data) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return NSImage(data: data) }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    var fileExtension: String { mediaType == "image/png" ? "png" : "jpg" }

    init?(image: NSImage, name: String) {
        guard let encoded = Self.encode(image) else { return nil }
        self.name = name
        self.data = encoded.data
        self.mediaType = encoded.mediaType
    }

    init?(url: URL) {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let image = NSImage(contentsOf: url) else { return nil }
        self.init(image: image, name: url.lastPathComponent)
    }

    // MARK: Encoding

    private static func encode(_ image: NSImage) -> (data: Data, mediaType: String)? {
        guard let tiff = image.tiffRepresentation, var rep = NSBitmapImageRep(data: tiff) else { return nil }
        let longest = CGFloat(max(rep.pixelsWide, rep.pixelsHigh))
        if longest > maxEdge, let scaled = scale(rep, by: maxEdge / longest) { rep = scaled }
        if rep.hasAlpha, let png = rep.representation(using: .png, properties: [:]) { return (png, "image/png") }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return (jpeg, "image/jpeg")
    }

    private static func scale(_ rep: NSBitmapImageRep, by factor: CGFloat) -> NSBitmapImageRep? {
        let width = max(1, Int(CGFloat(rep.pixelsWide) * factor))
        let height = max(1, Int(CGFloat(rep.pixelsHigh) * factor))
        let alpha = rep.hasAlpha
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // MARK: Getting pictures in

    /// Scaling and encoding a picture takes a moment for a big screenshot: it runs here, off the main thread, one at a
    /// time so pictures arrive in the order they came.
    private static let encoder = DispatchQueue(label: "nook.image-attachment", qos: .userInitiated)

    /// Builds attachments on `encoder` and hands them to `done` on the main thread; none are handed on when none came.
    private static func encodeOffMain(_ make: @escaping () -> [ImageAttachment], done: @escaping ([ImageAttachment]) -> Void) {
        encoder.async {
            let made = make()
            guard !made.isEmpty else { return }
            DispatchQueue.main.async { done(made) }
        }
    }

    /// The pictures on the clipboard: copied image files, or image data (a screenshot, "Copy Image" in a browser). Text on
    /// the clipboard, or other files, are left alone so pasting those keeps working as before. Whether the paste is a
    /// picture is decided now (the key is claimed or passed on right away); the pictures reach `done` once encoded.
    @discardableResult
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general, done: @escaping ([ImageAttachment]) -> Void) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let pictures = urls.filter(isImageFile)
            guard !pictures.isEmpty else { return false }
            encodeOffMain({ pictures.compactMap { ImageAttachment(url: $0) } }, done: done)
            return true
        }
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) else { return false }
        let name = tr("image.pasted")
        encodeOffMain({ ImageAttachment(image: image, name: name).map { [$0] } ?? [] }, done: done)
        return true
    }

    /// The same test `init?(url:)` starts with, without reading the file.
    private static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Handles what was dropped: pictures go to `images`, any other file to `file`. Returns whether anything can be read.
    @discardableResult
    static func receive(_ providers: [NSItemProvider], images: @escaping ([ImageAttachment]) -> Void, file: @escaping (URL) -> Void) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    guard url.isFileURL else {
                        DispatchQueue.main.async { loadImage(from: provider, into: images) }
                        return
                    }
                    guard isImageFile(url) else {
                        DispatchQueue.main.async { file(url) }
                        return
                    }
                    encoder.async {
                        let image = ImageAttachment(url: url)
                        DispatchQueue.main.async {
                            if let image { images([image]) } else { file(url) }
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                loadImage(from: provider, into: images)
            }
        }
        return handled
    }

    private static func loadImage(from provider: NSItemProvider, into images: @escaping ([ImageAttachment]) -> Void) {
        guard provider.canLoadObject(ofClass: NSImage.self) else { return }
        let name = tr("image.dropped")
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            guard let image = object as? NSImage else { return }
            encodeOffMain({ ImageAttachment(image: image, name: name).map { [$0] } ?? [] }, done: images)
        }
    }

    // MARK: For agents

    /// Agents read pictures from disk: the picture is saved in Nook's folder and its path is what the agent gets.
    func writeToDisk() -> URL? {
        let dir = NookPaths.supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("\(id.uuidString.prefix(8).lowercased()).\(fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The text with the paths of the pictures below it, one per line.
    static func appendingPaths(of images: [ImageAttachment], to text: String) -> String {
        let paths = images.compactMap { $0.writeToDisk()?.path }
        guard !paths.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + paths.joined(separator: "\n")
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// The reverse of `appendingPaths`: the picture paths at the end of a sent message, split off its text, so the chat
    /// shows the pictures instead of their paths.
    static func splittingPaths(from text: String) -> (text: String, images: [URL]) {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var images: [URL] = []
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            let path = line.count > 1 && line.hasPrefix("\"") && line.hasSuffix("\"") ? String(line.dropFirst().dropLast()) : line
            guard path.hasPrefix("/"), imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { break }
            images.insert(URL(fileURLWithPath: path), at: 0)
            lines.removeLast()
        }
        guard !images.isEmpty else { return (text, []) }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), images)
    }
}

/// The pictures of a message sent to an agent, read from disk and shown above its bubble. A click enlarges a picture in
/// place, and clicking it again shrinks it back to its normal size.
struct MessagePictures: View {
    let urls: [URL]
    @State private var enlargedURLs: Set<URL> = []

    var body: some View {
        let layout = enlargedURLs.isEmpty
            ? AnyLayout(HStackLayout(spacing: NookTheme.Spacing.sm))
            : AnyLayout(VStackLayout(alignment: .trailing, spacing: NookTheme.Spacing.sm))
        layout { items }
    }

    private var items: some View {
        ForEach(urls, id: \.self) { url in
            MessagePicture(url: url, enlarged: enlargedURLs.contains(url)) {
                withAnimation(NookTheme.reveal) {
                    if enlargedURLs.contains(url) {
                        enlargedURLs.remove(url)
                    } else {
                        enlargedURLs.insert(url)
                    }
                }
            }
        }
    }
}

private struct MessagePicture: View {
    let url: URL
    let enlarged: Bool
    let toggle: () -> Void
    @State private var image: NSImage?
    @State private var missing = false
    @State private var hovering = false

    private var label: String {
        enlarged ? tr("button.shrink") : tr("button.enlarge")
    }

    var body: some View {
        Button {
            if image != nil { toggle() }
        } label: {
            ZStack(alignment: .topTrailing) {
                if let image {
                    if enlarged {
                        let size = ImageAttachment.enlargedSize(for: image)
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: size.width, maxHeight: size.height)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 120)
                    }
                } else {
                    Image(systemName: missing ? "photo.badge.exclamationmark" : "photo")
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 120, height: 120)
                }
                if image != nil && (hovering || enlarged) {
                    ChatPictureSizeBadge(enlarged: enlarged)
                }
            }
            .background(NookTheme.smoke)
            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if !missing {
                Button { toggle() } label: {
                    Label(label, systemImage: enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                Button { NSWorkspace.shared.open(url) } label: {
                    Label(tr("card.attachment.open"), systemImage: "arrow.up.forward.app")
                }
            }
        }
        .help(image == nil ? url.lastPathComponent : label)
        .accessibilityLabel(image == nil ? url.lastPathComponent : "\(label): \(url.lastPathComponent)")
        .task(id: url) {
            let url = url
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            let loaded = data.flatMap { NSImage(data: $0) }
            image = loaded
            missing = loaded == nil
        }
    }
}

/// Corner badge indicating that a chat picture can be enlarged or shrunk back to its normal size.
struct ChatPictureSizeBadge: View {
    let enlarged: Bool

    var body: some View {
        Image(systemName: enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            .font(NookTheme.font(10, .semibold))
            .foregroundStyle(NookTheme.paper)
            .frame(width: 24, height: 24)
            .background(Circle().fill(NookTheme.ink.opacity(0.65)))
            .padding(NookTheme.Spacing.sm)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The pictures above the text field, each with a small remove button.
struct ImageAttachmentStrip: View {
    let images: [ImageAttachment]
    let remove: (ImageAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        thumbnail(image)
                        Button { remove(image) } label: {
                            Image(systemName: "xmark")
                                .font(NookTheme.font(8, .bold))
                                .foregroundStyle(NookTheme.paper)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .accessibilityLabel(tr("image.remove"))
                    }
                }
            }
        }
        .frame(height: 56)
    }

    private func thumbnail(_ image: ImageAttachment) -> some View {
        Group {
            if let thumbnail = image.thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(NookTheme.textTertiary)
            }
        }
        .frame(width: 56, height: 56)
        .background(NookTheme.smoke)
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
        .help(image.name)
    }
}

/// The pictures in a sent message: clicking a picture enlarges it in place, and clicking it again shrinks it back.
struct ImageMessageRow: View {
    let images: [ImageAttachment]
    @State private var enlargedIDs: Set<UUID> = []

    var body: some View {
        let layout = enlargedIDs.isEmpty
            ? AnyLayout(HStackLayout(spacing: NookTheme.Spacing.sm))
            : AnyLayout(VStackLayout(alignment: .trailing, spacing: NookTheme.Spacing.sm))
        layout { items }
    }

    private var items: some View {
        ForEach(images) { attachment in
            SentAttachmentPicture(attachment: attachment, enlarged: enlargedIDs.contains(attachment.id)) {
                withAnimation(NookTheme.reveal) {
                    if enlargedIDs.contains(attachment.id) {
                        enlargedIDs.remove(attachment.id)
                    } else {
                        enlargedIDs.insert(attachment.id)
                    }
                }
            }
        }
    }
}

private struct SentAttachmentPicture: View {
    let attachment: ImageAttachment
    let enlarged: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var label: String {
        enlarged ? tr("button.shrink") : tr("button.enlarge")
    }

    var body: some View {
        if let displayImage = (enlarged ? attachment.fullImage : nil) ?? attachment.thumbnail {
            Button(action: toggle) {
                ZStack(alignment: .topTrailing) {
                    if enlarged {
                        let size = ImageAttachment.enlargedSize(for: displayImage)
                        Image(nsImage: displayImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: size.width, maxHeight: size.height)
                    } else {
                        Image(nsImage: displayImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                    }
                    if hovering || enlarged {
                        ChatPictureSizeBadge(enlarged: enlarged)
                    }
                }
                .background(NookTheme.smoke)
                .clipShape(RoundedRectangle(cornerRadius: enlarged ? NookTheme.Radius.panel : NookTheme.Radius.card, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(label)
            .accessibilityLabel("\(label): \(attachment.name)")
        }
    }
}
