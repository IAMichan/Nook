import SwiftUI
import AppKit

/// The small symbol for a kind of file, as an editor's file tree shows it: a React atom for `.tsx`, braces for
/// `.json`, a terminal for a shell script. An agent's answer puts it before each file it links, so a list of changed
/// files reads at a glance. The shape tells the kind; every glyph is the same quiet grey, so a reply full of paths stays
/// black and white and color is left for state.
enum FileTypeGlyph {
    struct Glyph: Equatable {
        let symbol: String
        let color: Color
    }

    /// The glyph for a file name or path (`src/App.tsx`, `nl.json:12`); a folder for a path that ends in a slash.
    static func glyph(for path: String) -> Glyph {
        if path.hasSuffix("/") { return Glyph(symbol: "folder", color: NookTheme.textSecondary) }
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile": return Glyph(symbol: "shippingbox", color: NookTheme.textSecondary)
        case "makefile", "justfile": return Glyph(symbol: "hammer", color: NookTheme.textSecondary)
        case "license", "licence": return Glyph(symbol: "checkmark.seal", color: NookTheme.textSecondary)
        default: break
        }
        if name.hasPrefix(".env") { return Glyph(symbol: "key", color: NookTheme.textSecondary) }
        if name.hasPrefix(".git") { return Glyph(symbol: "arrow.triangle.branch", color: NookTheme.textSecondary) }
        switch (name as NSString).pathExtension {
        case "tsx", "jsx": return Glyph(symbol: "atom", color: NookTheme.textSecondary)
        case "ts", "mts", "cts": return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.textSecondary)
        case "js", "mjs", "cjs": return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.textSecondary)
        case "json", "jsonc", "json5": return Glyph(symbol: "curlybraces", color: NookTheme.textSecondary)
        case "swift": return Glyph(symbol: "swift", color: NookTheme.textSecondary)
        case "css", "scss", "sass", "less": return Glyph(symbol: "number", color: NookTheme.textSecondary)
        case "html", "htm", "vue", "svelte", "astro": return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.textSecondary)
        case "md", "mdx", "markdown", "txt", "rtf": return Glyph(symbol: "doc.plaintext", color: NookTheme.textSecondary)
        case "sh", "zsh", "bash", "fish", "ps1": return Glyph(symbol: "terminal", color: NookTheme.textSecondary)
        case "py", "rb", "go", "rs", "java", "kt", "kts", "c", "cc", "cpp", "h", "hpp", "m", "mm", "cs", "php", "dart", "lua":
            return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.textSecondary)
        case "yml", "yaml", "toml", "ini", "plist", "xml", "conf", "cfg", "xcconfig", "entitlements":
            return Glyph(symbol: "gearshape", color: NookTheme.textSecondary)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "icns", "tiff", "bmp":
            return Glyph(symbol: "photo", color: NookTheme.textSecondary)
        case "mp4", "mov", "webm", "m4v": return Glyph(symbol: "film", color: NookTheme.textSecondary)
        case "mp3", "wav", "m4a", "aiff", "flac": return Glyph(symbol: "waveform", color: NookTheme.textSecondary)
        case "pdf": return Glyph(symbol: "doc.richtext", color: NookTheme.textSecondary)
        case "csv", "tsv", "xlsx", "xls", "numbers": return Glyph(symbol: "tablecells", color: NookTheme.textSecondary)
        case "sql", "db", "sqlite", "prisma": return Glyph(symbol: "cylinder", color: NookTheme.textSecondary)
        case "lock", "resolved": return Glyph(symbol: "lock", color: NookTheme.textTertiary)
        case "zip", "gz", "tar", "tgz", "dmg": return Glyph(symbol: "archivebox", color: NookTheme.textSecondary)
        // An app that is not on this Mac; one that is shows its own icon (`appIcon`).
        case "app": return Glyph(symbol: "app", color: NookTheme.textSecondary)
        default: return Glyph(symbol: "doc", color: NookTheme.textSecondary)
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    /// The app's own icon for a link to an app on this Mac (`/Applications/Safari.app`, `~/Applications/Tool.app`), as
    /// Finder shows it, `size` points high; nil for anything else, or an app that is not there.
    static func appIcon(for path: String, size: CGFloat) -> NSImage? {
        guard FileLink.isAppBundle(path) else { return nil }
        let full = (path as NSString).expandingTildeInPath
        guard full.hasPrefix("/") else { return nil }
        let key = "app|\(full)|\(size)" as NSString
        if let known = cache.object(forKey: key) { return known }
        guard FileManager.default.fileExists(atPath: full) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: full)
        icon.size = NSSize(width: size, height: size)
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// The glyph as an image to set in text, `size` points high, tinted when drawn so it follows the window's
    /// appearance (Settings › Appearance) like the text around it.
    static func image(for path: String, size: CGFloat) -> NSImage {
        let glyph = glyph(for: path)
        let key = "\(glyph.symbol)|\(size)|\(path.hasSuffix("/") ? "/" : (path as NSString).pathExtension.lowercased())" as NSString
        if let known = cache.object(forKey: key) { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let symbol = (NookIcon.nsImage(glyph.symbol, accessibilityDescription: nil)
                      ?? NookIcon.nsImage("doc", accessibilityDescription: nil))?
            .withSymbolConfiguration(configuration)
        let bounds = symbol?.size ?? CGSize(width: size, height: size)
        let color = NSColor(glyph.color)
        let image = NSImage(size: bounds, flipped: false) { rect in
            guard let symbol else { return false }
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
