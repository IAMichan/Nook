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

    /// Decoded once at full size, for a sent picture in the chat (`ChatMessagePicture`).
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

    /// At most 256 pixels on the longest side: sharp at the size of the composer's strip on a Retina screen.
    static func makeThumbnail(_ data: Data) -> NSImage? {
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

    /// Builds attachments on `encoder` and hands them to `done` on the main thread, also when none could be made (so a
    /// caller that waits for them knows the wait is over).
    private static func encodeOffMain(_ make: @escaping () -> [ImageAttachment], done: @escaping ([ImageAttachment]) -> Void) {
        encoder.async {
            let made = make()
            DispatchQueue.main.async { done(made) }
        }
    }

    /// The pictures on the clipboard: copied image files, or image data (a screenshot, "Copy Image" in a browser). Text on
    /// the clipboard, or other files, are left alone so pasting those keeps working as before. Whether the paste is a
    /// picture is decided now (the key is claimed or passed on right away); the pictures reach `done` once encoded, and
    /// `done` is called exactly once for a claimed paste, with none when the picture could not be read.
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

    /// Copied files on the clipboard that are not pictures; pasting them attaches them like a drop.
    static func nonImageFiles(_ pasteboard: NSPasteboard = .general) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { !isImageFile($0) }
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
                    DispatchQueue.main.async { take(url, images: images, file: file) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                loadImage(from: provider, into: images)
            }
        }
        return handled
    }

    /// One file on this Mac: a picture goes to `images` once encoded, anything else (a folder too) to `file`.
    static func take(_ url: URL, images: @escaping ([ImageAttachment]) -> Void, file: @escaping (URL) -> Void) {
        guard isImageFile(url) else { return file(url) }
        encoder.async {
            let image = ImageAttachment(url: url)
            DispatchQueue.main.async {
                if let image { images([image]) } else { file(url) }
            }
        }
    }

    private static func loadImage(from provider: NSItemProvider, into images: @escaping ([ImageAttachment]) -> Void) {
        guard provider.canLoadObject(ofClass: NSImage.self) else { return }
        let name = tr("image.dropped")
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            guard let image = object as? NSImage else { return }
            encodeOffMain({ ImageAttachment(image: image, name: name).map { [$0] } ?? [] }) { made in
                if !made.isEmpty { images(made) }
            }
        }
    }

    // MARK: For agents

    /// Agents read pictures from disk: the picture is saved in Nook's folder and its path is what the agent gets.
    func writeToDisk() -> URL? {
        let url = diskURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The picture as a file: the one already saved for an agent, else saved now (to open it big or in Quick Look).
    func storedURL() -> URL? {
        FileManager.default.fileExists(atPath: diskURL.path) ? diskURL : writeToDisk()
    }

    private var diskURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.prefix(8).lowercased()).\(fileExtension)")
    }

    /// The text with the paths of the pictures below it, one per line.
    static func appendingPaths(of images: [ImageAttachment], to text: String) -> String {
        let paths = images.compactMap { $0.writeToDisk()?.path }
        guard !paths.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + paths.joined(separator: "\n")
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// Whether this file reads as a picture by its name, without opening it.
    static func isPicture(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// The reverse of `appendingPaths`: the picture paths at the end of a sent message, split off its text, so the chat
    /// shows the pictures instead of their paths.
    static func splittingPaths(from text: String) -> (text: String, images: [URL]) {
        let parts = splittingAttachments(from: text, exists: { _ in false })
        return (parts.text, parts.images)
    }

    /// The pictures, files and folders at the end of a sent message, each path on a line of its own, split off its text
    /// (`ContextRefs.timeline` writes them so). A path that is not a picture only counts when it is there on disk.
    static func splittingAttachments(from text: String,
                                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (text: String, images: [URL], files: [URL]) {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var images: [URL] = []
        var files: [URL] = []
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            let path = line.count > 1 && line.hasPrefix("\"") && line.hasSuffix("\"") ? String(line.dropFirst().dropLast()) : line
            guard path.hasPrefix("/"), path.count > 1 else { break }
            let url = URL(fileURLWithPath: path)
            if isPicture(url) {
                images.insert(url, at: 0)
            } else if exists(path) {
                files.insert(url, at: 0)
            } else {
                break
            }
            lines.removeLast()
        }
        guard !images.isEmpty || !files.isEmpty else { return (text, [], []) }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), images, files)
    }
}

