import Foundation

/// Checks a pull request description an agent wrote against the repository's pull request template, before
/// `pull_request_create` shows it for approval and opens the pull request. Everything it asks comes from the template
/// itself, so it works for any repository with one: every section of the template is there, filled in and in order,
/// and a section about issues that the template says may read "None" either links an issue or says exactly that.
/// Sections of its own may follow (a review bot adds one); a repository's CI check may ask more than the template says.
enum PullRequestBodyCheck {
    /// What is wrong with `body`, one sentence each; empty when it follows `template`.
    static func problems(body: String, template: String) -> [String] {
        let wanted = sections(template)
        guard !wanted.isEmpty else { return [] }
        let found = sections(body)
        var problems: [String] = []
        var expected = Set<String>()
        for section in wanted {
            let key = section.key
            expected.insert(key)
            guard let match = found.first(where: { $0.key == key }) else {
                problems.append("Missing section `\(section.heading)`.")
                continue
            }
            if match.content.isEmpty {
                problems.append("Section `\(section.heading)` is empty.")
            } else if asksNoneOrIssue(section), !linksIssueOrSaysNone(match.content) {
                problems.append("`\(section.heading)` must link an issue (`Closes #123`, `Part of #123`) or say `None` on a line of its own.")
            }
        }
        let order = found.map(\.key).filter(expected.contains)
        let wantedOrder = wanted.map(\.key).filter(Set(order).contains)
        if order != wantedOrder { problems.append("Keep the template's sections in its order: " + wanted.map { "`\($0.heading)`" }.joined(separator: ", ") + ".") }
        return problems
    }

    /// The tool's answer when the description does not follow the template: what to fix, and the template to fill in.
    static func refusal(_ problems: [String], template: String) -> String {
        (["The pull request was not opened: its description does not follow the repository's pull request template. Fix it and call pull_request_create again."]
            + problems.map { "- " + $0 } + ["", "The template:", String(template.prefix(4_000))]).joined(separator: "\n")
    }

    // MARK: Sections

    struct Section {
        let level: Int
        let heading: String
        /// What is under the heading, without HTML comments, trimmed.
        let content: String
        /// The heading's text, lowercased, for matching.
        var key: String { heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased() }
        /// The section as the template wrote it, comments included: what it asks of whoever fills it in.
        let raw: String
    }

    /// The markdown headings of `text` with what follows each up to the next heading of the same or a higher level (so a
    /// section's subsections are part of it), outside code blocks. Text before the first heading is left out.
    static func sections(_ text: String) -> [Section] {
        let lines = text.components(separatedBy: .newlines)
        var headings: [(index: Int, level: Int)] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            let level = trimmed.prefix { $0 == "#" }.count
            if !inFence, (1...6).contains(level), trimmed.dropFirst(level).first == " " { headings.append((index, level)) }
        }
        return headings.enumerated().map { position, heading in
            let end = headings[(position + 1)...].first { $0.level <= heading.level }?.index ?? lines.count
            let raw = lines[(heading.index + 1)..<end].joined(separator: "\n")
            let content = raw.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Section(level: heading.level, heading: lines[heading.index].trimmingCharacters(in: .whitespaces), content: content, raw: raw)
        }
    }

    /// A section about issues whose template says it may read "None".
    private static func asksNoneOrIssue(_ section: Section) -> Bool {
        section.key.contains("issue") && section.raw.range(of: #"\bNone\b"#, options: .regularExpression) != nil
    }

    private static func linksIssueOrSaysNone(_ content: String) -> Bool {
        let link = #"(?im)^\s*[-*]?\s*(closes|fixes|resolves|part of|refs?)\s+(\S+/\S+)?#\d+"#
        let url = #"(?i)https?://\S+/(issues|-/issues|workitems)/\d+"#
        let none = #"(?im)^\s*[-*]?\s*none\.?\s*$"#
        return [link, url, none].contains { content.range(of: $0, options: .regularExpression) != nil }
    }
}
