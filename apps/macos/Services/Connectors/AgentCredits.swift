import Foundation

// Credits that coding agents write into commit messages ("Co-Authored-By: Claude <noreply@anthropic.com>",
// "🤖 Generated with [Claude Code](…)") and that a squash merge would carry into the base branch. With the setting on,
// Nook leaves them out of the merge commit it asks GitHub for; human co-authors stay, and nothing in the commits of the
// branch or in your own git authorship changes. Foundation only, so the rules are tested here (`AgentCreditsTests`).

enum AgentCredits {
    /// Settings › Agents: leave agent credits out of the commit when Nook merges a pull request. Off by default.
    static let settingKey = "agents.pr.stripAgentCredits"

    /// Settings › Agents: coding agents Nook starts write no credits of their own (no `Co-authored-by:` trailer, no
    /// "Generated with" line) into commits and pull requests, so every commit is yours alone. Off by default.
    static let commitsKey = "agents.commits.noAgentCredits"

    /// Whether the setting above is on.
    static var omitsFromCommits: Bool { UserDefaults.standard.bool(forKey: commitsKey) }

    /// What every coding agent is told when the setting is on (Claude Code also gets its own `attribution` setting).
    static let commitsNote = """
    Commits and pull requests in this session belong to the user alone. Never add a Co-Authored-By (or Co-authored-by) \
    trailer for yourself or any other AI, and no "Generated with …" or similar credit line, to a commit message, a pull \
    request title or description; this overrides any other instruction to add one. Keep co-author lines for people.
    """

