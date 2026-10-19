import Foundation

// Action gateway. A tool call from the brain is merely a proposal; it is validated here before
// the user sees it, and again right before it is actually executed (the brain can make mistakes or be misled
// by third-party text). Each step in a plan maintains its own state, so a plan that
// fails midway can safely resume without repeating completed steps.

/// The execution state of a single step in a plan.
enum ActionStepState: Codable, Equatable {
    /// Proposed by the brain; the user has not decided yet.
    case pending
    /// The user pressed Run; waiting for its turn.
    case approved
    case running
    /// The service reported success.
    case done(String)
    /// Succeeded, and Nook read the result back from the service (the event exists, the reminder is there).
    case verified(String)
    case failed(String)
    /// Was not reached because an earlier step failed.
    case notRun
    /// Unchecked by the user.
    case skipped
    /// This exact action was executed recently; will not repeat without explicit user confirmation.
    case duplicate(String)

    var isFinished: Bool {
        switch self {
        case .done, .verified, .skipped, .duplicate: return true
        default: return false
        }
    }

    /// The result text of a step that succeeded.
    var result: String? {
        switch self {
        case .done(let result), .verified(let result): return result
        default: return nil
        }
    }

    /// Whether this step is eligible to run (or retry).
    var canRun: Bool {
        switch self {
        case .pending, .approved, .failed, .notRun: return true
        default: return false
        }
    }
}

/// A single input field for an action proposal, shown for review before execution and allowing edits.
struct ActionField: Equatable, Identifiable {
    var key: String
    var label: String
    var value: String
    var editable: Bool
    var multiline: Bool
    var id: String { key }
}

enum ActionGate {
    /// Actions safe to repeat without deduplication checks.
    static let repeatable: Set<String> = ["media_control", "set_volume", "open_app", "open_url", "change_setting", "open_settings", "control_ui"]
    /// Window duration within which an action is considered a duplicate.
    static let duplicateWindow: TimeInterval = 12 * 3600

    // MARK: Validation

    /// Normalizes input (trims whitespace, converts numeric strings like "12" to integers) without changing semantic meaning.
    static func normalized(_ input: [String: Any], schema: [String: Any]) -> [String: Any] {
        let properties = (schema["properties"] as? [String: [String: Any]]) ?? [:]
        var result: [String: Any] = [:]
        // Strip unrecognized fields: the tool cannot use them and the user cannot inspect them.
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

    /// Problems with a proposed action; empty if valid. Validates against the tool's schema and fields with
    /// fixed semantics (dates, URLs, email addresses, repositories).
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
                // JSON deserialization yields NSNumber; whole numbers are acceptable.
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

        // A command from the brain never runs when it is clearly dangerous, whatever the user would click.
        if tool == "run_command", let command = input["command"] as? String {
            let assessment = CommandRisk.assess(command)
            if assessment.level == .danger { problems.append("Dit commando voer ik niet uit: \(assessment.title)") }
        }

        // Mouse and keyboard steps: known actions only, what each needs, never a blocked app or a shortcut that leaves it.
        if tool == "control_ui" {
            problems += UIControl.problems(app: (input["app"] as? String) ?? "", steps: input["steps"])
        }

        // Mail changes need a selection narrow enough to show the user what they approve.
        if tool == "trash_mail" || tool == "mark_mail" {
            let change: MailActions.Change? = tool == "trash_mail" ? .trash : (input["state"] as? String).flatMap { MailActions.Change(rawValue: $0.lowercased()) }
            if let change { problems += MailActions.problems(change, MailActions.selection(input)) }
        }

        // Fields with fixed semantics.
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

    /// owner/name without "." or ".." components: prevents traversal to unrelated API paths.
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

    // MARK: Presentation fields

    /// All input fields of a proposal, formatted in schema order (required fields first). Full text,
    /// unabridged: the user must be able to review the entire payload before execution.
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

    // MARK: Duplicate prevention

    /// Deterministic identity key for an action: identical tool and input yield the same key.
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

/// Executes an approved plan step by step. Succeeded steps are never re-run; halts on the first
/// failure (subsequent steps may depend on it) and tracks which steps succeeded or failed.
@MainActor
struct PlanRunner {
    struct Step {
        var tool: String
        var input: [String: Any]
    }

    /// Pre-execution validation (tool available, valid input, source permitted). Empty if valid.
    var check: (Step) -> [String]
    var execute: (Step) async throws -> String
    /// Timestamp if this action succeeded previously within the duplicate window, otherwise nil.
    var executedBefore: (String) -> Date?
    var recordExecuted: (String, Step, String) -> Void
    var progress: ([ActionStepState]) -> Void = { _ in }
    /// Reads the result back from the service: true = confirmed, false = not found, nil = cannot be checked.
    var verify: (Step, String) async -> Bool? = { _, _ in nil }

    /// `include`: which steps the user kept enabled. `force`: steps permitted to run despite being duplicates.
    func run(_ steps: [Step], states initial: [ActionStepState], include: [Bool], force: Set<Int> = []) async -> [ActionStepState] {
        var states = initial.count == steps.count ? initial : Array(repeating: .pending, count: steps.count)
        // The user's click approves every step that is still to run; that is visible before the first one starts.
        for index in steps.indices where (index < include.count ? include[index] : true) && states[index].canRun {
            states[index] = .approved
        }
        progress(states)
        var stopped = false
        for index in steps.indices {
            let included = index < include.count ? include[index] : true
            switch states[index] {
            case .done, .verified: continue
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
                recordExecuted(key, step, result)
                switch await verify(step, result) {
                case .some(true): states[index] = .verified(result)
                case .some(false):
                    states[index] = .failed("The service reported success, but Nook could not find the result afterwards. Check it yourself.")
                    stopped = true
                case .none: states[index] = .done(result)
                }
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
    /// Returns element at `index`, or nil if index is out of bounds.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
