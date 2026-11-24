import Foundation

/// A block within a Markdown answer. Equatable, so a finished block of a streaming answer is not drawn again.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A bulleted or numbered list; nested items keep their depth.
    case list([MarkdownListItem])
    /// A fenced code block: its language (lowercased, "" when none) and the file it names in its fence
    /// (```` ```ts title="App.tsx" ```` or ```` ```App.tsx ````), nil when it names none.
    case code(language: String, code: String, title: String?)
    case chart(ChatChart)
    /// A question from the answer with options to pick from (a ```question block).
    case question(text: String, options: [String])
    case quote(String)
    /// A mail for the user to send: a ```mail block, or a quote that reads as a mail (`MailTemplate`).
    case mail(MailTemplate)
    case table(header: [String], rows: [[String]])
    case rule
    /// A pull request an agent reports on a line of its own (`<pr-created>https://…/pull/12</pr-created>`).
    case pullRequest(URL)
    /// A display formula in TeX: a ```math block, or `$$…$$` / `\[…\]` on lines of their own (`MathText`).
    case math(String)
    /// A folded passage the answer wrote as `<details><summary>…</summary>…</details>`: its summary and its Markdown.
    case details(summary: String, body: String)
    /// An image on a line of its own (`![alt](https://…/a.png)` or a path on this Mac).
    case image(alt: String, source: String)
    /// Pictures side by side, as GitHub draws a README's badges: images on consecutive lines of their own, each maybe a
    /// link (`[![CI](https://…/badge.svg)](https://…)`).
    case images([MarkdownImage])

    private static let brRegex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let headingRegex = try? NSRegularExpression(pattern: #"^#{1,6}\s"#)
    private static let ruleRegex = try? NSRegularExpression(pattern: #"^([-*_]\s*){3,}$"#)
    private static let tableDividerRegex = try? NSRegularExpression(pattern: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#)
    private static let bulletRegex = try? NSRegularExpression(pattern: #"^\s*[-*•◦▪+]\s+"#)
    private static let numberRegex = try? NSRegularExpression(pattern: #"^\s*\d{1,3}[.)]\s+"#)
    /// A bullet glyph a model typed after the list marker ("- • text"): it would show up as a second bullet.
    private static let strayBulletRegex = try? NSRegularExpression(pattern: #"^[•◦▪]\s+"#)

    /// An agent's own tag around a value, as Claude Code reports what it made (`<pr-created>…</pr-created>`). Only names
    /// with a dash or an underscore, so HTML a model writes on purpose (`<b>`, `<kbd>`) stays as it is.
    private static let agentTagRegex = try? NSRegularExpression(pattern: #"<([a-z][a-z0-9]*(?:[-_][a-z0-9]+)+)>\s*([^<]*?)\s*</\1>"#)

    private static func matches(_ text: String, _ rx: NSRegularExpression?) -> Bool {
        guard let rx else { return false }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func stripPrefix(_ text: String, _ rx: NSRegularExpression?) -> String {
        guard let rx else { return text }
        return rx.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Cleans up artifacts models sometimes output: trailing backslashes (hard breaks), `<br>`, and Windows line endings.
    static func clean(_ text: String) -> String {
        // By its scalars: "\r\n" is one Character in Swift, so `text.contains("\r")` misses every Windows line end.
        var normalized = text.unicodeScalars.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        if normalized.contains("<"), let rx = brRegex {
            normalized = rx.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "\n")
        }
        guard normalized.contains("\\") else { return normalized }
        return normalized
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "\\" || trimmed == "\\\\" { return "" }
                if line.hasSuffix("\\"), !line.hasSuffix("\\\\") { return String(line.dropLast()) }
                return line
            }
            .joined(separator: "\n")
    }

    private static let chartLanguages: Set<String> = ["chart", "chartjs", "vega", "vega-lite", "mermaid", "json"]

    /// `{"question": "...", "options": ["a", {"label": "b"}]}` as the model writes it in a ```question block.
    private static func question(from body: String) -> MarkdownBlock? {
        guard let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["question"] as? String else { return nil }
        let options = ((object["options"] as? [Any]) ?? []).compactMap { item -> String? in
            if let label = item as? String { return label }
            return (item as? [String: Any])?["label"] as? String
        }
        return options.count >= 2 ? .question(text: text, options: options) : nil
    }

    /// Options at the end of an answer that closes a question: the last list after a paragraph that asks something.
    static func trailingChoices(_ blocks: [MarkdownBlock]) -> (index: Int, options: [String])? {
        guard blocks.count >= 2, case .paragraph(let ask) = blocks[blocks.count - 2],
              ask.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") || ask.contains("?") && ask.hasSuffix(":") else { return nil }
        let last = blocks.count - 1
        guard case .list(let items) = blocks[last], (2...6).contains(items.count), items.allSatisfy({ $0.level == 0 }) else { return nil }
        return (last, items.map { stripTask($0.text) })
    }

    /// `[ ]` / `[x]` task markers at the start of a list item.
    static func task(_ item: String) -> (done: Bool, text: String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(marker) {
            return (done, String(item.dropFirst(marker.count)))
        }
        return nil
    }

    private static func stripTask(_ item: String) -> String { task(item)?.text ?? item }

    /// Leading whitespace of a line in columns; a tab counts as four.
    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// The list item a line starts, if any: its indent, its number when numbered, and its text.
    private static func listMarker(_ line: String) -> (indent: Int, number: String?, text: String)? {
        let number: String?
        let rest: String
        if matches(line, bulletRegex) {
            number = nil
            rest = stripPrefix(line, bulletRegex)
        } else if matches(line, numberRegex) {
            number = String(line.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) + "."
            rest = stripPrefix(line, numberRegex)
        } else {
            return nil
        }
        return (indent(line), number, stripPrefix(rest, strayBulletRegex))
    }

    /// A list from `index` on, bulleted, numbered, or both mixed, with each item's depth taken from its indent.
    private static func parseList(_ lines: [String], from index: inout Int) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []
        // The indents of the levels that are open, outermost first.
        var levels: [Int] = []
        while index < lines.count {
            let line = lines[index]
            if let marker = listMarker(line) {
                while let last = levels.last, marker.indent < last { levels.removeLast() }
                if levels.last.map({ marker.indent > $0 }) ?? true { levels.append(marker.indent) }
                items.append(MarkdownListItem(level: levels.count - 1, number: marker.number, text: marker.text))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line between items keeps the list going ("loose" lists).
                guard index + 1 < lines.count, listMarker(lines[index + 1]) != nil else { break }
            } else if indent(line) >= 2, !items.isEmpty {
                items[items.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
            index += 1
        }
        return items
    }

    /// The pull request of a line that is only an agent's tag around its link.
    static func pullRequestLine(_ line: String) -> URL? {
        guard line.hasPrefix("<"), line.hasSuffix(">"), let rx = agentTagRegex,
              let match = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.range.length == (line as NSString).length,
              let value = Range(match.range(at: 2), in: line), let url = URL(string: String(line[value])),
              pullRequestReference(url) != nil else { return nil }
        return url
    }

    private static let gitHubPullRequestRegex = try? NSRegularExpression(pattern: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#)

    /// The last GitHub pull request link in a text, tagged with `<pr-created>` or written out.
    static func lastGitHubPullRequest(in text: String) -> URL? {
        guard containsBytes(text, "/pull/"), let rx = gitHubPullRequestRegex,
              let match = rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }

    /// Whether a text holds a needle, compared as bytes (`memmem`): `String.contains` walked megabytes of tool output
    /// character by character. Its own, not `SearchText.contains`: this file is part of the iPhone app too, which has no
    /// search.
    private static func containsBytes(_ haystack: String, _ needle: String) -> Bool {
        var haystack = haystack, needle = needle
        return haystack.withUTF8 { text in
            needle.withUTF8 { wanted in
                guard let base = text.baseAddress, let pattern = wanted.baseAddress, wanted.count <= text.count else { return false }
                return memmem(base, text.count, pattern, wanted.count) != nil
            }
        }
    }

    /// "owner/repo" and the number of a GitHub pull request or GitLab merge request link.
    static func pullRequestReference(_ url: URL) -> (repo: String, number: Int)? {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http", isSafeLink(url) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let at = parts.firstIndex(where: { $0 == "pull" || $0 == "merge_requests" }), at >= 2, at + 1 < parts.count,
              let number = Int(parts[at + 1]) else { return nil }
        // GitLab puts a "-" between the project and its merge requests.
        return (parts[..<at].filter { $0 != "-" }.joined(separator: "/"), number)
    }

    /// Takes agents' tags off a line and keeps what they hold; a link inside becomes a link.
    static func untag(_ line: String) -> String {
        guard line.contains("</"), let rx = agentTagRegex else { return line }
        var result = line
        for match in rx.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let whole = Range(match.range, in: result), let value = Range(match.range(at: 2), in: line) else { continue }
            let inner = String(line[value])
            result.replaceSubrange(whole, with: inner.hasPrefix("http://") || inner.hasPrefix("https://") ? "<\(inner)>" : inner)
        }
        return result
    }

    private static let fenceTitleRegex = try? NSRegularExpression(
        pattern: #"(?:^|\s)(?:title|file(?:name)?)=(?:"([^"]+)"|'([^']+)'|(\S+))"#, options: [.caseInsensitive])
    private static let fenceFileRegex = try? NSRegularExpression(pattern: #"^[\w@][\w@./-]*\.[A-Za-z0-9]+$"#)

    /// The language and file name in the text after a code fence's backticks: ```` ```ts title="a.ts" ```` gives
    /// ("ts", "a.ts"), ```` ```src/App.tsx ```` gives ("tsx", "src/App.tsx"), ```` ```swift ```` gives ("swift", nil).
    static func fence(_ info: String) -> (language: String, title: String?) {
        let words = info.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return ("", nil) }
        var title: String?
        if let rx = fenceTitleRegex, let match = rx.firstMatch(in: info, range: NSRange(info.startIndex..., in: info)) {
            title = (1...3).lazy.compactMap { Range(match.range(at: $0), in: info).map { String(info[$0]) } }.first
        }
        if title == nil { title = words.first { matches($0, fenceFileRegex) && !$0.contains("=") } }
        // A fence that opens with a file name and no language: the language is the file's extension.
        if matches(first, fenceFileRegex), !first.contains("=") {
            return ((first as NSString).pathExtension.lowercased(), title)
        }
        return (first.contains("=") ? "" : first.lowercased(), title)
    }

    private static let imageItemRegex = try? NSRegularExpression(pattern:
        #"\[!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)|!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)

    /// Whether an image source can be shown: a web address or a path on this Mac (relative to the file's folder too).
    private static func isImageSource(_ source: String) -> Bool {
        let lower = source.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("file://")
            || source.hasPrefix("/") || source.hasPrefix("~/") || source.hasPrefix("./") || !source.contains(":")
    }

    /// The alt text and source of a line that is only an image, when the source is a web address or a path on this Mac.
    static func imageLine(_ line: String) -> (alt: String, source: String)? {
        guard let row = imageRow(line), row.count == 1, row[0].link == nil else { return nil }
        return (row[0].alt, row[0].source)
    }

    /// The images of a line that holds nothing else: one or more, each maybe inside a link, apart by spaces. Nil when
    /// anything else is on the line or a source cannot be shown.
    static func imageRow(_ line: String) -> [MarkdownImage]? {
        guard line.hasPrefix("![") || line.hasPrefix("[!["), let rx = imageItemRegex else { return nil }
        return imageRow(line, rx)
    }

    private static func imageRow(_ line: String, _ rx: NSRegularExpression) -> [MarkdownImage]? {
        let text = line as NSString
        var images: [MarkdownImage] = []
        var location = 0
        while location < text.length {
            if let scalar = UnicodeScalar(text.character(at: location)), CharacterSet.whitespaces.contains(scalar) {
                location += 1
                continue
            }
            guard let match = rx.firstMatch(in: line, options: .anchored, range: NSRange(location: location, length: text.length - location))
            else { return nil }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
            let linked = group(2) != nil
            let alt = (linked ? group(1) : group(4)) ?? ""
            guard let source = linked ? group(2) : group(5), isImageSource(source) else { return nil }
            // Only a web or mail link opens; another one (`#section`, a script) leaves the picture as it is.
            let link = group(3).flatMap { URL(string: $0) }.flatMap { isSafeLink($0) ? $0.absoluteString : nil }
            images.append(MarkdownImage(alt: alt, source: source, link: link))
            location = match.range.location + match.range.length
        }
        return images.isEmpty ? nil : images
    }

    /// A `<details>` passage from line `index` on: its summary, its body and the line after it. An unclosed one (still
    /// streaming) runs to the end of the answer. Nested passages stay inside the body.
    static func detailsBlock(_ lines: [String], from index: Int) -> (summary: String, body: String, next: Int)? {
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        guard first.lowercased().hasPrefix("<details") else { return nil }
        var depth = 0
        var collected: [String] = []
        var end = index
        while end < lines.count {
            let lower = lines[end].lowercased()
            depth += lower.components(separatedBy: "<details").count - 1
            depth -= lower.components(separatedBy: "</details>").count - 1
            collected.append(lines[end])
            end += 1
            if depth <= 0 { break }
        }
        var text = collected.joined(separator: "\n")
        // The outer tags come off; inner ones stay for the body's own parse.
        if let open = text.range(of: #"^\s*<details[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(open)
        }
        if depth <= 0, let close = text.range(of: "</details>", options: [.caseInsensitive, .backwards]) {
            text.removeSubrange(close.lowerBound..<text.endIndex)
        }
        var summary = ""
        if let start = text.range(of: #"^\s*<summary[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let rest = text[start.upperBound...]
            if let stop = rest.range(of: "</summary>", options: .caseInsensitive) {
                summary = String(rest[..<stop.lowerBound])
                text = String(rest[stop.upperBound...])
            }
        }
        summary = summary.replacingOccurrences(of: #"</?[a-zA-Z][^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, text.trimmingCharacters(in: .whitespacesAndNewlines), end)
    }

    static func parse(_ raw: String) -> [MarkdownBlock] {
        // Agents' tags come off every line outside a code block, except a pull request link of its own (a card below).
        var inCode = false
        let lines = clean(raw).components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle() }
            return inCode || trimmed.hasPrefix("```") || pullRequestLine(trimmed) != nil ? line : untag(line)
        }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            // Code block
            if trimmed.hasPrefix("```") {
                flush()
                let (language, title) = fence(String(trimmed.dropFirst(3)))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let body = code.joined(separator: "\n")
                if language == "math" {
                    blocks.append(.math(body.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else if MailTemplate.languages.contains(language) {
                    blocks.append(.mail(MailTemplate.fenced(body)))
                } else if language == "question", let block = question(from: body) {
                    blocks.append(block)
                } else if chartLanguages.contains(language), let chart = ChartRescue.chart(fromCode: body, language: language, title: "") {
                    blocks.append(.chart(chart))
                } else {
                    blocks.append(.code(language: language, code: body, title: title))
                }
                continue
            }
            if let details = detailsBlock(lines, from: index) {
                flush()
                blocks.append(.details(summary: details.summary, body: details.body))
                index = details.next
                continue
            }
            if var images = imageRow(trimmed) {
                flush()
                index += 1
                // Pictures on the lines that follow join the row, as badges do on GitHub.
                while index < lines.count, let more = imageRow(lines[index].trimmingCharacters(in: .whitespaces)) {
                    images += more
                    index += 1
                }
                if images.count == 1, images[0].link == nil {
                    blocks.append(.image(alt: images[0].alt, source: images[0].source))
                } else {
                    blocks.append(.images(images))
                }
                continue
            }
            // Display math: `$$` or `\[` opening a line, up to the line that closes it.
            if let (tex, next) = displayMath(lines, from: index) {
                flush()
                blocks.append(.math(tex))
                index = next
                continue
            }
            // Heading
            if matches(trimmed, headingRegex) {
                flush()
                let level = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(level: level, text: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            // Horizontal rule
            if matches(trimmed, ruleRegex) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            // Table: a header row with | followed by a divider row.
            if trimmed.contains("|"), index + 1 < lines.count,
               matches(lines[index + 1].trimmingCharacters(in: .whitespaces), tableDividerRegex) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[index])
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // Bulleted or numbered list
            if listMarker(line) != nil {
                flush()
                blocks.append(.list(parseList(lines, from: &index)))
                continue
            }
            // Blockquote
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let text = quote.joined(separator: "\n")
                blocks.append(MailTemplate.quoted(text).map(MarkdownBlock.mail) ?? .quote(text))
                continue
            }
            if let url = pullRequestLine(trimmed) {
                flush()
                blocks.append(.pullRequest(url))
                index += 1
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    /// A display formula that starts on line `index` (`$$…$$` or `\[…\]`, on one line or several) and the line after it;
    /// nil when the line does not open one or it is never closed (yet: the answer may still be streaming).
    static func displayMath(_ lines: [String], from index: Int) -> (String, Int)? {
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        let (open, close): (String, String)
        if first.hasPrefix("$$") { (open, close) = ("$$", "$$") } else if first.hasPrefix("\\[") { (open, close) = ("\\[", "\\]") } else { return nil }
        var body = String(first.dropFirst(open.count))
        var end = index
        while true {
            if let range = body.range(of: close) {
                // Only the formula on its lines: text after the closing marker makes it a paragraph instead.
                guard body[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let tex = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return tex.isEmpty ? nil : (tex, end + 1)
            }
            end += 1
            guard end < lines.count, end - index <= 200 else { return nil }
            body += "\n" + lines[end]
        }
    }

    static func isSafeLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "http": return url.host != nil && url.user == nil
        case "mailto": return true
        default: return false
        }
    }

    /// The web address a code span holds and nothing else (`http://localhost:8080/`, `localhost:3000`), so it opens like
    /// a link. A local address without a scheme is read as `http`.
    static func codeLink(_ code: String) -> URL? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lower = text.lowercased()
        let local = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"].contains { lower == $0 || lower.hasPrefix($0 + ":") || lower.hasPrefix($0 + "/") }
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || local,
              let url = URL(string: local ? "http://" + text : text), isSafeLink(url) else { return nil }
        return url
    }

    /// Web addresses written out in running text (`see https://example.com.`), with the punctuation after them left out.
    static func bareLinks(_ text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard text.contains("://") else { return [] }
        var links: [(range: Range<String.Index>, url: URL)] = []
        var searchStart = text.startIndex
        while let match = text.range(of: #"https?://[^\s<>"'`]+"#, options: [.regularExpression, .caseInsensitive], range: searchStart..<text.endIndex) {
            searchStart = match.upperBound
            var end = match.upperBound
            // Trailing punctuation ends the sentence, not the address; a closing bracket stays when the address opened one.
            while end > match.lowerBound, let last = text[..<end].last, ".,;:!?)]}*_".contains(last) {
                let inside = text[match.lowerBound..<text.index(before: end)]
                if last == ")", inside.filter({ $0 == "(" }).count > inside.filter({ $0 == ")" }).count { break }
                end = text.index(before: end)
            }
            let range = match.lowerBound..<end
            if let url = URL(string: String(text[range])), isSafeLink(url) { links.append((range, url)) }
        }
        return links
    }
}

// MARK: - Images

/// A picture in a row of them: its alt text, its source, and the web address it opens when it is a link.
struct MarkdownImage: Equatable {
    let alt: String
    let source: String
    var link: String?
}

// MARK: - List

/// One item of a list: how deep it is nested (0 is the outer list), its number when numbered ("1."), and its text.
struct MarkdownListItem: Equatable {
    let level: Int
    let number: String?
    var text: String
}

// MARK: - Callout

/// A quote that starts with `[!NOTE]`, `[!TIP]`, `[!WARNING]` (also Dutch: Let op, Tip, Waarschuwing) becomes a call-out.
struct Callout {
    enum Kind {
        case note, tip, warning, danger
        var symbol: String {
            switch self {
            case .note: return "info.circle.fill"
            case .tip: return "lightbulb.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            }
        }
    }

    let kind: Kind
    let title: String
    let body: String

    static func detect(_ text: String) -> Callout? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let keys: [(String, Kind, String)] = [
            ("note", .note, "Notitie"), ("info", .note, "Info"), ("tip", .tip, "Tip"), ("important", .warning, "Belangrijk"),
            ("warning", .warning, "Let op"), ("let op", .warning, "Let op"), ("waarschuwing", .warning, "Waarschuwing"),
            ("caution", .danger, "Voorzichtig"), ("danger", .danger, "Gevaar"), ("opmerking", .note, "Opmerking")
        ]
        let lower = first.lowercased()
        for (key, kind, title) in keys {
            if lower.hasPrefix("[!\(key)]") {
                let after = String(first.dropFirst(key.count + 3)).trimmingCharacters(in: .whitespaces)
                return Callout(kind: kind, title: title, body: [after, rest].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            // "**Let op:** tekst" / "**Tip**: tekst"
            for prefix in ["**\(key):**", "**\(key)**:", "**\(key)**"] where lower.hasPrefix(prefix) {
                let after = String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return Callout(kind: kind, title: title, body: [after, rest].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }
        return nil
    }
}

// MARK: - Markdown files

extension MarkdownBlock {
    private static let htmlOnlyLineRegex = try? NSRegularExpression(pattern: #"^(?:\s*<[^>]*>\s*)+$"#)
    private static let htmlImageRegex = try? NSRegularExpression(pattern: #"(?:<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>\s*)?<img\s([^>]*)>"#,
                                                                 options: [.caseInsensitive])
    private static let darkSourceRegex = try? NSRegularExpression(
        pattern: #"<source\s[^>]*?prefers-color-scheme:\s*dark[^>]*?srcset\s*=\s*["']([^"'\s,]+)|<source\s[^>]*?srcset\s*=\s*["']([^"'\s,]+)[^>]*?prefers-color-scheme:\s*dark"#,
        options: [.caseInsensitive])

    /// A Markdown file (a README) as GitHub reads it, for the parser that was made for answers: lines that wrap inside a
    /// paragraph run on as one (an answer keeps its line breaks), HTML that only lays out (`<div align="center">`,
    /// `<p>`) goes, and an `<img>` or a `<picture>` becomes an image (the dark one, as Nook is dark).
    static func fileDocument(_ source: String) -> String {
        let lines = clean(source).components(separatedBy: "\n")
        var output: [String] = []
        var inCode = false
        var index = 0
        // Whether the last line written is running text another line can join.
        var joinable = false
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                output.append(line)
                joinable = false
                continue
            }
            if inCode {
                output.append(line)
                continue
            }
            if trimmed.lowercased().hasPrefix("<picture") {
                var block = [trimmed]
                while !block.joined().lowercased().contains("</picture>"), index < lines.count {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                output.append(contentsOf: ["", htmlImages(block.joined(separator: " ")), ""])
                joinable = false
                continue
            }
            if isLayoutHTML(trimmed) {
                let images = htmlImages(trimmed)
                output.append(contentsOf: images.isEmpty ? [""] : ["", images, ""])
                joinable = false
                continue
            }
            // A quote's lines run on too, inside the quote.
            let quoted = trimmed.hasPrefix(">")
            let content = quoted ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            let prose = isRunningText(content)
            if prose, joinable, let last = output.last, last.trimmingCharacters(in: .whitespaces).hasPrefix(">") == quoted,
               !last.hasSuffix("  ") {
                // The indent stays: a list item's next lines join it under the item.
                output[output.count - 1] = String(last.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) + " " + content
            } else {
                output.append(line)
            }
            joinable = prose
        }
        return output.joined(separator: "\n")
    }

    /// A line of HTML tags only, none of them a fold the parser reads itself (`<details>`, `<summary>`).
    private static func isLayoutHTML(_ line: String) -> Bool {
        guard line.hasPrefix("<"), line.hasSuffix(">"), matches(line, htmlOnlyLineRegex) else { return false }
        let lower = line.lowercased()
        return !lower.contains("<details") && !lower.contains("</details") && !lower.contains("<summary")
            && !lower.contains("<br") && pullRequestLine(line) == nil
    }

    /// A line of a paragraph: not empty, and not the start of a heading, list, quote, table, picture, formula or fold.
    private static func isRunningText(_ line: String) -> Bool {
        guard !line.isEmpty, !line.contains("|"), listMarker(line) == nil, imageRow(line) == nil else { return false }
        if matches(line, headingRegex) || matches(line, ruleRegex) { return false }
        return !["#", ">", "<", "$$", "\\[", "```", "~~~", "[!"].contains { line.hasPrefix($0) }
    }

    /// The `<img>` tags in some HTML as Markdown images on one line (a `<picture>` gives its dark source), "" when none.
    private static func htmlImages(_ html: String) -> String {
        guard let rx = htmlImageRegex else { return "" }
        let text = html as NSString
        let dark = darkSourceRegex?.firstMatch(in: html, range: NSRange(location: 0, length: text.length)).flatMap { match in
            [1, 2].lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { text.substring(with: $0) }
        }
        return rx.matches(in: html, range: NSRange(location: 0, length: text.length)).compactMap { match -> String? in
            let attributes = text.substring(with: match.range(at: 2))
            guard let source = dark ?? attribute("src", in: attributes) else { return nil }
            let alt = attribute("alt", in: attributes) ?? ""
            let image = "![\(alt)](\(source))"
            let link = match.range(at: 1).location == NSNotFound ? nil : text.substring(with: match.range(at: 1))
            return link.map { "[\(image)](\($0))" } ?? image
        }.joined(separator: " ")
    }

    /// The value of an HTML attribute (`src="a.png"`).
    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"(?:^|\s)"# + name + #"\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive]),
              let match = rx.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
              let range = Range(match.range(at: 1), in: attributes) else { return nil }
        return String(attributes[range])
    }
}
