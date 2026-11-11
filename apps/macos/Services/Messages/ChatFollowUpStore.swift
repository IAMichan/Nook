import Foundation
import Combine

/// Your follow-ups (`ChatFollowUps`) and what you keep about people (`ChatPersonNotes`), saved in the user defaults. The
/// same for every chat app: nothing here knows an app, only chat keys. Nothing is ever sent from here: a message that is
/// due is handed to the caller, who sends it through the usual checks (`ChatAction.send`) and the audit log.
@MainActor
final class ChatFollowUpStore: ObservableObject {
    static let shared = ChatFollowUpStore()

    @Published private(set) var follow: ChatFollowUps
    @Published private(set) var notes: ChatPersonNotes

    private static let followKey = "chats.followUps.v1"
    private static let notesKey = "chats.personNotes.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // What cannot be read is kept aside first (`SafeStorage`), so the next change never loses it for good.
        follow = SafeStorage.decode(ChatFollowUps.self, defaults: defaults, key: Self.followKey).value ?? ChatFollowUps()
        notes = SafeStorage.decode(ChatPersonNotes.self, defaults: defaults, key: Self.notesKey).value ?? ChatPersonNotes()
    }

    /// Changes the follow-ups and saves them, only when something changed (a published value publishes on every write).
    func change(_ change: (inout ChatFollowUps) -> Void) {
        var next = follow
        change(&next)
        guard next != follow else { return }
        follow = next
        defaults.setEncoded(next, forKey: Self.followKey)
    }

    func changeNotes(_ change: (inout ChatPersonNotes) -> Void) {
        var next = notes
        change(&next)
        guard next != notes else { return }
        notes = next
        defaults.setEncoded(next, forKey: Self.notesKey)
    }

    /// The chats as the shared shape, for every app in the inbox at once.
    static func turns(of inbox: ChatInbox) -> [ChatFollowUpTurn] {
        inbox.threads.values.map(ChatFollowUpTurn.init)
    }

    /// Forgets the waits that were answered and the snoozes that ended, after the inbox changed.
    func settle(with inbox: ChatInbox, now: Date = Date()) {
        change { $0.settle(with: Self.turns(of: inbox), now: now) }
    }
}
