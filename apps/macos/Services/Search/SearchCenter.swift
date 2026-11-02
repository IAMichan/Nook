import Foundation
import Combine

/// Runs Search everything for the panel: builds the index off the main thread from what `AppModel+Search` collects,
/// then scores each query there too, so typing never waits on it. Session transcripts that are not in memory are read
/// from disk once and kept (by when the session last changed), so opening search again is instant. The index holds the
/// newest messages of each chat; after each query every chat app's whole history is searched too (`ChatSearchBridge`,
/// the same for every app), and what it finds joins the hits as it comes in.
@MainActor
final class SearchCenter: ObservableObject {
    static let shared = SearchCenter()

    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var query = SearchQuery()
    /// The text the hits are for.
    @Published private(set) var searched = ""
    /// The first index is being built, or transcripts from disk are being added to it.
    @Published private(set) var indexing = false
    /// The chat apps' history is being searched for the words in the field.
    @Published private(set) var searchingHistory = false
    @Published private(set) var recent: [String] = SearchCenter.loadRecent()

    private var index = SearchIndex([])
    private var text = ""
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var loadedAt: Date?
    /// The index's own hits for the text in the field, before what the chat apps' history found is added.
    private var indexHits: [SearchHit] = []
    /// What the chat apps' history found for `historyWords`, by document id.
    private var history: [String: SearchDocument] = [:]
    private var historyWords: [String] = []
    private var historyTask: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?
    /// The extra pause before the apps are asked: each search is a query to a database or a service.
    private static let historyPause: UInt64 = 250_000_000

    /// Session passages read from disk, by session, with the `updatedAt` they were read at.
    private static var transcripts: [UUID: (updated: Date, passages: [SearchPassage])] = [:]
    private static let recentKey = "nook.search.recent"
    private static let recentLimit = 8
    /// Most hits shown; the kind filter picks from these.
    static let limit = 200

    /// Collects every document and indexes them; the sessions' transcripts on disk follow in a second pass.
    func load(_ app: AppModel, force: Bool = false) {
        if let loadedAt, !force, !index.isEmpty, Date().timeIntervalSince(loadedAt) < 30 {
            return
        }
        indexTask?.cancel()
        if index.isEmpty {
            indexing = true
        }
        let transcripts = Self.transcripts.mapValues { $0.passages }
        indexTask = Task { [weak self] in
            let documents = app.searchDocuments(transcripts: transcripts)
            guard !Task.isCancelled else { return }
            let first = await Task.detached(priority: .userInitiated) { SearchIndex(documents) }.value
            guard let self, !Task.isCancelled else { return }
            self.index = first
            self.loadedAt = Date()
            if !self.text.isEmpty { self.rerun() }
            // The transcripts that are not in memory, read once and kept; a session that was deleted lets go of its own.
            let known = Set(app.workspace.runs.map(\.id))
            Self.transcripts = Self.transcripts.filter { known.contains($0.key) }
            let missing = app.workspace.runs.filter { run in Self.transcripts[run.id]?.updated != run.updatedAt && app.workspace.events[run.id] == nil }
            for run in missing {
                guard !Task.isCancelled else { return }
                let events = await app.workspace.timelineForSearch(run.id)
                Self.transcripts[run.id] = (run.updatedAt, AppModel.searchPassages(events, run: run))
            }
            guard !missing.isEmpty, !Task.isCancelled else { self.indexing = false; return }
            let full = app.searchDocuments(transcripts: Self.transcripts.mapValues { $0.passages })
            guard !Task.isCancelled else { return }
            let complete = await Task.detached(priority: .utility) { SearchIndex(full) }.value
            guard !Task.isCancelled else { return }
            self.index = complete
            self.loadedAt = Date()
            self.indexing = false
            if !self.text.isEmpty { self.rerun() }
        }
    }

    /// Prepares state when opening search panel.
    func prepareOpen(_ app: AppModel) {
        reset()
        load(app)
    }

