import Foundation

/// `nook://session/<id>?title=…`: a link to one of the sessions Nook runs. "Copy session link" in a session's menu makes
/// one, dragging a session row out of the Agents list carries one, and pasting or dropping it on an agent's composer turns
/// it into that session's chip (`ContextRef` of kind `.session`), the same as picking it after `@`. Opened from anywhere
/// else (a note, another app), it opens the session. The id is a run's UUID; the title is only a label for the chip and
/// never decides which session is meant.
struct SessionLink: Equatable, Sendable {
    static let scheme = "nook"
    static let host = "session"
    /// A label longer than this is cut: a title only names the chip.
    static let maxTitleLength = 200

    /// The session's id, as the composer's `@` list uses it (a run's UUID, lowercased).
    var id: String
    var title: String

    /// The reference a composer shows as a chip.
    var ref: ContextRef { ContextRef(kind: .session, id: id, label: title) }

    /// Nil for an id that is not a UUID: a link only ever names a session, never a path or a command.
    static func build(id: String, title: String) -> URL? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.path = "/" + uuid.uuidString.lowercased()
        let label = clean(title)
        if !label.isEmpty { parts.queryItems = [URLQueryItem(name: "title", value: label)] }
        return parts.url
    }

    static func parse(_ url: URL) -> SessionLink? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let segments = parts.path.split(separator: "/")
        guard segments.count == 1, let uuid = UUID(uuidString: String(segments[0])) else { return nil }
        let title = clean(parts.queryItems?.first { $0.name == "title" }?.value ?? "")
        let id = uuid.uuidString.lowercased()
        return SessionLink(id: id, title: title.isEmpty ? String(id.prefix(8)) : title)
    }

    static func parse(_ text: String) -> SessionLink? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(parse)
    }

    /// The session links in a text with their ranges, in order: a paste may hold one among other words.
    static func find(in text: String) -> [(link: SessionLink, range: Range<String.Index>)] {
        guard text.contains("nook://session/") else { return [] }
        var found: [(SessionLink, Range<String.Index>)] = []
        var cursor = text.startIndex
        while let start = text.range(of: "nook://session/", range: cursor..<text.endIndex) {
            let end = text[start.lowerBound...].firstIndex { $0.isWhitespace || $0 == ")" || $0 == "]" || $0 == ">" } ?? text.endIndex
            let candidate = text[start.lowerBound..<end]
            if let link = parse(String(candidate)) { found.append((link, start.lowerBound..<end)) }
            cursor = end
        }
        return found
    }

    /// What a composer's text becomes when a session link was pasted into it: each bare link that was added turns into the
    /// session's chip (`ContextRefs.link`). Links already inside a chip (`nook-context://`) are not touched, and neither
    /// is text that holds no new link. Nil when there is nothing to change.
    static func replacingPasted(old: String, new: String) -> String? {
        let added = find(in: new)
        guard !added.isEmpty, added.count > find(in: old).count else { return nil }
        var result = new
        for item in added.reversed() {
            result.replaceSubrange(item.range, with: ContextRefs.link(item.link.ref))
        }
        return result
    }

    /// The draft with a session's chip after the words typed so far (a dropped row): files attached at the end stay there.
    static func inserting(_ link: SessionLink, into text: String) -> String {
        let body = ComposerAttachments.split(text).body
        let separator = body.isEmpty || body.last?.isWhitespace == true ? "" : " "
        return ComposerAttachments.replacingBody(of: text, with: body + separator + ContextRefs.link(link.ref) + " ")
    }

    /// One line, no control characters, at most `maxTitleLength` characters.
    private static func clean(_ title: String) -> String {
        let flat = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let line = String(String.UnicodeScalarView(flat)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(maxTitleLength))
    }
}
