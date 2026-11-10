import Foundation

// The arguments and answers of the bridge's session tools: searching every session (`session_search`), keeping the
// Agents list tidy (`session_organize`) and the questions other sessions wait on (`session_questions`). Foundation only,
// so every rule is tested here (`WorkspaceBridgeSessionsTests`); WorkspaceBridge+Sessions does the work.

enum BridgeSessionArguments {
    // MARK: Start

    /// What `session_start` asks for: one or more sessions (`create_threads` and `thread_launch` in one tool),
    /// all in the same place.
    struct Start: Equatable, Sendable {
        struct Session: Equatable, Sendable {
            /// The first message; empty starts the session idle, waiting for yours (then `title` names it).
            var task: String
            var title: String
            /// The agent's name or id; empty is the folder's own.
            var agent: String
            var model: String
            var plan: Bool
        }

        enum Place: Equatable, Sendable {
            /// The caller's own folder or worktree, beside it.
            case yours(String)
            /// A project folder; `worktree` nil is the folder's own choice.
            case folder(String, worktree: Bool?)
            /// A new git worktree of `folder`, from `base` (a branch or `origin/main`; nil: the branch the folder is on).
            case worktree(String, base: String?)
            /// A new folder of its own under ~/.nook/scratch, no project.
            case scratch
        }

        var sessions: [Session]
        var place: Place

        /// The folder named or inherited; nil for a scratch folder, made per session.
        var folderPath: String? {
            switch place {
            case .yours(let path), .folder(let path, _), .worktree(let path, _): return path
            case .scratch: return nil
            }
        }
    }

    static let maxStart = 20
    static let maxTaskLength = 120_000

    /// `callerFolder`: where the calling agent works, the default place; empty for a script, which must name a folder.
    static func start(_ arguments: [String: Any], callerFolder: String) -> Result<Start, BridgeArgumentError> {
        // One session from the top-level fields, or several from `sessions`, which take those fields as their defaults.
        let shared = session(arguments, defaults: nil)
        var sessions: [Start.Session] = []
        if let list = arguments["sessions"] {
            guard let items = list as? [Any], !items.isEmpty else { return .failure(BridgeArgumentError("sessions must be a list of 1 to \(maxStart) sessions.")) }
            guard items.count <= maxStart else { return .failure(BridgeArgumentError("Start at most \(maxStart) sessions in one call.")) }
            for item in items {
                guard let fields = item as? [String: Any] else { return .failure(BridgeArgumentError("Each item of sessions is an object with task and/or title.")) }
                sessions.append(session(fields, defaults: shared))
            }
        } else {
            sessions = [shared]
        }
        for (index, item) in sessions.enumerated() {
            let which = sessions.count == 1 ? "" : " (session \(index + 1))"
            guard !item.task.isEmpty || !item.title.isEmpty else {
                return .failure(BridgeArgumentError("Give the first message in task, or a title to start it idle\(which)."))
            }
            guard item.task.count <= maxTaskLength else { return .failure(BridgeArgumentError("The task is too long\(which).")) }
        }

        let scratch = BridgeArgs.bool(arguments["scratch"]) ?? false
        let folder = BridgeArgs.string(arguments["folder"])
        var worktree = BridgeArgs.bool(arguments["worktree"])
        let base = BridgeArgs.string(arguments["base"])
        if let base {
            guard isPlausibleRef(base) else { return .failure(BridgeArgumentError("base is not a branch name: \(base)")) }
            guard worktree != false else { return .failure(BridgeArgumentError("base needs a worktree: leave worktree out or set it to true.")) }
            worktree = true
        }
        if scratch {
            guard folder == nil, worktree == nil else { return .failure(BridgeArgumentError("scratch starts in a new folder of its own: leave folder, worktree and base out.")) }
            return .success(Start(sessions: sessions, place: .scratch))
        }
        let place: Start.Place
        if let folder {
            place = worktree == true ? .worktree(folder, base: base) : .folder(folder, worktree: worktree)
        } else {
            let yours = callerFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !yours.isEmpty else { return .failure(BridgeArgumentError("Give the folder to work in (an absolute path), or scratch: true.")) }
            place = worktree == true ? .worktree(yours, base: base) : .yours(yours)
        }
        return .success(Start(sessions: sessions, place: place))
    }

    private static func session(_ fields: [String: Any], defaults: Start.Session?) -> Start.Session {
        Start.Session(task: BridgeArgs.string(fields["task"]) ?? "",
                      title: BridgeArgs.string(fields["title"]) ?? "",
                      agent: BridgeArgs.string(fields["agent"]) ?? defaults?.agent ?? "",
                      model: BridgeArgs.string(fields["model"]) ?? defaults?.model ?? "",
                      plan: BridgeArgs.bool(fields["plan"]) ?? defaults?.plan ?? false)
    }

    /// A git ref an agent may name as a base: `main`, `origin/main`, `release/1.2`. Never an option or a range.
    static func isPlausibleRef(_ ref: String) -> Bool {
        guard !ref.isEmpty, ref.count <= 200, !ref.hasPrefix("-"), !ref.hasPrefix("/"), !ref.hasSuffix("/"),
              !ref.contains(".."), !ref.contains("@{"), !ref.hasSuffix(".lock") else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.whitespacesAndNewlines).union(.controlCharacters)
        return ref.rangeOfCharacter(from: forbidden) == nil
    }

    // MARK: Send

    /// How `session_send` delivers (`thread_send` modes).
    enum SendMode: String, CaseIterable, Sendable {
        /// Starts an idle session, steers a running turn when the agent can take it, otherwise waits in line.
        case auto
        /// Always after the current turn.
        case queue
        /// Into the running turn now; refused when the agent cannot take it.
        case steer
        /// Stops the running turn and starts again with this message.
        case restart
    }

    static func sendMode(_ value: Any?) -> Result<SendMode, BridgeArgumentError> {
        guard let raw = BridgeArgs.string(value) else { return .success(.queue) }
        guard let mode = SendMode(rawValue: raw.lowercased()) else {
            return .failure(BridgeArgumentError("mode is one of auto, queue, steer or restart."))
        }
        return .success(mode)
    }

    // MARK: Wait

    static let maxWaitSessions = 8

    static func waitSessions(_ value: Any?) -> Result<[UUID], BridgeArgumentError> {
        let raw = ((value as? [Any]) ?? []).compactMap { BridgeArgs.string($0) }
        guard !raw.isEmpty, raw.count <= maxWaitSessions else {
            return .failure(BridgeArgumentError("Pass between 1 and \(maxWaitSessions) session ids in session_ids."))
        }
        var ids: [UUID] = []
        for text in raw {
            guard let id = UUID(uuidString: text) else { return .failure(BridgeArgumentError("\(text) is not a session id from session_list or session_start.")) }
            if !ids.contains(id) { ids.append(id) }
        }
        return .success(ids)
    }

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
