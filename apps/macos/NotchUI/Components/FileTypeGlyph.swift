import SwiftUI
import AppKit

/// The small colored symbol for a kind of file, as an editor's file tree shows it: a React atom for `.tsx`, braces for
/// `.json`, a terminal for a shell script. An agent's answer puts it before each file it links, so a list of changed
/// files reads at a glance.
enum FileTypeGlyph {
    struct Glyph: Equatable {
        let symbol: String
        let color: Color
    }

    /// The glyph for a file name or path (`src/App.tsx`, `nl.json:12`); a folder for a path that ends in a slash.
    static func glyph(for path: String) -> Glyph {
        if path.hasSuffix("/") { return Glyph(symbol: "folder", color: NookTheme.Syntax.type) }
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile": return Glyph(symbol: "shippingbox", color: NookTheme.Syntax.type)
        case "makefile", "justfile": return Glyph(symbol: "hammer", color: NookTheme.Syntax.number)
        case "license", "licence": return Glyph(symbol: "checkmark.seal", color: NookTheme.Syntax.attribute)
        default: break
        }
        if name.hasPrefix(".env") { return Glyph(symbol: "key", color: NookTheme.Syntax.attribute) }
        if name.hasPrefix(".git") { return Glyph(symbol: "arrow.triangle.branch", color: NookTheme.Syntax.number) }
        switch (name as NSString).pathExtension {
        case "tsx", "jsx": return Glyph(symbol: "atom", color: NookTheme.Syntax.type)
        case "ts", "mts", "cts": return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.Syntax.type)
        case "js", "mjs", "cjs": return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.Syntax.attribute)
        case "json", "jsonc", "json5": return Glyph(symbol: "curlybraces", color: NookTheme.Syntax.number)
        case "swift": return Glyph(symbol: "swift", color: NookTheme.coral)
        case "css", "scss", "sass", "less": return Glyph(symbol: "number", color: NookTheme.Syntax.tag)
        case "html", "htm", "vue", "svelte", "astro": return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.coral)
        case "md", "mdx", "markdown", "txt", "rtf": return Glyph(symbol: "doc.plaintext", color: NookTheme.textSecondary)
        case "sh", "zsh", "bash", "fish", "ps1": return Glyph(symbol: "terminal", color: NookTheme.Syntax.string)
        case "py", "rb", "go", "rs", "java", "kt", "kts", "c", "cc", "cpp", "h", "hpp", "m", "mm", "cs", "php", "dart", "lua":
            return Glyph(symbol: "chevron.left.forwardslash.chevron.right", color: NookTheme.Syntax.keyword)
        case "yml", "yaml", "toml", "ini", "plist", "xml", "conf", "cfg", "xcconfig", "entitlements":
            return Glyph(symbol: "gearshape", color: NookTheme.textSecondary)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "icns", "tiff", "bmp":
            return Glyph(symbol: "photo", color: NookTheme.Syntax.string)
        case "mp4", "mov", "webm", "m4v": return Glyph(symbol: "film", color: NookTheme.Syntax.tag)
        case "mp3", "wav", "m4a", "aiff", "flac": return Glyph(symbol: "waveform", color: NookTheme.Syntax.tag)
        case "pdf": return Glyph(symbol: "doc.richtext", color: NookTheme.coral)
        case "csv", "tsv", "xlsx", "xls", "numbers": return Glyph(symbol: "tablecells", color: NookTheme.Syntax.string)
        case "sql", "db", "sqlite", "prisma": return Glyph(symbol: "cylinder", color: NookTheme.Syntax.property)
        case "lock", "resolved": return Glyph(symbol: "lock", color: NookTheme.textTertiary)
        case "zip", "gz", "tar", "tgz", "dmg": return Glyph(symbol: "archivebox", color: NookTheme.textSecondary)
        default: return Glyph(symbol: "doc", color: NookTheme.textSecondary)
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    /// The glyph as an image to set in text, `size` points high, tinted when drawn so it follows the window's
    /// appearance (Settings › Appearance) like the text around it.
    static func image(for path: String, size: CGFloat) -> NSImage {
        let glyph = glyph(for: path)
        let key = "\(glyph.symbol)|\(size)|\(path.hasSuffix("/") ? "/" : (path as NSString).pathExtension.lowercased())" as NSString
        if let known = cache.object(forKey: key) { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let symbol = (NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil)
                      ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil))?
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
