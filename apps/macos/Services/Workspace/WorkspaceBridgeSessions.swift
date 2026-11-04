import Foundation

// The arguments and answers of the bridge's session tools: searching every session (`session_search`), keeping the
// Agents list tidy (`session_organize`) and the questions other sessions wait on (`session_questions`). Foundation only,
// so every rule is tested here (`WorkspaceBridgeSessionsTests`); WorkspaceBridge+Sessions does the work.

enum BridgeSessionArguments {
    // MARK: Search

    struct Search: Equatable, Sendable {
        var query: String
        /// Only this session; nil searches every session.
        var sessionID: UUID?
        /// At most this many sessions in the answer.
        var limit: Int
        var includeArchived: Bool
    }

    static let defaultSearchLimit = 8
    static let maxSearchLimit = 25

    static func search(_ arguments: [String: Any]) -> Result<Search, BridgeArgumentError> {
        guard let query = BridgeArgs.string(arguments["query"]) else { return .failure(BridgeArgumentError("Give the words to search for in query.")) }
        guard query.utf16.count <= TimelineSearch.maxQueryLength else {
            return .failure(BridgeArgumentError("The query is too long (at most \(TimelineSearch.maxQueryLength) characters)."))
        }
        var session: UUID?
        if let raw = BridgeArgs.string(arguments["session_id"]) {
            guard let id = UUID(uuidString: raw) else { return .failure(BridgeArgumentError("session_id is not a session id from session_list.")) }
            session = id
        }
        let limit = min(maxSearchLimit, max(1, BridgeArgs.int(arguments["limit"]) ?? defaultSearchLimit))
        return .success(Search(query: query, sessionID: session, limit: limit,
                               includeArchived: BridgeArgs.bool(arguments["include_archived"]) ?? false))
    }

    /// A line of text around a match: `radius` characters on each side, on one line, with … where it was cut.
    static func excerpt(_ text: String, range: Range<Int>, radius: Int = 70) -> String {
        let ns = text as NSString
        let start = max(0, range.lowerBound - radius)
        let end = min(ns.length, range.upperBound + radius)
        guard start < end else { return "" }
        var piece = ns.substring(with: NSRange(location: start, length: end - start))
        piece = piece.components(separatedBy: .newlines).joined(separator: " ")
        while piece.contains("  ") { piece = piece.replacingOccurrences(of: "  ", with: " ") }
        piece = piece.trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + piece + (end < ns.length ? "…" : "")
    }

    /// Which part of a session a match was in, for the agent.
    static func role(of kind: RunEvent.Kind) -> String {
        switch kind {
        case .user: return "user"
        case .assistant: return "agent"
        case .thinking: return "thinking"
        case .tool: return "tool"
        case .fileChange: return "file change"
        case .approval: return "approval"
        case .error: return "error"
        case .system: return "note"
        case .result: return "result"
        case .page: return "page"
        }
    }

