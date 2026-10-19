import Foundation

// What Nook actually retrieved for a given response. Every read tool routes through here, across all brains (Claude, other
// providers, Claude Code, and local models). This lets the chat distinguish between connected sources, searched
// sources, productive sources, and failed sources. It also produces numbered citations with clickable links where available.

/// A single reference supporting an answer: an email, calendar event, document, issue, webpage…
struct SourceReference: Codable, Equatable, Identifiable {
    var number: Int
    var sourceID: String
    var title: String
    var detail: String = ""
    /// Only https, file, and message (Mail) schemes are actionable links.
    var url: String?

    var id: Int { number }

    static func isOpenable(_ raw: String?) -> Bool {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https": return url.host != nil
        case "file", "message": return true
        default: return false
        }
    }
}

/// A single retrieval invocation against a source.
struct RetrievalStep: Codable, Equatable, Identifiable {
    enum Outcome: Codable, Equatable {
        case running
        /// Results found; integer indicates line count or hit count (approximate magnitude).
        case found(Int)
        case empty
        case failed(String)
    }

    var id = UUID()
    var tool: String
    var sourceID: String?
    /// Search query or target, concise (e.g. "proposal", "IAMichan/nook#12").
    var query: String = ""
    var outcome: Outcome = .running
    /// Served from cache of an earlier query (less than 90 seconds old).
    var cached = false
    var references: [Int] = []

    var sourceTitle: String { sourceID.map(SourceCatalog.title) ?? tool }
}

struct RetrievalTimeout: LocalizedError {
    let seconds: Double
    var errorDescription: String? { tr("chat.sources.timeout", Int(seconds)) }
}

/// Tracks what was retrieved for a given answer. Runs on the main actor, matching tools.
@MainActor
final class RetrievalLedger {
    private(set) var steps: [RetrievalStep] = []
    private(set) var references: [SourceReference] = []
    /// Fired on changes so chat can display live retrieval status.
    var onChange: (() -> Void)?

    /// Duplicate queries to the same source within a single response are deduplicated.
    private var local: [String: String] = [:]

    /// Recent results shared across responses: follow-up questions avoid redundant fetching.
    private struct Cached { let date: Date; let output: String }
    private static var recent: [String: Cached] = [:]
    static var cacheLifetime: TimeInterval = 90
    /// Tools requiring fresh real-time data (live screen contents, pre-booking availability checks).
    static let neverCached: Set<String> = ["read_screen", "check_availability", "list_open_loops"]

    static func clearCache() { recent = [:] }

    /// Executes a read tool with timeout and returns formatted text for the brain (including numbered citations).
    func run(
        tool: String,
        input: [String: Any],
        timeout: Double = 25,
        operation: @escaping @MainActor ([String: Any]) async throws -> String
    ) async throws -> String {
        let key = Self.key(tool, input)
        if let output = local[key] { return output + "\n(Already retrieved in this response turn.)" }

        var step = RetrievalStep(tool: tool, sourceID: SourceCatalog.source(forTool: tool), query: Self.query(input))
        steps.append(step)
        let index = steps.count - 1
        onChange?()

        let raw: String
        if !Self.neverCached.contains(tool), let hit = Self.recent[key], Date().timeIntervalSince(hit.date) < Self.cacheLifetime {
            raw = hit.output
            step.cached = true
        } else {
            do {
                raw = try await Self.withTimeout(timeout) { try await operation(input) }
            } catch {
                step.outcome = .failed(Self.describe(error))
                steps[index] = step
                onChange?()
                throw error
            }
            Self.recent[key] = Cached(date: Date(), output: raw)
            Self.recent = Self.recent.filter { Date().timeIntervalSince($0.value.date) < Self.cacheLifetime * 4 }
        }

        let parsed = ReferenceParser.parse(raw)
        var numbered: [SourceReference] = []
        for found in parsed.references.prefix(10) {
            if let existing = references.first(where: { $0.url != nil && $0.url == found.url && $0.title == found.title }) {
                numbered.append(existing)
                continue
            }
            var reference = found
            reference.number = references.count + 1
            reference.sourceID = step.sourceID ?? tool
            references.append(reference)
            numbered.append(reference)
        }
        step.references = numbered.map(\.number)
        step.outcome = ReferenceParser.isEmptyResult(parsed.text) ? .empty
            : .found(max(numbered.count, parsed.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count))
        steps[index] = step
        onChange?()

        var output = parsed.text
        if !numbered.isEmpty {
            output += "\n\nSources in this result (cite using the bracketed number, e.g. [\(numbered[0].number)]):\n"
            output += numbered.map { "[\($0.number)] \($0.title)" + ($0.detail.isEmpty ? "" : " — \($0.detail)") }.joined(separator: "\n")
        }
        local[key] = output
        return output
    }

    /// A source the question asks for that Nook cannot read right now (no access, not installed): shown and reported
    /// like a failed search, so the user sees why and the answer never pretends it looked there.
    func noteUnavailable(source: String, tool: String, reason: String) {
        guard !steps.contains(where: { $0.sourceID == source }) else { return }
        steps.append(RetrievalStep(tool: tool, sourceID: source, outcome: .failed(reason)))
        onChange?()
    }

    /// Everything the tools returned for this answer: what an answer may rightly quote from.
    var retrievedText: String { local.values.joined(separator: "\n") }

    /// Failed retrievals, displayed as a disclaimer under the response.
    var failures: [RetrievalStep] {
        steps.filter { if case .failed = $0.outcome { return true }; return false }
    }

    // MARK: Helpers

