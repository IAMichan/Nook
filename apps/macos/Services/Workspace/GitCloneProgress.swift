import Foundation

/// How far a `git clone --progress` is, read from what git writes to stderr: the stage ("Receiving objects"), its
/// percentage and git's own detail (the size and speed so far). Git redraws a line with a bare carriage return, so the
/// output is cut on both `\r` and `\n` (`Lines`). Foundation only, so tests can feed it git's own output.
struct GitCloneProgress: Equatable, Sendable {
    enum Stage: Int, Comparable, Sendable {
        /// The server counts and compresses what it sends.
        case counting
        case receiving
        case resolving
        /// Writing out the files of the default branch.
        case checkout

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The `tr` key of its name.
        var titleKey: String {
            switch self {
            case .counting: return "clone.stage.counting"
            case .receiving: return "clone.stage.receiving"
            case .resolving: return "clone.stage.resolving"
            case .checkout: return "clone.stage.checkout"
            }
        }

        /// The part of the whole clone this stage takes, so one bar can go from 0 to 1 over all of them. Receiving the
        /// objects is by far the longest.
        fileprivate var span: ClosedRange<Double> {
            switch self {
            case .counting: return 0...0.05
            case .receiving: return 0.05...0.85
            case .resolving: return 0.85...0.95
            case .checkout: return 0.95...1
            }
        }
    }

    var stage: Stage
    /// 0–100; nil when git gave no percentage for the stage.
    var percent: Int?
    /// Git's own words after the count ("12.40 MiB | 3.10 MiB/s"); nil when there are none.
    var detail: String?

    /// The whole clone from 0 to 1.
    var fraction: Double {
        let span = stage.span
        return span.lowerBound + (span.upperBound - span.lowerBound) * Double(percent ?? 0) / 100
    }

    /// The notice's line: "Receiving objects · 42% · 12.40 MiB | 3.10 MiB/s".
    var summary: String {
        ([tr(stage.titleKey)] + [percent.map { "\($0)%" }, detail].compactMap { $0 }).joined(separator: " · ")
    }

    /// "owner/repo" of a clone address (https, ssh or scp style), without ".git"; the address itself when it has no path.
    static func displayName(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            text = text.firstIndex(of: "/").map { String(text[text.index(after: $0)...]) } ?? text
        } else if let colon = text.firstIndex(of: ":") {
            text = String(text[text.index(after: colon)...])
        }
        let parts = text.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return url }
        return parts.suffix(2).joined(separator: "/")
    }

    private static let stages: [(prefix: String, stage: Stage)] = [
        ("remote: Enumerating objects", .counting),
        ("remote: Counting objects", .counting),
        ("remote: Compressing objects", .counting),
        ("Receiving objects", .receiving),
        ("Resolving deltas", .resolving),
        ("Updating files", .checkout),
        ("Checking out files", .checkout),
    ]

    /// One line of git's stderr; nil when it is not a progress line (a warning, "Cloning into …", an error).
    static func parse(_ line: String) -> GitCloneProgress? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = stages.first(where: { text.hasPrefix($0.prefix) }) else { return nil }
        let stage = entry.stage
        // The colon after the stage's name, not the one after "remote".
        let named = text.index(text.startIndex, offsetBy: entry.prefix.count)
        // "Receiving objects:  42% (420/1000), 12.40 MiB | 3.10 MiB/s" or "…: 100% (1000/1000), 24.00 MiB | 3.10 MiB/s, done."
        guard let colon = text[named...].firstIndex(of: ":"),
              let match = text[text.index(after: colon)...].range(of: #"^\s*(\d{1,3})%\s*\(\d+/\d+\)"#, options: .regularExpression) else {
            return GitCloneProgress(stage: stage, percent: nil, detail: nil)
        }
        let head = text[match]
        let digits = head.drop { !$0.isNumber }.prefix { $0.isNumber }
        var rest = String(text[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(",") { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)
        for suffix in [", done.", "done."] where rest.hasSuffix(suffix) {
            rest = String(rest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        if rest.hasSuffix(",") { rest.removeLast() }
        return GitCloneProgress(stage: stage, percent: Int(digits).map { min(100, max(0, $0)) },
                                detail: rest.isEmpty ? nil : rest)
    }

    /// Cuts a stream of stderr into lines on `\r` and `\n`, keeping a line that is not finished for the next chunk.
    struct Lines: Sendable {
        private var pending = ""

        init() {}

        mutating func feed(_ text: String) -> [String] {
            var lines: [String] = []
            var current = ""
            for character in pending + text {
                // "\r\n" is one Character in Swift.
                if character == "\r" || character == "\n" || character == "\r\n" {
                    if !current.isEmpty { lines.append(current) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            pending = current
            return lines
        }
    }

    /// The lines that say why a clone failed: everything that is not progress or "Cloning into", the last few of them,
    /// with any password in a URL taken out. Nil when git said nothing else.
    static func failure(_ stderr: String, keep: Int = 4) -> String? {
        var lines = Lines()
        let all = lines.feed(stderr + "\n")
        let reasons = all.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && parse($0) == nil && !$0.hasPrefix("Cloning into") }
            .map(redacted)
        guard !reasons.isEmpty else { return nil }
        return reasons.suffix(keep).joined(separator: "\n")
    }

    /// "https://user:secret@host/x" → "https://***@host/x": git echoes the address in some failures.
    static func redacted(_ line: String) -> String {
        line.replacingOccurrences(of: #"(?<=://)[^/@\s]+@"#, with: "***@", options: .regularExpression)
    }
}
