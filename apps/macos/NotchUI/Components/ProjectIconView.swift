import SwiftUI
import AppKit

/// A project's icon where projects are listed (the composer's project menu, the session list's project headers,
/// Settings › Projects): its emoji, its monogram on a tint, or its image, else the folder symbol.
struct ProjectIconView: View {
    let icon: ProjectIcon?
    var size: CGFloat = 15
    /// Drawn without an icon of the project's own.
    var symbol = "folder"

    var body: some View {
        Group {
            switch icon {
            case .emoji(let emoji)?:
                Text(emoji).font(NookTheme.font(size * 0.9))
            case .monogram(let letters, let tint)?:
                let color = Self.color(tint)
                Text(letters)
                    .font(NookTheme.font(size * (letters.count > 1 ? 0.5 : 0.62), .bold))
                    .foregroundStyle(color)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip * size / 24, style: .continuous)
                        .fill(color.opacity(0.22)))
            case .image(let path)?:
                if let image = ProjectIconImages.image(path) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.chip * size / 24, style: .continuous))
                } else {
                    Image(systemName: symbol).font(NookTheme.font(size * 0.85, .medium))
                }
            case nil:
                Image(systemName: symbol).font(NookTheme.font(size * 0.85, .medium))
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
