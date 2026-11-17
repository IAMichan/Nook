import Foundation

// What Nook could do next for what was just said (`CompanionFeature.actionSuggestions`), as the Mac shows it above the
// field of a conversation (`ActionSuggestionBar`, `ChatActionSuggestions`): an agent on a task that came up, a reminder,
// an event. The same steps in every place they show on the Mac: under an agent's turn (`SessionDigest.suggestion`), in
// a chat with Nook (`ChatDigest.suggestion`) and in a chat of your apps (`InboxChatDigest.suggestion`). The Mac looks
// while a phone has the conversation open, as it looks while its own screen shows it. *Do it* and the cross are
// `suggestionAct` (`item` the conversation key, `text` "run" or "dismiss"); a run needs *operate*, is checked again,
// runs through the Mac's own `runDraftActions` (anything risky still asks there) and is logged as
// `companion_suggestion_run`.

/// The steps Nook offers for one conversation, and how running them went.
struct ActionSuggestionDigest: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        var text: String
        /// The Mac's symbol for the kind of step (a bell for a reminder, a calendar for an event…).
        var symbol: String
    }

    enum State: String, Codable, Sendable { case waiting, running, done, failed }

    /// The Mac's key of the conversation (`ChatActionSuggestion.Turn.conversation`), sent back with `suggestionAct`.
    var conversation: String
    var steps: [Step]
    /// Why Nook offers them.
    var reason: String? = nil
    var state: State
    /// What came of it: the result once done, why once failed.
    var result: String? = nil

    /// At most this many steps travel.
    static let stepLimit = 6
}

/// What `suggestionAct` does with the steps (`CompanionRequest.text`).
enum SuggestionAct: String, Codable, Sendable {
    case run, dismiss
}
