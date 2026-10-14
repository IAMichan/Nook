import Foundation

/// Hoeveel je van je Codex-abonnement hebt gebruikt: het 5-uursvenster en de week.
struct CodexUsageSnapshot: Equatable {
    struct Window: Equatable {
        /// Percentage gebruikt, 0–100, zoals Codex het meldde.
        var usedPercent: Double
        /// Wanneer dit venster weer vol is. `nil` als Codex het niet doorgaf.
        var resetsAt: Date?
        /// Lengte van het venster in minuten (300 voor 5 uur, 10080 voor een week).
        var windowMinutes: Int?

        /// Percentage op dit moment: is het venster intussen gereset, dan is het 0.
        func percent(at date: Date = Date()) -> Int {
            if let resetsAt, resetsAt <= date { return 0 }
            return Int(min(100, max(0, usedPercent)).rounded())
        }
    }

    enum Source: Equatable {
        /// `codex app-server`, dezelfde bron als `/status` in Codex.
        case appServer
        /// De laatste regel met limieten in een sessielog onder ~/.codex/sessions.
        case sessionLog
    }

    var fiveHour: Window?
    var weekly: Window?
    var planType: String?
    var updatedAt: Date
    var source: Source

    /// Bijvoorbeeld "5 uur: 42% gebruikt · weer vol om 14:30".
    var fiveHourLabel: String? {
        guard let fiveHour else { return nil }
        var text = "5 uur: \(fiveHour.percent())% gebruikt"
        if let reset = fiveHour.resetsAt, reset > Date() {
            text += " · weer vol om \(Self.timeFormatter.string(from: reset))"
        }
        return text
    }

    /// Bijvoorbeeld "Week: 18% gebruikt · reset do 16 okt".
    var weeklyLabel: String? {
        guard let weekly else { return nil }
        var text = "Week: \(weekly.percent())% gebruikt"
        if let reset = weekly.resetsAt, reset > Date() {
            text += " · reset \(Self.dayFormatter.string(from: reset))"
        }
        return text
    }

    /// Hoogste van de twee: daar loop je het eerst tegenaan.
    var dominantPercent: Int? {
        [fiveHour?.percent(), weekly?.percent()].compactMap { $0 }.max()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

/// Leest het Codex-plangebruik, zoals Codex' eigen `/status`: via `codex app-server` (`account/rateLimits/read`),
/// en anders uit de laatste sessielog onder ~/.codex/sessions. Kost niets als ~/.codex niet bestaat.
@MainActor
final class CodexUsage: ObservableObject {
    @Published private(set) var snapshot: CodexUsageSnapshot?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "nl.imdigital.nook.codexusage", qos: .utility)
    private var busy = false
    /// Laatst geziene wijzigingstijd van de nieuwste sessielog. Verandert die, dan is Codex gebruikt.
    private var lastSessionDate: Date?
    private var lastAppServerFetch: Date?

    /// Vraag `codex app-server` hooguit zo vaak, tenzij er intussen een sessie is bijgewerkt.
    private nonisolated static let appServerInterval: TimeInterval = 10 * 60

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Eén regel voor de context van Nook, bijvoorbeeld "Codex-limiet: 5 uur 42% · week 18%".
    var contextLine: String? {
        guard let snapshot, Date().timeIntervalSince(snapshot.updatedAt) < 12 * 3600 else { return nil }
        var parts: [String] = []
        if let fiveHour = snapshot.fiveHour { parts.append("5 uur \(fiveHour.percent())%") }
        if let weekly = snapshot.weekly { parts.append("week \(weekly.percent())%") }
        guard !parts.isEmpty else { return nil }
        return "Codex-limiet: " + parts.joined(separator: " · ")
    }

    private func refresh() {
        guard !busy else { return }
        let home = Self.codexHome
        // Geen Codex op deze Mac: één stat per minuut, verder niets.
        guard FileManager.default.fileExists(atPath: home.path) else {
            if snapshot != nil { snapshot = nil }
            return
        }
        busy = true
        let previousSessionDate = lastSessionDate
        let lastFetch = lastAppServerFetch
        let hasSnapshot = snapshot != nil
        queue.async { [weak self] in
            let result = CodexUsage.work(
                home: home,
                previousSessionDate: previousSessionDate,
                lastAppServerFetch: lastFetch,
                hasSnapshot: hasSnapshot
            )
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.lastSessionDate = result.newestSessionDate ?? self.lastSessionDate
                if result.askedAppServer { self.lastAppServerFetch = Date() }
                if let fresh = result.snapshot, fresh != self.snapshot { self.snapshot = fresh }
            }
        }
    }

    // MARK: Achtergrondwerk

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

        if let codex = codexExecutable() {
            let due = lastAppServerFetch.map { Date().timeIntervalSince($0) >= appServerInterval } ?? true
            if !hasSnapshot || sessionChanged || due {
                result.askedAppServer = true
                if let usage = readRateLimits(codex: codex) {
                    result.snapshot = usage
                    return result
                }
            }
        }
        // Geen (werkende) codex app-server: dan de laatste limieten uit de sessielogs, alleen als er iets veranderd is.
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
        // nvm: één bin-map per Node-versie, nieuwste eerst.
        let nvmNode = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmNode) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += sorted.map { "\(nvmNode)/\($0)/bin/codex" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Start `codex app-server`, vraagt `account/rateLimits/read` en stopt het proces weer. `nil` als Codex niet is ingelogd.
    private nonisolated static func readRateLimits(codex: String) -> CodexUsageSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            URL(fileURLWithPath: codex).deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? "",
        ].joined(separator: ":")
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        // Na 15 seconden opgeven: stoppen sluit stdout, en dan eindigt de leeslus vanzelf.
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

    /// Leest een `account/rateLimits/read`-antwoord. primary en secondary liggen niet vast: de duur bepaalt welk venster het is.
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

    // MARK: Sessielogs

    /// Rollout-bestanden van de afgelopen dagen, nieuwste eerst. Alleen de mappen van die dagen, nooit de hele boom.
    private nonisolated static func recentSessionFiles(home: URL) -> [(url: URL, date: Date)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var files: [(url: URL, date: Date)] = []
        var seen = Set<String>()
        let now = Date()
        // Een dag extra vooruit en terug: Codex kan de map in UTC of lokale tijd benoemen.
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

    /// Zoekt van achter naar voren de laatste `token_count`-regel met `rate_limits`.
    private nonisolated static func readSessionLog(_ url: URL, fileDate: Date) -> CodexUsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailSize: UInt64 = 512 * 1024
        let start = size > tailSize ? size - tailSize : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

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

    // MARK: Hulpjes

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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
