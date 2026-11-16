import Foundation

/// The chats you pinned in Nook (by the Chats tab's chat id), the same for every chat app: they stay on top of the Chats
/// list, under "Pinned", whatever came in elsewhere. This works for every app, also the ones that let no other app pin a
/// chat (Messages, Mail, Slack, Teams, Snapchat); pinning a chat in its app itself is a separate step
/// (`AppModel.setChatPinned`). Kept in Nook's support folder, so a restart keeps them.
@MainActor
final class ChatPins: ObservableObject {
    static let shared = ChatPins()

    @Published private(set) var pinned: Set<String>

    private let file: URL

    init(file: URL = NookPaths.supportDirectory.appendingPathComponent("chat-pins.json")) {
        self.file = file
        // Chats kept under the ids they had before WhatsApp joined the shared inbox stay pinned.
        pinned = Set((SafeStorage.load(Set<String>.self, from: file).value ?? []).map(ChatIDMigration.current))
    }

    func isPinned(_ chat: String) -> Bool { pinned.contains(chat) }

    /// Pins a chat on top of the list, or lets it go back to its place by date.
    func setPinned(_ value: Bool, chat: String) {
        guard value != isPinned(chat) else { return }
        if value { pinned.insert(chat) } else { pinned.remove(chat) }
        save()
    }

    func toggle(_ chat: String) { setPinned(!isPinned(chat), chat: chat) }

    private func save() {
        guard let data = try? JSONEncoder().encode(pinned) else { return }
        try? SafeStorage.write(data, to: file)
    }
}