    /// One session's matches as the agent reads them: the session line, then at most `shown` excerpts.
    static func renderMatches(sessionLine: String, events: [RunEvent], result: TimelineSearchResult, shown: Int = 3) -> String {
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = [sessionLine + " · \(result.matches.count) match" + (result.matches.count == 1 ? "" : "es")]
        var seen = Set<UUID>()
        for match in result.matches where seen.insert(match.eventID).inserted {
            guard let event = byID[match.eventID] else { continue }
            let text: String?
            switch match.field {
            case .text: text = event.text
            case .detail: text = event.detail
            case .output: text = event.output
            }
            guard let text else { continue }
            lines.append("  - [\(role(of: event.kind))] " + excerpt(BridgeSecret.redact(text), range: match.range))
            if seen.count >= shown { break }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Organize

    /// What `session_organize` can do: the same actions the Agents list offers on a session's row.
    enum OrganizeAction: String, CaseIterable, Sendable {
        case pin, unpin, settle, reopen, snooze, wake, archive, unarchive
        case markUnread = "mark_unread"
        case markRead = "mark_read"
    }

    struct Organize: Equatable, Sendable {
        var sessionID: UUID
        var action: OrganizeAction
        /// For `snooze`: until when.
        var snooze: SnoozePolicy.Choice?
    }

    static func organize(_ arguments: [String: Any]) -> Result<Organize, BridgeArgumentError> {
        guard let raw = BridgeArgs.string(arguments["session_id"]), let id = UUID(uuidString: raw) else {
            return .failure(BridgeArgumentError("Give session_id: a session id from session_list."))
        }
        let names = OrganizeAction.allCases.map(\.rawValue).joined(separator: ", ")
        guard let name = BridgeArgs.string(arguments["action"]), let action = OrganizeAction(rawValue: name.lowercased()) else {
            return .failure(BridgeArgumentError("Give action: one of \(names)."))
        }
        var choice: SnoozePolicy.Choice?
        if action == .snooze {
            let until = BridgeArgs.string(arguments["until"])?.lowercased() ?? SnoozePolicy.Choice.hour.rawValue
            guard let parsed = SnoozePolicy.Choice(rawValue: until) else {
                return .failure(BridgeArgumentError("until must be one of \(SnoozePolicy.Choice.allCases.map(\.rawValue).joined(separator: ", "))."))
            }
            choice = parsed
        }
        return .success(Organize(sessionID: id, action: action, snooze: choice))
    }

    // MARK: Questions

    enum QuestionAction: String, CaseIterable, Sendable { case list, read, answer }

    struct Questions: Equatable, Sendable {
        var action: QuestionAction
        var sessionID: UUID?
        var questionID: String?
        /// For `answer`: per question id, the chosen labels and/or your own text.
        var answers: [String: [String]]
    }

    static func questions(_ arguments: [String: Any]) -> Result<Questions, BridgeArgumentError> {
        let name = BridgeArgs.string(arguments["action"])?.lowercased() ?? QuestionAction.list.rawValue
        guard let action = QuestionAction(rawValue: name) else {
            return .failure(BridgeArgumentError("action must be list, read or answer."))
        }
        var session: UUID?
        if let raw = BridgeArgs.string(arguments["session_id"]) {
            guard let id = UUID(uuidString: raw) else { return .failure(BridgeArgumentError("session_id is not a session id from session_list.")) }
            session = id
        }
        let question = BridgeArgs.string(arguments["question_id"])
        if action != .list, session == nil || question == nil {
            return .failure(BridgeArgumentError("\(action.rawValue) needs session_id and question_id (from session_questions with action list)."))
        }
        var answers: [String: [String]] = [:]
        if action == .answer {
            guard let given = arguments["answers"] as? [String: Any], !given.isEmpty else {
                return .failure(BridgeArgumentError("answer needs answers: an object from each question's id to the chosen option label(s) or your own text."))
            }
            for (key, value) in given {
                let values: [String]
                if let one = BridgeArgs.string(value) {
                    values = [one]
                } else if let list = value as? [Any] {
                    values = list.compactMap { BridgeArgs.string($0) }
                } else {
                    values = []
                }
                guard !values.isEmpty else { return .failure(BridgeArgumentError("The answer to \(key) is empty.")) }
                answers[key] = values
            }
        }
        return .success(Questions(action: action, sessionID: session, questionID: question, answers: answers))
    }

    /// The answers checked against the questions they answer: every question answered, one label for a single choice,
    /// and words of your own only where the question takes them. Labels are matched without regard to case and come back
    /// as the question spells them.
    static func validate(_ answers: [String: [String]], for questions: [RunQuestion]) -> Result<[String: [String]], BridgeArgumentError> {
        let known = Set(questions.map(\.id))
        if let stray = answers.keys.first(where: { !known.contains($0) }) {
            return .failure(BridgeArgumentError("There is no question \(stray) here; use the ids from session_questions with action read."))
        }
        var result: [String: [String]] = [:]
        for question in questions {
            guard let given = answers[question.id], !given.isEmpty else {
                return .failure(BridgeArgumentError("Answer every question; \(question.id) has no answer."))
            }
            var values: [String] = []
            for value in given {
                if let option = question.options.first(where: { $0.label.caseInsensitiveCompare(value) == .orderedSame }) {
                    values.append(option.label)
                } else if question.allowsOther || question.options.isEmpty {
                    values.append(value)
                } else {
                    let labels = question.options.map { "\"\($0.label)\"" }.joined(separator: ", ")
                    return .failure(BridgeArgumentError("\(question.id) takes only these options: \(labels)."))
                }
            }
            if !question.multiSelect, values.count > 1 {
                return .failure(BridgeArgumentError("\(question.id) takes one answer."))
            }
            result[question.id] = values
        }
        return .success(result)
    }

    /// A pending question as the agent reads it: its id, then each question with its options.
    static func render(questionID: String, questions: [RunQuestion], asked: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(asked) / 60))
        var lines = ["Question \(questionID) · waiting \(minutes) min"]
        for item in questions {
            var head = "- \(item.id)"
            if !item.header.isEmpty { head += " (\(item.header))" }
            head += ": \(item.question)"
            if item.multiSelect { head += " [several answers allowed]" }
            if item.allowsOther || item.options.isEmpty { head += " [own text allowed]" }
            lines.append(head)
            for option in item.options {
                lines.append("    • \(option.label)" + (option.description.isEmpty ? "" : " — \(option.description)"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
