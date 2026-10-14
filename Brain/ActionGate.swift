import Foundation

// De poort voor acties. Een tool-aanroep van het brein is alleen een voorstel; hier wordt hij gecontroleerd voordat
// de gebruiker hem ziet, en opnieuw vlak voordat hij echt wordt uitgevoerd (het brein kan zich vergissen of door
// tekst van derden op een dwaalspoor zijn gezet). Elke stap van een plan heeft een eigen toestand, zodat een plan dat
// halverwege mislukt veilig verder kan zonder dat iets wat al gelukt is nog een keer gebeurt.

/// Hoe het met één stap van een plan gaat.
enum ActionStepState: Codable, Equatable {
    case pending
    case running
    case done(String)
    case failed(String)
    /// Kwam niet aan de beurt omdat een eerdere stap faalde.
    case notRun
    /// Door de gebruiker uitgevinkt.
    case skipped
    /// Precies deze actie is kort geleden al uitgevoerd; niet nog een keer zonder dat de gebruiker dat zegt.
    case duplicate(String)

    var isFinished: Bool {
        switch self {
        case .done, .skipped, .duplicate: return true
        default: return false
        }
    }

    /// Mag (opnieuw) proberen.
    var canRun: Bool {
        switch self {
        case .pending, .failed, .notRun: return true
        default: return false
        }
    }
}

/// Eén invulveld van een voorstel, voor het overzicht vóór Uitvoeren en om het aan te passen.
struct ActionField: Equatable, Identifiable {
    var key: String
    var label: String
    var value: String
    var editable: Bool
    var multiline: Bool
    var id: String { key }
}

enum ActionGate {
    /// Acties die je gerust twee keer doet: geen dubbelcontrole.
    static let repeatable: Set<String> = ["media_control", "set_volume", "open_app", "open_url"]
    /// Hoe lang een uitgevoerde actie als "al gedaan" telt.
    static let duplicateWindow: TimeInterval = 12 * 3600

    // MARK: Controleren

