import Foundation

// Unsent text per session and the prompt stash. Stored, so decoding is tolerant.

struct DraftEntry: Codable, Equatable, Sendable {
    var text: String
    var updatedAt: Date

    init(text: String, updatedAt: Date) { self.text = text; self.updatedAt = updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }
    enum CodingKeys: String, CodingKey { case text, updatedAt }
}

struct ComposerDrafts: Codable, Equatable, Sendable {
    static let maxSessions = 100
    static let maxBytes = 200 * 1024

    private(set) var drafts: [String: DraftEntry] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drafts = try c.decodeIfPresent([String: DraftEntry].self, forKey: .drafts) ?? [:]
    }
    enum CodingKeys: String, CodingKey { case drafts }

    func draft(for sessionID: String) -> String? { drafts[sessionID]?.text }

    /// An empty (or blank) text removes the draft: nothing worth bringing back.
    mutating func save(sessionID: String, text: String, now: Date) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { drafts[sessionID] = nil; return }
        drafts[sessionID] = DraftEntry(text: Self.cap(text), updatedAt: now)
        while drafts.count > Self.maxSessions {
            guard let oldest = drafts.min(by: { ($0.value.updatedAt, $0.key) < ($1.value.updatedAt, $1.key) }) else { break }
            drafts[oldest.key] = nil
        }
    }

    mutating func clear(sessionID: String) { drafts[sessionID] = nil }

    mutating func pruneUnused(keeping ids: Set<String>) { drafts = drafts.filter { ids.contains($0.key) } }

    /// Cut on a character boundary so the text stays valid.
    private static func cap(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var n = maxBytes
        while n > 0 {
            if let s = String(text.utf8.prefix(n)) { return s }
            n -= 1
        }
        return ""
    }
}

struct PromptStash: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var text: String
        var title: String { Self.title(of: text) }
        static func title(of text: String) -> String {
            let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            return String(first.trimmingCharacters(in: .whitespaces).prefix(40))
        }
        enum CodingKeys: String, CodingKey { case text }
    }

    static let limit = 10
    /// Oldest first; the last entry is the top of the stack.
    private(set) var entries: [Entry] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = Array((try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []).suffix(Self.limit))
    }
    enum CodingKeys: String, CodingKey { case entries }

    /// Empty text and an exact copy of the top are ignored. Returns whether it was stored.
    @discardableResult
    mutating func push(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entries.last?.text != text else { return false }
        entries.append(Entry(text: text))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        return true
    }

    mutating func pop() -> String? { entries.popLast()?.text }

    mutating func restore(at index: Int) -> String? {
        guard entries.indices.contains(index) else { return nil }
        return entries.remove(at: index).text
    }

    mutating func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }
}

/// Mod+S: text in the box goes to the stash; an empty box restores one entry, or opens the menu when there are several.
enum StashAction: Equatable, Sendable {
    case stash, restoreOnly, openMenu, nothing

    static func decide(composerText: String, stashCount: Int) -> StashAction {
        if !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .stash }
        switch stashCount {
        case ..<1: return .nothing
        case 1: return .restoreOnly
        default: return .openMenu
        }
    }
}
