import Foundation

// Wat Nook bij één antwoord echt heeft opgezocht. Elke lees-tool loopt hierlangs, voor elk brein (Claude, de andere
// providers, Claude Code en het lokale model). Zo weet de chat het verschil tussen een bron die gekoppeld is, een bron die
// doorzocht werd, een bron die iets opleverde en een bron die faalde. Uit de uitkomsten komen ook de bronverwijzingen:
// genummerd, met een echte link als die er is, zodat het brein met [1], [2] kan verwijzen en de gebruiker kan doorklikken.

/// Eén ding waar een antwoord op steunt: een mail, afspraak, document, issue, pagina…
struct SourceReference: Codable, Equatable, Identifiable {
    var number: Int
    var sourceID: String
    var title: String
    var detail: String = ""
    /// Alleen https, file en message (Mail) worden klikbaar.
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

/// Eén keer dat Nook in een bron keek.
struct RetrievalStep: Codable, Equatable, Identifiable {
    enum Outcome: Codable, Equatable {
        case running
        /// Iets gevonden; het getal is het aantal regels of treffers (ruwe maat).
        case found(Int)
        case empty
        case failed(String)
    }

    var id = UUID()
    var tool: String
    var sourceID: String?
    /// Waar naar gezocht werd, kort ("offerte", "IAMichan/nook#12").
    var query: String = ""
    var outcome: Outcome = .running
    /// Kwam uit het geheugen van een eerdere vraag (minder dan anderhalve minuut oud).
    var cached = false
    var references: [Int] = []

    var sourceTitle: String { sourceID.map(SourceCatalog.title) ?? tool }
}

struct RetrievalTimeout: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "Geen antwoord binnen \(Int(seconds)) seconden." }
}

/// Houdt bij wat er bij één antwoord gelezen werd. Draait op de main actor, net als de tools.
@MainActor
final class RetrievalLedger {
    private(set) var steps: [RetrievalStep] = []
    private(set) var references: [SourceReference] = []
    /// Na elke wijziging, zodat de chat live kan laten zien waar Nook nu kijkt.
    var onChange: (() -> Void)?

    /// Dezelfde vraag aan dezelfde bron binnen één antwoord wordt niet opnieuw gesteld.
    private var local: [String: String] = [:]

    /// Uitkomsten van kort geleden, gedeeld tussen antwoorden: een vervolgvraag hoeft niet alles opnieuw op te halen.
    private struct Cached { let date: Date; let output: String }
    private static var recent: [String: Cached] = [:]
    static var cacheLifetime: TimeInterval = 90
    /// Tools die altijd vers moeten zijn (wat er nu op het scherm staat, beschikbaarheid vlak voor een afspraak maken).
    static let neverCached: Set<String> = ["read_screen", "check_availability", "list_open_loops"]

    static func clearCache() { recent = [:] }

    /// Draait één lees-tool, met time-out, en geeft de tekst voor het brein terug (met genummerde bronnen).
    func run(
        tool: String,
        input: [String: Any],
        timeout: Double = 25,
        operation: @escaping @MainActor ([String: Any]) async throws -> String
    ) async throws -> String {
        let key = Self.key(tool, input)
        if let output = local[key] { return output + "\n(Dit had je in dit antwoord al opgehaald.)" }

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
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                step.outcome = .failed(message)
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
            output += "\n\nBronnen in dit resultaat (verwijs ernaar met het nummer tussen haken, bijvoorbeeld [\(numbered[0].number)]):\n"
            output += numbered.map { "[\($0.number)] \($0.title)" + ($0.detail.isEmpty ? "" : " — \($0.detail)") }.joined(separator: "\n")
        }
        local[key] = output
        return output
    }

    /// Bronnen die faalden, voor de waarschuwing onder een antwoord.
    var failures: [RetrievalStep] {
        steps.filter { if case .failed = $0.outcome { return true }; return false }
    }

    // MARK: Hulp

    static func key(_ tool: String, _ input: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        return tool + "|" + (String(data: data, encoding: .utf8) ?? "")
    }

    /// De zoekterm of het doel, kort, zonder hele berichten of sleutels.
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

/// Haalt bronverwijzingen uit wat een tool teruggeeft.
///
/// Een tool kan een verwijzing expliciet meegeven met een regel `@ref <titel> | <link> | <detail>` (link en detail mogen leeg).
/// Zulke regels gaan niet naar het brein; die krijgt de genummerde lijst. Tools zonder zulke regels: elke regel met een
/// https-link wordt een verwijzing, met de rest van de regel als titel.
enum ReferenceParser {
    static let marker = "@ref "

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

/// Verwijzingen in de tekst van het brein: [1], [2, 3]. Alleen nummers die echt bij een opgehaalde bron horen blijven staan,
/// zodat een antwoord nooit naar een verzonnen bron verwijst.
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

    /// Haalt verwijzingen weg die nergens bij horen; houdt de rest, ook in een lijstje als [1, 4].
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

/// Tekst van derden (mail, webpagina's, berichten, schermtekst) gaat omlijnd naar het brein. Zulke tekst mag die omlijning
/// niet zelf kunnen sluiten of een nieuwe openen; anders kan een mail zich voordoen als een opdracht van de gebruiker.
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