    /// Maakt invoer netjes (spaties eraf, "12" wordt 12 bij een getal) zonder de betekenis te veranderen.
    static func normalized(_ input: [String: Any], schema: [String: Any]) -> [String: Any] {
        let properties = (schema["properties"] as? [String: [String: Any]]) ?? [:]
        var result: [String: Any] = [:]
        // Velden die de tool niet kent, gaan eruit: die kan de tool niet gebruiken en de gebruiker kan ze niet zien.
        for (key, value) in input where properties.isEmpty || properties[key] != nil {
            let type = properties[key]?["type"] as? String
            switch (value, type) {
            case let (text as String, "integer"):
                if let number = Int(text.trimmingCharacters(in: .whitespaces)) { result[key] = number } else { result[key] = text }
            case let (text as String, "number"):
                if let number = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) { result[key] = number } else { result[key] = text }
            case let (text as String, _):
                result[key] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                result[key] = value
            }
        }
        return result
    }

    /// Wat er mis is met een voorstel; leeg = in orde. Kijkt naar het schema van de tool en naar velden met een
    /// vaste betekenis (datums, links, mailadressen, repositories).
    static func problems(tool: String, input: [String: Any], schema: [String: Any], parseDate: (String) -> Date?) -> [String] {
        var problems: [String] = []
        let properties = (schema["properties"] as? [String: [String: Any]]) ?? [:]
        let required = (schema["required"] as? [String]) ?? []

        for key in required {
            let value = input[key]
            if value == nil || (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                problems.append("\(label(key, properties)) ontbreekt.")
            }
        }
        for (key, value) in input {
            guard let property = properties[key] else {
                problems.append("Onbekend veld \(key).")
                continue
            }
            switch property["type"] as? String {
            case "string":
                guard let text = value as? String else { problems.append("\(label(key, properties)) moet tekst zijn."); continue }
                if text.count > 20_000 { problems.append("\(label(key, properties)) is te lang.") }
                if let options = property["enum"] as? [String], !text.isEmpty, !options.contains(text), !options.contains(text.uppercased()), !options.contains(text.lowercased()) {
                    problems.append("\(label(key, properties)) moet een van deze zijn: \(options.joined(separator: ", ")).")
                }
            case "integer":
                // Uit JSON komt een NSNumber; een heel getal is goed.
                let whole = (value as? Int) != nil || (value as? NSNumber).map { $0.doubleValue == $0.doubleValue.rounded() } == true
                if !whole { problems.append("\(label(key, properties)) moet een heel getal zijn.") }
            case "number":
                if (value as? NSNumber) == nil && (value as? Double) == nil && (value as? Int) == nil {
                    problems.append("\(label(key, properties)) moet een getal zijn.")
                }
            case "boolean":
                if (value as? Bool) == nil { problems.append("\(label(key, properties)) moet ja of nee zijn.") }
            default:
                break
            }
        }

        // Velden met een vaste betekenis.
        var dates: [String: Date] = [:]
        for key in ["start", "end", "due", "from", "to", "date"] {
            guard let text = input[key] as? String, !text.isEmpty, properties[key]?["description"].map({ "\($0)".contains("ISO") }) ?? false else { continue }
            if let date = parseDate(text) { dates[key] = date } else { problems.append("\(label(key, properties)) is geen geldige datum (\(text)).") }
        }
        if let start = dates["start"], let end = dates["end"], end <= start {
            problems.append("Het einde ligt niet na het begin.")
        }
        if let url = input["url"] as? String, !url.isEmpty {
            let parsed = URL(string: url)
            if parsed?.scheme?.lowercased() != "https" || parsed?.host == nil { problems.append("Alleen https-links mogen.") }
        }
        if let repo = input["repo"] as? String, !repo.isEmpty, !isRepository(repo) {
            problems.append("De repository moet eigenaar/naam zijn.")
        }
        for key in ["to", "cc"] where tool == "compose_mail" || tool == "send_mail" {
            guard let text = input[key] as? String, !text.isEmpty else { continue }
            for address in text.split(whereSeparator: { $0 == "," || $0 == ";" }) where !isMailAddress(String(address)) {
                problems.append("\(address.trimmingCharacters(in: .whitespaces)) is geen geldig mailadres.")
            }
        }
        return problems
    }

    /// eigenaar/naam, zonder ".." of "." als deel: anders wijst het pad naar een ander deel van de API.
    static func isRepository(_ text: String) -> Bool {
        guard text.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return false }
        return !text.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    static func isMailAddress(_ raw: String) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        return text.range(of: #"^[^\s@<>,;]+@[^\s@<>,;]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    private static func label(_ key: String, _ properties: [String: [String: Any]]) -> String {
        let known: [String: String] = [
            "title": "De titel", "start": "Het begin", "end": "Het einde", "due": "De datum", "name": "De naam",
            "message": "Het bericht", "body": "De tekst", "repo": "De repository", "number": "Het nummer",
            "url": "De link", "to": "De ontvanger", "subject": "Het onderwerp", "id": "Het id", "event": "Het oordeel"
        ]
        return known[key] ?? key
    }

    // MARK: Voor het overzicht

    /// Alle invoer van een voorstel als velden, in de volgorde van het schema (verplichte eerst). Volledige tekst,
    /// niet ingekort: wat er straks gebeurt, moet je vooraf helemaal kunnen lezen.
    static func fields(_ input: [String: Any], schema: [String: Any]) -> [ActionField] {
        let properties = (schema["properties"] as? [String: [String: Any]]) ?? [:]
        let required = (schema["required"] as? [String]) ?? []
        let order = required + properties.keys.sorted().filter { !required.contains($0) }
        return order.compactMap { key -> ActionField? in
            guard let value = input[key] else { return nil }
            let text: String
            switch value {
            case let string as String: text = string
            case let number as NSNumber: text = number.stringValue
            default:
                let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
                text = String(data: data, encoding: .utf8) ?? "\(value)"
            }
            guard !text.isEmpty else { return nil }
            let property = properties[key] ?? [:]
            let isString = (property["type"] as? String) == "string" && property["enum"] == nil
            return ActionField(
                key: key,
                label: shortLabel(key, property),
                value: text,
                editable: isString,
                multiline: isString && (text.count > 60 || text.contains("\n") || ["body", "message", "notes"].contains(key))
            )
        }
    }

    private static func shortLabel(_ key: String, _ property: [String: Any]) -> String {
        let known: [String: String] = [
            "title": "Titel", "start": "Begin", "end": "Einde", "due": "Wanneer", "location": "Plaats", "notes": "Notities",
            "name": "Bron", "message": "Bericht", "to": "Aan", "cc": "Cc", "subject": "Onderwerp", "body": "Tekst",
            "repo": "Repository", "number": "Nummer", "event": "Oordeel", "method": "Methode", "url": "Link",
            "level": "Niveau", "action": "Actie", "id": "Id", "labels": "Labels", "state": "Status"
        ]
        if let label = known[key] { return label }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    // MARK: Dubbel uitvoeren voorkomen

    /// Vaste sleutel voor "precies deze actie": dezelfde tool met dezelfde invoer geeft dezelfde sleutel.
    static func identity(tool: String, input: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(tool.utf8) + [0x7C] + Array(data) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return tool + ":" + String(hash, radix: 16)
    }
}

