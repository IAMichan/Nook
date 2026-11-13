import Foundation

/// Finds a project's own icon in its folder: a favicon or app icon at a well-known
/// place, else the icon an `index.html` (or a root route) links, else one in a web app of a monorepo (`apps/*/public`,
/// `apps/*/web/public`), else one in a site folder of its own, else an app's `AppIcon` (`.icns` or `.appiconset`). The session list shows it as the project's badge; without one the badge is the
/// project's initials. Foundation only: it reads a few files, never more than a bounded walk, and runs off the main thread.
enum ProjectFavicon {
    /// The places looked at first, in order, plus `.icns` for Mac apps.
    static let candidates = [
        "favicon.svg", "favicon.ico", "favicon.png",
        "public/favicon.svg", "public/favicon.ico", "public/favicon.png",
        "app/favicon.ico", "app/favicon.png", "app/icon.svg", "app/icon.png", "app/icon.ico",
        "src/favicon.ico", "src/favicon.svg", "src/app/favicon.ico", "src/app/icon.svg", "src/app/icon.png",
        // Phoenix (`priv/static`) and SvelteKit or Hugo (`static`) serve their public files from here.
        "priv/static/favicon.svg", "priv/static/favicon.ico", "priv/static/favicon.png",
        "static/favicon.svg", "static/favicon.ico", "static/favicon.png",
        "assets/icon.svg", "assets/icon.png", "assets/logo.svg", "assets/logo.png",
        ".idea/icon.svg",
    ]

    /// Files that may link the icon (`<link rel="icon" href="…">`, or `rel: "icon", href: "…"` in a route).
    static let sources = ["index.html", "public/index.html", "app/routes/__root.tsx", "src/routes/__root.tsx",
                          "app/root.tsx", "src/root.tsx", "src/index.html"]

    /// Folders of a monorepo whose packages may hold the web app with the favicon.
    static let workspaces = ["apps", "packages", "web", "site", "website"]

    /// Folders inside a monorepo package that hold its web app.
    static let webFolders = ["web", "app", "site", "frontend", "client", "www"]

    /// The repository's name, lowercased: the folder's own name, and for a worktree (`…/worktrees/<repo>/<branch>`)
    /// also the repository's folder above it.
    static func repositoryNames(of base: URL) -> [String] {
        let components = base.standardizedFileURL.pathComponents
        var names = [base.lastPathComponent.lowercased()]
        if components.count >= 3, components[components.count - 3] == "worktrees" {
            names.append(components[components.count - 2].lowercased())
        }
        return names
    }

    /// Whether a package is named after the repository (`infaris` in `infaris-monorepo`); short names never match.
    static func matches(_ package: String, _ names: [String]) -> Bool {
        let package = package.lowercased()
        return package.count >= 3 && names.contains { $0.contains(package) }
    }

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
        // A monorepo: the package named after the repository first (`apps/infaris` in `Infaris-monorepo`), then the
        // others by name; in each, the package itself or its web app (`apps/infaris/web/public/favicon.ico`).
        let names = repositoryNames(of: base)
        for folder in workspaces {
            let packages = (try? fileManager.contentsOfDirectory(atPath: base.appendingPathComponent(folder).path)) ?? []
            let ordered = packages.filter { !$0.hasPrefix(".") }.sorted().sorted { lhs, rhs in
                matches(lhs, names) && !matches(rhs, names)
            }
            for package in ordered {
                for sub in [""] + webFolders.map({ $0 + "/" }) {
                    let prefix = folder + "/" + package + "/" + sub
                    if let hit = candidates.lazy.compactMap({ existing(prefix + $0) }).first { return hit }
                }
            }
        }
        // A repository of several sites side by side (`bettr-finance/favicon.svg`): its own folders, the same way.
        let folders = ((try? fileManager.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !skipped.contains($0) && !workspaces.contains($0) }
            .sorted().sorted { matches($0, names) && !matches($1, names) }
        for folder in folders {
            if let hit = candidates.lazy.compactMap({ existing(folder + "/" + $0) }).first { return hit }
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

    /// An app's icon within four levels, nearest first: an `AppIcon.icns`, or the biggest picture of up to 2 MB in an
    /// `AppIcon.appiconset` (a 1024 px icon is often a few hundred KB; it is drawn small once, so size barely matters).
    static func appIcon(in base: URL, fileManager: FileManager, maxDepth: Int = 4, budget: Int = 400) -> String? {
        var queue: [(URL, Int)] = [(base, 0)]
        var visited = 0
        while !queue.isEmpty, visited < budget {
            let (folder, depth) = queue.removeFirst()
            visited += 1
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() {
                let url = folder.appendingPathComponent(name)
                if name == "AppIcon.icns" { return url.path }
                if name == "AppIcon.appiconset" || name == "AppIcon.icon" {
                    let pictures = ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
                        .filter { $0.lowercased().hasSuffix(".png") }
                        .map { url.appendingPathComponent($0).path }
                        .compactMap { path -> (String, Int)? in
                            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
                            return size.map { (path, $0) }
                        }
                        .filter { $0.1 <= 2 * 1024 * 1024 }
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
