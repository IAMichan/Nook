import Foundation

/// Bewaart werkruimte-sessies op je Mac: een lijst met sessies en per sessie zijn tijdlijn.
/// Alleen leesbaar voor jou (map 0700, bestanden 0600). Schrijft atomair, zodat een crash niets half achterlaat.
final class RunStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default

    /// Zoveel regels per tijdlijn bewaren; oudere vallen eraf (het volledige transcript houdt de agent zelf bij).
    static let eventLimit = 4_000

    init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private var runsURL: URL { directory.appendingPathComponent("runs.json") }
    private var eventsDirectory: URL { directory.appendingPathComponent("events", isDirectory: true) }

    private func eventsURL(_ id: UUID) -> URL {
        eventsDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Leest alle sessies. Wat bij het afsluiten nog "actief" was, heeft geen proces meer: dat wordt "gestopt".
    func loadRuns(now: Date = Date()) -> [WorkspaceRun] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: runsURL),
              let runs = try? Self.decoder.decode([WorkspaceRun].self, from: data) else { return [] }
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

    func loadEvents(_ id: UUID) -> [RunEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: eventsURL(id)),
              var events = try? Self.decoder.decode([RunEvent].self, from: data) else { return [] }
        // Een tool of goedkeuring die nog liep toen Nook stopte, loopt niet meer.
        for index in events.indices where events[index].state == .running || events[index].state == .pending {
            events[index].state = events[index].kind == .approval ? .expired : .failed
        }
        return events
    }

    func saveEvents(_ id: UUID, _ events: [RunEvent]) throws {
        lock.lock()
        defer { lock.unlock() }
        let kept = events.count > Self.eventLimit ? Array(events.suffix(Self.eventLimit)) : events
        try write(Self.encoder.encode(kept), to: eventsURL(id))
    }

    func deleteEvents(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: eventsURL(id))
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: Gebruik over sessies heen

/// Een periode voor het gebruiksoverzicht.
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

/// Telt het gebruik van werkruimte-sessies op. Alleen wat de agents zelf meldden; ontbrekende cijfers blijven ontbreken.
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
        /// Sessies in deze rij zonder tokencijfers (bijvoorbeeld gestopt voor de eerste melding).
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
    /// Som van de kosten die agents zelf meldden; nil als geen enkele sessie kosten meldde.
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

    /// Het model zoals in de rapportage: de gekozen naam, of "standaard".
    static func displayModel(_ run: WorkspaceRun) -> String {
        if let resolved = run.resolvedModel, !resolved.isEmpty { return resolved }
        return run.model.isEmpty ? "default" : run.model
    }
}
