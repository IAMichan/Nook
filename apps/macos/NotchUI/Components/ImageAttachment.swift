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

    private static let thumbnails: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 200
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

    /// The pictures on the clipboard: copied image files, or image data (a screenshot, "Copy Image" in a browser). Text on
    /// the clipboard, or other files, are left alone so pasting those keeps working as before.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [ImageAttachment] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { ImageAttachment(url: $0) }
        }
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard),
              let attachment = ImageAttachment(image: image, name: tr("image.pasted")) else { return [] }
        return [attachment]
    }

    /// Handles what was dropped: pictures go to `images`, any other file to `file`. Returns whether anything can be read.
    @discardableResult
    static func receive(_ providers: [NSItemProvider], images: @escaping ([ImageAttachment]) -> Void, file: @escaping (URL) -> Void) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        guard let url else { return }
                        if !url.isFileURL {
                            loadImage(from: provider, into: images)
                        } else if let image = ImageAttachment(url: url) {
                            images([image])
                        } else {
                            file(url)
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
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            DispatchQueue.main.async {
                guard let image = object as? NSImage, let attachment = ImageAttachment(image: image, name: tr("image.dropped")) else { return }
                images([attachment])
            }
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

/// The pictures of a message sent to an agent, read from disk and shown above its bubble. A click opens the picture.
struct MessagePictures: View {
    let urls: [URL]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(urls, id: \.self) { url in
                MessagePicture(url: url)
            }
        }
    }
}

private struct MessagePicture: View {
    let url: URL
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: missing ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .frame(width: 120, height: 120)
        .background(NookTheme.smoke)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !missing { NSWorkspace.shared.open(url) } }
        .help(url.lastPathComponent)
        .task(id: url) {
            let url = url
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            let loaded = data.flatMap { NSImage(data: $0) }
            image = loaded
            missing = loaded == nil
        }
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
                                .font(.system(size: 8, weight: .bold))
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
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help(image.name)
    }
}

/// The pictures in a sent message.
struct ImageMessageRow: View {
    let images: [ImageAttachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(images) { image in
                if let thumbnail = image.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .help(image.name)
                }
            }
        }
    }
}
