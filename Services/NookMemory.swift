import Foundation

/// Nook's memory as the app uses it: the `MemoryBook` and what Nook learned about its sources, kept in `nook.sqlite`.
/// Every change is written right away, row by row, so nothing learned is lost when Nook quits.
@MainActor
final class NookMemory: ObservableObject {
    @Published private(set) var book = MemoryBook()
    private(set) var affinity = SourceAffinity()
    private let store: NookStore

    /// Per conversation: how many of the user's messages the last reflection covered, and which reflections run now.
    private var reflected: [UUID: Int] = [:]
    private var reflecting: Set<UUID> = []

    init(store: NookStore) {
        self.store = store
        book.items = store.memories()
        if let data = store.memoryState("affinity"), let decoded = try? JSONDecoder().decode(SourceAffinity.self, from: data) {
            affinity = decoded
        }
        update { $0.prune() }
    }

    var items: [MemoryItem] { book.items }

    /// Applies a change to the book and stores exactly the rows that changed.
    @discardableResult
    private func update<T>(_ change: (inout MemoryBook) -> T) -> T {
        let before = Dictionary(book.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = book
        let result = change(&next)
        let after = Dictionary(next.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, item) in after where before[id] != item { store.saveMemory(item) }
        for id in before.keys where after[id] == nil { store.deleteMemory(id: id) }
        book = next
        return result
    }

    // MARK: Remembering and forgetting

    @discardableResult
    func remember(_ text: String, kind: MemoryItem.Kind, subject: String = "", origin: MemoryItem.Origin,
                  replaces: String? = nil, localOnly: Bool = false) -> MemoryBook.Change {
        update { $0.remember(text, kind: kind, subject: subject, origin: origin, replaces: replaces, localOnly: localOnly) }
    }

    @discardableResult
    func forget(_ query: String) -> [MemoryItem] {
        update { $0.forget(query) }
    }

    /// The user rewrote a memory in Settings: it is theirs now, and does not fade.
    func edit(_ id: String, text: String) {
        let cleaned = MemoryText.clean(text)
        guard !cleaned.isEmpty, MemoryText.problem(cleaned) == nil else { return }
        update { book in
            guard let index = book.items.firstIndex(where: { $0.id == id }) else { return }
            book.items[index].text = cleaned
            book.items[index].origin = .told
            book.items[index].strength = max(book.items[index].strength, MemoryBook.initialStrength(.told))
            book.items[index].updated = Date()
            if book.items[index].isHabit {
                book.items[index].tool = nil
                book.items[index].field = nil
                book.items[index].value = nil
            }
        }
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        update { book in
            guard let index = book.items.firstIndex(where: { $0.id == id }) else { return }
            book.items[index].pinned = pinned
            if pinned { book.items[index].strength = max(book.items[index].strength, 0.9) }
        }
    }

    func setLocalOnly(_ id: String, _ localOnly: Bool) {
        update { book in
            guard let index = book.items.firstIndex(where: { $0.id == id }) else { return }
            book.items[index].localOnly = localOnly
        }
    }

    func delete(_ id: String) {
        update { book in book.items.removeAll { $0.id == id } }
    }

    /// Forgets everything, including what Nook learned about its sources.
    func clear() {
        store.clearMemories()
        book = MemoryBook()
        affinity = SourceAffinity()
        reflected = [:]
    }

    // MARK: Recall

    /// The memories for a question, marked as used (used memories keep their strength).
    func recall(_ question: String, tools: Set<String>, limit: Int, characters: Int, includeLocalOnly: Bool) -> [MemoryItem] {
        let found = book.recall(question, tools: tools, limit: limit, characters: characters, includeLocalOnly: includeLocalOnly)
        if !found.isEmpty { update { $0.markUsed(Set(found.map(\.id))) } }
        return found
    }

    // MARK: Learning from plans

    func observeEdit(tool: String, field: String, from old: String, to new: String) {
        update { $0.observeEdit(tool: tool, field: field, from: old, to: new) }
    }

    func observeOutcome(tool: String, input: [String: Any], failure: String?) {
        update { book in
            if let failure {
                book.observeFailure(tool: tool, error: failure)
            } else {
                book.observeSuccess(tool: tool)
                book.observeAccepted(tool: tool, input: input)
            }
        }
    }

    func applyHabits(tool: String, input: [String: Any], schema: [String: Any]) -> (input: [String: Any], filled: [(field: String, value: String)]) {
        book.applyHabits(tool: tool, input: input, schema: schema)
    }

    // MARK: Learning which sources answer what

    func learnSources(terms: [String], useful: Set<String>, empty: Set<String>) {
        guard !terms.isEmpty, !useful.isEmpty || !empty.isEmpty else { return }
        for source in useful { affinity.reward(terms: terms, source: source) }
        for source in empty.subtracting(useful) { affinity.penalize(terms: terms, source: source) }
        if let data = try? JSONEncoder().encode(affinity) { store.setMemoryState("affinity", data) }
    }

    func suggestSources(terms: [String], among allowed: Set<String>) -> [String] {
        affinity.suggest(terms: terms, among: allowed)
    }

    /// How many words Nook connected to a source (shown in Settings).
    var learnedWords: Int { affinity.scores.count }

    // MARK: Reflection bookkeeping

    /// Whether to reflect on a conversation now: right after a correction or something the user shares about
    /// themselves, otherwise once every four questions. Never twice at the same time for one conversation.
    func shouldReflect(conversation: UUID, userMessages: Int, latest: String) -> Bool {
        guard !reflecting.contains(conversation) else { return false }
        let done = reflected[conversation] ?? 0
        guard userMessages > done else { return false }
        return Reflection.isCorrection(latest) || Reflection.sharesSomething(latest) || userMessages - done >= 4
    }

    func beginReflection(_ conversation: UUID) { reflecting.insert(conversation) }

    func endReflection(_ conversation: UUID, covered: Int) {
        reflecting.remove(conversation)
        reflected[conversation] = covered
    }

    // MARK: Importing the MCP memory server

    /// Knowledge graphs of the MCP memory server found on this Mac, with how many memories each holds.
    func importable() -> [(url: URL, count: Int)] {
        MemoryImport.candidateFiles().compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let count = MemoryImport.parseKnowledgeGraph(text).count
            return count > 0 ? (url, count) : nil
        }
    }

    /// Reads a knowledge graph into memory. Returns how many memories were added (repeats strengthen, not add).
    @discardableResult
    func importGraph(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let entries = MemoryImport.parseKnowledgeGraph(text)
        return update { book in
            var added = 0
            for entry in entries {
                if case .added = book.remember(entry.text, kind: .fact, subject: entry.subject, origin: .imported) { added += 1 }
            }
            return added
        }
    }
}
