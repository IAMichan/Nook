import Foundation

/// A file an agent pointed at: `src/app.swift:12:3`, `src/app.swift:42-64`, `./README.md`, `~/notes.txt`,
/// `/abs/path.swift#L12`, `/abs/path.swift#L42-L64`, or `file:///abs/path.swift`. Opening it puts the cursor on that line in your editor.
struct FileTarget: Equatable, Sendable {
    var path: String
    var line: Int?
    var column: Int?
    /// The last line of a range (`app.swift:42-64`, `#L42-L64`); the file opens at `line`, the first.
    var endLine: Int? = nil

    /// "L42", or "L42–64" for a range: how a link's place reads next to its file.
    var lineLabel: String? {
        guard let line else { return nil }
        guard let endLine, endLine > line else { return "L\(line)" }
        return "L\(line)\u{2013}\(endLine)"
    }

    /// `path:line:column`, the form most editors take after `--goto`.
    var positioned: String {
        guard let line else { return path }
        guard let column else { return "\(path):\(line)" }
        return "\(path):\(line):\(column)"
    }
}

enum FileLink {
    private static let position = try! NSRegularExpression(pattern: #"^(.+?):(\d+)(?::(\d+))?(?:-(\d+))?$"#)
    private static let githubAnchor = try! NSRegularExpression(pattern: #"#L(\d+)(?:C(\d+))?(?:-L?(\d+)(?:C\d+)?)?$"#)
    private static let scheme = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9+.-]*):"#)