/// Voert een goedgekeurd plan uit, stap voor stap. Wat al gelukt is, gebeurt nooit nog een keer; stopt bij de eerste
/// fout (latere stappen kunnen ervan afhangen) en laat zien wat wel en niet gebeurde.
@MainActor
struct PlanRunner {
    struct Step {
        var tool: String
        var input: [String: Any]
    }

    /// Controle vlak voor uitvoeren (tool nog beschikbaar, invoer klopt, bron toegestaan). Leeg = in orde.
    var check: (Step) -> [String]
    var execute: (Step) async throws -> String
    /// Wanneer deze actie al eens lukte (binnen het venster), anders nil.
    var executedBefore: (String) -> Date?
    var recordExecuted: (String, Step, String) -> Void
    var progress: ([ActionStepState]) -> Void = { _ in }

    /// `include`: welke stappen de gebruiker aan liet staan. `force`: stappen die toch mogen, ook als ze dubbel lijken.
    func run(_ steps: [Step], states initial: [ActionStepState], include: [Bool], force: Set<Int> = []) async -> [ActionStepState] {
        var states = initial.count == steps.count ? initial : Array(repeating: .pending, count: steps.count)
        var stopped = false
        for index in steps.indices {
            let included = index < include.count ? include[index] : true
            switch states[index] {
            case .done: continue
            case .duplicate where !force.contains(index): continue
            case .skipped where !included: continue
            default: break
            }
            if stopped {
                states[index] = .notRun
                continue
            }
            guard included else {
                states[index] = .skipped
                continue
            }
            let step = steps[index]
            let problems = check(step)
            if !problems.isEmpty {
                states[index] = .failed(problems.joined(separator: " "))
                stopped = true
                progress(states)
                continue
            }
            let key = ActionGate.identity(tool: step.tool, input: step.input)
            if !ActionGate.repeatable.contains(step.tool), !force.contains(index), let when = executedBefore(key) {
                states[index] = .duplicate(when.formatted(date: .abbreviated, time: .shortened))
                progress(states)
                continue
            }
            states[index] = .running
            progress(states)
            do {
                let result = try await execute(step)
                states[index] = .done(result)
                recordExecuted(key, step, result)
            } catch {
                states[index] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                stopped = true
            }
            progress(states)
        }
        return states
    }
}

extension Array {
    /// Het element op `index`, of nil als de lijst zo lang niet is.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
