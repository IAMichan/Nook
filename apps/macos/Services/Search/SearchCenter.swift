import Foundation
import Combine

/// Runs Search everything for the panel: builds the index off the main thread from what `AppModel+Search` collects,
/// then scores each query there too, so typing never waits on it. Session transcripts that are not in memory are read
/// from disk once and kept (by when the session last changed), so opening search again is instant. The same goes for
/// every coding agent's own transcript files: the sessions Nook follows and every earlier (settled) one. The index holds the
/// newest messages of each chat; after each query every chat app's whole history is searched too (`ChatSearchBridge`,
/// the same for every app), and what it finds joins the hits as it comes in.
///
/// All of this is built when search opens and let go a while after it closes, never at launch: it reads every session and
/// transcript on disk and holds their text, which is a lot to spend on a panel that may stay closed all day.
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
    /// What you opened from search lately, newest first, as the index has it now: shown before you type.
    @Published private(set) var recentlyOpened: [SearchHit] = []
    /// Search with AI for the text in the field: what it is doing, its answer and the hits it read.
    @Published private(set) var ai: AIAnswer?

    private var index = SearchIndex([])
    private var text = ""
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    /// Search panels on screen: the notch and the main window each have their own, and share this index.
    private var openPanels = 0
    private var loadedAt: Date?
    /// The index's own hits for the text in the field, before what the chat apps' history found is added.
    private var indexHits: [SearchHit] = []
    /// What the chat apps' history found for `historyWords`, by document id.
    private var history: [String: SearchDocument] = [:]
    private var historyWords: [String] = []
    private var historyTask: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    /// What you opened from search: by document id, how often and when last. Ranks those higher next time.
    private var openedLog: [String: Opened] = SearchCenter.loadOpened()
    /// The extra pause before the apps are asked: each search is a query to a database or a service.
    private static let historyPause: UInt64 = 250_000_000

    /// Session passages read from disk, by session, with the `updatedAt` they were read at.
    private static var transcripts: [UUID: (updated: Date, passages: [SearchPassage])] = [:]
    /// Passages of the agents' own transcript files, by path, with the file's modification date they were read at.
    private static var agentTranscripts: [String: (modified: Date, passages: [SearchPassage])] = [:]
    /// How many transcript files are read before the index is built again with them: results fill in as they are read.
    private static let transcriptBatch = 150
    /// How long the index stays after the panel closed, for opening search again at once.
    private static let keepFor: UInt64 = 600_000_000_000
    private static let recentKey = "nook.search.recent"
    private static let recentLimit = 8
    /// Most hits shown; the kind filter picks from these.
    static let limit = 200

    /// Collects every document and indexes them; the sessions' transcripts on disk follow in a second pass.
    func load(_ app: AppModel, force: Bool = false) {
        releaseTask?.cancel()
        if let loadedAt, !force, !index.isEmpty, Date().timeIntervalSince(loadedAt) < 30 {
            return
        }
        // The list of earlier sessions refreshes every few minutes while nobody looks: search is someone looking. What it
        // finds is in the next load.
        app.history.refresh(showsProgress: false)
        indexTask?.cancel()
        if index.isEmpty {
            indexing = true
        }
        indexTask = Task { [weak self] in
            guard let self else { return }
            let documents = await self.documents(app, priority: .userInitiated)
            guard !Task.isCancelled else { return }
            let previous = self.index.isEmpty ? nil : self.index
            let first = await Task.detached(priority: .userInitiated) { SearchIndex(documents, reusing: previous) }.value
            guard !Task.isCancelled else { return }
            self.index = first
            self.refreshRecentlyOpened()
            self.loadedAt = Date()
            if !self.text.isEmpty { self.rerun() }
            // The transcripts that are not in memory, read once and kept; a session that was deleted lets go of its own.
            let known = Set(app.workspace.runs.map(\.id))
            Self.transcripts = Self.transcripts.filter { known.contains($0.key) }
            let missing = app.workspace.runs.filter { run in Self.transcripts[run.id]?.updated != run.updatedAt && app.workspace.events[run.id] == nil }
            for run in missing {
                guard !Task.isCancelled else { return }
                let events = await app.workspace.timelineForSearch(run.id)
                // Off the main thread: a long session's timeline held it up once for every session after launch.
                let passages = await Task.detached(priority: .utility) { AppModel.searchPassages(events, run: run) }.value
                Self.transcripts[run.id] = (run.updatedAt, passages)
            }
            guard !Task.isCancelled else { return }
            if !missing.isEmpty { guard await self.rebuild(app) else { return } }

            // Every coding agent's own transcripts (earlier and settled sessions, and the ones Nook follows), newest
            // first; a file that did not change since it was read is not read again.
            let files = app.searchTranscriptFiles()
            let paths = Set(files.map(\.path))
            Self.agentTranscripts = Self.agentTranscripts.filter { paths.contains($0.key) }
            let read = Self.agentTranscripts.mapValues(\.modified)
            for start in stride(from: 0, to: files.count, by: Self.transcriptBatch) {
                let batch = Array(files[start..<min(start + Self.transcriptBatch, files.count)])
                let found = await Task.detached(priority: .utility) { Self.readTranscripts(batch, known: read) }.value
                guard !Task.isCancelled else { return }
                for file in found { Self.agentTranscripts[file.path] = (file.modified, file.passages) }
                if !found.isEmpty { guard await self.rebuild(app) else { return } }
            }
            self.indexing = false
        }
    }

    /// Everything to index. The sessions in memory go through the text of their whole timeline, and that happens off the
    /// main thread; the rest is quick to gather.
    private func documents(_ app: AppModel, priority: TaskPriority) async -> [SearchDocument] {
        let runs = app.workspace.runs
        let timelines = app.workspace.events
        let live = await Task.detached(priority: priority) {
            var passages: [UUID: [SearchPassage]] = [:]
            for run in runs {
                if let events = timelines[run.id] { passages[run.id] = AppModel.searchPassages(events, run: run) }
            }
            return passages
        }.value
        return app.searchDocuments(transcripts: Self.transcripts.mapValues { $0.passages }.merging(live) { _, new in new },
                                   agentTranscripts: Self.agentTranscripts.mapValues { $0.passages })
    }

    /// The index again with every transcript read so far; false when the load was cancelled meanwhile.
    private func rebuild(_ app: AppModel) async -> Bool {
        let full = await documents(app, priority: .utility)
        guard !Task.isCancelled else { return false }
        // The documents whose text did not change keep their folded words: most of them, after a batch of transcripts.
        let previous = index
        let complete = await Task.detached(priority: .utility) { SearchIndex(full, reusing: previous) }.value
        guard !Task.isCancelled else { return false }
        index = complete
        refreshRecentlyOpened()
        loadedAt = Date()
        if !text.isEmpty { rerun() }
        return true
    }

    /// The transcript files that changed since they were read (`known`), read without filling the transcript cache the
    /// views use.
    private nonisolated static func readTranscripts(_ files: [(path: String, agent: String)], known: [String: Date])
        -> [(path: String, modified: Date, passages: [SearchPassage])] {
        files.compactMap { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            guard let modified = attributes?[.modificationDate] as? Date, known[file.path] != modified else { return nil }
            let messages = AgentTranscript.recent(path: file.path, remember: false)
            return (file.path, modified, AppModel.searchPassages(messages, agent: file.agent))
        }
    }

    /// Resets the active search query and results without throwing away the index.
    func reset() {
        text = ""
        stopAI()
        searchTask?.cancel()
        query = SearchQuery()
        hits = []
        searched = ""
        indexHits = []
        forgetHistory()
    }

    func panelOpened() {
        openPanels += 1
        releaseTask?.cancel()
    }

    /// A panel closed. Cancels search typing debounce without interrupting indexing; with no panel left, lets go of the
    /// index after a while unless search opens again.
    func cancelSearch() {
        searchTask?.cancel()
        openPanels = max(0, openPanels - 1)
        guard openPanels == 0 else { return }
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.keepFor)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    private func release() {
        cancel()
        reset()
        recentlyOpened = []
        index = SearchIndex([])
        loadedAt = nil
        indexing = false
        Self.transcripts = [:]
        Self.agentTranscripts = [:]
    }

    /// What the field holds now: scored after a short pause, so a burst of keystrokes is one search.
    func search(_ text: String) {
        self.text = text
        searchTask?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reset()
            return
        }
        // Scoring takes milliseconds now: the pause only folds a burst of keystrokes into one search.
        let pause: UInt64 = text.count <= 2 ? 15_000_000 : 50_000_000
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
        let bonus = openedBonus()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { index.search(parsed, limit: limit, bonus: bonus) }.value
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
        let bonus = openedBonus()
        mergeTask = Task { [weak self] in
            let merged = await Task.detached(priority: .userInitiated) {
                let documents = SearchMerge.documents(found, in: index)
                return SearchMerge.hits(base, adding: SearchIndex(documents).search(query, limit: limit, bonus: bonus), limit: limit)
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
        aiTask?.cancel()
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

// MARK: - What you opened

extension SearchCenter {
    struct Opened: Codable, Equatable {
        var count: Int
        var last: Date
    }

    private static let openedKey = "nook.search.opened"
    private static let openedLimit = 200
    private static let recentlyOpenedShown = 5

    /// A hit was opened: next time it ranks a little higher, and it is first among what you opened before you type.
    func opened(_ hit: SearchHit) {
        let id = hit.document.id
        // Actions run again by their name; they need no help to be found.
        guard hit.document.kind != .action else { return }
        var entry = openedLog[id] ?? Opened(count: 0, last: Date())
        entry.count += 1
        entry.last = Date()
        openedLog[id] = entry
        if openedLog.count > Self.openedLimit {
            let kept = openedLog.sorted { $0.value.last > $1.value.last }.prefix(Self.openedLimit)
            openedLog = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(openedLog) { UserDefaults.standard.set(data, forKey: Self.openedKey) }
        refreshRecentlyOpened()
    }

    /// Added to a document's score: more for what you open often and lately, fading over a month.
    func openedBonus(now: Date = Date()) -> [String: Double] {
        openedLog.mapValues { entry in
            let days = max(0, now.timeIntervalSince(entry.last) / 86_400)
            return min(1.5, 0.6 * log2(1 + Double(entry.count))) * exp(-days / 30)
        }
    }

    func refreshRecentlyOpened() {
        recentlyOpened = openedLog.sorted { $0.value.last > $1.value.last }
            .lazy.compactMap { [index] item in index.document(item.key) }
            .prefix(Self.recentlyOpenedShown)
            .map { SearchHit(document: $0, score: 0, titleRanges: [], snippet: "", snippetRanges: [], passage: nil, matches: 0) }
    }

    static func loadOpened() -> [String: Opened] {
        guard let data = UserDefaults.standard.data(forKey: openedKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Opened].self, from: data)) ?? [:]
    }
}

// MARK: - Search with AI

extension SearchCenter {
    struct AIAnswer: Equatable {
        enum Phase: Equatable {
            /// The brain is working out what to search for.
            case planning
            /// The searches ran; the brain reads this many hits.
            case reading(Int)
            case answered
            /// No brain is chosen: the hits of the question's own words, without an answer.
            case noBrain
            /// The brain gave no answer in time.
            case failed
        }

        var question: String
        var phase: Phase
        var answer = ""
        /// What the brain read, numbered from 1 as the answer cites them.
        var sources: [SearchHit] = []
        /// The source numbers the answer cites, in the order it names them.
        var cited: [Int] = []

        var isWorking: Bool {
            switch phase {
            case .planning, .reading: return true
            case .answered, .noBrain, .failed: return false
            }
        }
    }

    /// Asks the chosen brain about the question, over everything search can find: it writes the searches, Nook runs them
    /// on its own index, and the brain answers from what they found, citing it.
    func askAI(_ question: String, brain: BrainService, settings: AppSettings) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        aiTask?.cancel()
        ai = AIAnswer(question: question, phase: .planning)
        aiTask = Task { [weak self] in
            guard let self else { return }
            let ready = settings.brainReady
            // The searches: the brain's, and always the question's own words, so there is something to read when the
            // brain's plan is late or poor.
            var searches = [SearchAI.keywordQuery(question)]
            if ready, let reply = await brain.rewrite(system: SearchAI.planSystem,
                                                      prompt: SearchAI.planPrompt(question: question, today: Date()), timeout: 15) {
                searches = SearchAI.queries(fromPlan: SearchAI.clean(reply)) + searches
            }
            guard !Task.isCancelled, self.ai?.question == question else { return }
            let index = self.index
            let bonus = self.openedBonus()
            let lists = searches.filter { !$0.isEmpty }
            let sources = await Task.detached(priority: .userInitiated) {
                SearchAI.gather(lists.map { index.search(SearchQuery.parse($0), limit: SearchAI.hitsPerQuery, bonus: bonus) })
            }.value
            guard !Task.isCancelled, self.ai?.question == question else { return }
            guard ready else {
                self.ai = AIAnswer(question: question, phase: .noBrain, sources: sources)
                return
            }
            guard !sources.isEmpty else {
                self.ai = AIAnswer(question: question, phase: .answered, answer: tr("search.ai.nothing"))
                return
            }
            self.ai = AIAnswer(question: question, phase: .reading(sources.count), sources: sources)
            let prompt = SearchAI.answerPrompt(question: question, sources: sources,
                                               language: settings.languageInstruction(for: question), shield: { settings.shielded($0) })
            let reply = await brain.rewrite(system: SearchAI.answerSystem, prompt: prompt, timeout: 60)
            guard !Task.isCancelled, self.ai?.question == question else { return }
            guard let reply, !SearchAI.clean(reply).isEmpty else {
                self.ai = AIAnswer(question: question, phase: .failed, sources: sources)
                return
            }
            let answer = SearchAI.clean(reply)
            self.ai = AIAnswer(question: question, phase: .answered, answer: answer, sources: sources,
                               cited: SearchAI.citations(in: answer, count: sources.count))
        }
    }

    /// Back to the plain results: the field changed, or the panel closed.
    func stopAI() {
        aiTask?.cancel()
        aiTask = nil
        if ai != nil { ai = nil }
    }
}
