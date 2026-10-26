import Foundation
import Combine

/// Who is typing right now, in every chat (see `ChatTypingState`): the open chat says it under its last message, the
/// chat's row in the list in place of its newest message. Each word goes again on its own once it runs out.
@MainActor
final class ChatTypingCenter: ObservableObject {
    static let shared = ChatTypingCenter()

    @Published private(set) var state = ChatTypingState()
    private var expiry: Task<Void, Never>?

    /// `person` (their id in the app; `name` empty in a private chat) is typing in the chat with the Chats tab's id
    /// `chat`, for `seconds` (the app's own timeout, else `ChatTypingState.hold`).
    func typing(chat: String, person: String, name: String, kind: ChatTypist.Kind = .text, seconds: TimeInterval? = nil) {
        let until = Date().addingTimeInterval(seconds ?? ChatTypingState.hold)
        var next = state
        next.typing(ChatTypist(id: person, name: name, kind: kind, until: until), in: chat)
        if next != state { state = next }
        scheduleExpiry()
    }

    /// `person` stopped typing in `chat`, or their message came in.
    func stopped(chat: String, person: String) {
        var next = state
        if next.stopped(person, in: chat) { state = next }
    }

    /// Everyone typing in `chat` now.
    func typists(_ chat: String) -> [ChatTypist] { state.typists(in: chat, now: Date()) }

    /// What `chat` shows while people type; nil when no one does.
    func line(_ chat: String) -> String? { ChatTypingLine.text(typists(chat)) }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let next = state.nextExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled, let self else { return }
            var state = self.state
            if state.expire(now: Date()) { self.state = state }
            self.scheduleExpiry()
        }
    }
}
