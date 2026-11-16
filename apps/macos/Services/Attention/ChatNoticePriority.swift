import Foundation

/// Which chat messages may come through the pacer a little sooner, the way an agent that waits on you does, while
/// staying calm. Conservative on purpose:
/// - a direct question in a private chat (someone asks you something), or
/// - a mention of you in a group that is otherwise quiet (it reached you only because it names you).
///
/// Priority never bypasses a rule: a muted or hidden chat, an app switched off, quiet mode, the quiet hours and "don't
/// show" all still hold (it is not passed to `NoticeRules.decide` as urgent). It only lets the message past the pacer's
/// burst limit; the gap between two pop-ups and the one-per-chat gap still apply, also stretched by feedback.
/// The same for every chat app. Tested in ChatNoticePriorityTests.
enum ChatNoticePriority {
    /// - `quietByKind`: the chat's kind is quiet in its app (a WhatsApp group).
    /// - `mode`: the chat's own choice; a muted chat never has priority, a loud one follows the same rule.
    static func raises(kind: ChatKind, mentionsMe: Bool, asksQuestion: Bool, quietByKind: Bool, mode: ChatMode) -> Bool {
        guard mode != .muted else { return false }
        switch kind {
        case .person: return asksQuestion
        case .group: return mentionsMe && quietByKind
        default: return false
        }
    }
}
