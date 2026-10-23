import Foundation

/// A file an agent pointed at: `src/app.swift:12:3`, `./README.md`, `~/notes.txt`,
/// `/abs/path.swift#L12`, or `file:///abs/path.swift`. Opening it puts the cursor on that line in your editor.
struct FileTarget: Equatable, Sendable {
    var path: String
    var line: Int?
    var column: Int?

    /// `path:line:column`, the form most editors take after `--goto`.
    var positioned: String {
        guard let line else { return path }
        guard let column else { return "\(path):\(line)" }
        return "\(path):\(line):\(column)"
    }
}

enum FileLink {
    private static let position = try! NSRegularExpression(pattern: #"^(.+?):(\d+)(?::(\d+))?$"#)
    private static let githubAnchor = try! NSRegularExpression(pattern: #"#L(\d+)(?:C(\d+))?(?:-L?\d+(?:C\d+)?)?$"#)
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
        if let match = first(githubAnchor, in: text) {
            line = group(match, 1, in: text).flatMap(Int.init)
            column = group(match, 2, in: text).flatMap(Int.init)
            text = String(text[..<Range(match.range, in: text)!.lowerBound])
        } else if let match = first(position, in: text) {
            line = group(match, 2, in: text).flatMap(Int.init)
            column = group(match, 3, in: text).flatMap(Int.init)
            text = group(match, 1, in: text) ?? text
        }
        guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("?") else { return nil }
        if let line, line < 1 { return nil }
        return FileTarget(path: text, line: line, column: column.flatMap { $0 >= 1 ? $0 : nil })
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
