import SwiftUI
import AppKit

/// A project's icon where projects are listed (the composer's project menu, the session list's rows and project headers,
/// Settings › Projects): the icon you set (emoji, monogram on a tint, or image); else, given the project's `folder`, the
/// project's own favicon or app icon (`ProjectFavicons`, as t3code's); else `fallback`, else the folder symbol.
struct ProjectIconView: View {
    let icon: ProjectIcon?
    var size: CGFloat = 15
    /// The project's folder on this Mac: its own icon shows when you set none.
    var folder: String? = nil
    /// Drawn when the project has no icon at all (the session list's initials); nil for the folder symbol.
    var fallback: ProjectIcon? = nil
    /// Drawn without an icon of the project's own.
    var symbol = "folder"
    @ObservedObject private var favicons = ProjectFavicons.shared

    var body: some View {
        if icon == nil, let folder, let image = favicons.image(for: folder) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .roundedClip(NookTheme.Radius.chip * size / 24)
                .accessibilityHidden(true)
        } else {
            drawn(icon ?? fallback)
        }
    }

    private func drawn(_ icon: ProjectIcon?) -> some View {
        Group {
            switch icon {
            case .emoji(let emoji)?:
                Text(emoji).font(NookTheme.font(size * 0.9))
            case .monogram(let letters, let tint)?:
                let color = Self.color(tint)
                Text(letters)
                    // Large enough to read in a list: two letters fill most of the tile, one a bit more.
                    .font(NookTheme.font(size * (letters.count > 1 ? 0.56 : 0.66), .bold))
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(color)
                    .frame(width: size, height: size)
                    .roundedBackground(color.opacity(0.22), radius: NookTheme.Radius.chip * size / 24)
            case .image(let path)?:
                if let image = ProjectIconImages.image(path) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .roundedClip(NookTheme.Radius.chip * size / 24)
                } else {
                    Image(icon: symbol).font(NookTheme.font(size * 0.85, .medium))
                }
            case nil:
                Image(icon: symbol).font(NookTheme.font(size * 0.85, .medium))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func color(_ tint: ProjectIcon.Tint) -> Color {
        switch tint {
        case .mint: return NookTheme.mint
        case .amber: return NookTheme.amber
        case .coral: return NookTheme.coral
        case .violet: return NookTheme.violet
        case .blue: return NookTheme.blue
        case .music: return NookTheme.music
        }
    }
}

/// Image icons, read once per file and kept small; a list that redraws never reads the file again.
@MainActor
enum ProjectIconImages {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func image(_ path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// The projects' own icons (`ProjectFavicon`), looked up once per folder off the main thread and kept as small pictures,
/// for the session list's project badges. A folder without one is remembered too, and looked at again after ten minutes,
/// so a favicon added later shows up.
@MainActor
final class ProjectFavicons: ObservableObject {
    static let shared = ProjectFavicons()

    private enum Entry { case found(NSImage), none(Date), loading }
    /// Not published: a view asking starts a lookup, and changing published state while a view draws is not allowed.
    /// Only a finished lookup bumps `version`, which redraws the badges.
    private var entries: [String: Entry] = [:]
    @Published private var version = 0
    private static let retryAfter: TimeInterval = 10 * 60
    /// Drawn at most 20 pt, so 64 px covers a Retina screen at three times.
    private static let pixels: CGFloat = 64

    /// The project's icon when it has one; the first ask starts the lookup and returns nil until it is done.
    func image(for root: String) -> NSImage? {
        switch entries[root] {
        case .found(let image)?: return image
        case .loading?: return nil
        case .none(let at)? where Date().timeIntervalSince(at) < Self.retryAfter: return nil
        default: break
        }
        entries[root] = .loading
        Task.detached(priority: .utility) {
            let image = ProjectFavicon.find(in: root).flatMap(Self.thumbnail)
            await MainActor.run {
                self.entries[root] = image.map { .found($0) } ?? .none(Date())
                if image != nil { self.version += 1 }
            }
        }
        return nil
    }

    /// The file drawn once into a small square bitmap, so a list never holds a large `.icns` or decodes it again.
    nonisolated private static func thumbnail(_ path: String) -> NSImage? {
        guard let source = NSImage(contentsOfFile: path), source.size.width > 0, source.size.height > 0 else { return nil }
        let side = pixels
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Fit, centered: a wide logo keeps its shape.
        let scale = min(side / source.size.width, side / source.size.height)
        let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        source.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}
