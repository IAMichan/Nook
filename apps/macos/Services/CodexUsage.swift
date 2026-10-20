import Foundation

/// Codex subscription plan usage: 5-hour window and weekly limits.
struct CodexUsageSnapshot: Equatable {
    struct Window: Equatable {
        /// Percentage used, 0–100, as reported by Codex.
        var usedPercent: Double
        /// Timestamp when this window resets. `nil` if not reported by Codex.
        var resetsAt: Date?
        /// Window duration in minutes (300 for 5 hours, 10080 for one week).
        var windowMinutes: Int?

        /// Current percentage: 0 if window has already reset.
        func percent(at date: Date = Date()) -> Int {
            if let resetsAt, resetsAt <= date { return 0 }
            return Int(min(100, max(0, usedPercent)).rounded())
        }
    }

    enum Source: Equatable {
        /// `codex app-server`, same source as `/status` in Codex.
        case appServer
        /// The last rate limit entry in a session log under ~/.codex/sessions.
        case sessionLog
    }

    var fiveHour: Window?
    var weekly: Window?
    var planType: String?
    var updatedAt: Date
    var source: Source

    /// E.g. "5 hours: 42% used · resets at 14:30".
    var fiveHourLabel: String? {
        guard let fiveHour else { return nil }
        var text = "5 hours: \(fiveHour.percent())% used"
        if let reset = fiveHour.resetsAt, reset > Date() {
            text += " · resets at \(Self.timeFormatter.string(from: reset))"
        }
        return text
    }

    /// E.g. "Weekly: 18% used · resets Thu Oct 16".
    var weeklyLabel: String? {
        guard let weekly else { return nil }
        var text = "Weekly: \(weekly.percent())% used"
        if let reset = weekly.resetsAt, reset > Date() {
            text += " · resets \(Self.dayFormatter.string(from: reset))"
        }
        return text
    }

