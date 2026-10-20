import Foundation

/// GitHub-flavoured Markdown as written in pull request descriptions, reviews and comments, rewritten into the Markdown
/// Nook's renderer draws. Reviews (review bots above all) mix in HTML that GitHub renders and Nook would show as raw
/// tags: `<details>`/`<summary>`, `<!-- … -->` markers, `<b>`, `<a href>`, `<sub>`, entities. Code blocks nested in a
/// list item are moved out of the item, so they draw as code instead of being glued onto the item's text.
enum GitHubMarkdown {
    static func markdown(_ raw: String) -> String {
        let text = raw.contains("\r") ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        var output: [String] = []
        var prose: [String] = []
        var lines = text.components(separatedBy: "\n")[...]

        func flushProse() {
            guard !prose.isEmpty else { return }
            output.append(html(prose.joined(separator: "\n")))
            prose.removeAll()
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let fence = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) else {
                prose.append(line)
                continue
            }
            flushProse()
            // A fence indented under a list item: its lines lose that indent, so the block stands on its own.
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            var block = ["```" + trimmed.dropFirst(fence.count)]
            while let inner = lines.popFirst() {
                if inner.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                let lead = min(indent, inner.prefix { $0 == " " || $0 == "\t" }.count)
                block.append(String(inner.dropFirst(lead)))
            }
            block.append("```")
            output.append("\n" + block.joined(separator: "\n") + "\n")
        }
        flushProse()
        return collapse(output.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTML

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let spanRegex = regex(#"`[^`\n]+`"#)
    private static let placeholderRegex = regex("\u{E000}([0-9]+)\u{E001}")
    private static let commentRegex = regex(#"<!--.*?(-->|$)"#)
    private static let summaryRegex = regex(#"<summary[^>]*>(.*?)</summary>"#)
    private static let headingRegex = regex(#"<h([1-6])[^>]*>(.*?)</h\1>"#)
    private static let linkRegex = regex(#"<a\s[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>"#)
    private static let imageRegex = regex(#"<img\s[^>]*?>"#)
    private static let altRegex = regex(#"\balt\s*=\s*["']([^"']*)["']"#)
    private static let breakRegex = regex(#"<br\s*/?>"#)
    private static let ruleRegex = regex(#"<hr\s*/?>"#)
    private static let boldRegex = regex(#"</?(b|strong)\s*>"#)
    private static let italicRegex = regex(#"</?(i|em)\s*>"#)
    private static let codeRegex = regex(#"</?(code|kbd|tt)\s*>"#)
    private static let itemRegex = regex(#"<li[^>]*>"#)
    private static let blockRegex = regex(#"</?(details|p|div|ul|ol|table|blockquote|pre|center)(\s[^>]*)?>|</li\s*>"#)
    /// Tags that only style a run of text; what is inside stays.
    private static let inlineRegex = regex(#"</?(sub|sup|small|span|ins|u|mark|font|picture|source|a|del|s|strike|summary|img)(\s[^>]*)?/?>"#)

    private static func replace(_ text: String, _ rx: NSRegularExpression?, _ transform: ([String]) -> String) -> String {
        guard let rx else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    /// The text inside a tag, on one line and without the tags or emphasis around it.
    private static func plain(_ text: String) -> String {
        let flat = replace(replace(text, boldRegex) { _ in "" }, inlineRegex) { _ in "" }
            .replacingOccurrences(of: "**", with: "")
        return flat.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func html(_ text: String) -> String {
        guard text.contains("<") || text.contains("&") else { return text }
        // Inline code keeps its tags and entities: set aside before, put back after.
        var spans: [String] = []
        var text = replace(text, spanRegex) { groups in
            spans.append(groups[0])
            return "\u{E000}\(spans.count - 1)\u{E001}"
        }
        text = replace(text, commentRegex) { _ in "" }
        text = replace(text, summaryRegex) { groups in
            let title = plain(groups[1])
            return title.isEmpty ? "\n\n" : "\n\n**" + title + "**\n\n"
        }
        text = replace(text, headingRegex) { groups in
            "\n\n" + String(repeating: "#", count: Int(groups[1]) ?? 3) + " " + plain(groups[2]) + "\n\n"
        }
        text = replace(text, imageRegex) { groups in
            let alt = altRegex?.firstMatch(in: groups[0], range: NSRange(location: 0, length: (groups[0] as NSString).length))
                .map { (groups[0] as NSString).substring(with: $0.range(at: 1)) } ?? ""
            return alt
        }
        text = replace(text, linkRegex) { groups in
            let label = plain(groups[2])
            let url = groups[1]
            guard url.hasPrefix("http") else { return label }
            return "[" + (label.isEmpty ? url : label) + "](" + url + ")"
        }
        text = replace(text, breakRegex) { _ in "\n" }
        text = replace(text, ruleRegex) { _ in "\n\n---\n\n" }
        text = replace(text, boldRegex) { _ in "**" }
        text = replace(text, italicRegex) { _ in "*" }
        text = replace(text, codeRegex) { _ in "`" }
        text = replace(text, itemRegex) { _ in "\n- " }
        text = replace(text, blockRegex) { _ in "\n\n" }
        text = replace(text, inlineRegex) { _ in "" }
        return replace(entities(text), placeholderRegex) { groups in Int(groups[1]).map { spans[$0] } ?? "" }
    }

    private static let namedEntities: [String: String] = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&#x27;": "'",
        "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rarr;": "→", "&larr;": "←", "&check;": "✓", "&times;": "×",
    ]

    private static func entities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, value) in namedEntities { result = result.replacingOccurrences(of: entity, with: value) }
        // Last, so "&amp;lt;" stays the literal text "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Lines left with only spaces become empty, and runs of empty lines one.
    private static func collapse(_ text: String) -> String {
        var result: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            let blank = !inCode && line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, result.last?.isEmpty ?? true { continue }
            result.append(blank ? "" : line)
        }
        return result.joined(separator: "\n")
    }
}