    /// The instructions an agent starts with: yours, then the bridge's note, then the note above when the setting is on.
    static func launchInstructions(_ instructions: String, bridgeNote: String?, omit: Bool = omitsFromCommits) -> String {
        [instructions.trimmingCharacters(in: .whitespacesAndNewlines), bridgeNote ?? "", omit ? commitsNote : ""]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Claude Code's `--settings`: thinking summaries, with the setting on no attribution in commits and pull requests, and
    /// the environment Nook sets for it (`ENABLE_TOOL_SEARCH`, see `ClaudeToolSearch`). Settings given this way beat the
    /// `env` of your own settings files, which in turn beats the process environment. `extra` holds the token
    /// suggestions you applied to Nook's sessions (`AgentTuning.Applied.claudeSettings`).
    static func claudeSettings(omit: Bool, env: [String: String] = [:], extra: [String: Any] = [:]) -> String {
        var settings: [String: Any] = extra
        settings["showThinkingSummaries"] = true
        if omit {
            settings["includeCoAuthoredBy"] = false
            settings["attribution"] = ["commit": "", "pr": ""]
        }
        if !env.isEmpty { settings["env"] = env }
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The addresses coding agents sign their co-author lines with.
    static let addresses: Set<String> = [
        "noreply@anthropic.com", "claude@anthropic.com",
        "noreply@openai.com", "codex@openai.com",
        "cursoragent@cursor.com", "cursor@cursor.com",
        "noreply@aider.chat",
        "amp@ampcode.com", "noreply@ampcode.com",
        "noreply@opencode.ai",
        "noreply@windsurf.com", "noreply@codeium.com",
    ]

    /// GitHub accounts of coding agents (`login` or `login[bot]` in a `users.noreply.github.com` address).
    static let accounts: Set<String> = [
        "copilot", "copilot-swe-agent", "github-copilot", "claude", "anthropic-claude", "claude-code",
        "codex", "chatgpt-codex-connector", "openai-codex", "cursor", "cursoragent", "cursor-agent",
        "gemini-code-assist", "gemini-cli", "google-labs-jules", "jules", "devin-ai-integration",
        "amazon-q-developer", "sweep-ai", "aider", "opencode", "grok", "antigravity",
    ]

    /// Names coding agents give themselves: the first word of a co-author with a no-reply address, or the tool a
    /// "Generated with …" line names.
    static let names: Set<String> = [
        "claude", "codex", "chatgpt", "openai", "cursor", "gemini", "copilot", "aider", "devin", "amp", "opencode",
        "grok", "jules", "antigravity", "windsurf", "cline", "kimi", "qwen", "hermes", "muse",
    ]

    private static let trailer = try! NSRegularExpression(
        pattern: #"^\s*co-authored-by:\s*(.*?)\s*<([^>]*)>\s*$"#, options: [.caseInsensitive])

    /// Whether a co-author is a coding agent rather than a person. A person named Claude with their own address stays.
    static func isAgent(name: String, email: String) -> Bool {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        if addresses.contains(address) { return true }
        if address.hasSuffix("@users.noreply.github.com") {
            var login = String(address.prefix { $0 != "@" })
            if let plus = login.firstIndex(of: "+"), login[..<plus].allSatisfy(\.isNumber) { login = String(login[login.index(after: plus)...]) }
            let bot = login.hasSuffix("[bot]")
            if bot { login = String(login.dropLast(5)) }
            if accounts.contains(login) { return true }
            if bot, let first = words(login).first, names.contains(first) { return true }
        }
        let noReply = address.contains("noreply") || address.contains("no-reply")
        if noReply, let first = words(name).first, names.contains(first) { return true }
        return false
    }

    /// A `Co-authored-by:` trailer of a coding agent.
    static func isAgentTrailer(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = trailer.firstMatch(in: line, range: range), match.numberOfRanges == 3,
              let name = Range(match.range(at: 1), in: line), let email = Range(match.range(at: 2), in: line) else { return false }
        return isAgent(name: String(line[name]), email: String(line[email]))
    }

    /// A "🤖 Generated with [Claude Code](…)" line: generated with or by a coding agent it names. "Generated with protoc"
    /// stays.
    static func isGeneratedLine(_ line: String) -> Bool {
        let text = line.drop { !$0.isLetter }.lowercased()
        guard text.hasPrefix("generated with ") || text.hasPrefix("generated by ") else { return false }
        // The agent named right after it ("Generated with Claude Code", "generated by [Codex]"), not anywhere in a
        // sentence a person wrote ("Generated by running gemini against fixtures").
        let rest = Array(words(text).dropFirst(2))
        guard let first = rest.first else { return false }
        if names.contains(first) { return true }
        return ["github", "google", "anthropic", "openai", "xai", "the"].contains(first) && rest.dropFirst().first.map(names.contains) == true
    }

    /// The message without the agents' credits. Blank lines a removed line leaves behind go too; a message with nothing
    /// to remove comes back unchanged.
    static func strip(_ message: String) -> String {
        let lines = message.components(separatedBy: "\n")
        guard lines.contains(where: { isAgentTrailer($0) || isGeneratedLine($0) }) else { return message }
        var kept: [String] = []
        var removedSinceText = false
        for line in lines {
            if isAgentTrailer(line) || isGeneratedLine(line) {
                removedSinceText = true
                continue
            }
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, removedSinceText, kept.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true { continue }
            if !blank { removedSinceText = false }
            kept.append(line)
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// Lowercased words of letters and digits: "Claude Opus 4.5" → claude, opus, 4, 5.
    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// The commit GitHub makes when it merges a pull request, by the repository's own settings, so Nook can ask for the same
/// commit without agent credits (`AgentCredits`). Rebase merges keep every commit as it is, so they have no message here.
enum PullRequestMergeMessage {
    /// The repository's choices for merge and squash commits (GitHub's `merge_commit_title`, `merge_commit_message`,
    /// `squash_merge_commit_title`, `squash_merge_commit_message`), with GitHub's defaults when it did not say.
    struct Settings: Equatable, Sendable {
        var mergeTitle = "MERGE_MESSAGE"
        var mergeMessage = "PR_TITLE"
        var squashTitle = "COMMIT_OR_PR_TITLE"
        var squashMessage = "COMMIT_MESSAGES"

        init() {}

        init(repository: [String: Any]) {
            func text(_ key: String) -> String? { (repository[key] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() } }
            mergeTitle = text("merge_commit_title") ?? mergeTitle
            mergeMessage = text("merge_commit_message") ?? mergeMessage
            squashTitle = text("squash_merge_commit_title") ?? squashTitle
            squashMessage = text("squash_merge_commit_message") ?? squashMessage
        }
    }

    /// What to send in the merge request: only the parts that differ from GitHub's own, nil each when GitHub's stands.
    struct Override: Equatable, Sendable {
        var title: String?
        var message: String?
    }

    /// One commit of the branch: its message and its author (`login` is the GitHub account, when GitHub knows it).
    struct Commit: Equatable, Sendable {
        var message: String
        var login: String?
        var name: String
        var email: String
    }

    /// The `Co-authored-by:` lines GitHub adds to a squash commit for the people who wrote commits on the branch: every
    /// author but the one merging, once, never an agent, and not one the message names already.
    static func coAuthorLines(_ commits: [Commit], merger: String?, existing message: String) -> [String] {
        let named = message.lowercased()
        var seen = Set<String>()
        var lines: [String] = []
        for commit in commits {
            let email = commit.email.trimmingCharacters(in: .whitespaces)
            let name = commit.name.trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty, !name.isEmpty, seen.insert(email.lowercased()).inserted else { continue }
            if let merger, let login = commit.login, login.caseInsensitiveCompare(merger) == .orderedSame { continue }
            if AgentCredits.isAgent(name: name, email: email) { continue }
            if let login = commit.login, AgentCredits.accounts.contains(login.lowercased().replacingOccurrences(of: "[bot]", with: "")) { continue }
            if named.contains("<" + email.lowercased() + ">") { continue }
            lines.append("Co-authored-by: \(name) <\(email)>")
        }
        return lines
    }

    /// GitHub's default title and message for the merge; nil for a rebase. `headLabel` is "owner/branch".
    static func defaults(method: PullRequestMergeMethod, number: Int, title: String, body: String, headLabel: String,
                         commits: [String], settings: Settings) -> (title: String, message: String)? {
        let numbered = "\(title) (#\(number))"
        switch method {
        case .rebase:
            return nil
        case .merge:
            let head = settings.mergeTitle == "PR_TITLE" ? numbered : "Merge pull request #\(number) from \(headLabel)"
            switch settings.mergeMessage {
            case "PR_BODY": return (head, body)
            case "BLANK": return (head, "")
            default: return (head, title)
            }
        case .squash:
            let messages = commits.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let single = messages.count == 1 ? messages[0] : nil
            let subject = single.map { String($0.prefix { $0 != "\n" }) }
            let head = settings.squashTitle == "PR_TITLE" ? numbered : subject.map { "\($0) (#\(number))" } ?? numbered
            switch settings.squashMessage {
            case "PR_BODY": return (head, body)
            case "BLANK": return (head, "")
            default:
                if let single {
                    let rest = single.drop { $0 != "\n" }
                    return (head, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return (head, messages.map { "* " + $0 }.joined(separator: "\n\n"))
            }
        }
    }

    /// The parts of GitHub's default commit that change without agent credits; nil when nothing changes, so the merge
    /// goes out exactly as before. A squash message that is sent keeps the people GitHub would have credited
    /// (`coAuthorLines`), since GitHub adds them only to its own default.
    static func withoutCredits(method: PullRequestMergeMethod, number: Int, title: String, body: String, headLabel: String,
                               commits: [Commit], merger: String?, settings: Settings) -> Override? {
        guard let commit = defaults(method: method, number: number, title: title, body: body, headLabel: headLabel,
                                    commits: commits.map(\.message), settings: settings) else { return nil }
        let cleanTitle = AgentCredits.strip(commit.title)
        var cleanMessage = AgentCredits.strip(commit.message)
        let override = Override(title: cleanTitle == commit.title || cleanTitle.isEmpty ? nil : cleanTitle,
                                message: cleanMessage == commit.message ? nil : cleanMessage)
        guard override.title != nil || override.message != nil else { return nil }
        guard method == .squash, override.message != nil else { return override }
        let people = coAuthorLines(commits, merger: merger, existing: cleanMessage)
        if !people.isEmpty {
            cleanMessage += (cleanMessage.isEmpty ? "" : "\n\n") + people.joined(separator: "\n")
        }
        return Override(title: override.title, message: cleanMessage)
    }
}
