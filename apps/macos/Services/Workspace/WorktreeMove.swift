import Foundation

/// An agent that makes a worktree of its own with `git worktree add` and goes on working there: after its session's
/// worktree was cleaned up (a merged pull request), or to start the next change from a fresh base. Nook reads git in the
/// session's folder only, so without following the agent the new branch, its changes and its pull request never show.
/// The same for every agent: it reads the shell commands of the shared timeline.
enum WorktreeMove {
    /// The folder a `git worktree add` in `command` makes, as an absolute path. A relative path counts from the folder
    /// the command is in by then: `cwd`, a `cd` before it in the same command, or git's `-C`. Nil when it makes none.
    static func added(in command: String, cwd: String) -> String? {
        guard command.contains("worktree") else { return nil }
        var folder = cwd
        var found: String?
        for segment in segments(command) {
            let words = shellWords(segment)
            guard let first = words.first else { continue }
            if first == "cd" || first == "pushd" {
                if let target = words.dropFirst().first(where: { !$0.hasPrefix("-") }) { folder = absolute(target, from: folder) }
                continue
            }
            guard first == "git" || first.hasSuffix("/git"), let path = worktreeAddPath(Array(words.dropFirst()), cwd: folder) else { continue }
            found = path
        }
        return found
    }

    /// Whether the session moves to the worktree the agent made: its own folder is no git checkout anymore (cleaned up,
    /// maybe with a stray file left behind), or the agent changed files in the new one during the turn.
    static func follows(ownIsCheckout: Bool, added: String, changedFiles: [String]) -> Bool {
        if !ownIsCheckout { return true }
        let root = normalize(added)
        return changedFiles.contains { normalize($0).hasPrefix(root + "/") }
    }

    /// `/a/b/` and `/a/./b` alike, `~` expanded.
    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standard = (expanded as NSString).standardizingPath
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    // MARK: Reading the command

    /// The path argument after git's own options and `worktree add`'s, made absolute.
    private static func worktreeAddPath(_ arguments: [String], cwd: String) -> String? {
        var folder = cwd
        var index = 0
        // git's options before the subcommand: `-C <dir>` moves, `-c key=value` takes a value.
        while index < arguments.count, arguments[index].hasPrefix("-") {
            if arguments[index] == "-C", index + 1 < arguments.count {
                folder = absolute(arguments[index + 1], from: folder)
                index += 2
            } else if arguments[index] == "-c" {
                index += 2
            } else {
                index += 1
            }
        }
        guard index + 1 < arguments.count, arguments[index] == "worktree", arguments[index + 1] == "add" else { return nil }
        index += 2
        while index < arguments.count {
            let word = arguments[index]
            if word == "--" {
                return index + 1 < arguments.count ? absolute(arguments[index + 1], from: folder) : nil
            }
            if word.hasPrefix("-") {
                index += valueOptions.contains(word) ? 2 : 1
                continue
            }
            return absolute(word, from: folder)
        }
        return nil
    }

    /// `git worktree add` options that take the next word as their value.
    private static let valueOptions: Set<String> = ["-b", "-B", "--reason"]

    private static func absolute(_ path: String, from folder: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return normalize(expanded.hasPrefix("/") ? expanded : (folder as NSString).appendingPathComponent(expanded))
    }

    /// The simple commands of a shell line: split at `&&`, `||`, `;`, `|` and line breaks outside quotes.
    private static func segments(_ command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var previous: Character?
        for char in command {
            if let open = quote {
                if char == open { quote = nil }
                current.append(char)
            } else if char == "'" || char == "\"" {
                quote = char
                current.append(char)
            } else if char == ";" || char == "\n" || char == "|" || (char == "&" && previous == "&") {
                if char == "&" { current.removeLast() }
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Words split at spaces outside quotes, the quotes taken off.
    private static func shellWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        for char in text {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "'" || char == "\"" {
                quote = char
                inWord = true
            } else if char.isWhitespace {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(char)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
