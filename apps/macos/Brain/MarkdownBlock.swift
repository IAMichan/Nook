import Foundation

/// A block within a Markdown answer.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([(number: String, text: String)])
    case code(language: String, code: String)
    case chart(ChatChart)
    /// A question from the answer with options to pick from (a ```question block).
    case question(text: String, options: [String])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    private static let brRegex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let headingRegex = try? NSRegularExpression(pattern: #"^#{1,6}\s"#)
    private static let ruleRegex = try? NSRegularExpression(pattern: #"^([-*_]\s*){3,}$"#)
    private static let tableDividerRegex = try? NSRegularExpression(pattern: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#)
    private static let bulletRegex = try? NSRegularExpression(pattern: #"^\s*[-*•+]\s+"#)
    private static let numberRegex = try? NSRegularExpression(pattern: #"^\s*\d{1,3}[.)]\s+"#)

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
        var normalized = text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
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
        switch blocks[last] {
        case .bullets(let items) where (2...6).contains(items.count): return (last, items.map(stripTask))
        case .numbered(let items) where (2...6).contains(items.count): return (last, items.map(\.text))
        default: return nil
        }
    }

    /// `[ ]` / `[x]` task markers at the start of a list item.
    static func task(_ item: String) -> (done: Bool, text: String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(marker) {
            return (done, String(item.dropFirst(marker.count)))
        }
        return nil
    }

    private static func stripTask(_ item: String) -> String { task(item)?.text ?? item }

    static func parse(_ raw: String) -> [MarkdownBlock] {
        let lines = clean(raw).components(separatedBy: "\n")
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
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let body = code.joined(separator: "\n")
                if language == "question", let block = question(from: body) {
                    blocks.append(block)
                } else if chartLanguages.contains(language), let chart = ChartRescue.chart(fromCode: body, language: language, title: "") {
                    blocks.append(.chart(chart))
                } else {
                    blocks.append(.code(language: language, code: body))
                }
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
            // Bulleted list
            if matches(line, bulletRegex) {
                flush()
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if matches(current, bulletRegex) {
                        let indent = current.prefix { $0 == " " || $0 == "\t" }.count
                        let text = stripPrefix(current, bulletRegex)
                        items.append((indent >= 2 ? "◦ " : "") + text)
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += " " + current.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.bullets(items))
                continue
            }
            // Numbered list
            if matches(line, numberRegex) {
                flush()
                var items: [(number: String, text: String)] = []
                while index < lines.count, matches(lines[index], numberRegex) {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    let digits = String(current.prefix { $0.isNumber })
                    let text = stripPrefix(current, numberRegex)
                    items.append((digits + ".", text))
                    index += 1
                    // Blank lines between list items are treated as part of the list.
                    if index + 1 < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty, matches(lines[index + 1], numberRegex) {
                        index += 1
                    }
                }
                blocks.append(.numbered(items))
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
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    static func isSafeLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "http": return url.host != nil && url.user == nil
        case "mailto": return true
        default: return false
        }
    }
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