    /// The file a link or a piece of text points at, or nil when it is a web, mail or other link.
    static func parse(_ raw: String) -> FileTarget? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path + (url.fragment.map { "#" + $0 } ?? "")
        } else if let match = first(scheme, in: text) {
            // `app.swift:12` reads as the scheme `app.swift`; a real scheme is not followed by a line number.
            let name = group(match, 1, in: text) ?? ""
            let rest = text.dropFirst(name.count + 1)
            guard name.contains("."), let digit = rest.first, digit.isNumber else { return nil }
        }
        text = text.removingPercentEncoding ?? text

        var line: Int?
        var column: Int?
        var endLine: Int?
        if let match = first(githubAnchor, in: text) {
            line = group(match, 1, in: text).flatMap(Int.init)
            column = group(match, 2, in: text).flatMap(Int.init)
            endLine = group(match, 3, in: text).flatMap(Int.init)
            text = String(text[..<Range(match.range, in: text)!.lowerBound])
        } else if let match = first(position, in: text) {
            line = group(match, 2, in: text).flatMap(Int.init)
            column = group(match, 3, in: text).flatMap(Int.init)
            endLine = group(match, 4, in: text).flatMap(Int.init)
            text = group(match, 1, in: text) ?? text
        }
        guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("?") else { return nil }
        if let line, line < 1 { return nil }
        // A range runs forward; `:64-42` or `:42-42` is just its first line.
        let end = endLine.flatMap { end in line.flatMap { end > $0 ? end : nil } }
        return FileTarget(path: text, line: line, column: column.flatMap { $0 >= 1 ? $0 : nil }, endLine: end)
    }

    /// A link to an app (`/Applications/Safari.app`): it shows the app's own icon and a click opens the app, rather than
    /// showing the bundle in Finder as a folder.
    static func isAppBundle(_ path: String) -> Bool {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let name = (trimmed as NSString).lastPathComponent
        return name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    /// The target with an absolute path: `~` is your home folder, a relative path is read from `base` (the session's
    /// folder). Nil for a relative path without a base.
    static func resolve(_ target: FileTarget, base: String?, home: String = NSHomeDirectory()) -> FileTarget? {
        var path = target.path
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            guard let base, !base.isEmpty else { return nil }
            path = (base as NSString).appendingPathComponent(path)
        }
        var resolved = target
        resolved.path = (path as NSString).standardizingPath
        return resolved
    }

    /// The file a code span names on its own (`banner.png`, `src/app.swift:12`, `~/notes.md`), so an answer that lists
    /// the files it made can open them. A name needs an extension Nook knows, or a folder before it; a type
    /// (`AppModel.shared`), a domain (`example.com`) or a route (`/api/users`) is no file.
    static func named(_ code: String) -> FileTarget? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 300, !text.contains(where: \.isWhitespace), !text.contains("://"),
              !text.hasSuffix("/"), let target = parse(text) else { return nil }
        let name = (target.path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.first?.isLetter == true, ext.count <= 10, name.count > ext.count + 1 else { return nil }
        let folder = target.path.contains("/")
        guard fileExtensions.contains(ext) || (folder && !domainEndings.contains(ext)) else { return nil }
        return target
    }

    /// Extensions a bare name is read as a file by.
    static let fileExtensions: Set<String> = [
        "md", "markdown", "mdx", "txt", "rtf", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers",
        "csv", "tsv", "json", "jsonl", "yml", "yaml", "toml", "xml", "plist", "ini", "conf", "env", "log", "lock",
        "html", "htm", "css", "scss", "svg", "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico",
        "mp4", "mov", "m4v", "webm", "mp3", "wav", "m4a", "zip", "ipynb", "sql",
        "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "py", "rb", "go", "rs", "java", "kt", "kts",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish", "gradle", "strings",
        "xcconfig", "entitlements", "pbxproj", "storyboard", "xib"
    ]

    /// Endings of web addresses that are no file extension (`docs.example.com/guide.io`).
    private static let domainEndings: Set<String> = ["com", "net", "org", "io", "nl", "de", "fr", "es", "be", "uk", "app", "dev"]

    /// The files an answer names in code spans or links (`banner.png`, `[the plan](docs/plan.md)`), in order and once
    /// each, leaving out code blocks and web addresses.
    static func mentions(in markdown: String) -> [FileTarget] {
        var prose: [Substring] = []
        var fenced = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            if !fenced { prose.append(line) }
        }
        let text = prose.joined(separator: "\n")
        var found: [FileTarget] = []
        var seen: Set<String> = []
        for match in mention.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let raw = group(match, 1, in: text) ?? group(match, 2, in: text) ?? ""
            guard let target = named(raw), seen.insert(target.path).inserted else { continue }
            found.append(target)
        }
        return found
    }

    private static let mention = try! NSRegularExpression(pattern: #"`([^`\n]+)`|\]\(([^)\s]+)\)"#)

    /// Where a relative name lives in `base` when it is not right there: the newest file under it whose path ends in the
    /// name (`banner.png` in `marketing/banner.png`). Hidden folders and dependency or build folders are skipped, and the
    /// search stops after `limit` entries, so a large folder cannot hold it up.
    static func locate(_ relative: String, in base: String, limit: Int = 40_000) -> String? {
        let name = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), !name.hasPrefix("../") else { return nil }
        let root = URL(fileURLWithPath: base, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let suffix = "/" + name
        var best: (path: String, date: Date)?
        var count = 0
        for case let url as URL in walk {
            count += 1
            if count > limit { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { walk.skipDescendants() }
                continue
            }
            let path = url.path
            guard path.hasSuffix(suffix) else { continue }
            let date = values?.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (path, date) }
        }
        return best?.path
    }

    private static let skippedFolders: Set<String> = [
        "node_modules", "build", "dist", "DerivedData", "Pods", "Carthage", "vendor", "target", "__pycache__", "venv"
    ]

    /// `target` resolved against `base`, and looked up inside it (`locate`) when a relative name is not right there.
    static func find(_ target: FileTarget, base: String?) -> FileTarget? {
        guard var resolved = resolve(target, base: base) else { return nil }
        if FileManager.default.fileExists(atPath: resolved.path) { return resolved }
        guard let base, !target.path.hasPrefix("/"), let found = locate(target.path, in: base) else { return resolved }
        resolved.path = found
        return resolved
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

/// How to open a file at a line in the editor you chose in Settings › Workspace. Editors take the position in one of three
/// ways: `--goto path:line:col` (VS Code and its forks), `path:line:col` as is (Zed, Sublime Text), or
/// separate flags (Xcode's `xed --line`, JetBrains' `--line` with a column counted from 0).
enum EditorLaunch: Equatable {
    /// Run the editor's own command line tool.
    case process(executable: String, arguments: [String])
    /// Hand the file to the editor app (no line to go to, or no tool known for it).
    case open

    /// `appPath` is the editor's `.app`; `executable` its `CFBundleExecutable` (JetBrains names its tool after it).
    static func plan(bundleID: String, appPath: String, executable: String?, target: FileTarget) -> EditorLaunch {
        guard let line = target.line else { return .open }
        let app = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
        switch bundleID {
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders":
            return .process(executable: app + "/Contents/Resources/app/bin/code", arguments: ["--goto", target.positioned])
        case "com.todesktop.230313mzl4w4u92":
            return .process(executable: app + "/Contents/Resources/app/bin/cursor", arguments: ["--goto", target.positioned])
        case "com.exafunction.windsurf":
            return .process(executable: app + "/Contents/Resources/app/bin/windsurf", arguments: ["--goto", target.positioned])
        case "com.vscodium":
            return .process(executable: app + "/Contents/Resources/app/bin/codium", arguments: ["--goto", target.positioned])
        case "dev.zed.Zed", "dev.zed.Zed-Preview":
            return .process(executable: app + "/Contents/MacOS/cli", arguments: [target.positioned])
        case "com.sublimetext.4", "com.sublimetext.3":
            return .process(executable: app + "/Contents/SharedSupport/bin/subl", arguments: [target.positioned])
        case "com.apple.dt.Xcode":
            return .process(executable: "/usr/bin/xed", arguments: ["--line", String(line), target.path])
        default:
            let jetBrains = bundleID.hasPrefix("com.jetbrains.") || bundleID == "com.google.android.studio"
            guard jetBrains, let executable, !executable.isEmpty else { return .open }
            var arguments = ["--line", String(line)]
            if let column = target.column { arguments += ["--column", String(column - 1)] }
            return .process(executable: app + "/Contents/MacOS/" + executable, arguments: arguments + [target.path])
        }
    }
}
