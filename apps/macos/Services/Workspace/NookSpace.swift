import Foundation

/// A space: instructions and attached context that go with every Nook conversation filed in it ("Taxes 2026", "Garden
/// project"). Not the same as a coding project (a folder an agent works in). Attached files are paths on this Mac, read
/// when a conversation uses the space, never copied.
struct NookSpace: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// What Nook should always know or do inside this space ("Answer in Dutch. The client is Aron.").
    var instructions = ""
    /// Files and folders attached as context, by absolute path.
    var attachments: [String] = []
    var createdAt = Date()

    /// The instruction block for the model, empty when the space has none.
    var contextText: String {
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return "Instructions of the space \"\(name)\" (written by the user; follow them):\n" + text
    }
}

/// The user's spaces and which conversation is filed in which. Foundation only; kept in `spaces.json`.
struct NookSpaceBook: Codable, Equatable, Sendable {
    var spaces: [NookSpace] = []
    /// Conversation id (UUID string) to space id.
    var membership: [String: UUID] = [:]

    mutating func save(_ space: NookSpace) {
        var space = space
        space.name = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !space.name.isEmpty else { return }
        if let index = spaces.firstIndex(where: { $0.id == space.id }) { spaces[index] = space } else { spaces.append(space) }
    }

    mutating func remove(_ id: UUID) {
        spaces.removeAll { $0.id == id }
        membership = membership.filter { $0.value != id }
    }

    /// Files a conversation in a space; nil (or a space that is gone) takes it out of any space.
    mutating func assign(conversation: UUID, to space: UUID?) {
        if let space, spaces.contains(where: { $0.id == space }) { membership[conversation.uuidString] = space }
        else { membership[conversation.uuidString] = nil }
    }

    func space(of conversation: UUID) -> NookSpace? {
        membership[conversation.uuidString].flatMap { id in spaces.first { $0.id == id } }
    }

    func conversations(in space: UUID) -> [UUID] {
        membership.filter { $0.value == space }.compactMap { UUID(uuidString: $0.key) }
    }

    static func load(_ url: URL) -> NookSpaceBook {
        guard let data = try? Data(contentsOf: url), let book = try? JSONDecoder().decode(NookSpaceBook.self, from: data) else { return NookSpaceBook() }
        return book
    }

    func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
