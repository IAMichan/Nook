import Foundation

/// A poll in a chat, the same for every chat app: its question, its options with how many chose each and whether you
/// did, and whether more than one may be chosen. WhatsApp and Telegram polls both come in as this; `ChatPollView` draws
/// it and lets you vote where the app's bridge can. Foundation only, so it can be tested anywhere.
struct ChatPoll: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable, Identifiable {
        var text: String
        var votes: Int = 0
        var chosen: Bool = false
        /// Who chose it, by name (you as "You", first); nil where the app does not say.
        var voters: [String]? = nil

        var id: String { text }
    }

    var question: String
    var options: [Option]
    /// More than one option may be chosen.
    var multiple: Bool = false
    /// True when the votes are not all known: a poll Nook found later, whose app keeps the votes. It then shows no
    /// counts, or the ones Nook saw itself with a word that earlier ones may be missing (`partial`).
    var unknownCounts: Bool? = nil

    /// Whether the counts can be shown.
    var counted: Bool { unknownCounts != true }

    /// Some votes are known, but earlier ones may be missing: the counts show, with a word that they may be short.
    var partial: Bool { !counted && total > 0 }

    /// Whether any option says who chose it.
    var namesVoters: Bool { options.contains { !($0.voters ?? []).isEmpty } }

    /// Votes cast in all, for the share of each option.
    var total: Int { options.reduce(0) { $0 + $1.votes } }

    /// Your choice now.
    var chosen: [String] { options.filter(\.chosen).map(\.text) }

    /// Your choice after a click on `option`: in a poll of one answer it replaces your choice (a second click takes it
    /// back), in one of more answers it is added or taken off.
    func choice(afterTapping option: String) -> [String] {
        let now = chosen
        if now.contains(option) { return now.filter { $0 != option } }
        return multiple ? now + [option] : [option]
    }

    /// The poll with `choice` as your vote: the counts move with it at once, before the app confirms.
    func voting(_ choice: [String]) -> ChatPoll {
        var poll = self
        for index in poll.options.indices {
            let was = poll.options[index].chosen
            let now = choice.contains(poll.options[index].text)
            poll.options[index].chosen = now
            poll.options[index].votes = max(0, poll.options[index].votes + (now ? 1 : 0) - (was ? 1 : 0))
        }
        return poll
    }

    /// "📊 Lunch?": a poll in one line, for a chat's line in a list and for Nook.
    var line: String { "📊 " + question }
}
