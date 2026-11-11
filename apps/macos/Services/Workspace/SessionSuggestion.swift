import Foundation

/// A new session an agent suggests (`session_suggest` on the bridge), as Claude's "New session" card: a side task it
/// noticed, shown in its own timeline with a title, where it would run and a short summary. Nothing starts until you
/// choose: Start (a new session beside this one), Do it here (the prompt goes to this session as your next message),
/// Options (the new-session composer, filled in) or ×. The agent does not wait for the answer.
/// Kept as a `.system` event with `tool` `SessionSuggestion.tool`: `text` the title, `detail` this as JSON, `state`
/// pending until you choose, `output` the new session's id once started. Foundation only (`SessionSuggestionTests`).
struct SessionSuggestion: Codable, Equatable, Sendable {
    static let tool = "session_suggestion"
    static let maxTitleLength = 120
    static let maxSummaryLength = 400
    static let maxPromptBytes = 64 * 1024

    var title: String
    /// What the new session is asked: everything it needs, since it does not see this conversation.
    var prompt: String
    /// One or two sentences for the card.
    var summary: String
    /// An agent other than the caller's (its name), or empty for the same agent.
    var agent: String = ""
    /// True for a worktree of its own, false for the caller's folder as it is, nil for the folder's default.
    var worktree: Bool? = nil

    /// What you chose on the card.
    enum Choice: String, Sendable {
        case start, here, options, dismiss
    }

    static func parse(_ arguments: [String: Any]) -> Result<SessionSuggestion, BridgeArgumentError> {
        let title = BridgeArgs.string(arguments["title"]).map(oneLine) ?? ""
        let prompt = (arguments["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            return .failure(BridgeArgumentError("Give prompt: the full task for the new session, which does not see this conversation."))
        }
        guard prompt.utf8.count <= maxPromptBytes else {
            return .failure(BridgeArgumentError("The prompt is too long (at most \(maxPromptBytes / 1024) KB)."))
        }
        let summary = BridgeArgs.string(arguments["summary"]).map(oneLine) ?? ""
        let shownTitle = title.isEmpty ? String(oneLine(prompt).prefix(60)) : title
        return .success(SessionSuggestion(
            title: String(shownTitle.prefix(maxTitleLength)),
            prompt: prompt,
            summary: String(summary.prefix(maxSummaryLength)),
            agent: BridgeArgs.string(arguments["agent"]) ?? "",
            worktree: arguments["worktree"] as? Bool))
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    func event(id: UUID = UUID()) -> RunEvent {
        let json = (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
        return RunEvent(kind: .system, text: title, tool: Self.tool, detail: json, state: .pending, id: id)
    }

    /// Where the card's state is kept: pending while it waits; done once started (`output` the session id), allowed when
    /// done here, denied when dismissed.
    static func state(after choice: Choice) -> RunEvent.State? {
        switch choice {
        case .start: return .done
        case .here: return .allowed
        case .dismiss: return .denied
        case .options: return nil
        }
    }

    /// The answer `session_suggest` gives the agent.
    static let toolAnswer = "Shown to the user as a suggested new session in your timeline. They decide: start it beside you, have you do it here (it then arrives as their next message), open it in the new-session composer, or dismiss it. Do not wait for it and do not do the task yourself unless it comes back to you; carry on or end your turn."
}

extension SessionSuggestion {
    /// The suggestion an event carries; nil for any other event.
    init?(event: RunEvent) {
        guard event.kind == .system, event.tool == Self.tool, let detail = event.detail,
              let value = try? JSONDecoder().decode(SessionSuggestion.self, from: Data(detail.utf8)) else { return nil }
        self = value
    }
}

extension RunProvider {
    /// The agent with this id or name ("codex", "Claude Code"); nil for none.
    static func named(_ name: String) -> RunProvider? {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        return allCases.first { $0.rawValue == name || $0.displayName.lowercased() == name }
    }
}
