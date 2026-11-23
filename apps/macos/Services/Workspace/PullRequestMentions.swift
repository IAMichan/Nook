import Foundation

/// The pull requests a session works on without them being its own branch's: the ones its agent works on with the forge's
/// CLI (`gh pr checks 3877`, `gh pr checkout https://…/pull/12`, `glab mr view 5 -R group/app`) and the ones you name in
/// your message ("#3877", a link). They join the session's linked pull requests, so the tray above its composer and the
/// side panel show them with their state and checks. Works the same for every agent: it reads the shared timeline.
enum PullRequestMentions {
    /// `gh pr` and `glab mr` subcommands that act on one existing pull request named by its number or link.
    private static let command = try? NSRegularExpression(
        pattern: #"(?:^|[\s;&|(`"'])(?:gh\s+pr|glab\s+mr)\s+(?:checkout|co|view|show|checks|diff|edit|comment|note|merge|"#
            + #"ready|review|approve|close|reopen|update-branch|rebase)\b([^;&|\n`)]*)"#,
        options: [.caseInsensitive])

    /// "#123" standing on its own in prose (not "abc#123" or a heading "# 1"), and links to a pull or merge request.
    private static let hashNumber = try? NSRegularExpression(pattern: #"(?<![\w#/&])#(\d{1,7})\b"#)
    private static let link = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"'`]+"#, options: [.caseInsensitive])

    /// A pull request a command acts on, with the folder the command moved to first (`cd ../app && gh pr view 12`).
    /// Nil `directory`: the session's own folder.
    struct Found: Equatable, Sendable {
        var ref: PullRequestRef
        var directory: String? = nil
    }

    /// `cd` or `pushd` into a folder, with its flags; the folder is group 1.
    private static let changeDirectory = try? NSRegularExpression(
        pattern: #"(?:^|[\s;&|(])(?:cd|pushd)\s+(?:-[LPe@]+\s+)*("[^"]*"|'[^']*'|[^\s;&|()]+)"#)

    /// The pull requests a tool call's command acts on, in order, each once. A number without `--repo` means the
    /// repository of the folder the command is in: the one its last `cd` before it moved to, else the session's own
    /// ("#12"). A number after a `cd` to a folder that cannot be read from the command (`cd -`, `cd "$DIR"`) is left
    /// out: guessing the session's repository would link another project's pull request with the same number.
    /// `directory`: the folder the tool call itself ran in, when the agent gave one (`workdir`, see `folder(in:)`).
    static func inCommand(_ parts: [String], directory base: String? = nil) -> [Found] {
        guard let command else { return [] }
        var found: [Found] = []
        for text in parts {
            let range = NSRange(text.startIndex..., in: text)
            let moves = changeDirectory?.matches(in: text, range: range) ?? []
            for match in command.matches(in: text, range: range) {
                guard let rest = Range(match.range(at: 1), in: text),
                      let ref = target(arguments: String(text[rest])) else { continue }
                guard ref.repository == nil, ref.url == nil,
                      let move = moves.last(where: { $0.range.location < match.range.location }),
                      let folder = Range(move.range(at: 1), in: text) else {
                    found.append(Found(ref: ref, directory: ref.repository == nil && ref.url == nil ? base : nil))
                    continue
                }
                guard let directory = directory(String(text[folder])) else { continue }
                found.append(Found(ref: ref, directory: base.map { SessionProjects.absolute(directory, cwd: $0) } ?? directory))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert(($0.directory ?? "") + "\n" + key($0.ref)).inserted }
    }

    /// The folder a shell tool call runs in when the agent names one: Codex's `workdir`, Gemini CLI's `dir_path` or
    /// `directory`, Antigravity's `Cwd`, a `cwd`. Nil: the session's own folder.
    static func folder(in input: [String: Any]) -> String? {
        for key in ["workdir", "cwd", "Cwd", "dir_path", "directory"] {
            if let folder = input[key] as? String, let found = directory(folder) { return found }
        }
        return nil
    }

    /// The folder a `cd` names, unquoted, with `~` expanded; nil when the shell decides it (`-`, a variable, a command).
    private static func directory(_ word: String) -> String? {
        var folder = word
        if folder.count >= 2, let first = folder.first, first == "\"" || first == "'", folder.last == first {
            folder = String(folder.dropFirst().dropLast())
        }
        guard !folder.isEmpty, folder != "-", !folder.contains("$"), !folder.contains("`") else { return nil }
        return (folder as NSString).expandingTildeInPath
    }

    /// The pull requests you named in a message: links to one, and "#12" (this project's). A "#12" can be an issue;
    /// the caller checks it exists as a pull request before it is linked.
    static func inMessage(_ text: String) -> [PullRequestRef] {
        var found: [PullRequestRef] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in link?.matches(in: text, range: range) ?? [] {
            guard let r = Range(match.range, in: text) else { continue }
            let url = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if let ref = PullRequestRef.parse(url), ref.repository != nil { found.append(ref) }
        }
        for match in hashNumber?.matches(in: text, range: range) ?? [] {
            guard let r = Range(match.range(at: 1), in: text), let number = Int(text[r]), number > 0 else { continue }
            found.append(PullRequestRef(host: nil, hostName: nil, repository: nil, number: number, url: nil))
        }
        return unique(found)
    }

    /// The pull request one command's arguments name: the first number or pull request link that is not the value of
    /// a flag, in the repository `-R`/`--repo` names when it gives one.
    private static func target(arguments: String) -> PullRequestRef? {
        let words = arguments.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        var repository: String?
        var number: Int?
        var linked: PullRequestRef?
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "-R" || word == "--repo" {
                if index + 1 < words.count { repository = words[index + 1] }
                index += 2
                continue
            }
            if word.hasPrefix("--repo=") {
                repository = String(word.dropFirst("--repo=".count))
            } else if word.hasPrefix("-") {
                // A flag's value ("--body 12") is not the pull request; only the known value flags take one.
                if valueFlags.contains(word) { index += 1 }
            } else if number == nil, linked == nil {
                if word.contains("://") {
                    linked = PullRequestRef.parse(word).flatMap { $0.repository == nil ? nil : $0 }
                } else if let n = Int(word.hasPrefix("#") ? String(word.dropFirst()) : word), n > 0 {
                    number = n
                }
            }
            index += 1
        }
        if let linked { return linked }
        guard let number else { return nil }
        let repo = repository.flatMap { $0.contains("/") && !$0.contains("://") ? $0 : nil }
        return PullRequestRef(host: nil, hostName: nil, repository: repo, number: number, url: nil)
    }

    private static let valueFlags: Set<String> = [
        "-b", "--body", "-F", "--body-file", "-t", "--title", "-m", "--message", "--subject", "-q", "--jq", "--json",
        "--template", "-B", "--base", "--branch", "--add-label", "--remove-label", "--add-reviewer", "--remove-reviewer",
        "--add-assignee", "--remove-assignee", "--milestone", "-i", "--interval", "--match-head-commit", "--author-email",
        "-A", "--assignee", "-l", "--label", "--reviewer", "--target-branch", "--source-branch", "--description",
    ]

    private static func unique(_ refs: [PullRequestRef]) -> [PullRequestRef] {
        var seen = Set<String>()
        return refs.filter { seen.insert(key($0)).inserted }
    }

    private static func key(_ ref: PullRequestRef) -> String { (ref.url?.absoluteString ?? ref.reference).lowercased() }
}
