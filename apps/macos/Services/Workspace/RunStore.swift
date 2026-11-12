import Foundation

/// Stores workspace sessions on your Mac: a list of sessions (`runs.json`) and the timelines, as an append-only log in
/// `runs.sqlite` (see `RunEventLog`). Only readable by current user (directory 0700, files 0600).
///
/// Saving a timeline writes only what changed since it was last written: new events as `event` rows, events that
/// changed (a streamed answer, a finished tool) as `update` rows. Nothing already written is rewritten, so a crash loses
/// at most the changes not yet saved and never what was there before.
final class RunStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private var log: RunEventLog?
    /// A second connection, only for reading timelines: replaying one never waits for a save, a save never for it.
    private var reader: RunEventLog?
    private var opened = false
    /// Per timeline, what the log holds: each event's fingerprint in timeline order. Saves compare against it.
    private var written: [UUID: WrittenTimeline] = [:]
    /// Sessions deleted this launch: a save still queued for one must not bring its timeline back.
    private var deleted: Set<UUID> = []

    /// A log this much longer than its timeline (rows of updates no longer needed) is compacted into one snapshot.
    static let compactionMinimumRows = 256

    init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private var runsURL: URL { directory.appendingPathComponent("runs.json") }
    var databaseURL: URL { directory.appendingPathComponent("runs.sqlite") }
    /// Timelines as JSON files, from before the log; imported once and kept as a backup.
    private var eventsDirectory: URL { directory.appendingPathComponent("events", isDirectory: true) }

    private func eventsURL(_ id: UUID) -> URL {
        eventsDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let ioQueue = DispatchQueue(label: "nook.workspace.runstore.io", qos: .utility)

    /// Loads all sessions. Anything still "active" at shutdown has no running process: it becomes "stopped".
    func loadRuns(now: Date = Date()) -> [WorkspaceRun] {
        lock.lock()
        defer { lock.unlock() }
        // Opened here, off the main thread at launch: the one-time import of old timelines can take a moment.
        _ = openLog()
        // Entry by entry, and an unreadable file is kept aside: the next save must never wipe your sessions.
        guard let runs = SafeStorage.load(LossyArray<WorkspaceRun>.self, from: runsURL, decoder: Self.decoder, skipped: { $0.skipped })
            .value?.elements else { return [] }
        return runs.map { run in
            // Its keeper may hold it still: `reattachKeptRuns` looks.
            guard run.status.isActive, run.kept == nil else { return run }
            var recovered = run
            recovered.interruptedWhileWaiting = run.status == .waitingApproval ? true : nil
            recovered.status = run.status.afterRelaunch
            recovered.statusDetail = "interrupted"
            recovered.turnStartedAt = nil
            recovered.updatedAt = now
            return recovered
        }
    }

    func saveRuns(_ runs: [WorkspaceRun]) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(encodeRuns(runs), to: runsURL)
    }

    /// Each session's JSON as last encoded, with the session it came from.
    private var encodedRuns: [UUID: (run: WorkspaceRun, json: Data)] = [:]

    /// The list as one JSON array, encoding only the sessions that changed since the last save. While agents stream, a
    /// session changes with every message; encoding all of them (hundreds, a megabyte) each time kept a core busy.
    /// Call with the lock held.
    private func encodeRuns(_ runs: [WorkspaceRun]) throws -> Data {
        var json = Data()
        json.reserveCapacity(encodedRuns.values.reduce(2) { $0 + $1.json.count + 1 })
        json.append(UInt8(ascii: "["))
        var encoded: [UUID: (run: WorkspaceRun, json: Data)] = [:]
        encoded.reserveCapacity(runs.count)
        for (index, run) in runs.enumerated() {
            let piece: Data
            if let known = encodedRuns[run.id], known.run == run {
                piece = known.json
            } else {
                piece = try Self.encoder.encode(run)
            }
            encoded[run.id] = (run, piece)
            if index > 0 { json.append(UInt8(ascii: ",")) }
            json.append(piece)
        }
        json.append(UInt8(ascii: "]"))
        encodedRuns = encoded
        return json
    }

    /// - Parameter failed: called, off the main thread, when the list could not be written.
    func saveRunsAsync(_ runs: [WorkspaceRun], failed: (@Sendable () -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do { try self.saveRuns(runs) } catch { failed?() }
        }
    }

    /// Reads and decodes outside the lock, so a long timeline holds up neither saves nor the reading of another one.
    func loadEvents(_ id: UUID) -> [RunEvent] {
        Self.settled(readTimeline(id, remember: true))
    }

    /// The timeline for a one-time read (a search over every session): keeps nothing of it, and never compacts.
    func peekEvents(_ id: UUID) -> [RunEvent] {
        Self.settled(readTimeline(id, remember: false))
    }

    private static func settled(_ timeline: [RunEvent]) -> [RunEvent] {
        var events = timeline
        // A tool or approval still running when Nook stopped is no longer running.
        for index in events.indices where events[index].state == .running || events[index].state == .pending {
            events[index].state = events[index].kind == .approval ? .expired : .failed
        }
        return events
    }

    /// Writes what changed in the timeline since it was last written. The whole timeline is kept, however long.
    func saveEvents(_ id: UUID, _ events: [RunEvent]) throws {
        prepareWritten(id)
        lock.lock()
        guard !deleted.contains(id) else { lock.unlock(); return }
        guard let log = openLog() else { lock.unlock(); throw RunStoreError.unavailable }
        let before = writtenTimeline(id, log: log)
        lock.unlock()
        // Comparing and encoding a long timeline takes a while: done outside the lock, so reading another session's
        // timeline (one you open) does not wait for it.
        guard let change = TimelineChange.between(before, events) else { return }
        let payloads = try Self.payloads(for: change, events)
        lock.lock()
        defer { lock.unlock() }
        guard !deleted.contains(id) else { return }
        // Something else wrote this timeline in between: compare again with what is written now.
        let current = writtenTimeline(id, log: log)
        if current != before {
            guard let fresh = TimelineChange.between(current, events) else { return }
            try write(fresh, payloads: Self.payloads(for: fresh, events), of: id, log: log)
            index(fresh, events, of: id, log: log)
        } else {
            try write(change, payloads: payloads, of: id, log: log)
            index(change, events, of: id, log: log)
        }
    }

    /// Keeps the search index in step with what was written. Call with the lock held.
    private func index(_ change: TimelineChange, _ events: [RunEvent], of id: UUID, log: RunEventLog) {
        switch change {
        case .snapshot: log.reindex(id, TimelineSearchText.entries(events))
        case .rows(let rows, _): log.index(id, TimelineSearchText.entries(rows.map(\.1)))
        }
    }

    /// The encoded rows of a change: the whole timeline for a snapshot, else each new or changed event.
    private static func payloads(for change: TimelineChange, _ events: [RunEvent]) throws -> [Data] {
        switch change {
        case .snapshot: return [try encoder.encode(events)]
        case .rows(let rows, _): return try rows.map { try encoder.encode($0.1) }
        }
    }

    /// Call with the lock held.
    private func write(_ change: TimelineChange, payloads: [Data], of id: UUID, log: RunEventLog) throws {
        switch change {
        case .snapshot(let after):
            try writeSnapshot(id, payload: payloads[0], log: log)
            written[id] = after
        case .rows(let rows, let after):
            if !rows.isEmpty {
                let now = Date()
                let saved = log.transaction {
                    for (row, payload) in zip(rows, payloads) {
                        guard log.append(id, row.0, payload, at: now) != nil else { return false }
                    }
                    return true
                }
                guard saved else { throw RunStoreError.writeFailed }
            }
            written[id] = after
        }
    }

    /// Adds one event at the end of the timeline right away (a message, a tool call), without waiting for the next save.
    func appendEvent(_ id: UUID, _ event: RunEvent) {
        // Encoded before taking the lock, which reads of other timelines wait for.
        guard let payload = try? Self.encoder.encode(event) else { return }
        prepareWritten(id)
        lock.lock()
        defer { lock.unlock() }
        guard !deleted.contains(id), let log = openLog() else { return }
        var timeline = writtenTimeline(id, log: log)
        // Already written (an event appended twice): the next save notices any change.
        guard timeline.fingerprints[event.id] == nil, log.append(id, .event, payload) != nil else { return }
        log.index(id, TimelineSearchText.entries([event]))
        timeline.add(event.id, Self.fingerprint(event))
        written[id] = timeline
    }

    func appendEventAsync(_ id: UUID, _ event: RunEvent) {
        ioQueue.async { [weak self] in
            self?.appendEvent(id, event)
        }
    }

    func saveEventsAsync(_ id: UUID, _ events: [RunEvent]) {
        ioQueue.async { [weak self] in
            try? self?.saveEvents(id, events)
        }
    }

    /// Forgets a session's timeline: its log rows and the old JSON copy, if any.
    func deleteEvents(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        openLog()?.delete(id)
        log?.removeIndex(id)
        written[id] = nil
        deleted.insert(id)
        try? fileManager.removeItem(at: eventsURL(id))
    }

    /// `deleteEvents` on the background queue, after the saves handed to it before: deleting a long session's rows is a
    /// write to runs.sqlite the main thread need not wait for. Saves handed to the queue after it are dropped, as the
    /// timeline is marked deleted by then.
    func deleteEventsAsync(_ id: UUID) {
        ioQueue.async { [weak self] in
            self?.deleteEvents(id)
        }
    }

    /// Waits until every save handed to the background queue is written.
    func flush() {
        ioQueue.sync {}
    }

    // MARK: Log

    /// Opens the log on first use and imports the old JSON timelines once. Call with the lock held.
    private func openLog() -> RunEventLog? {
        if opened { return log }
        opened = true
        log = RunEventLog(url: databaseURL)
        if let log {
            importJSONTimelines(into: log)
            reader = RunEventLog(url: databaseURL, readOnly: true)
            if log.searchAvailable, log.meta(Self.indexedKey) == nil {
                ioQueue.async { [weak self] in self?.buildSearchIndex() }
            }
        } else {
            SafeStorage.report("runs.sqlite could not be opened; timelines are not saved this launch")
        }
        return log
    }

    private static let importedKey = "json_timelines_imported"
    /// Set once every session is indexed. The third key: the first index (`run_text`) and the second, which kept a copy of
    /// the text (`RunEventLog.dropSearchWithText`), are dropped and built anew.
    private static let indexedKey = "search_index_v3_built"

    /// Indexes every session written before the index existed, once, in the background. Rows are read on the read
    /// connection and folded without the lock; only writing a session's index takes it, so a timeline you open never waits
    /// for more than one session. A session saved meanwhile is indexed by that save as well. Stopped halfway (a new build
    /// from Xcode), the next launch starts again, and replacing what is already indexed is cheap.
    private func buildSearchIndex() {
        lock.lock()
        log?.dropLegacySearchIndex()
        let ids = log?.runIDs() ?? []
        let reader = reader
        lock.unlock()
        for id in ids {
            lock.lock()
            let skip = deleted.contains(id)
            lock.unlock()
            if skip { continue }
            guard let rows = reader?.readRows(id) ?? lockedRows(id) else { continue }
            let entries = TimelineSearchText.entries(RunEventFold.fold(rows, decoder: Self.decoder).events)
            lock.lock()
            if let log, !deleted.contains(id) {
                // A row written after the read: its save indexed it already, and these older entries must not undo that.
                if log.lastSequence(id) == rows.last?.seq {
                    log.reindex(id, entries)
                } else {
                    log.reindex(id, TimelineSearchText.entries(RunEventFold.fold(log.rows(id), decoder: Self.decoder).events))
                }
            }
            lock.unlock()
        }
        lock.lock()
        log?.setMeta(Self.indexedKey, ISO8601DateFormatter().string(from: Date()))
        // An index that kept the text was dropped on opening: its room goes back to the disk.
        log?.compact()
        lock.unlock()
    }

    /// A session's rows from the write connection, for when there is no read connection.
    private func lockedRows(_ id: UUID) -> [RunEventLog.Row]? {
        lock.lock()
        defer { lock.unlock() }
        return log?.readRows(id)
    }

    /// The sessions whose timelines mention `query`, newest match first; nil when the index cannot answer (no FTS5, a
    /// query under three characters, or the index still being built), so the caller reads the timelines itself.
    func sessions(mentioning query: String) -> [UUID]? {
        lock.lock()
        defer { lock.unlock() }
        guard let log = openLog(), log.meta(Self.indexedKey) != nil else { return nil }
        return log.sessions(mentioning: query)
    }

    /// Copies each `events/<id>.json` into the log as a snapshot, once. The files stay where they are, as a backup.
    private func importJSONTimelines(into log: RunEventLog) {
        guard log.meta(Self.importedKey) == nil else { return }
        let files = (try? fileManager.contentsOfDirectory(at: eventsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let done = log.transaction {
            for file in files where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !log.hasRows(id) else { continue }
                // Unreadable entries or files are copied aside by SafeStorage, as before.
                guard let events = SafeStorage.load(LossyArray<RunEvent>.self, from: file, decoder: Self.decoder, skipped: { $0.skipped })
                    .value?.elements, let payload = try? Self.encoder.encode(events) else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                guard log.append(id, .snapshot, payload, at: modified) != nil else { return false }
            }
            log.setMeta(Self.importedKey, ISO8601DateFormatter().string(from: Date()))
            return true
        }
        if !done { SafeStorage.report("Importing the JSON timelines into runs.sqlite failed; trying again next launch") }
    }

    /// A session's rows, from the read connection when there is one: no lock held. Nil when neither can read them.
    private func readRows(_ id: UUID) -> [RunEventLog.Row]? {
        lock.lock()
        _ = openLog()
        let reader = reader
        lock.unlock()
        if let rows = reader?.readRows(id) { return rows }
        lock.lock()
        defer { lock.unlock() }
        return openLog()?.readRows(id)
    }

    /// Replays the session's rows, compacting a log that grew much longer than its timeline.
    ///
    /// Reads on its own connection and decodes outside the lock: the main thread takes the lock to write an event, and must
    /// not wait for a session being read in the background. A save does not wait for it either.
    private func readTimeline(_ id: UUID, remember: Bool) -> [RunEvent] {
        guard let rows = readRows(id) else {
            guard remember else { return [] }
            // Nothing to go on, and the list handed to the next save will be short: told what the log holds, that save
            // would read as events removed and replace them all with a snapshot. New events are only added this way.
            SafeStorage.report("A timeline could not be read from runs.sqlite")
            lock.lock()
            defer { lock.unlock() }
            written[id] = WrittenTimeline()
            return []
        }
        let result = RunEventFold.fold(rows, decoder: Self.decoder)
        guard remember else { return result.events }
        let timeline = WrittenTimeline(result.events)
        // Unreadable rows (a newer version's) are left alone: compacting would drop them.
        let compact = result.unreadableRows == 0 && rows.count >= Self.compactionMinimumRows && result.supersededRows >= result.events.count
        let payload = compact ? try? Self.encoder.encode(result.events) : nil
        lock.lock()
        defer { lock.unlock() }
        guard !deleted.contains(id) else { return result.events }
        // Already known: a save got here first, and what it noted is newer than these rows.
        if written[id] == nil { written[id] = timeline }
        // A snapshot replaces every earlier row: not when a row came in after this read, which it does not hold.
        if let payload, let log = openLog(), log.lastSequence(id) == rows.last?.seq {
            try? writeSnapshot(id, payload: payload, log: log)
        }
        return result.events
    }

    /// Reads what the log holds for a timeline this launch has not seen yet, before a save takes the lock for it.
    private func prepareWritten(_ id: UUID) {
        lock.lock()
        _ = openLog()
        let known = written[id] != nil
        let reader = reader
        lock.unlock()
        guard !known, let rows = reader?.readRows(id) else { return }
        let timeline = WrittenTimeline(RunEventFold.fold(rows, decoder: Self.decoder).events)
        lock.lock()
        defer { lock.unlock() }
        if written[id] == nil { written[id] = timeline }
    }

    /// One row with the whole timeline, replacing the session's earlier rows in the same transaction.
    private func writeSnapshot(_ id: UUID, payload: Data, log: RunEventLog) throws {
        let saved = log.transaction {
            guard let seq = log.append(id, .snapshot, payload) else { return false }
            log.delete(id, through: seq - 1)
            return true
        }
        guard saved else { throw RunStoreError.writeFailed }
    }

    /// What the log holds for a timeline, read from it when this launch has not seen it yet. Call with the lock held.
    private func writtenTimeline(_ id: UUID, log: RunEventLog) -> WrittenTimeline {
        if let known = written[id] { return known }
        let timeline = WrittenTimeline(RunEventFold.fold(log.rows(id), decoder: Self.decoder).events)
        written[id] = timeline
        return timeline
    }

    /// Tells two versions of an event apart without keeping a copy of it.
    static func fingerprint(_ event: RunEvent) -> Int {
        var hasher = Hasher()
        hasher.combine(event.id)
        hasher.combine(event.date)
        hasher.combine(event.kind)
        hasher.combine(event.text)
        hasher.combine(event.tool)
        hasher.combine(event.callID)
        hasher.combine(event.detail)
        hasher.combine(event.output)
        hasher.combine(event.state)
        hasher.combine(event.rolledBack)
        hasher.combine(event.source)
        hasher.combine(event.subagentSteps)
        hasher.combine(event.steer)
        hasher.combine(event.steerStatus)
        return hasher.finalize()
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum RunStoreError: Error {
    case unavailable, writeFailed
}

/// The ids and fingerprints of a timeline as written to the log, in order.
struct WrittenTimeline: Equatable {
    var order: [UUID] = []
    var fingerprints: [UUID: Int] = [:]

    init() {}

    init(_ events: [RunEvent]) {
        for event in events { add(event.id, RunStore.fingerprint(event)) }
    }

    mutating func add(_ id: UUID, _ fingerprint: Int) {
        if fingerprints.updateValue(fingerprint, forKey: id) == nil { order.append(id) }
    }
}

/// Which timelines to release from memory. They stay whole on disk and come back when asked for, so what counts is what
/// the Mac gets back: a count alone keeps sixteen huge timelines as readily as sixteen small ones.
enum TimelineEviction {
    struct Candidate: Equatable {
        var id: UUID
        var lastUsed: Date
        var bytes: Int
        /// Nothing runs in it, nothing is left to save and nobody used it for a while.
        var idle: Bool
    }

    /// The idle timelines to release, longest unused first: until at most `limit` are left and they hold at most `budget`
    /// bytes. A timeline in use stays, whatever it holds, so the two can stay exceeded.
    static func pick(_ all: [Candidate], limit: Int, budget: Int) -> [UUID] {
        var count = all.count
        var bytes = all.reduce(0) { $0 + $1.bytes }
        var picked: [UUID] = []
        for candidate in all.filter(\.idle).sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard count > limit || bytes > budget else { break }
            picked.append(candidate.id)
            count -= 1
            bytes -= candidate.bytes
        }
        return picked
    }
}

extension RunEvent {
    /// About what the event holds in memory: its texts, in bytes.
    var approximateBytes: Int {
        text.utf8.count + (detail?.utf8.count ?? 0) + (output?.utf8.count ?? 0) + 200
    }
}

/// What a save has to write: the new and changed events as rows, or, when events were removed or reordered, a snapshot.
enum TimelineChange {
    case rows([(RunEventLog.Kind, RunEvent)], after: WrittenTimeline)
    case snapshot(after: WrittenTimeline)

    /// Nil when nothing changed.
    static func between(_ before: WrittenTimeline, _ events: [RunEvent]) -> TimelineChange? {
        var after = WrittenTimeline()
        var rows: [(RunEventLog.Kind, RunEvent)] = []
        var structural = false
        // The next position in `before.order` an event written earlier may take.
        var position = 0
        var kept = 0
        for event in events {
            let fingerprint = RunStore.fingerprint(event)
            after.add(event.id, fingerprint)
            if let old = before.fingerprints[event.id] {
                kept += 1
                // Written events keep their order: one that moved needs a snapshot.
                guard position < before.order.count, let at = before.order[position...].firstIndex(of: event.id) else {
                    structural = true
                    continue
                }
                position = at + 1
                if old != fingerprint { rows.append((.update, event)) }
            } else {
                // A new event goes at the end: one placed before written events needs a snapshot.
                if position < before.order.count { structural = true }
                rows.append((.event, event))
            }
        }
        // Events that are no longer in the timeline, or a duplicate id: also a snapshot.
        if kept != before.order.count || after.order.count != events.count { structural = true }
        if structural { return .snapshot(after: after) }
        return rows.isEmpty ? nil : .rows(rows, after: after)
    }
}

// MARK: Cross-session Usage

/// A time range for the usage overview.
enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all
    var id: String { rawValue }

    func start(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

/// Aggregates usage across workspace sessions. Only what agents reported themselves; missing figures remain missing.
struct UsageReport: Equatable, Sendable {
    struct Filter: Equatable, Sendable {
        var range: UsageRange = .week
        var provider: RunProvider?
        var model: String?
        var project: String?
    }

    struct Row: Equatable, Identifiable, Sendable {
        var provider: RunProvider
        var model: String
        var sessions: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var reportedCostUSD: Double?
        /// Sessions in this row without token numbers (for example, stopped before the first report).
        var sessionsWithoutTokens: Int
        var id: String { provider.rawValue + "|" + model }
    }

    struct Day: Equatable, Identifiable, Sendable {
        var day: Date
        var provider: RunProvider
        var tokens: Int
        var id: String { "\(day.timeIntervalSince1970)|\(provider.rawValue)" }
    }

    var sessions = 0
    var completed = 0
    var failed = 0
    var running = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    /// Sum of costs reported by agents themselves; nil if no session reported cost.
    var reportedCostUSD: Double?
    var sessionsWithCost = 0
    var sessionsWithTokens = 0
    var rows: [Row] = []
    var days: [Day] = []

    var averageTokensPerSession: Int? {
        guard sessionsWithTokens > 0 else { return nil }
        return (inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens) / sessionsWithTokens
    }

    static func make(runs: [WorkspaceRun], filter: Filter, now: Date = Date(), calendar: Calendar = .current) -> UsageReport {
        let start = filter.range.start(now: now, calendar: calendar)
        let selected = runs.filter { run in
            if let start, run.updatedAt < start { return false }
            if let provider = filter.provider, run.provider != provider { return false }
            if let model = filter.model, displayModel(run) != model { return false }
            if let project = filter.project, run.projectPath != project { return false }
            return true
        }
        var report = UsageReport()
        var rows: [String: Row] = [:]
        var days: [String: Day] = [:]
        for run in selected {
            report.sessions += 1
            switch run.status {
            case .completed: report.completed += 1
            case .failed: report.failed += 1
            case .preparing, .running, .waitingApproval: report.running += 1
            case .stopped: break
            }
            let usage = run.usage
            let hasTokens = usage.totalTokens != nil
            if hasTokens { report.sessionsWithTokens += 1 }
            report.inputTokens += usage.inputTokens ?? 0
            report.outputTokens += usage.outputTokens ?? 0
            report.cacheReadTokens += usage.cacheReadTokens ?? 0
            report.cacheWriteTokens += usage.cacheWriteTokens ?? 0
            if let cost = usage.reportedCostUSD {
                report.reportedCostUSD = (report.reportedCostUSD ?? 0) + cost
                report.sessionsWithCost += 1
            }

            let model = displayModel(run)
            let key = run.provider.rawValue + "|" + model
            var row = rows[key] ?? Row(provider: run.provider, model: model, sessions: 0, inputTokens: 0, outputTokens: 0,
                                       cacheReadTokens: 0, reportedCostUSD: nil, sessionsWithoutTokens: 0)
            row.sessions += 1
            row.inputTokens += usage.inputTokens ?? 0
            row.outputTokens += usage.outputTokens ?? 0
            row.cacheReadTokens += usage.cacheReadTokens ?? 0
            if let cost = usage.reportedCostUSD { row.reportedCostUSD = (row.reportedCostUSD ?? 0) + cost }
            if !hasTokens { row.sessionsWithoutTokens += 1 }
            rows[key] = row

            if let total = usage.totalTokens {
                let day = calendar.startOfDay(for: run.createdAt)
                let dayKey = "\(day.timeIntervalSince1970)|\(run.provider.rawValue)"
                var entry = days[dayKey] ?? Day(day: day, provider: run.provider, tokens: 0)
                entry.tokens += total
                days[dayKey] = entry
            }
        }
        report.rows = rows.values.sorted { lhs, rhs in
            let l = lhs.inputTokens + lhs.outputTokens + lhs.cacheReadTokens
            let r = rhs.inputTokens + rhs.outputTokens + rhs.cacheReadTokens
            return l != r ? l > r : lhs.id < rhs.id
        }
        report.days = days.values.sorted { $0.day != $1.day ? $0.day < $1.day : $0.provider.rawValue < $1.provider.rawValue }
        return report
    }

    /// The model as shown in reporting: the chosen name, or "default".
    static func displayModel(_ run: WorkspaceRun) -> String {
        if let resolved = run.resolvedModel, !resolved.isEmpty { return resolved }
        return run.model.isEmpty ? "default" : run.model
    }
}

/// What waits on you in a session survives a restart of Nook. The process that asked is gone after one, so:
/// - A question the agent asked (Claude Code's AskUserQuestion, Codex's `requestUserInput`, an ACP agent's form, Pi's
///   dialogs, OpenCode's `question` tool) shows again where it was, and your answer goes to the agent as a message of
///   yours, which resumes its conversation the way every message does.
/// - An approval cannot be given any more: the timeline says it expired because Nook restarted.
/// - Messages you queued stay queued, held as after a stop: they go out once you send or resume (also after "Continue
///   where you left off"), never by themselves at launch.
/// They are written into `runs.json` with the session (`merged`) and taken out again when it is read (`take`), so the
/// sessions in memory never carry them.
enum RestartRequests {
    /// What was saved with one session.
    struct Saved: Equatable, Sendable {
        var questions: [SavedQuestion] = []
        /// The summaries of the approvals it waited for.
        var approvals: [String] = []
        var queue: MessageQueue?

        var isEmpty: Bool { questions.isEmpty && approvals.isEmpty && (queue?.isEmpty ?? true) }
    }

    /// The list as it is written: each session with what waits on it now. Only the sessions in `runs` are written, so what
    /// waited on a deleted session is gone with it.
    static func merged(_ runs: [WorkspaceRun], questions: [UUID: [SavedQuestion]], approvals: [UUID: [String]],
                       queues: [UUID: MessageQueue]) -> [WorkspaceRun] {
        guard !questions.isEmpty || !approvals.isEmpty || !queues.isEmpty
                || runs.contains(where: { $0.waitingQuestions != nil || $0.waitingApprovals != nil || $0.queue != nil })
        else { return runs }
        return runs.map { run in
            var run = run
            let asked = questions[run.id] ?? []
            run.waitingQuestions = asked.isEmpty ? nil : asked
            let waiting = approvals[run.id] ?? []
            run.waitingApprovals = waiting.isEmpty ? nil : waiting
            if let queue = queues[run.id], !queue.isEmpty { run.queue = queue } else { run.queue = nil }
            return run
        }
    }

    /// Takes what was saved out of the loaded sessions, by session.
    static func take(_ runs: inout [WorkspaceRun]) -> [UUID: Saved] {
        var saved: [UUID: Saved] = [:]
        for index in runs.indices
            where runs[index].waitingQuestions != nil || runs[index].waitingApprovals != nil || runs[index].queue != nil {
            let entry = Saved(questions: runs[index].waitingQuestions ?? [], approvals: runs[index].waitingApprovals ?? [],
                              queue: restoredQueue(runs[index].queue))
            runs[index].waitingQuestions = nil
            runs[index].waitingApprovals = nil
            runs[index].queue = nil
            if !entry.isEmpty { saved[runs[index].id] = entry }
        }
        return saved
    }

    /// A saved queue as it comes back: held, so nothing goes out by itself at launch; nil when it is empty.
    static func restoredQueue(_ queue: MessageQueue?) -> MessageQueue? {
        guard var queue, !queue.isEmpty else { return nil }
        queue.hold()
        return queue
    }

    /// The question as it is saved; one without anything to ask is not.
    static func saved(id: String, questions: [RunQuestion], created: Date) -> SavedQuestion? {
        let asked = questions.filter { !$0.question.isEmpty || !$0.options.isEmpty }
        return asked.isEmpty ? nil : SavedQuestion(id: id, questions: asked, created: created)
    }

    /// Your answers as the message the agent gets: each question with what you chose or wrote. After a restart the agent
    /// no longer waits for them, so the message says what they answer.
    static func message(_ questions: [RunQuestion], answers: [String: [String]], restored: Bool) -> String {
        let lines = questions.map { item in
            "\(item.question) → \((answers[item.id] ?? []).joined(separator: ", "))"
        }.joined(separator: "\n")
        guard restored else { return lines }
        return "My answers to the questions you asked before Nook restarted:\n" + lines
    }
}
