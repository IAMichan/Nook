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
    /// The session it is about ("<id>" for a terminal session, "run:<id>" for one Nook runs).
    var session: String

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

    /// The macOS notification's subtitle: the folder and which session, in one short line.
    var bannerSubtitle: String { BannerText.subtitle(project: project, topic: topic) }

    /// The macOS notification's body: the gist of what the agent said, not the whole reply.
    var bannerBody: String { BannerText.gist(summary) }

    /// What the notice is about for `NoticePacer`: its session, and a failure apart, so a session that ends in an error
    /// right after a finished turn still tells you.
    var pace: String { "agent:" + session + (state == .failed ? ":failed" : "") }

    /// The card's id: one per session whatever its state, so a newer notice from the same session (a failure too)
    /// redraws its card instead of counting as a new pop-up (`AppModel.deliverNotice`).
    var cardID: String { Self.cardID(session: session) }

    /// The card, and the macOS notification, of an agent session's notice.
    static func cardID(session: String) -> String { "agentstatus-" + session }

    /// The one line of the compact strip: the headline and which session, by what it is about (or its folder when it
    /// has no topic), so two sessions in one folder tell apart.
    var stripLine: String {
        let which = Self.short(topic).isEmpty ? project : Self.short(topic)
        return which.isEmpty ? headline : headline + " · " + which
    }

    /// The line under the headline in the notice history: which session, and what the agent said last.
    var historyDetail: String {
        [Self.short(topic), summary].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One line of at most `topicLimit` characters, cut at a word with an ellipsis.
    static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.trimmingCharacters(in: .whitespaces)
        guard clean.count > topicLimit else { return clean }
        // One character is kept for the ellipsis, so the result never passes the limit.
        let cut = clean.prefix(topicLimit - 1)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}

/// Text for a macOS notification: a banner has room for about two short lines, so it gets the gist (the first sentence
/// in plain words) instead of the whole reply. The full text stays one click away, in the session.
/// Pure, so what a banner says can be tested without a Mac.
enum BannerText {
    /// Longest body line of an agent's banner.
    static let limit = 90
    /// Longest topic in a banner's subtitle, next to the folder.
    static let subtitleLimit = 48

    /// The first sentence of `text` without Markdown, links shortened ("#1394", "github.com"), and cut at a word
    /// to at most `limit` characters.
    static func gist(_ text: String, limit: Int = BannerText.limit) -> String {
        let first = text.split(whereSeparator: \.isNewline)
            .map { plain(String($0)) }
            .first { !$0.isEmpty } ?? ""
        return cut(firstSentence(first), to: limit)
    }

    /// `text` without Markdown marks and with its links shortened, on one line.
    static func plain(_ text: String) -> String {
        var line = text
        // [title](url) → title
        line = replace(#"\[([^\]]+)\]\([^)]+\)"#, in: line, with: "$1")
        // A pull request or issue link → its number.
        line = replace(#"https?://[^\s)]+/(?:pull|issues|merge_requests)/(\d+)[^\s)]*"#, in: line, with: "#$1")
        // Any other link → its host.
        line = replace(#"https?://(?:www\.)?([^/\s)]+)[^\s)]*"#, in: line, with: "$1")
        line = replace(#"\*\*|__|`"#, in: line, with: "")
        line = replace(#"^\s*(?:#{1,6}\s+|[-*+>]\s+|\d+[.)]\s+)"#, in: line, with: "")
        line = replace(#"\s+"#, in: line, with: " ")
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Up to the end of the first sentence that says something (a few words at least): "Done. Tests pass." → "Done.".
    static func firstSentence(_ text: String) -> String {
        let minimum = 12
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next] == " ",
               text.distance(from: text.startIndex, to: index) >= minimum {
                return String(text[...index])
            }
            index = next
        }
        return text
    }

    /// At most `limit` characters, cut at a word with an ellipsis.
    static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit - 1)
        let word = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// "Nook · Fix the login bug": where, and which session, in one short line.
    static func subtitle(project: String, topic: String) -> String {
        let topic = cut(AgentStatusNotice.short(topic), to: subtitleLimit)
        return [project, topic].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// An approval's context without the agent's name when the title already says it ("Claude Code · Fix it" under
    /// "Claude Code wants to …" → "Fix it").
    static func context(_ context: String, title: String) -> String {
        let parts = context.components(separatedBy: " · ")
        guard parts.count > 1, let agent = parts.first, !agent.isEmpty, title.contains(agent) else { return context }
        return cut(parts.dropFirst().joined(separator: " · "), to: subtitleLimit + 20)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