/// The pictures of a message sent to an agent, read from disk and shown above its bubble (`ChatMessagePicture`).
struct MessagePictures: View {
    let urls: [URL]

    var body: some View {
        ChipFlow(spacing: NookTheme.Spacing.sm) {
            ForEach(urls, id: \.self) { url in
                MessagePicture(url: url)
            }
        }
    }
}

/// The files and folders sent with a message to an agent, above its bubble as the pictures are: the same tiles the
/// composer showed while they waited to go.
struct MessageFiles: View {
    let urls: [URL]

    var body: some View {
        ChipFlow(spacing: NookTheme.Spacing.sm) {
            ForEach(urls, id: \.self) { url in
                ComposerFileTile(label: url.lastPathComponent, url: url)
            }
        }
    }
}

private struct MessagePicture: View {
    let url: URL
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        ChatMessagePicture(image: image, missing: missing, name: url.lastPathComponent) { url }
            .task(id: url) {
                let url = url
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                let loaded = data.flatMap { NSImage(data: $0) }
                image = loaded
                missing = loaded == nil
            }
    }
}

/// A picture in a message to an agent or to Nook: whole, in its own shape, a little smaller than its own size. A click
/// opens it big, as a chat's photo does (`ImageModalButton`).
struct ChatMessagePicture: View {
    let image: NSImage?
    var missing = false
    let name: String
    /// The picture as a file on this Mac, asked for when it opens.
    let file: () -> URL?

    static let maxWidth: CGFloat = 280
    static let maxHeight: CGFloat = 240
    /// How much smaller than its own size a picture is shown.
    static let scale: CGFloat = 0.75

    /// Three quarters of the picture's own size, fitted inside `maxWidth × maxHeight`.
    static func size(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let factor = min(scale, maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
    }

    var body: some View {
        ImageModalButton(name: name, preview: image, file: file) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .fittedMedia(Self.size(for: image.size))
                } else {
                    Image(icon: missing ? "photo.badge.exclamationmark" : "photo")
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 96, height: 96)
                        .background(NookTheme.smoke)
                }
            }
            .roundedClip(NookTheme.Radius.card)
        }
    }
}

/// Corner badge indicating that a chat picture can be enlarged or shrunk back to its normal size.
struct ChatPictureSizeBadge: View {
    let enlarged: Bool

    var body: some View {
        Image(icon: enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            .font(NookTheme.font(10, .semibold))
            .foregroundStyle(NookTheme.paper)
            .frame(width: 24, height: 24)
            .background(Circle().fill(NookTheme.ink.opacity(0.65)))
            .padding(NookTheme.Spacing.sm)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A file, folder or picture dragged over a composer. `hovering` shows the empty place it would land in. Dropped, the
/// pictures take a moment to encode, so `landing` keeps the row open until they are in; without it the box would shrink
/// and grow again under the pointer.
struct ComposerDrop: Equatable {
    var hovering = false
    var landing = false

    /// The row above the text is open for what is coming.
    var open: Bool { hovering || landing }

    fileprivate static let landingTime = 0.4
}

extension View {
    /// `onDrop` for a composer, keeping `drop` up to date for `ComposerDropSlot`. The area must hold the slot as well
    /// as the field: when the row opens the field moves, and the pointer must not end up outside the drop area.
    func composerDrop(of types: [UTType], _ drop: Binding<ComposerDrop>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        onDrop(of: types, isTargeted: drop.hovering) { providers in
            guard perform(providers) else { return false }
            drop.wrappedValue.landing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + ComposerDrop.landingTime) { drop.wrappedValue.landing = false }
            return true
        }
    }
}

/// The empty place in a composer's row of attachments while something is dragged over it, the size of the tile it
/// becomes, so the box is already as tall as it will be and nothing jumps on the drop.
struct ComposerDropSlot: View {
    var tint = NookTheme.iris
    var side: CGFloat = 56

    private var shape: RoundedRectangle {
        NookTheme.shape(NookTheme.Radius.card)
    }

    var body: some View {
        Image(icon: "plus")
            .font(NookTheme.font(16, .medium))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(shape.fill(tint.opacity(0.12)))
            .overlay(shape.strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

/// The pictures and files above the text field, each with a small remove button; a click on a picture enlarges it
/// (`ImageModalButton`). A file shows its first page (or its icon) with its type written across it, so you see what it
/// is instead of its path.
struct ImageAttachmentStrip: View {
    let images: [ImageAttachment]
    var files: [ContextRefs.Found] = []
    /// The folder relative file references start from.
    var fileRoot: String? = nil
    /// While something is dragged over the composer: the tint of the empty place after the tiles (`ComposerDropSlot`).
    var dropSlot: Color? = nil
    let remove: (ImageAttachment) -> Void
    var removeFile: (Int) -> Void = { _ in }

    private static let slotID = "drop-slot"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        ZStack(alignment: .topTrailing) {
                            thumbnail(image)
                            removeButton { remove(image) }
                        }
                    }
                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        ZStack(alignment: .topTrailing) {
                            ComposerFileTile(label: file.label, paste: file.kind == .paste, url: url(of: file))
                            removeButton { removeFile(index) }
                        }
                    }
                    if let dropSlot {
                        ComposerDropSlot(tint: dropSlot).id(Self.slotID)
                    }
                }
            }
            // With a full row the empty place would be out of sight.
            .onChange(of: dropSlot != nil) { _, shown in
                if shown { proxy.scrollTo(Self.slotID, anchor: .trailing) }
            }
        }
        .frame(height: 56)
    }

    private func url(of file: ContextRefs.Found) -> URL? {
        guard file.kind == .file else { return nil }
        if file.id.hasPrefix("/") { return URL(fileURLWithPath: file.id) }
        guard let fileRoot else { return nil }
        return URL(fileURLWithPath: fileRoot, isDirectory: true).appendingPathComponent(file.id)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: "xmark")
                .font(NookTheme.font(8, .bold))
                .foregroundStyle(NookTheme.paper)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(0.7)))
        }
        .buttonStyle(.nookPlain)
        .padding(3)
        .accessibilityLabel(tr("image.remove"))
    }

    private func thumbnail(_ image: ImageAttachment) -> some View {
        ImageModalButton(name: image.name, preview: image.thumbnail, file: { image.storedURL() }) {
            Group {
                if let thumbnail = image.thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(icon: "photo").foregroundStyle(NookTheme.textTertiary)
                }
            }
            .frame(width: 56, height: 56)
            .background(NookTheme.smoke)
            .roundedClip(NookTheme.Radius.card)
        }
    }
}