    /// Resets the active search query and results without throwing away the index.
    func reset() {
        text = ""
        searchTask?.cancel()
        query = SearchQuery()
        hits = []
        searched = ""
        indexHits = []
        forgetHistory()
    }

    /// Cancels search typing debounce without interrupting indexing.
    func cancelSearch() {
        searchTask?.cancel()
    }

    /// What the field holds now: scored after a short pause, so a burst of keystrokes is one search.
    func search(_ text: String) {
        self.text = text
        searchTask?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reset()
            return
        }
        let pause: UInt64 = text.count <= 2 ? 30_000_000 : 110_000_000
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: pause)
            guard !Task.isCancelled else { return }
            self?.rerun()
        }
    }

    /// Return came before the typing pause was over: scores what is typed now instead of waiting for the pause.
    func searchNow() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, searched != text else { return }
        rerun()
    }

    private func rerun() {
        let text = text
        let parsed = SearchQuery.parse(text)
        let index = index
        let limit = Self.limit
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { index.search(parsed, limit: limit) }.value
            guard let self, !Task.isCancelled, self.text == text else { return }
            self.query = parsed
            self.indexHits = found
            self.searched = text
            self.searchHistory(parsed)
        }
    }

    // MARK: Every chat app's history

    /// Asks every chat app that can search its whole history (`ChatCaptureService.historySearchers`) for the query's
    /// words, all at once; each answer joins the hits when it comes. The same words again (a filter added, a typo
    /// fixed in another word) reuse what was found.
    private func searchHistory(_ parsed: SearchQuery) {
        let words = ChatHistorySearch.words(parsed)
        if words == historyWords {
            remerge()
            return
        }
        forgetHistory()
        hits = indexHits
        historyWords = words
        let searchers = words.isEmpty ? [] : ChatCaptureService.shared.historySearchers
        guard !searchers.isEmpty else { return }
        searchingHistory = true
        historyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.historyPause)
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: [BridgedChat].self) { group in
                for bridge in searchers {
                    group.addTask { @MainActor in
                        (try? await bridge.searchHistory(words, limit: ChatHistorySearch.limit)) ?? []
                    }
                }
                for await chats in group {
                    guard let self, !Task.isCancelled, self.historyWords == words else {
                        group.cancelAll()
                        return
                    }
                    self.addHistory(chats)
                }
            }
            guard let self, !Task.isCancelled, self.historyWords == words else { return }
            self.searchingHistory = false
        }
    }

    private func addHistory(_ chats: [BridgedChat]) {
        let found = AppModel.searchHistoryDocuments(chats)
        guard !found.isEmpty else { return }
        for document in found {
            guard var known = history[document.id] else {
                history[document.id] = document
                continue
            }
            known.passages = SearchMerge.passages(known.passages, adding: document.passages)
            history[document.id] = known
        }
        remerge()
    }

    /// The index's hits with what the history found, scored off the main thread.
    private func remerge() {
        mergeTask?.cancel()
        guard !history.isEmpty else {
            hits = indexHits
            return
        }
        let found = Array(history.values)
        let index = index
        let query = query
        let base = indexHits
        let limit = Self.limit
        mergeTask = Task { [weak self] in
            let merged = await Task.detached(priority: .userInitiated) {
                let documents = SearchMerge.documents(found, in: index)
                return SearchMerge.hits(base, adding: SearchIndex(documents).search(query, limit: limit), limit: limit)
            }.value
            guard let self, !Task.isCancelled, self.query == query else { return }
            self.hits = merged
        }
    }

    private func forgetHistory() {
        historyTask?.cancel()
        mergeTask?.cancel()
        history = [:]
        historyWords = []
        searchingHistory = false
    }

    func cancel() {
        searchTask?.cancel()
        indexTask?.cancel()
        forgetHistory()
    }

    // MARK: Recent searches

    /// Keeps a search you opened something from, newest first, without repeats.
    func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recent = Array(([trimmed] + recent.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }).prefix(Self.recentLimit))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    private static func loadRecent() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }
}