    /// Highest of the two windows: the one you will reach first.
    var dominantPercent: Int? {
        [fiveHour?.percent(), weekly?.percent()].compactMap { $0 }.max()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

/// Reads Codex plan usage matching Codex's native `/status`: via `codex app-server` (`account/rateLimits/read`),
/// falling back to the latest session log under ~/.codex/sessions. No-op if ~/.codex does not exist.
@MainActor
final class CodexUsage: ObservableObject {
    /// Latest limits per Codex account, by the account's home directory (`CODEX_HOME`).
    @Published private(set) var snapshots: [String: CodexUsageSnapshot] = [:]

    /// The account directories to read, set by the app from its Codex accounts. Without it, only the default one is read.
    var homes: () -> [URL] = { [CodexUsage.codexHome] }

    private struct HomeState {
        /// Last modified timestamp of newest session log; changes indicate Codex activity.
        var lastSessionDate: Date?
        var lastAppServerFetch: Date?
        var busy = false
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "nl.imdigital.nook.codexusage", qos: .utility)
    private var states: [String: HomeState] = [:]

    /// Query `codex app-server` at most this often, unless a session log was modified in the interim.
    private nonisolated static let appServerInterval: TimeInterval = 10 * 60
    private nonisolated static let appServerRetryInterval: TimeInterval = 2 * 60

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledCoalesced(withTimeInterval: 60) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The limits of the default account (the one in `~/.codex`, or `CODEX_HOME` of Nook's own environment).
    var snapshot: CodexUsageSnapshot? { snapshots[Self.codexHome.path] }

    /// The limits of one account directory; the default account when `home` is nil.
    func snapshot(home: URL?) -> CodexUsageSnapshot? {
        snapshots[(home ?? Self.codexHome).path]
    }

    /// Single summary line for Nook context, e.g. "Codex limit: 5h 42% · week 18%".
    var contextLine: String? {
        guard let snapshot, Date().timeIntervalSince(snapshot.updatedAt) < 12 * 3600 else { return nil }
        var parts: [String] = []
        if let fiveHour = snapshot.fiveHour { parts.append("5h \(fiveHour.percent())%") }
        if let weekly = snapshot.weekly { parts.append("week \(weekly.percent())%") }
        guard !parts.isEmpty else { return nil }
        return "Codex limit: " + parts.joined(separator: " · ")
    }

    /// Reads every account right away, instead of waiting for the next minute tick: after adding, logging in or changing an account.
    func refreshNow() {
        refresh()
    }

    private func refresh() {
        var wanted: [URL] = []
        var seen = Set<String>()
        for home in homes() + [Self.codexHome] where seen.insert(home.path).inserted { wanted.append(home) }
        // Accounts that are gone no longer show limits.
        for key in snapshots.keys where !seen.contains(key) { snapshots[key] = nil }
        for home in wanted { refresh(home) }
    }

    private func refresh(_ home: URL) {
        let key = home.path
        var state = states[key] ?? HomeState()
        guard !state.busy else { return }
        // No Codex for this account: check presence once per minute, nothing else.
        guard FileManager.default.fileExists(atPath: home.path) else {
            if snapshots[key] != nil { snapshots[key] = nil }
            return
        }
        state.busy = true
        states[key] = state
        let previousSessionDate = state.lastSessionDate
        let lastFetch = state.lastAppServerFetch
        let hasSnapshot = snapshots[key] != nil
        queue.async { [weak self] in
            let result = CodexUsage.work(
                home: home,
                previousSessionDate: previousSessionDate,
                lastAppServerFetch: lastFetch,
                hasSnapshot: hasSnapshot
            )
            Task { @MainActor in
                guard let self else { return }
                var state = self.states[key] ?? HomeState()
                state.busy = false
                state.lastSessionDate = result.newestSessionDate ?? state.lastSessionDate
                if result.askedAppServer { state.lastAppServerFetch = Date() }
                self.states[key] = state
                if var fresh = result.snapshot {
                    // A session log does not always name the plan; keep the one the app-server reported.
                    if fresh.planType == nil, fresh.source == .sessionLog { fresh.planType = self.snapshots[key]?.planType }
                    if fresh != self.snapshots[key] { self.snapshots[key] = fresh }
                }
            }
        }
    }

    // MARK: Background Work

    private struct WorkResult {
        var snapshot: CodexUsageSnapshot?
        var newestSessionDate: Date?
        var askedAppServer: Bool
    }

    nonisolated static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private nonisolated static func work(
        home: URL,
        previousSessionDate: Date?,
        lastAppServerFetch: Date?,
        hasSnapshot: Bool
    ) -> WorkResult {
        let sessions = recentSessionFiles(home: home)
        let newest = sessions.first?.date
        let sessionChanged = newest != nil && newest != previousSessionDate
        var result = WorkResult(snapshot: nil, newestSessionDate: newest, askedAppServer: false)

        let due = lastAppServerFetch.map { Date().timeIntervalSince($0) >= appServerInterval } ?? true
        // A running session rewrites its log every minute, and each response in it carries the same limits the app-server
        // reports. Read those instead of starting a whole `codex app-server` each minute; it still runs when due.
        if hasSnapshot, sessionChanged, !due, let latest = sessions.first,
           let usage = readSessionLog(latest.url, fileDate: latest.date) {
            result.snapshot = usage
            return result
        }
        // Without any limits yet (Codex installed but not signed in, or an app-server that does not answer) a new try every
        // two minutes, not on every one-minute tick: each one starts `codex app-server` and can wait 15 seconds for it.
        let retryDue = lastAppServerFetch.map { Date().timeIntervalSince($0) >= appServerRetryInterval } ?? true
        if let codex = codexExecutable() {
            if hasSnapshot ? (sessionChanged || due) : retryDue {
                result.askedAppServer = true
                if let usage = readRateLimits(codex: codex, home: home) {
                    result.snapshot = usage
                    return result
                }
            }
        }
        // No (working) codex app-server: fallback to latest limits from session logs, only if something changed.
        if !hasSnapshot || sessionChanged || result.askedAppServer {
            for session in sessions.prefix(3) {
                if let usage = readSessionLog(session.url, fileDate: session.date) {
                    result.snapshot = usage
                    break
                }
            }
        }
        return result
    }

    // MARK: codex app-server

    private nonisolated static func codexExecutable() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/Library/pnpm/codex",
        ]
        // nvm: one bin directory per Node version, newest first.
        let nvmNode = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmNode) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += sorted.map { "\(nvmNode)/\($0)/bin/codex" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Starts `codex app-server`, requests `account/rateLimits/read`, and stops the process. `nil` if Codex is not signed in.
    private nonisolated static func readRateLimits(codex: String, home: URL) -> CodexUsageSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            URL(fileURLWithPath: codex).deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? "",
        ].joined(separator: ":")
        // Each account has its own directory, and so its own limits.
        env["CODEX_HOME"] = home.path
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        // Give up after 15 seconds: terminating closes stdout, ending the read loop.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"nook","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      number(object["id"]) == 2 else { continue }
                guard let result = object["result"] as? [String: Any] else { return nil }
                return parseAppServer(result)
            }
        }
    }

    /// Reads an `account/rateLimits/read` response. primary and secondary are not fixed: duration determines which window it is.
    private nonisolated static func parseAppServer(_ result: [String: Any]) -> CodexUsageSnapshot? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var snapshot = CodexUsageSnapshot(
            fiveHour: nil, weekly: nil,
            planType: limits["planType"] as? String,
            updatedAt: Date(), source: .appServer
        )
        for (index, key) in ["primary", "secondary"].enumerated() {
            guard let raw = limits[key] as? [String: Any], let percent = number(raw["usedPercent"]) else { continue }
            let minutes = number(raw["windowDurationMins"]).map { Int($0) }
            let window = CodexUsageSnapshot.Window(
                usedPercent: percent,
                resetsAt: number(raw["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
                windowMinutes: minutes
            )
            assign(window, minutes: minutes, isPrimary: index == 0, to: &snapshot)
        }
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else { return nil }
        return snapshot
    }

    // MARK: Session Logs

    /// Rollout files from recent days, newest first. Only directories for those days, never the whole tree.
    private nonisolated static func recentSessionFiles(home: URL) -> [(url: URL, date: Date)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var files: [(url: URL, date: Date)] = []
        var seen = Set<String>()
        let now = Date()
        // An extra day ahead and back: Codex can name the folder in UTC or local time.
        for offset in -1...8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            let path = String(format: "%04d/%02d/%02d", y, m, d)
            guard seen.insert(path).inserted else { continue }
            let dir = root.appendingPathComponent(path, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                if let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                    files.append((url: url, date: date))
                }
            }
            if files.count >= 3 && offset >= 1 { break }
        }
        return files.sorted { $0.date > $1.date }
    }

    /// Searches backwards for the latest `token_count` line containing `rate_limits`.
    private nonisolated static func readSessionLog(_ url: URL, fileDate: Date) -> CodexUsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailSize: UInt64 = 512 * 1024
        let start = size > tailSize ? size - tailSize : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        // The tail may start in the middle of a multi-byte character: `String(data:encoding:)` would then fail for the
        // whole tail, and with it fall back to starting `codex app-server` every minute. A cut first line just fails to parse.
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let lineData = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            let payload = (object["payload"] as? [String: Any]) ?? object
            guard let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let lineDate = (object["timestamp"] as? String).flatMap(parseTimestamp) ?? fileDate
            var snapshot = CodexUsageSnapshot(
                fiveHour: nil, weekly: nil,
                planType: (limits["plan_type"] as? String) ?? (limits["planType"] as? String),
                updatedAt: lineDate, source: .sessionLog
            )
            for (index, key) in ["primary", "secondary"].enumerated() {
                guard let raw = limits[key] as? [String: Any], let percent = number(raw["used_percent"]) else { continue }
                let minutes = number(raw["window_minutes"]).map { Int($0) }
                var resetsAt: Date?
                if let absolute = number(raw["resets_at"]) {
                    resetsAt = Date(timeIntervalSince1970: absolute)
                } else if let relative = number(raw["resets_in_seconds"]) {
                    resetsAt = lineDate.addingTimeInterval(relative)
                }
                let window = CodexUsageSnapshot.Window(usedPercent: percent, resetsAt: resetsAt, windowMinutes: minutes)
                assign(window, minutes: minutes, isPrimary: index == 0, to: &snapshot)
            }
            if snapshot.fiveHour != nil || snapshot.weekly != nil { return snapshot }
        }
        return nil
    }

    // MARK: Helpers

    private nonisolated static func assign(
        _ window: CodexUsageSnapshot.Window,
        minutes: Int?,
        isPrimary: Bool,
        to snapshot: inout CodexUsageSnapshot
    ) {
        let isShort = minutes.map { $0 <= 24 * 60 } ?? isPrimary
        if isShort { snapshot.fiveHour = window } else { snapshot.weekly = window }
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private nonisolated static func parseTimestamp(_ string: String) -> Date? {
        NookDates.isoFractional.date(from: string) ?? NookDates.isoPlain.date(from: string)
    }
}
