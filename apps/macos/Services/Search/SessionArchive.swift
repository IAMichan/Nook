import Foundation
import SQLite3

/// The text of every coding agent session for Search everything, on disk (`session-search.sqlite`): the sessions Nook
/// runs and every earlier session of Claude Code, Codex, Gemini CLI and the other agents whose transcripts Nook reads.
/// Search everything keeps only a light description of each session in memory (title, project, branch, prompts) and asks
/// this for the rest, so a word said anywhere in any settled session is found without reading thousands of transcripts
/// into memory first. Built searches its threads and Nook's own chat archive (`ChatStore`) does:
///
/// - **One row per session**, its passages (what you asked, what the agent said, the steps it took; thinking stays out)
///   as compact JSON, LZFSE-compressed: what a hit shows and what its exact match is checked against.
/// - **A contentless trigram index without positions** (`session_search`, `detail = none`): which sessions hold every
///   trigram of a word, a fraction of the size of the text. A word is asked for as all its trigrams (`TrigramQuery`),
///   and the few sessions that hold them apart are dropped by the search over their passages.
/// - **Kept up to date by stamp**: a session is read again only when its transcript changed (a file's date and size, a
///   session's last update), and one that is gone is removed.
/// - **Incremental vacuum** and a bounded write-ahead log keep the file as small as what it holds.
///
/// Thread-safe: one connection behind a lock, used off the main thread.
final class SessionArchive: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// The trigram index can be used (FTS5 with its trigram tokenizer is there); without it nothing is found here.
    private(set) var searchAvailable = false
    private var setupFailure: Int32 = SQLITE_OK

    static var defaultURL: URL { NookPaths.supportDirectory.appendingPathComponent("session-search.sqlite") }

    private static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS session (
            id INTEGER PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            stamp REAL NOT NULL,
            at REAL NOT NULL,
            passages BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS session_at ON session (at);
        """,
    ]

    /// Opens (or creates) the archive. A damaged file is moved aside and a fresh one made (`SQLiteRecovery`): everything in
    /// it can be read again from the transcripts. Nil when there is no file to use this launch.
    init?(url: URL = SessionArchive.defaultURL, incidents: DatabaseIncidents = .shared) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        db = SQLiteRecovery.open(url, flags: flags, incidents: incidents) { handle in
            db = handle
            setupFailure = SQLITE_OK
            sqlite3_busy_timeout(handle, 5_000)
            exec("PRAGMA temp_store = MEMORY;")
            exec("PRAGMA cache_size = -2000;")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Before the first table, or it has no effect: freed pages can be given back to the disk a few at a time.
            exec("PRAGMA auto_vacuum = INCREMENTAL;")
            exec("PRAGMA journal_mode = WAL;")
            exec("PRAGMA synchronous = NORMAL;")
            exec("PRAGMA journal_size_limit = 8388608;")
            guard migrate() else { return setupFailure == SQLITE_OK ? SQLITE_ERROR : setupFailure }
            return SQLITE_OK
        }
        guard db != nil else { return nil }
        // Contentless needs SQLite 3.43 (`contentless_delete`); an older one keeps a copy of the text in the index.
        searchAvailable = exec(Self.searchSchema(contentless: true)) || exec(Self.searchSchema(contentless: false))
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    private static func searchSchema(contentless: Bool) -> String {
        "CREATE VIRTUAL TABLE IF NOT EXISTS session_search USING fts5(body, tokenize = 'trigram', detail = none"
            + (contentless ? ", content = '', contentless_delete = 1" : "") + ");"
    }

    private func migrate() -> Bool {
        let version = Int(scalar("PRAGMA user_version") ?? 0)
        for (index, sql) in Self.migrations.enumerated() where index >= version {
            guard transaction({ exec(sql) && exec("PRAGMA user_version = \(index + 1);") }) else { return false }
        }
        return true
    }

    // MARK: Writing

    /// Each session's stamp as written: what tells a sync which ones changed.
    func stamps() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = prepared("SELECT key, stamp FROM session") else { return [:] }
        defer { sqlite3_reset(stmt) }
        var out: [String: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let key = text(stmt, 0) { out[key] = sqlite3_column_double(stmt, 1) }
        }
        return out
    }

    /// Writes a session's passages over what it held, with its stamp and date (the newest thing in it).
    @discardableResult
    func save(_ key: String, stamp: Double, date: Date, passages: [SearchPassage]) -> Bool {
        let blob = Self.pack(passages)
        let body = passages.map { SearchText.fold($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
        lock.lock()
        defer { lock.unlock() }
        return transaction {
            let existing = rowID(key)
            if let existing, searchAvailable, !execute("DELETE FROM session_search WHERE rowid = ?", [existing]) { return false }
            let sql = """
                INSERT INTO session (key, stamp, at, passages) VALUES (?, ?, ?, ?)
                ON CONFLICT (key) DO UPDATE SET stamp = excluded.stamp, at = excluded.at, passages = excluded.passages
                RETURNING id
                """
            guard let stmt = prepared(sql) else { return false }
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            sqlite3_bind_double(stmt, 2, stamp)
            sqlite3_bind_double(stmt, 3, date.timeIntervalSinceReferenceDate)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), transient) }
            let step = sqlite3_step(stmt)
            let id = step == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
            sqlite3_reset(stmt)
            guard let id else { return false }
            guard searchAvailable, !body.isEmpty else { return true }
            return execute("INSERT INTO session_search (rowid, body) VALUES (?, ?)", [id, body])
        }
    }

    /// Forgets sessions that are gone (a deleted session, a transcript that was removed).
    func remove(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        _ = transaction {
            for key in keys {
                guard let id = rowID(key) else { continue }
                if searchAvailable, !execute("DELETE FROM session_search WHERE rowid = ?", [id]) { return false }
                if !execute("DELETE FROM session WHERE id = ?", [id]) { return false }
            }
            return true
        }
    }

    // MARK: Searching

    /// The sessions that may hold what `query` asks for, newest first, at most `limit`: every one that does (for the
    /// words of three characters or more; typos and shorter words are left to the search over their passages) and a few
    /// that hold a word's trigrams apart. Nil when this cannot narrow the search: no index, or no such word.
    func candidates(_ query: SearchQuery, limit: Int) -> [String]? {
        guard let expression = TrigramQuery.expression(query) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard searchAvailable else { return nil }
        let sql = """
            SELECT s.key FROM session_search f JOIN session s ON s.id = f.rowid
            WHERE session_search MATCH ? ORDER BY s.at DESC LIMIT ?
            """
        guard let stmt = prepared(sql) else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, expression, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var keys: [String] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let key = text(stmt, 0) { keys.append(key) }
            step = sqlite3_step(stmt)
        }
        return step == SQLITE_DONE ? keys : nil
    }

    /// The passages of these sessions, only those that hold a word of `query` (`SearchArchiveFilter`): what a hit can match
    /// and show, without building a search over every line of a long session.
    func passages(_ keys: [String], for query: SearchQuery) -> [String: [SearchPassage]] {
        let wanted = SearchArchiveFilter(query)
        var blobs: [(String, Data)] = []
        lock.lock()
        if let stmt = prepared("SELECT passages FROM session WHERE key = ?") {
            for key in keys {
                sqlite3_bind_text(stmt, 1, key, -1, transient)
                if sqlite3_step(stmt) == SQLITE_ROW, let data = blob(stmt, 0) { blobs.append((key, data)) }
                sqlite3_reset(stmt)
            }
        }
        lock.unlock()
        var out: [String: [SearchPassage]] = [:]
        for (key, data) in blobs {
            let kept = Self.unpack(data).filter(wanted.keeps)
            if !kept.isEmpty { out[key] = kept }
        }
        return out
    }

    /// The sessions that hold what `query` asks for, newest first, with their passages that do (`passages(_:for:)`): at
    /// most `want` of them, checked in batches along the index's candidates, so a word whose trigrams many sessions hold
    /// apart does not crowd out an older session that holds the word itself. `keeps` leaves out sessions the caller does
    /// not know. Nil when the index cannot narrow the search.
    func found(_ query: SearchQuery, want: Int, budget: Int = 5_000, batch: Int = 100,
               keeps: (String) -> Bool = { _ in true }) -> [(key: String, passages: [SearchPassage])]? {
        guard let keys = candidates(query, limit: budget) else { return nil }
        let known = keys.filter(keeps)
        var out: [(key: String, passages: [SearchPassage])] = []
        var start = 0
        while out.count < want, start < known.count {
            let slice = Array(known[start..<min(start + batch, known.count)])
            let passages = self.passages(slice, for: query)
            for key in slice where out.count < want {
                if let kept = passages[key] { out.append((key, kept)) }
            }
            start += batch
        }
        return out
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(scalar("SELECT COUNT(*) FROM session") ?? 0)
    }

    // MARK: Upkeep

    /// After a sync: gives free pages back to the disk once they are a tenth of the file, and merges the index's segments
    /// a little.
    func maintain() {
        lock.lock()
        defer { lock.unlock() }
        if let free = scalar("PRAGMA freelist_count"), let pages = scalar("PRAGMA page_count"), pages > 0, free * 10 > pages {
            exec("PRAGMA incremental_vacuum;")
        }
        if searchAvailable { exec("INSERT INTO session_search (session_search, rank) VALUES ('merge', 64);") }
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: Passages as stored

    /// Short keys: they are in every passage of every session.
    private struct Stored: Codable {
        var t: String
        var a: String?
        var d: Double?
        var n: String?
    }

    static func pack(_ passages: [SearchPassage]) -> Data {
        let stored = passages.map { passage in
            Stored(t: passage.text, a: passage.author.isEmpty ? nil : passage.author,
                   d: passage.date?.timeIntervalSinceReferenceDate, n: passage.anchor)
        }
        let json = (try? JSONEncoder().encode(stored)) ?? Data("[]".utf8)
        return ChatStore.packed(json)
    }

    static func unpack(_ data: Data) -> [SearchPassage] {
        guard let stored = try? JSONDecoder().decode([Stored].self, from: ChatStore.unpacked(data)) else { return [] }
        return stored.map { item in
            SearchPassage(text: item.t, author: item.a ?? "", date: item.d.map(Date.init(timeIntervalSinceReferenceDate:)),
                          anchor: item.n)
        }
    }

    // MARK: SQLite

    private func rowID(_ key: String) -> Int64? {
        guard let stmt = prepared("SELECT id FROM session WHERE key = ?") else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        if result != SQLITE_OK, setupFailure == SQLITE_OK { setupFailure = result }
        return result == SQLITE_OK
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        guard exec("SAVEPOINT session_archive;") else { return false }
        if body(), exec("RELEASE session_archive;") { return true }
        exec("ROLLBACK TO session_archive;")
        exec("RELEASE session_archive;")
        return false
    }

    private func scalar(_ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func execute(_ sql: String, _ arguments: [Any]) -> Bool {
        guard let stmt = prepared(sql) else { return false }
        defer { sqlite3_reset(stmt) }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case let value as Int64: sqlite3_bind_int64(stmt, index, value)
            case let value as String: sqlite3_bind_text(stmt, index, value, -1, transient)
            default: sqlite3_bind_null(stmt, index)
            }
        }
        let result = sqlite3_step(stmt)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    private func prepared(_ sql: String) -> OpaquePointer? {
        if let known = statements[sql] { return known }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        statements[sql] = stmt
        return stmt
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    private func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }
}

/// Asking a trigram index without positions for text: every trigram of it, each quoted (never FTS syntax), joined by
/// AND. Such an index cannot match a phrase, so what it finds is checked against the text itself.
enum TrigramQuery {
    /// One text: a long one keeps a spread of its trigrams (more add little but cost a lookup each).
    static func text(_ text: String, limit: Int = 48) -> String {
        let characters = Array(text)
        guard characters.count >= 3 else { return quoted(text) }
        var seen = Set<String>()
        var grams: [String] = []
        for start in 0...(characters.count - 3) {
            let gram = String(characters[start..<start + 3])
            if seen.insert(gram).inserted { grams.append(gram) }
        }
        if grams.count > limit {
            let step = Double(grams.count) / Double(limit)
            grams = (0..<limit).map { grams[Int(Double($0) * step)] }
        }
        return grams.map(quoted).joined(separator: " AND ")
    }

    /// A search's words: every group (all must be there), each the OR of its terms. A group with a term shorter than a
    /// trigram cannot be asked for and is left to the search over the passages; nil when no group is left.
    static func expression(_ query: SearchQuery) -> String? {
        if !query.kinds.isEmpty, !query.kinds.contains(.session) { return nil }
        if query.excludedKinds.contains(.session) { return nil }
        let groups = query.groups.compactMap { group -> String? in
            guard !group.isEmpty, group.allSatisfy({ $0.text.count >= 3 }) else { return nil }
            return "(" + group.map { "(" + text($0.text) + ")" }.joined(separator: " OR ") + ")"
        }
        return groups.isEmpty ? nil : groups.joined(separator: " AND ")
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Which stored passages can take part in a hit for a query: those that hold one of its words, folded. A passage without
/// any adds nothing a hit needs (every group must match somewhere, and the title and prompts are in memory already).
struct SearchArchiveFilter {
    let words: [String]

    init(_ query: SearchQuery) {
        var seen = Set<String>()
        words = query.groups.flatMap { $0.map(\.text) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func keeps(_ passage: SearchPassage) -> Bool {
        guard !words.isEmpty else { return true }
        let folded = SearchText.fold(passage.text)
        return words.contains { SearchText.contains(folded, $0) }
    }
}

/// What a sync of `SessionArchive` does: which sessions to write (new or changed since they were written) and which to
/// forget. Pure, apart from reading the transcript files' dates, so it is tested without a database.
enum SessionArchiveSync {
    /// Most messages read from one transcript: the whole of nearly every session.
    static let messageLimit = 20_000
    /// Most passages kept of one transcript, the newest. Kept on disk and read only for a query's candidates.
    static let passageLimit = 5_000

    /// An earlier session of a coding agent, by the search document it is ("past:<id>").
    struct Transcript: Sendable {
        var key: String
        var path: String
        var agent: String
        var date: Date
    }

    struct Source: Sendable {
        enum Content: Sendable {
            case run(WorkspaceRun)
            case transcript(path: String, agent: String)
        }

        var key: String
        /// What tells whether it changed: a session's last update, a transcript file's date.
        var stamp: Double
        var date: Date
        var content: Content
    }

    struct Plan: Sendable {
        /// Newest first.
        var changed: [Source]
        var gone: [String]
    }

    static func plan(runs: [WorkspaceRun], transcripts: [Transcript], stored: [String: Double],
                     modified: (String) -> Date? = Self.modified) -> Plan {
        var sources = runs.map { run in
            Source(key: "run:" + run.id.uuidString, stamp: run.updatedAt.timeIntervalSinceReferenceDate, date: run.updatedAt,
                   content: .run(run))
        }
        var seen = Set(sources.map(\.key))
        for transcript in transcripts where seen.insert(transcript.key).inserted {
            // A file that is gone has nothing to read; what was written of it is forgotten.
            guard let date = modified(transcript.path) else { seen.remove(transcript.key); continue }
            sources.append(Source(key: transcript.key, stamp: date.timeIntervalSinceReferenceDate, date: transcript.date,
                                  content: .transcript(path: transcript.path, agent: transcript.agent)))
        }
        let changed = sources.filter { stored[$0.key] != $0.stamp }.sorted { $0.date > $1.date }
        let gone = stored.keys.filter { !seen.contains($0) }.sorted()
        return Plan(changed: changed, gone: gone)
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// The text of a coding agent session worth finding, for Search everything and `SessionArchive`, the same for every
/// agent: from a session Nook runs (its timeline) or from an agent's own transcript.
enum SessionPassages {
    /// The text of an agent's own transcript worth finding, the same way as a session Nook runs (`make(_:run:)`):
    /// what you asked, what the agent said and the steps it took; thinking stays out. Bounded as the index keeps it.
    static func make(_ messages: [AgentChatMessage], agent: String,
                     limit: Int = SearchIndex.passagesPerDocument) -> [SearchPassage] {
        let passages = messages.compactMap { message -> SearchPassage? in
            let text: String
            switch message.kind {
            case .thinking: return nil
            case .tools:
                let steps = message.steps.map { [$0.name, $0.summary, $0.error ?? ""].filter { !$0.isEmpty }.joined(separator: " ") }
                text = String(steps.joined(separator: "\n").prefix(Self.toolLimit))
            case .user, .assistant, .notice:
                text = String(message.text.prefix(SearchIndex.passageLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { return nil }
            return SearchPassage(text: text, author: message.kind == .user ? "me" : agent, date: message.date, anchor: message.id)
        }
        return Array(passages.suffix(limit))
    }

    /// The text of a session's timeline worth finding: what you asked, what the agent said, what failed, which tools ran.
    /// Thinking and tool output stay out; they drown the conversation.
    static let toolLimit = 1_000

    static func make(_ events: [RunEvent], run: WorkspaceRun) -> [SearchPassage] {
        events.compactMap { event in
            if event.kind == .thinking || event.kind == .approval || event.kind == .system { return nil }
            // A tool's output is cut before it is trimmed: trimming walked all of it, hundreds of KB, for its first 1,000.
            let tool = event.kind == .tool || event.kind == .fileChange
            let text = (tool ? String(event.text.prefix(Self.toolLimit + 64)) : event.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch event.kind {
            case .user: return SearchPassage(text: text, author: "me", date: event.date, anchor: event.id.uuidString)
            case .assistant, .result, .error, .page:
                // A page the agent showed is found by its title.
                return SearchPassage(text: text, author: run.provider.displayName, date: event.date, anchor: event.id.uuidString)
            case .tool, .fileChange:
                // A tool's output can run to hundreds of KB, and every session's passages are kept in the archive
                // (`SessionArchive`): its start is enough to find it by.
                let line = [event.tool ?? "", text, event.kind == .fileChange ? (event.detail ?? "") : ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                return SearchPassage(text: String(line.prefix(Self.toolLimit)), author: run.provider.displayName, date: event.date, anchor: event.id.uuidString)
            case .thinking, .approval, .system: return nil
            }
        }
    }
}