/// A file or folder going out with a message: its preview (a picture, a document's first page, else the Finder icon),
/// dimmed, with its type ("PDF", "JPG", "FOLDER") across it like a watermark.
struct ComposerFileTile: View {
    let label: String
    /// Text you pasted, kept out of the box: a "TXT" tile without a file behind it.
    var paste = false
    let url: URL?
    @State private var preview: NSImage?
    @State private var isFolder = false

    private var type: String {
        if isFolder { return tr("compose.folder.type") }
        let ext = URL(fileURLWithPath: label).pathExtension
        if paste || ext.isEmpty { return paste ? "TXT" : tr("compose.file.type") }
        return String(ext.uppercased().prefix(5))
    }

    var body: some View {
        if let url, ImageAttachment.isPicture(url) {
            ImageModalButton(name: label, preview: preview, file: { url }) { tile }
        } else {
            tile
        }
    }

    private var tile: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview).resizable().scaledToFill()
            } else {
                Image(icon: paste ? "doc.plaintext" : "doc")
                    .font(NookTheme.font(22, .regular))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            NookTheme.ink.opacity(0.45)
            Text(type)
                .font(NookTheme.font(13, .heavy))
                .foregroundStyle(NookTheme.paper.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, NookTheme.Spacing.xs)
        }
        .frame(width: 56, height: 56)
        .background(NookTheme.smoke)
        .roundedClip(NookTheme.Radius.card)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .task(id: url) {
            guard let url else { return }
            let kind = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            isFolder = kind?.isDirectory == true && kind?.isPackage != true
            if isFolder {
                preview = NSWorkspace.shared.icon(forFile: url.path)
            } else if let image = await ChatFileThumbnails.shared.image(url, kind: .file) {
                preview = image
            } else if FileManager.default.fileExists(atPath: url.path) {
                preview = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
}

/// The pictures in a message sent to Nook, shown as an agent's are (`ChatMessagePicture`).
struct ImageMessageRow: View {
    let images: [ImageAttachment]

    var body: some View {
        ChipFlow(spacing: NookTheme.Spacing.sm) {
            ForEach(images) { attachment in
                ChatMessagePicture(image: attachment.fullImage ?? attachment.thumbnail, name: attachment.name) {
                    attachment.storedURL()
                }
            }
        }
    }
}
