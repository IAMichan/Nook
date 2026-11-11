import Foundation

// `nook://prompt?text=…&project=…&repo=owner/name&agent=…&model=…&pr=owner/name/123`. A link only fills a draft; it never
// sends, never sets permissions or a branch. Hidden characters are removed because they can smuggle instructions to the
// agent. `repo` picks the project whose GitHub remote it names; `pr` opens the session linked to that pull request, or
// (after you confirm) a draft in a new worktree on its branch. Only a pull request link may come without text.

struct PromptLink: Equatable, Sendable {
    static let maxTextLength = 8_000

    enum Warning: String, Hashable, Sendable {
        case strippedHiddenCharacters, droppedProject, droppedAgent, droppedModel, droppedRepository, droppedPullRequest
    }

    /// A GitHub pull request named by a link: `owner/name` and its number.
    struct PullRequest: Equatable, Hashable, Sendable {
        var repository: String
        var number: Int

        var url: String { "https://github.com/\(repository)/pull/\(number)" }
    }

    var text: String
    var project: String?
    var agent: String?
    var model: String?
    /// A GitHub repository as `owner/name`.
    var repository: String?
    var pullRequest: PullRequest?
    var warnings: Set<Warning> = []

    /// Control, format (zero-width, bidi, soft hyphen) and tag characters out; newline and tab stay.
    static func sanitize(_ raw: String) -> (text: String, stripped: Bool) {
        var out = String.UnicodeScalarView()
        var stripped = false
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for s in unified.unicodeScalars {
            if s == "\n" || s == "\t" { out.append(s); continue }
            switch s.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                stripped = true
            default:
                if (0xE0000...0xE007F).contains(s.value) { stripped = true } else { out.append(s) }
            }
        }
        return (String(out), stripped)
    }

    private static func isAllowed(_ s: String, max: Int, extra: (Unicode.Scalar) -> Bool) -> Bool {
        !s.isEmpty && s.unicodeScalars.count <= max && s.unicodeScalars.allSatisfy(extra)
    }

    /// A plain name or a path hint; never `..`, never control characters.
    static func validProject(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.unicodeScalars.count <= 512 else { return nil }
        guard !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) else { return nil }
        guard !s.contains("\\"), !s.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return s
    }

    static func validAgent(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return isAllowed(s, max: 40) { $0.isASCII && ($0.properties.numericType != nil || ("a"..."z").contains(Character($0)) || "-_.".unicodeScalars.contains($0)) } ? s : nil
    }

    static func validModel(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let ok = isAllowed(s, max: 100) { $0.isASCII && (("a"..."z").contains(Character($0)) || ("A"..."Z").contains(Character($0)) || ("0"..."9").contains(Character($0)) || "-_.:/@+".unicodeScalars.contains($0)) }
        return ok ? s : nil
    }

    /// One part of a GitHub repository path: letters, digits, `-`, `_` and `.`, never `.` or `..` alone.
    private static func validPathPart(_ s: Substring, max: Int) -> Bool {
        !s.isEmpty && s.count <= max && s != "." && s != ".."
            && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    /// The path of a GitHub address or the text itself, split at `/`: `https://github.com/a/b/pull/1` gives `a b pull 1`.
    /// Nil for another host or scheme.
    private static func githubPath(_ raw: String) -> [Substring]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.unicodeScalars.count <= 300 else { return nil }
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            guard s.lowercased().hasPrefix("github.com/") || s.lowercased().hasPrefix("www.github.com/") else { return nil }
        }
        if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if s.lowercased().hasPrefix("github.com/") { s = String(s.dropFirst("github.com/".count)) }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        return s.split(separator: "/", omittingEmptySubsequences: true)
    }

    /// `owner/name`, or the address of the repository on GitHub (with `.git`, or a page in it); nil for anything else.
    static func validRepository(_ raw: String) -> String? {
        guard let parts = githubPath(raw), parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name = name.dropLast(4) }
        guard validPathPart(parts[0], max: 39), validPathPart(name, max: 100) else { return nil }
        return "\(parts[0])/\(name)"
    }

    /// `owner/name/123`, `owner/name#123`, or the pull request's address on GitHub; nil for anything else.
    static func validPullRequest(_ raw: String) -> PullRequest? {
        let hashed = raw.trimmingCharacters(in: .whitespaces)
        if !hashed.contains("://"), let hash = hashed.lastIndex(of: "#") {
            guard let repo = validRepository(String(hashed[..<hash])), let number = Int(hashed[hashed.index(after: hash)...]),
                  (1...999_999_999).contains(number) else { return nil }
            return PullRequest(repository: repo, number: number)
        }
        guard let parts = githubPath(hashed) else { return nil }
        let numberPart: Substring
        switch parts.count {
        case 3: numberPart = parts[2]
        case 4... where parts[2] == "pull": numberPart = parts[3]
        default: return nil
        }
        guard let repo = validRepository("\(parts[0])/\(parts[1])"), numberPart.allSatisfy(\.isASCII),
              let number = Int(numberPart), (1...999_999_999).contains(number) else { return nil }
        return PullRequest(repository: repo, number: number)
    }

    static func parse(url: URL) -> PromptLink? {
        guard url.scheme?.lowercased() == "nook",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.lowercased() == "prompt" else { return nil }
        var first: [String: String] = [:]
        for item in parts.queryItems ?? [] where first[item.name] == nil { first[item.name] = item.value ?? "" }

        // A pull request link may come without words: it opens the session that works on that request.
        let pullRequest = first["pr"].flatMap { $0.isEmpty ? nil : validPullRequest($0) }
        let cleaned = sanitize(first["text"] ?? "")
        let text = cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cut-off prompts change meaning, so an overlong one is refused instead of truncated.
        guard !text.isEmpty || pullRequest != nil, text.count <= maxTextLength else { return nil }

        var link = PromptLink(text: text)
        if cleaned.stripped { link.warnings.insert(.strippedHiddenCharacters) }
        if let p = first["project"], !p.isEmpty { if let v = validProject(p) { link.project = v } else { link.warnings.insert(.droppedProject) } }
        if let a = first["agent"], !a.isEmpty { if let v = validAgent(a) { link.agent = v } else { link.warnings.insert(.droppedAgent) } }
        if let m = first["model"], !m.isEmpty { if let v = validModel(m) { link.model = v } else { link.warnings.insert(.droppedModel) } }
        if let r = first["repo"], !r.isEmpty { if let v = validRepository(r) { link.repository = v } else { link.warnings.insert(.droppedRepository) } }
        if let pr = first["pr"], !pr.isEmpty {
            if let pullRequest { link.pullRequest = pullRequest } else { link.warnings.insert(.droppedPullRequest) }
        }
        return link
    }

    private static func encode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            let c = Character(Unicode.Scalar(byte))
            if byte < 128, c.isLetter || c.isNumber || "-._~".contains(c) { out.append(c) }
            else { out += String(format: "%%%02X", byte) }
        }
        return out
    }

    /// Nil when the text is empty or too long after sanitising, so a link that `parse` would refuse is never made.
    static func build(text: String, project: String? = nil, agent: String? = nil, model: String? = nil,
                      repository: String? = nil, pullRequest: PullRequest? = nil) -> URL? {
        let cleaned = sanitize(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty || pullRequest != nil, cleaned.count <= maxTextLength else { return nil }
        var parts: [String] = cleaned.isEmpty ? [] : ["text=" + encode(cleaned)]
        if let project, let v = validProject(project) { parts.append("project=" + encode(v)) }
        if let repository, let v = validRepository(repository) { parts.append("repo=" + encode(v)) }
        if let agent, let v = validAgent(agent) { parts.append("agent=" + encode(v)) }
        if let model, let v = validModel(model) { parts.append("model=" + encode(v)) }
        if let pullRequest { parts.append("pr=" + encode("\(pullRequest.repository)/\(pullRequest.number)")) }
        return URL(string: "nook://prompt?" + parts.joined(separator: "&"))
    }
}

extension PromptLink {
    /// The project the link names among the ones a Mac offers: by its name, or by the end of its path
    /// (`app`, `code/app`). Nil when it names none, so the default stays.
    func project(in projects: [LaunchOptions.Project]) -> LaunchOptions.Project? {
        guard let hint = project?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(), !hint.isEmpty else { return nil }
        return projects.first { $0.name.lowercased() == hint }
            ?? projects.first { $0.path.lowercased().hasSuffix("/" + hint) || $0.path.lowercased() == hint }
    }

    /// The agent the link names: its exact id, else the agent whose id starts with it (`claude` → `claude-code`).
    func agent(in agents: [LaunchOptions.Agent]) -> LaunchOptions.Agent? {
        guard let hint = agent, !hint.isEmpty else { return nil }
        return agents.first { $0.id == hint } ?? agents.first { $0.id.hasPrefix(hint) }
    }
}