    /// A failure as a person reads it: no "Swift.CancellationError error 1" or "The operation couldn't be completed".
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return tr("chat.sources.interrupted") }
        if let message = (error as? LocalizedError)?.errorDescription, !message.isEmpty { return message }
        let text = error.localizedDescription
        if text.isEmpty || text.contains("couldn’t be completed") || text.contains("couldn't be completed") {
            return tr("chat.sources.unknownError")
        }
        return text
    }

    static func key(_ tool: String, _ input: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        return tool + "|" + (String(data: data, encoding: .utf8) ?? "")
    }

    /// Concise query or target, excluding verbose bodies or credentials.
    static func query(_ input: [String: Any]) -> String {
        for key in ["query", "q", "path", "repo", "name", "from"] {
            if let value = input[key] as? String, !value.isEmpty {
                var text = value
                if key == "repo", let number = input["number"] { text += "#\(number)" }
                return String(text.prefix(60))
            }
        }
        return ""
    }

    static func withTimeout(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RetrievalTimeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RetrievalTimeout(seconds: seconds) }
            return first
        }
    }
}

/// Extracts source references from tool output.
///
/// A tool can explicitly include a reference with a line `@ref <title> | <link> | <detail>` (link and detail may be empty).
/// Such lines are not passed to the brain; the brain receives the numbered list. For tools without such lines: every line containing an
/// https link becomes a reference, with the remainder of the line as the title.
enum ReferenceParser {
    /// Includes a random part chosen at launch, so a mail, note or web page that contains a line starting with "@ref"
    /// cannot pose as a reference (with a link of its choosing). Only Nook's own tools write this marker.
    static let marker = "@ref-" + String(UUID().uuidString.prefix(8)) + " "

    static func line(title: String, url: String?, detail: String = "") -> String {
        let clean = { (text: String) in text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
        return marker + clean(title) + " | " + (url ?? "") + " | " + clean(detail)
    }

    static func parse(_ raw: String) -> (text: String, references: [SourceReference]) {
        var kept: [Substring] = []
        var explicit: [SourceReference] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix(marker) else { kept.append(line); continue }
            let parts = line.dropFirst(marker.count).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let title = parts.first, !title.isEmpty else { continue }
            let url = parts.count > 1 && SourceReference.isOpenable(parts[1]) ? parts[1] : nil
            explicit.append(SourceReference(number: 0, sourceID: "", title: String(title.prefix(120)),
                                            detail: parts.count > 2 ? String(parts[2].prefix(120)) : "", url: url))
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return (text, explicit) }
        return (text, links(in: text))
    }

    private static let linkPattern = try? NSRegularExpression(pattern: #"https://[^\s<>"'\)\]]+"#)

    private static func links(in text: String) -> [SourceReference] {
        guard let linkPattern else { return [] }
        var result: [SourceReference] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let string = String(line)
            let matches = linkPattern.matches(in: string, range: NSRange(string.startIndex..., in: string))
            guard let match = matches.first, let range = Range(match.range, in: string) else { continue }
            var url = String(string[range])
            while let last = url.last, ".,;:".contains(last) { url.removeLast() }
            guard SourceReference.isOpenable(url), seen.insert(url).inserted else { continue }
            var title = string.replacingCharacters(in: range, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -*|·•\t"))
            title = title.replacingOccurrences(of: #"\s*[·|]\s*$"#, with: "", options: .regularExpression)
            if title.isEmpty { title = URL(string: url)?.host ?? url }
            result.append(SourceReference(number: 0, sourceID: "", title: String(title.prefix(120)), url: url))
        }
        return result
    }

    static func isEmptyResult(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let pattern = #"^(geen |niets gevonden|no |nothing found|keine |leeg antwoord)"#
        return trimmed.count < 140 && trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Citations in the brain's text: [1], [2, 3]. Only numbers that correspond to an actual retrieved source are kept,
/// ensuring an answer never refers to a fabricated source.
enum Citations {
    private static let pattern = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?!\()"#)

    static func used(in text: String) -> Set<Int> {
        guard let pattern else { return [] }
        var result = Set<Int>()
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            for part in text[range].split(separator: ",") {
                if let number = Int(part.trimmingCharacters(in: .whitespaces)) { result.insert(number) }
            }
        }
        return result
    }

    /// Strips citations that don't match any source; preserves the rest, including lists like [1, 4].
    static func sanitize(_ text: String, valid: Set<Int>) -> String {
        guard let pattern else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let inner = ns.substring(with: match.range(at: 1))
            let keep = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { valid.contains($0) }
            if !keep.isEmpty {
                result += "[" + keep.map(String.init).joined(separator: ", ") + "]"
            } else if result.hasSuffix(" ") {
                result.removeLast()
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

/// Third-party text (email, webpages, messages, screen text) is enclosed in tags before being passed to the brain.
/// Such text must not be able to close or open tags itself; otherwise an email could pose as a user instruction.
enum UntrustedText {
    private static let tags = try? NSRegularExpression(
        pattern: #"<\s*/?\s*(tool_data|screen_content|system|instructions?|user|assistant|human)\b"#,
        options: [.caseInsensitive]
    )

    static func neutralize(_ text: String) -> String {
        guard let tags else { return text }
        let ns = NSMutableString(string: text)
        for match in tags.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let original = ns.substring(with: match.range)
            ns.replaceCharacters(in: match.range, with: "‹" + original.dropFirst())
        }
        return ns as String
    }

    static func wrap(_ text: String) -> String {
        "<tool_data>\n\(neutralize(text))\n</tool_data>"
    }
}
