import Foundation

/// Finds a project's own icon in its folder `ProjectFaviconResolver`: a favicon or app icon at a well-known
/// place, else the icon an `index.html` (or a root route) links, else one in a web app of a monorepo (`apps/*/public`),
/// else an Xcode app's `AppIcon`. The session list shows it as the project's badge; without one the badge is the
/// project's initials. Foundation only: it reads a few files, never more than a bounded walk, and runs off the main thread.
enum ProjectFavicon {
    /// The places looks first, in its order, plus `.icns` for Mac apps.
    static let candidates = [
        "favicon.svg", "favicon.ico", "favicon.png",
        "public/favicon.svg", "public/favicon.ico", "public/favicon.png",
        "app/favicon.ico", "app/favicon.png", "app/icon.svg", "app/icon.png", "app/icon.ico",
        "src/favicon.ico", "src/favicon.svg", "src/app/favicon.ico", "src/app/icon.svg", "src/app/icon.png",
        "assets/icon.svg", "assets/icon.png", "assets/logo.svg", "assets/logo.png",
        ".idea/icon.svg", "Resources/AppIcon.icns", "AppIcon.icns",
    ]

    /// Files that may link the icon (`<link rel="icon" href="…">`, or `rel: "icon", href: "…"` in a route).
    static let sources = ["index.html", "public/index.html", "app/routes/__root.tsx", "src/routes/__root.tsx",
                          "app/root.tsx", "src/root.tsx", "src/index.html"]

    /// Folders of a monorepo whose packages may hold the web app with the favicon.
    static let workspaces = ["apps", "packages", "web", "site", "website"]

    /// Folders never walked into while looking for an `AppIcon`.
    static let skipped: Set<String> = ["node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", ".next",
                                       "vendor", "Vendor", "target", ".scratch"]

    /// The icon file of the project at `root`, or nil.
    static func find(in root: String, fileManager: FileManager = .default) -> String? {
        let base = URL(fileURLWithPath: root, isDirectory: true)
        func existing(_ relative: String) -> String? {
            let path = base.appendingPathComponent(relative).path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return path
        }
        if let hit = candidates.lazy.compactMap(existing).first { return hit }
        for source in sources {
            guard let text = read(base.appendingPathComponent(source).path), let href = iconHref(in: text) else { continue }
            let clean = href.hasPrefix("/") ? String(href.dropFirst()) : href
            if let hit = ["public/" + clean, clean].lazy.compactMap(existing).first { return hit }
        }
        // A monorepo: the first package (by name) with a favicon of its own.
        for folder in workspaces {
            let packages = (try? fileManager.contentsOfDirectory(atPath: base.appendingPathComponent(folder).path)) ?? []
            for package in packages.sorted() where !package.hasPrefix(".") {
                let prefix = folder + "/" + package + "/"
                if let hit = candidates.lazy.compactMap({ existing(prefix + $0) }).first { return hit }
            }
        }
        return appIcon(in: base, fileManager: fileManager)
    }

    /// The `href` of the first icon link in an HTML page or a route file; nil when there is none.
    static func iconHref(in text: String) -> String? {
        let patterns = [
            #"<link\b(?=[^>]*\brel=["'](?:icon|shortcut icon)["'])[^>]*\bhref=["']([^"'?]+)"#,
            #"<link\b[^>]*\bhref=["']([^"'?]+)["'][^>]*\brel=["'](?:icon|shortcut icon)["']"#,
            #"\brel\s*:\s*["'](?:icon|shortcut icon)["'][^{}]*?\bhref\s*:\s*["']([^"'?]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let href = String(text[range])
            // Only a file in the project: no address on the web, no data URL.
            if href.contains("://") || href.hasPrefix("data:") || href.hasPrefix("//") { continue }
            return href
        }
        return nil
    }

    /// An Xcode app's icon: the biggest picture of up to 256 KB in the first `AppIcon.appiconset` within four levels.
    static func appIcon(in base: URL, fileManager: FileManager, maxDepth: Int = 4, budget: Int = 400) -> String? {
        var queue: [(URL, Int)] = [(base, 0)]
        var visited = 0
        while !queue.isEmpty, visited < budget {
            let (folder, depth) = queue.removeFirst()
            visited += 1
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() {
                let url = folder.appendingPathComponent(name)
                if name == "AppIcon.appiconset" || name == "AppIcon.icon" {
                    let pictures = ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
                        .filter { $0.lowercased().hasSuffix(".png") }
                        .map { url.appendingPathComponent($0).path }
                        .compactMap { path -> (String, Int)? in
                            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
                            return size.map { (path, $0) }
                        }
                        .filter { $0.1 <= 256 * 1024 }
                    if let best = pictures.max(by: { $0.1 < $1.1 }) { return best.0 }
                    continue
                }
                guard depth < maxDepth, !name.hasPrefix("."), !skipped.contains(name) else { continue }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    queue.append((url, depth + 1))
                }
            }
        }
        return nil
    }

    private static func read(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // The head of a page holds its links; a big file is not read whole.
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? nil
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
}
