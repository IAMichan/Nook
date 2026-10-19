import Foundation

/// A message waiting for the agent to finish its turn.
struct QueuedMessage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var text: String
    var createdAt: Date
    var edited: Bool

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), edited: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.edited = edited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }
}

/// The per-session queue of follow-up messages (reorder / cancel / edit, promote-to-steer,
/// resume, held state). It is *held* after a failure, a stop or a restart so nothing is sent on top of a
/// problem; the user resumes it explicitly.
struct MessageQueue: Codable, Equatable, Sendable {
    static let limit = 50

    private(set) var messages: [QueuedMessage] = []
    private(set) var isHeld = false

    /// Edit in progress; never stored, a restart simply drops it.
    struct EditSession: Equatable, Sendable {
        var messageID: UUID
        /// What the composer held before the edit started, restored afterwards.
        var previousDraft: String
    }
    private(set) var editSession: EditSession?

    private enum CodingKeys: String, CodingKey { case messages, isHeld }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([QueuedMessage].self, forKey: .messages) ?? []
        isHeld = try c.decodeIfPresent(Bool.self, forKey: .isHeld) ?? false
        if messages.count > Self.limit { messages = Array(messages.prefix(Self.limit)) }
    }

    var count: Int { messages.count }
    var isEmpty: Bool { messages.isEmpty }

    // MARK: Changing the queue

    /// Returns the new message, or nil when the text is empty or the queue is full.
    @discardableResult
    mutating func enqueue(_ text: String, now: Date = Date(), id: UUID = UUID()) -> QueuedMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, messages.count < Self.limit else { return nil }
        let message = QueuedMessage(id: id, text: trimmed, createdAt: now)
        messages.append(message)
        return message
    }

    /// An empty text is refused (the user removes a message with `remove`).
    @discardableResult
    mutating func edit(_ id: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        guard messages[index].text != trimmed else { return true }
        messages[index].text = trimmed
        messages[index].edited = true
        return true
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages.remove(at: index)
        if editSession?.messageID == id { editSession = nil }
        return true
    }

    /// `toIndex` is clamped to the queue, so a drag past either end lands at the end.
    @discardableResult
    mutating func move(_ id: UUID, toIndex: Int) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        let target = min(max(toIndex, 0), messages.count - 1)
        guard target != index else { return true }
        messages.insert(messages.remove(at: index), at: target)
        return true
    }

    /// Takes the message out to send it into the running turn now; a second call finds nothing.
    mutating func promoteToSteer(_ id: UUID) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        if editSession?.messageID == id { editSession = nil }
        return messages.remove(at: index).text
    }

    /// Puts a message that could not go out back at the front. It was shown already, so the limit does not apply:
    /// it waits instead of getting lost.
    mutating func requeueFirst(_ text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.insert(QueuedMessage(text: trimmed, createdAt: now), at: 0)
    }

    mutating func clear() {
        messages.removeAll()
        editSession = nil
    }

    // MARK: Sending

    /// The next message to send, or nil when the queue is held or empty. The message being edited stays put.
    mutating func next(held: Bool = false) -> QueuedMessage? {
        guard !held, !isHeld else { return nil }
        guard let index = messages.firstIndex(where: { $0.id != editSession?.messageID }) else { return nil }
        return messages.remove(at: index)
    }

    mutating func hold() { isHeld = true }
    mutating func resume() { isHeld = false }

    // MARK: Editing a queued message in the composer

    /// Returns the text to show in the composer. A second `beginEdit` keeps the first draft, so the user's own
    /// text is never replaced by another queued message's text.
    mutating func beginEdit(_ id: UUID, currentDraft: String) -> String? {
        guard let message = messages.first(where: { $0.id == id }) else { return nil }
        editSession = EditSession(messageID: id, previousDraft: editSession?.previousDraft ?? currentDraft)
        return message.text
    }

    /// Ends the edit and returns the draft to put back in the composer ("Your previous draft is restored").
    /// With `save` the message takes `text`; a message that left the queue meanwhile is not brought back.
    @discardableResult
    mutating func endEdit(save: Bool, text: String = "") -> String? {
        guard let session = editSession else { return nil }
        editSession = nil
        if save { edit(session.messageID, text: text) }
        return session.previousDraft
    }
}
