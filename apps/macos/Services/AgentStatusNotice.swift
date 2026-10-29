import Foundation

/// What a coding agent tells you by itself (a turn finished, failed, or waits on you), the same for every agent: one in
/// a terminal (Claude Code, Codex, Gemini CLI, …) and a session Nook runs alike. Each agent only fills it in from what
/// its app says; `AppModel.deliverAgentNotice` shows it as a card or a strip, so they all look the same.
/// Pure, so what the notice says can be tested without a Mac.
struct AgentStatusNotice: Equatable, Sendable {
    enum State: String, Sendable {
        case done, failed, waiting
    }

    /// The agent's display name ("Claude Code", "Codex"): its logo and the headline name it.
    var agent: String
    /// The folder it works in.
    var project: String = ""
    /// What the session is about (its first prompt, or the title of a session Nook runs).
    var topic: String = ""
    /// The agent's last reply in one line, or what went wrong.
    var summary: String = ""
    var state: State
    /// The lines it changed, when its app says so.
    var added = 0
    var removed = 0
    /// What the notice is about for `NoticePacer` (one session).
    var pace: String

    /// Longest topic shown as the card's title; a longer first prompt is cut at a word.
    static let topicLimit = 90

    /// "Claude Code is done", "Codex needs you".
    var headline: String { tr("agentNotice.compact.\(state.rawValue)", agent) }

    /// Who and where, for the card's header and the history: "Claude Code · nook".
    var context: String { [agent, project].filter { !$0.isEmpty }.joined(separator: " · ") }

    /// The card's title: what the session is about, so you know which one at a glance; the reply when it has no topic.
    var title: String {
        let topic = Self.short(topic)
        if !topic.isEmpty { return topic }
        if !summary.isEmpty { return summary }
        return headline
    }

    /// The quieter line under the title: the reply (or the error), when the title is the topic. Nil when there is
    /// nothing more to say.
    var detail: String? {
        let topic = Self.short(topic)
        guard !topic.isEmpty, !summary.isEmpty, summary != topic else { return nil }
        return summary
    }

    var hasChanges: Bool { added + removed > 0 }

    /// The card's id: one per session, so a newer notice from the same session redraws its card instead of counting as
    /// a new pop-up (`AppModel.deliverNotice`).
    var cardID: String { "agentstatus-" + pace }

    /// The one line of the compact strip: the headline and which session, by what it is about (or its folder when it
    /// has no topic), so two sessions in one folder tell apart.
    var stripLine: String {
        let which = Self.short(topic).isEmpty ? project : Self.short(topic)
        return which.isEmpty ? headline : headline + " · " + which
    }

    /// The line under the headline in the history under the bell: which session, and what the agent said last.
    var historyDetail: String {
        [Self.short(topic), summary].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One line of at most `topicLimit` characters, cut at a word with an ellipsis.
    static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.trimmingCharacters(in: .whitespaces)
        guard clean.count > topicLimit else { return clean }
        let cut = clean.prefix(topicLimit)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}
