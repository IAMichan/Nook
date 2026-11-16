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
    /// Only https, file, message (Mail) and Nook's own chat links (`ReferenceParser.chatLink`) are actionable.
    var url: String?
    /// What the source said: the part of the tool's result it came from (a mail's header and body, a chat's messages, a
    /// calendar line), so a citation can show what the answer rests on. Nil for answers saved before Nook kept it.
    var excerpt: String?

    var id: Int { number }

    /// Who sent a mail ("Vimexx" from its detail "Vimexx · 2026-11-14"); nil for any other source.
    var sender: String? {
        let mail = sourceID.lowercased().contains("mail") || (url?.hasPrefix("message:") ?? false)
        guard mail, let name = detail.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, name.first?.isNumber == false else { return nil }
        return name
    }

    static func isOpenable(_ raw: String?) -> Bool {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https": return url.host != nil
        case "file", "message": return true
        case chatScheme: return chat(raw) != nil
        default: return false
        }
    }

    /// A chat in one of the chat apps Nook reads (WhatsApp, Messages…): opens on that chat in the Chats tab.
    static let chatScheme = "nookchat"

    /// The app and the chat's name of a chat link, or nil when it is not one.
    static func chat(_ raw: String?) -> (app: String, name: String)? {
        guard let raw, let parts = URLComponents(string: raw), parts.scheme?.lowercased() == chatScheme else { return nil }
        let items = parts.queryItems ?? []
        guard let name = items.first(where: { $0.name == "name" })?.value, !name.isEmpty else { return nil }
        return (items.first { $0.name == "app" }?.value ?? "", name)
    }

    /// The link of a chat in `app` named `name`. Only Nook's own tools write it, through `ReferenceParser.line`.
    static func chatLink(app: String, name: String) -> String {
        var parts = URLComponents()
        parts.scheme = chatScheme
        parts.path = "open"
        parts.queryItems = [URLQueryItem(name: "app", value: app), URLQueryItem(name: "name", value: name)]
        // `|` separates the parts of a reference line: never leave it in the link.
        return (parts.string ?? "").replacingOccurrences(of: "|", with: "%7C")
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
            reference.excerpt = ReferenceParser.excerpt(for: found.title, in: parsed.text, alone: parsed.references.count == 1)
            references.append(reference)
            numbered.append(reference)
        }
        step.references = numbered.map(\.number)
        step.outcome = ReferenceParser.isEmptyResult(parsed.text) ? .empty
            : .found(max(numbered.count, parsed.text.split(separator: "\n").count(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })))
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
        // Not a task group: a group waits for all its tasks, so a lookup that ignores cancellation (a script waiting for
        // Mail) would hold the answer up long after its limit.
        let race = TimeoutRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.begin(continuation)
                let work = Task { @MainActor in
                    do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
                }
                let clock = Task {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    work.cancel()
                    race.finish(.failure(RetrievalTimeout(seconds: seconds)))
                }
                race.whenOver {
                    work.cancel()
                    clock.cancel()
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// The first of a lookup, its time limit and a cancelled question ends the wait; the rest is ignored.
private final class TimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var cleanUp: (() -> Void)?

    /// Stops what still runs. Comes after the tasks exist, so a race that is already over stops them at once.
    func whenOver(_ stop: @escaping () -> Void) {
        lock.lock()
        let over = result != nil
        if !over { cleanUp = stop }
        lock.unlock()
        if over { stop() }
    }

    func begin(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let result { continuation.resume(with: result) } else { self.continuation = continuation }
    }

    func finish(_ outcome: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiting = continuation
        continuation = nil
        let stop = cleanUp
        cleanUp = nil
        lock.unlock()
        waiting?.resume(with: outcome)
        stop?()
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

    /// The longest excerpt kept per reference: enough for a mail's opening or a few chat messages.
    static let excerptLimit = 900

    /// The part of a tool's result that a reference with `title` came from: the block under the heading that names it
    /// (a mail, a chat, a note), or the line that names it (a calendar event, an issue in a list). `alone`: the result has
    /// only this reference, so all of it is the source when no line names it. Ids and other bookkeeping for the model are
    /// left out. Nil when nothing in the text belongs to it.
    static func excerpt(for title: String, in text: String, alone: Bool) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let keys = excerptKeys(title)
        let hit = lines.firstIndex { line in
            let lower = line.lowercased()
            return keys.contains { lower.contains($0) }
        }
        var picked: [String]
        if let hit {
            let line = lines[hit].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || alone {
                // A heading owns everything up to the next heading of the same or a higher level.
                let level = line.prefix { $0 == "#" }.count
                var end = hit + 1
                while end < lines.count {
                    let next = lines[end].trimmingCharacters(in: .whitespaces)
                    let nextLevel = next.prefix { $0 == "#" }.count
                    if nextLevel > 0 && (level == 0 || nextLevel <= level) { break }
                    end += 1
                }
                picked = Array(lines[hit..<end])
            } else {
                picked = [lines[hit]]
            }
        } else if alone {
            picked = lines
        } else {
            return nil
        }
        let cleaned = picked.map(cleanExcerptLine).reduce(into: [String]()) { result, line in
            // One empty line at most between two parts.
            if line.isEmpty, result.last?.isEmpty ?? true { return }
            result.append(line)
        }
        var excerpt = cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return nil }
        if excerpt.count > excerptLimit {
            let cut = excerpt.prefix(excerptLimit)
            let end = cut.lastIndex(of: "\n") ?? cut.lastIndex(of: " ") ?? cut.endIndex
            excerpt = String(cut[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + " …"
        }
        return excerpt
    }

    /// What a line of the source contains when it names a reference: its title without the app before it, or for an
    /// issue ("owner/repo#12 Title") its number.
    private static func excerptKeys(_ title: String) -> [String] {
        var name = title
        if let colon = title.range(of: ": "), title.distance(from: title.startIndex, to: colon.lowerBound) <= 20 {
            name = String(title[colon.upperBound...])
        }
        var keys = [name.lowercased()]
        if let hash = name.firstIndex(of: "#"), let space = name[hash...].firstIndex(of: " ") {
            keys.append(String(name[..<space]).lowercased())
        }
        return keys.filter { $0.count >= 2 }
    }

    private static let excerptNoise = try? NSRegularExpression(
        pattern: #"\s*\[(?:id|chat): [^\]]*\]|\s*\|\s*id \S+\s*$|\s*\|\s*calendar [^|]*"#)

    /// A line of the source as a person reads it: no Markdown heading marks, ids or links meant for the model.
    private static func cleanExcerptLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        if let excerptNoise {
            text = excerptNoise.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text
    }

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

    /// A piece of text with citations in it: words, or the numbers of one or more citations in a row.
    enum Piece: Equatable {
        case text(String)
        case citation([Int])
    }

    /// Whether the text cites anything.
    static func contains(_ text: String) -> Bool {
        guard text.contains("["), let pattern else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The text in words and citations. Citations in a row ("[2][3]", "[2] [3]") are one piece, and the space before
    /// a citation goes, so its numbers sit against the fact they back ("today [5]." → "today", [5], ".").
    static func split(_ text: String) -> [Piece] {
        guard let pattern else { return [.text(text)] }
        let ns = text as NSString
        var pieces: [Piece] = []
        var cursor = 0
        func addText(_ words: String) {
            guard !words.isEmpty else { return }
            if case .text(let before) = pieces.last { pieces[pieces.count - 1] = .text(before + words) } else { pieces.append(.text(words)) }
        }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let numbers = ns.substring(with: match.range(at: 1)).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            cursor = match.range.location + match.range.length
            if between.allSatisfy({ $0 == " " }), case .citation(let earlier) = pieces.last {
                pieces[pieces.count - 1] = .citation(earlier + numbers)
                continue
            }
            while between.last == " " { between.removeLast() }
            addText(between)
            pieces.append(.citation(numbers))
        }
        addText(ns.substring(from: cursor))
        return pieces
    }

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

    private static let sourceLabels = "sources?|bronnen|bron|quellen?|fuentes?"
    /// "Sources: …", "**Bronnen:** …", "- Quellen: …": the label with its colon, then the list on the same line.
    private static let sourceListLine = try? NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s+)?(?:[*_]{1,2})?(?:"# + sourceLabels + #")(?:[*_]{1,2})?\s*:(?:[*_]{1,2})?(.*)$"#,
        options: [.caseInsensitive])
    /// "## Sources" or "**Bronnen**" alone on a line, over the list.
    private static let sourceListHeading = try? NSRegularExpression(
        pattern: #"^\s*(?:#{1,6}\s*|[*_]{1,2})(?:"# + sourceLabels + #")\s*:?\s*(?:[*_]{1,2})?\s*$"#,
        options: [.caseInsensitive])

    /// The answer without a list of its sources written out by the model ("Sources: [4] Vimexx · [8] WhatsApp …", or a
    /// "Sources" heading over cited lines): Nook shows every source beside the fact it backs, so such a list only repeats
    /// them, out of place and with bare numbers. Only a line that names the list and cites something goes, with the cited
    /// lines under a heading.
    static func withoutSourceList(_ text: String) -> String {
        guard let sourceListLine, let sourceListHeading, text.contains("["), contains(text) else { return text }
        var lines = text.components(separatedBy: "\n")
        var index = 0
        var changed = false
        while index < lines.count {
            let line = lines[index]
            let range = NSRange(line.startIndex..., in: line)
            var remainder: String?
            if line.count < 600, let match = sourceListLine.firstMatch(in: line, range: range), let rest = Range(match.range(at: 1), in: line) {
                remainder = String(line[rest])
            } else if line.count < 60, sourceListHeading.firstMatch(in: line, range: range) != nil {
                remainder = ""
            }
            guard let remainder else { index += 1; continue }
            let rest = remainder.trimmingCharacters(in: .whitespaces)
            var end = index + 1
            if rest.isEmpty {
                // A label on its own line: the cited lines under it are the list, after one empty line at most.
                if end + 1 < lines.count, lines[end].trimmingCharacters(in: .whitespaces).isEmpty, contains(lines[end + 1]) { end += 1 }
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty, contains(lines[end]) { end += 1 }
                guard end > index + 1, contains(lines[end - 1]) else { index += 1; continue }
            } else if !contains(rest) {
                index += 1
                continue
            }
            lines.removeSubrange(index..<end)
            changed = true
        }
        guard changed else { return text }
        return lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let shownCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 200
        return cache
    }()

    /// `withoutSourceList` for an answer on screen, once per text: answers saved before Nook took the list out still
    /// have it, and a message's view asks for its text on every redraw.
    static func shown(_ text: String) -> String {
        guard text.contains("[") else { return text }
        let key = text as NSString
        if let hit = shownCache.object(forKey: key) { return hit as String }
        let result = withoutSourceList(text)
        shownCache.setObject(result as NSString, forKey: key)
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

/// The lines of a source to show beside the sentence that cites it: the ones that share the most words with the sentence,
/// with a little around them, so a hover on a citation shows what the answer rests on rather than the source's start.
enum SourcePassage {
    struct Line: Equatable {
        var text: String
        /// Shares words with the sentence: what the answer took from the source.
        var relevant: Bool
    }

    /// At most `limit` lines of `excerpt` around the best match for `claim`; each line at most `width` characters, cut
    /// around its first matching word. With nothing in common, the source's first lines, none marked.
    /// `title`: the source's name, shown above the passage already, so a line that starts with it ("Invoice | from
    /// Vimexx") keeps only the rest.
    static func pick(_ excerpt: String, claim: String, title: String = "", limit: Int = 7, width: Int = 240) -> [Line] {
        let lines = excerpt.components(separatedBy: "\n")
            .map { readable(withoutTitle($0.trimmingCharacters(in: .whitespaces), title)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let words = terms(claim)
        let scores = lines.map { line -> Int in
            let lower = line.lowercased()
            return words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        }
        let best = scores.max() ?? 0
        guard best > 0, let top = scores.firstIndex(of: best) else {
            return lines.prefix(limit).map { Line(text: clip($0, around: nil, width: width), relevant: false) }
        }
        // The heading line (a mail's subject, a chat's name) stays on top when the match is further down.
        let start = max(0, min(top - 1, lines.count - limit))
        let threshold = max(1, (best + 1) / 2)
        var result: [Line] = []
        if start > 0 { result.append(Line(text: clip(lines[0], around: nil, width: width), relevant: scores[0] >= threshold)) }
        for index in start..<min(lines.count, start + limit - result.count) {
            let lower = lines[index].lowercased()
            let hit = words.first { lower.contains($0) }
            result.append(Line(text: clip(lines[index], around: hit, width: width), relevant: scores[index] >= threshold))
        }
        return result
    }

    private static func withoutTitle(_ line: String, _ title: String) -> String {
        guard !title.isEmpty, line.lowercased().hasPrefix(title.lowercased()) else { return line }
        let rest = line.dropFirst(title.count).trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("|") || rest.hasPrefix("·") else { return line }
        return String(rest.drop { $0 == "|" || $0 == "·" }).trimmingCharacters(in: .whitespaces)
    }

    private static let isoTime = try? NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?"#)

    /// A line as a person reads it: "2026-11-16 13:00" for an ISO time, and "·" between the parts the tools put "|" between.
    static func readable(_ line: String) -> String {
        var text = line
        if let isoTime, text.contains("T") {
            text = isoTime.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1 $2")
        }
        return text.replacingOccurrences(of: " | ", with: " · ")
    }

    /// The words of a sentence worth matching: four letters or more, or a number of two digits or more, lowercased.
    static func terms(_ text: String) -> [String] {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        var seen = Set<String>()
        return words.filter { word in
            let number = word.allSatisfy(\.isNumber)
            guard number ? word.count >= 2 : word.count >= 4 else { return false }
            return !stopWords.contains(word) && seen.insert(word).inserted
        }
    }

    /// Common words in Nook's five languages that say nothing about where a fact comes from.
    private static let stopWords: Set<String> = [
        "that", "this", "with", "from", "have", "they", "will", "your", "there", "about", "what", "when", "which",
        "deze", "voor", "niet", "maar", "heeft", "hebben", "naar", "wordt", "worden", "jouw", "staat", "staan", "waar", "over",
        "dass", "nicht", "eine", "einen", "sind", "wird", "dann", "auch", "noch", "oder", "aber",
        "dans", "pour", "avec", "sont", "mais", "plus", "vous", "votre",
        "para", "pero", "esta", "este", "como", "sobre", "tiene",
    ]

    /// A line cut to `width` characters around `word` (its start when there is none), with "…" where it was cut.
    static func clip(_ line: String, around word: String?, width: Int) -> String {
        guard line.count > width else { return line }
        var start = line.startIndex
        if let word, let found = line.range(of: word, options: .caseInsensitive) {
            let offset = line.distance(from: line.startIndex, to: found.lowerBound)
            let begin = max(0, min(offset - width / 3, line.count - width))
            start = line.index(line.startIndex, offsetBy: begin)
        }
        let end = line.index(start, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
        return (start > line.startIndex ? "…" : "") + String(line[start..<end]).trimmingCharacters(in: .whitespaces)
            + (end < line.endIndex ? "…" : "")
    }
}
