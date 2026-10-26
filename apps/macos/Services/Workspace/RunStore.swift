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
            guard run.status.isActive else { return run }
            var recovered = run
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
        try write(Self.encoder.encode(runs), to: runsURL)
    }

    func saveRunsAsync(_ runs: [WorkspaceRun]) {
        ioQueue.async { [weak self] in
            try? self?.saveRuns(runs)
        }
    }

    func loadEvents(_ id: UUID) -> [RunEvent] {
        lock.lock()
        defer { lock.unlock() }
        var events = readTimeline(id)
        // A tool or approval still running when Nook stopped is no longer running.
        for index in events.indices where events[index].state == .running || events[index].state == .pending {
            events[index].state = events[index].kind == .approval ? .expired : .failed
        }
        return events
    }

    /// Writes what changed in the timeline since it was last written. The whole timeline is kept, however long.
    func saveEvents(_ id: UUID, _ events: [RunEvent]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !deleted.contains(id) else { return }
        guard let log = openLog() else { throw RunStoreError.unavailable }
        let before = writtenTimeline(id, log: log)
        guard let change = TimelineChange.between(before, events) else { return }
        switch change {
        case .snapshot(let after):
            try writeSnapshot(id, events, log: log)
            written[id] = after
        case .rows(let rows, let after):
            if !rows.isEmpty {
                let now = Date()
                let saved = log.transaction {
                    for (kind, event) in rows {
                        guard let payload = try? Self.encoder.encode(event), log.append(id, kind, payload, at: now) != nil else { return false }
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
        lock.lock()
        defer { lock.unlock() }
        guard !deleted.contains(id), let log = openLog() else { return }
        var timeline = writtenTimeline(id, log: log)
        // Already written (an event appended twice): the next save notices any change.
        guard timeline.fingerprints[event.id] == nil, let payload = try? Self.encoder.encode(event),
              log.append(id, .event, payload) != nil else { return }
        timeline.add(event.id, Self.fingerprint(event))
        written[id] = timeline
    }

    func appendEventAsync(_ id: UUID, _ event: RunEvent) {
        ioQueue.async { [weak self] in
            self?.appendEvent(id, event)
        }
    }

    /// Without `runs` only the timeline is written (the session list has not been read yet).
    func saveEventsAsync(_ id: UUID, _ events: [RunEvent], runs: [WorkspaceRun]?) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? self.saveEvents(id, events)
            if let runs { try? self.saveRuns(runs) }
        }
    }

    /// Forgets a session's timeline: its log rows and the old JSON copy, if any.
    func deleteEvents(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        openLog()?.delete(id)
        written[id] = nil
        deleted.insert(id)
        try? fileManager.removeItem(at: eventsURL(id))
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
        } else {
            SafeStorage.report("runs.sqlite could not be opened; timelines are not saved this launch")
        }
        return log
    }

    private static let importedKey = "json_timelines_imported"

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

    /// Replays the session's rows, compacting a log that grew much longer than its timeline. Call with the lock held.
    private func readTimeline(_ id: UUID) -> [RunEvent] {
        guard let log = openLog() else { return [] }
        let rows = log.rows(id)
        let result = RunEventFold.fold(rows, decoder: Self.decoder)
        written[id] = WrittenTimeline(result.events)
        // Unreadable rows (a newer version's) are left alone: compacting would drop them.
        if result.unreadableRows == 0, rows.count >= Self.compactionMinimumRows, result.supersededRows >= result.events.count {
            try? writeSnapshot(id, result.events, log: log)
        }
        return result.events
    }

    /// One row with the whole timeline, replacing the session's earlier rows in the same transaction.
    private func writeSnapshot(_ id: UUID, _ events: [RunEvent], log: RunEventLog) throws {
        let payload = try Self.encoder.encode(events)
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
