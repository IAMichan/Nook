import Foundation

// `nook://prompt?text=…&project=…&agent=…&model=…`. A link only fills a draft; it never sends,
// never sets permissions or a branch. Hidden characters are removed because they can smuggle instructions to the agent.

struct PromptLink: Equatable, Sendable {
    static let maxTextLength = 8_000

    enum Warning: String, Hashable, Sendable {
        case strippedHiddenCharacters, droppedProject, droppedAgent, droppedModel
    }

    var text: String
    var project: String?
    var agent: String?
    var model: String?
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

    static func parse(url: URL) -> PromptLink? {
        guard url.scheme?.lowercased() == "nook",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.lowercased() == "prompt" else { return nil }
        var first: [String: String] = [:]
        for item in parts.queryItems ?? [] where first[item.name] == nil { first[item.name] = item.value ?? "" }

        guard let raw = first["text"] else { return nil }
        let cleaned = sanitize(raw)
        let text = cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cut-off prompts change meaning, so an overlong one is refused instead of truncated.
        guard !text.isEmpty, text.count <= maxTextLength else { return nil }

        var link = PromptLink(text: text)
        if cleaned.stripped { link.warnings.insert(.strippedHiddenCharacters) }
        if let p = first["project"], !p.isEmpty { if let v = validProject(p) { link.project = v } else { link.warnings.insert(.droppedProject) } }
        if let a = first["agent"], !a.isEmpty { if let v = validAgent(a) { link.agent = v } else { link.warnings.insert(.droppedAgent) } }
        if let m = first["model"], !m.isEmpty { if let v = validModel(m) { link.model = v } else { link.warnings.insert(.droppedModel) } }
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
    static func build(text: String, project: String? = nil, agent: String? = nil, model: String? = nil) -> URL? {
        let cleaned = sanitize(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= maxTextLength else { return nil }
        var query = "text=" + encode(cleaned)
        if let project, let v = validProject(project) { query += "&project=" + encode(v) }
        if let agent, let v = validAgent(agent) { query += "&agent=" + encode(v) }
        if let model, let v = validModel(model) { query += "&model=" + encode(v) }
        return URL(string: "nook://prompt?" + query)
    }
}
