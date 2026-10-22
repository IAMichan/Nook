import Foundation
import Combine

/// Runs Search everything for the panel: builds the index off the main thread from what `AppModel+Search` collects,
/// then scores each query there too, so typing never waits on it. Session transcripts that are not in memory are read
/// from disk once and kept (by when the session last changed), so opening search again is instant.
@MainActor
final class SearchCenter: ObservableObject {
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var query = SearchQuery()
    /// The text the hits are for.
    @Published private(set) var searched = ""
    /// The first index is being built, or transcripts from disk are being added to it.
    @Published private(set) var indexing = false
    @Published private(set) var recent: [String] = SearchCenter.loadRecent()

    private var index = SearchIndex([])
    private var text = ""
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    /// Session passages read from disk, by session, with the `updatedAt` they were read at.
    private static var transcripts: [UUID: (updated: Date, passages: [SearchPassage])] = [:]
    private static let recentKey = "nook.search.recent"
    private static let recentLimit = 8
    /// Most hits shown; the kind filter picks from these.
    static let limit = 200

    /// Collects every document and indexes them; the sessions' transcripts on disk follow in a second pass.
    func load(_ app: AppModel) {
        indexTask?.cancel()
        let documents = app.searchDocuments(transcripts: Self.transcripts.mapValues { $0.passages })
        indexing = true
        indexTask = Task { [weak self] in
            let first = await Task.detached(priority: .userInitiated) { SearchIndex(documents) }.value
            guard let self, !Task.isCancelled else { return }
            self.index = first
            self.rerun()
            // The transcripts that are not in memory, read once and kept.
            let missing = app.workspace.runs.filter { run in Self.transcripts[run.id]?.updated != run.updatedAt && app.workspace.events[run.id] == nil }
            for run in missing {
                guard !Task.isCancelled else { return }
                let events = await app.workspace.timelineForSearch(run.id)
                Self.transcripts[run.id] = (run.updatedAt, AppModel.searchPassages(events, run: run))
            }
            guard !missing.isEmpty, !Task.isCancelled else { self.indexing = false; return }
            let full = app.searchDocuments(transcripts: Self.transcripts.mapValues { $0.passages })
            let complete = await Task.detached(priority: .utility) { SearchIndex(full) }.value
            guard !Task.isCancelled else { return }
            self.index = complete
            self.indexing = false
            self.rerun()
        }
    }

    /// What the field holds now: scored after a short pause, so a burst of keystrokes is one search.
    func search(_ text: String) {
        self.text = text
        searchTask?.cancel()
        let pause: UInt64 = text.count <= 2 ? 30_000_000 : 110_000_000
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: pause)
            guard !Task.isCancelled else { return }
            self?.rerun()
        }
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
            self.hits = found
            self.searched = text
        }
    }

    func cancel() {
        searchTask?.cancel()
        indexTask?.cancel()
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
