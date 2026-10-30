import Foundation

/// Messages you deleted for yourself, per chat (the Chats tab's chat id), the same for every chat app: the chat no longer
/// shows them on this Mac, also when its app brings them in again at its next read. Kept in Nook's support folder, so a
/// restart does not bring them back. The app itself is told only where it can delete for you alone (Telegram).
@MainActor
final class ChatHiddenMessages: ObservableObject {
    static let shared = ChatHiddenMessages()

    @Published private(set) var hidden: [String: Set<String>]

    private let file: URL

    init(file: URL = NookPaths.supportDirectory.appendingPathComponent("chat-hidden.json")) {
        self.file = file
        // Chats kept under the ids they had before WhatsApp joined the shared inbox find their hidden messages again.
        hidden = ChatIDMigration.current(SafeStorage.load([String: Set<String>].self, from: file).value ?? [:]) { $0.union($1) }
    }

    /// The ids hidden in one chat.
    func ids(in chat: String) -> Set<String> { hidden[chat] ?? [] }

    func isHidden(_ message: String, in chat: String) -> Bool { hidden[chat]?.contains(message) ?? false }

    /// Hides a message in a chat from now on.
    func hide(_ message: String, in chat: String) {
        guard !isHidden(message, in: chat) else { return }
        hidden[chat, default: []].insert(message)
        save()
    }

    /// What a chat shows of `items`: the ones not hidden.
    func visible<Item>(_ items: [Item], in chat: String, id: (Item) -> String) -> [Item] {
        guard let gone = hidden[chat], !gone.isEmpty else { return items }
        return items.filter { !gone.contains(id($0)) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hidden) else { return }
        try? SafeStorage.write(data, to: file)
    }
}
