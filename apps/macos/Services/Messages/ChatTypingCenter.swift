import Foundation
import Combine

/// Who is typing right now, in every chat (see `ChatTypingState`): the open chat says it under its last message, the
/// chat's row in the list in place of its newest message. Each word goes again on its own once it runs out.
@MainActor
final class ChatTypingCenter: ObservableObject {
    static let shared = ChatTypingCenter()

    /// Who types where, published only when that changes (who, in which chat, typing or recording): an app repeats the
    /// word every few seconds while someone keeps typing, with a new end time each time, and publishing each repeat
    /// redrew the chat list and the open chat. The end times live in `current`.
    @Published private(set) var state = ChatTypingState()
    /// The state with every end time as the apps last said it; `typists` and the expiry read this one.
    private var current = ChatTypingState()
    private var expiry: Task<Void, Never>?

    /// `person` (their id in the app; `name` empty in a private chat) is typing in the chat with the Chats tab's id
    /// `chat`, for `seconds` (the app's own timeout, else `ChatTypingState.hold`).
    func typing(chat: String, person: String, name: String, kind: ChatTypist.Kind = .text, seconds: TimeInterval? = nil) {
        let until = Date().addingTimeInterval(seconds ?? ChatTypingState.hold)
        current.typing(ChatTypist(id: person, name: name, kind: kind, until: until), in: chat)
        publish()
        scheduleExpiry()
    }

    /// `person` stopped typing in `chat`, or their message came in.
    func stopped(chat: String, person: String) {
        if current.stopped(person, in: chat) { publish() }
    }

    /// Everyone typing in `chat` now.
    func typists(_ chat: String) -> [ChatTypist] { current.typists(in: chat, now: Date()) }

    /// What `chat` shows while people type; nil when no one does.
    func line(_ chat: String) -> String? { ChatTypingLine.text(typists(chat)) }

    private func publish() {
        if current.shown != state.shown { state = current }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let next = current.nextExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled, let self else { return }
            if self.current.expire(now: Date()) { self.publish() }
            self.scheduleExpiry()
        }
    }
}
