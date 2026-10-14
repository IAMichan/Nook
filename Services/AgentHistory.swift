import Foundation
import SwiftUI

/// Welke agent een eerdere sessie of account hoort bij. Van Claude Code en Codex leest Nook ook de sessies;
/// van Gemini CLI alleen met welk Google-account je bent ingelogd.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, gemini

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        }
    }

    /// Het commando in de terminal.
    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        }
    }

    /// Kort, voor op een knop of in een kop.
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(hex: 0xE08A5E)
        case .codex: return Color(hex: 0x6FCFB3)
        case .gemini: return Color(hex: 0x8AB4F8)
        }
    }

    /// De koppeling in Instellingen › Agents die voortgang en toestemming naar de notch brengt.
    var hookTarget: AgentConfigInstaller.Target {
        switch self {
        case .claude: return .claudeHooks
        case .codex: return .codex
        case .gemini: return .gemini
        }
    }

    /// Alles wat Nook voor deze agent koppelt met één klik.
    var targets: [AgentConfigInstaller.Target] {
        switch self {
        case .claude: return [.claudeHooks, .claudeStatusLine]
        case .codex: return [.codex]
        case .gemini: return [.gemini]
        }
    }

    /// Hoe je de agent installeert als hij er nog niet is.
    var installCommand: String {
        switch self {
        case .claude:
            return #"curl -fsSL https://claude.ai/install.sh | bash && export PATH="$HOME/.local/bin:$PATH""#
        case .codex:
            return "if command -v npm >/dev/null 2>&1; then npm install -g @openai/codex; else brew install --cask codex; fi"
        case .gemini:
            return "if command -v npm >/dev/null 2>&1; then npm install -g @google/gemini-cli; else brew install gemini-cli; fi"
        }
    }

    /// Inloggen. Claude Code en Gemini CLI vragen het zelf bij de eerste start; Codex heeft er een eigen commando voor.
    var loginCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex login"
        case .gemini: return "gemini"
        }
    }

    /// Kandidaat-paden voor de agent, naast wat je shell vindt.
    var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/Library/pnpm"]
        if self == .claude { paths.insert("\(home)/.claude/local", at: 0) }
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        return paths.map { "\($0)/\(command)" }
    }

    init?(agentName: String) {
        switch agentName {
        case "Claude Code", "Claude (app)": self = .claude
        case "Codex": self = .codex
        case "Gemini CLI": self = .gemini
        default: return nil
        }
    }
}

/// Tokens uit een transcript. `cacheRead` is wat de agent opnieuw uit de cache las: goedkoop, maar telt mee voor je limiet.
struct TokenTally: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
        TokenTally(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    static func += (lhs: inout TokenTally, rhs: TokenTally) { lhs = lhs + rhs }

    /// "845k", "1,2M".
    static func format(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<100_000: return String(format: "%.1fk", Double(count) / 1_000).replacingOccurrences(of: ".", with: ",")
        case ..<1_000_000: return "\(count / 1_000)k"
        default: return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        }
    }
}

/// Een afgelopen (of nog lopende) sessie, uit het transcript dat de agent zelf bewaart.
struct PastSession: Identifiable, Equatable {
    let agent: AgentKind
    var sessionID: String
    var title: String
    var cwd: String
    var branch: String
    var model: String
    var started: Date
    var ended: Date
    var prompts: Int
    var tokens: TokenTally
    var lastPrompt: String
    var lastReply: String

    var id: String { "\(agent.rawValue):\(sessionID)" }

    var project: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return cwd.isEmpty || name.isEmpty || name == "/" ? "geen map" : name
    }

    var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }

    /// Het commando om verder te gaan waar je was.
    var resumeArguments: [String] {
        switch agent {
        case .claude: return ["--resume", sessionID]
        case .codex: return ["resume", sessionID]
        case .gemini: return ["--resume", sessionID]
        }
    }
}

/// Met welk account een agent is ingelogd, uit zijn eigen instellingen.
struct AgentAccount: Equatable {
    let agent: AgentKind
    /// E-mailadres, of "API-sleutel" als er geen account is.
    var name: String
    var organization: String
    var plan: String
}

/// Hoe ver het koppelen met één klik is.
enum AgentConnectProgress: Equatable {
    case working(String)
    case waitingForLogin(String)
    case done(String)
    case failed(String)

    var text: String {
        switch self {
        case .working(let text), .waitingForLogin(let text), .done(let text), .failed(let text): return text
        }
    }

    var isBusy: Bool {
        switch self {
        case .working, .waitingForLogin: return true
        case .done, .failed: return false
        }
    }
}

/// Gebruik over een periode, voor één agent.
struct AgentUsageSummary: Equatable {
    var today = TokenTally()
    var week = TokenTally()
    var sessionsToday = 0
    var sessionsWeek = 0
    /// Tokens per dag, de laatste 7 dagen, oudste eerst.
    var perDay: [(day: Date, tokens: Int)] = []

    static func == (lhs: AgentUsageSummary, rhs: AgentUsageSummary) -> Bool {
        lhs.today == rhs.today && lhs.week == rhs.week && lhs.sessionsToday == rhs.sessionsToday
            && lhs.sessionsWeek == rhs.sessionsWeek && lhs.perDay.map { $0.tokens } == rhs.perDay.map { $0.tokens }
    }
}

/// Eerdere sessies, tokengebruik en accounts van Claude Code en Codex. Leest alleen hun eigen bestanden op deze Mac
/// (~/.claude en ~/.codex), op de achtergrond, en leest een transcript pas opnieuw als het veranderd is.
@MainActor
final class AgentHistory: ObservableObject {
    @Published private(set) var sessions: [PastSession] = []
    @Published private(set) var accounts: [AgentKind: AgentAccount] = [:]
    @Published private(set) var usage: [AgentKind: AgentUsageSummary] = [:]
    /// Welke agents op deze Mac staan (er is een ~/.claude of ~/.codex).
    @Published private(set) var installed: Set<AgentKind> = []
    /// Agents waarvan het programma op deze Mac staat.
    @Published private(set) var executables: [AgentKind: String] = [:]
    @Published private(set) var loading = false

    private let scanner = HistoryScanner()
    private var lastRefresh = Date.distantPast

    /// Ververst als het langer dan `minimumInterval` geleden is. De Agents-tab roept dit aan als hij opent.
    func refresh(minimumInterval: TimeInterval = 20) {
        guard !loading, Date().timeIntervalSince(lastRefresh) >= minimumInterval else { return }
        loading = true
        lastRefresh = Date()
        let scanner = scanner
        let ownFolder = NookPaths.supportDirectory.standardizedFileURL.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scanner.scan(excludingFolder: ownFolder)
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                if self.sessions != result.sessions { self.sessions = result.sessions }
                if self.accounts != result.accounts { self.accounts = result.accounts }
                if self.usage != result.usage { self.usage = result.usage }
                if self.installed != result.installed { self.installed = result.installed }
                if self.executables != result.executables { self.executables = result.executables }
            }
        }
    }

    func sessions(for agent: AgentKind) -> [PastSession] {
        sessions.filter { $0.agent == agent }
    }
}

// MARK: Lezen

/// Doet het leeswerk. Wordt alleen vanaf één achtergrondtaak tegelijk gebruikt (zie `AgentHistory.loading`).
private final class HistoryScanner: @unchecked Sendable {
    struct Result {
        var sessions: [PastSession]
        var accounts: [AgentKind: AgentAccount]
        var usage: [AgentKind: AgentUsageSummary]
        var installed: Set<AgentKind>
        var executables: [AgentKind: String]
    }

    /// Eén tokenregel, met een sleutel om dubbele regels over transcripten heen maar één keer te tellen.
    struct UsageEntry {
        var key: String
        var date: Date
        var tokens: TokenTally
    }

    struct Parsed {
        var session: PastSession?
        var entries: [UsageEntry]
    }

    private struct CacheKey: Equatable {
        var modified: Date
        var size: Int
    }

    private var cache: [String: (key: CacheKey, parsed: Parsed)] = [:]
    private let lock = NSLock()

    /// Zoveel dagen terug lezen we transcripten.
    private static let days = 30
    private static let maxFiles = 400

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func scan(excludingFolder ownFolder: String) -> Result {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let since = Date().addingTimeInterval(-Double(Self.days) * 86_400)
        var installed: Set<AgentKind> = []
        var files: [(url: URL, agent: AgentKind, key: CacheKey)] = []

        let claudeHome = Self.claudeHome
        if fm.fileExists(atPath: claudeHome.path) {
            installed.insert(.claude)
            files += claudeFiles(claudeHome, since: since).map { ($0.url, .claude, $0.key) }
        }
        let codexHome = CodexUsage.codexHome
        if fm.fileExists(atPath: codexHome.path) {
            installed.insert(.codex)
            files += codexFiles(codexHome, since: since).map { ($0.url, .codex, $0.key) }
        }
        files.sort { $0.key.modified > $1.key.modified }
        files = Array(files.prefix(Self.maxFiles))

        var fresh: [String: (key: CacheKey, parsed: Parsed)] = [:]
        var parsedAll: [(AgentKind, Parsed)] = []
        for file in files {
            let path = file.url.path
            let parsed: Parsed
            if let hit = cache[path], hit.key == file.key {
                parsed = hit.parsed
            } else {
                parsed = file.agent == .claude ? parseClaude(file.url) : parseCodex(file.url)
            }
            fresh[path] = (file.key, parsed)
            parsedAll.append((file.agent, parsed))
        }
        cache = fresh

        // Sessies voor de lijst: zonder de gesprekken die Nook zelf via Claude Code voert (zijn eigen map).
        let sessions = parsedAll.compactMap { $0.1.session }
            .filter { $0.prompts > 0 && $0.cwd != ownFolder }
            .sorted { $0.ended > $1.ended }

        var usage: [AgentKind: AgentUsageSummary] = [:]
        for agent in installed {
            usage[agent] = summarize(parsedAll.filter { $0.0 == agent }.map { $0.1 }, excludingFolder: ownFolder)
        }

        var accounts: [AgentKind: AgentAccount] = [:]
        if installed.contains(.claude), let account = claudeAccount() { accounts[.claude] = account }
        if installed.contains(.codex), let account = codexAccount(codexHome) { accounts[.codex] = account }
        let geminiHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
        if fm.fileExists(atPath: geminiHome.path) {
            installed.insert(.gemini)
            if let account = geminiAccount(geminiHome) { accounts[.gemini] = account }
        }

        let executables = locateExecutables()
        installed.formUnion(executables.keys)
        return Result(sessions: sessions, accounts: accounts, usage: usage, installed: installed, executables: executables)
    }

    // MARK: Programma's

    private var foundExecutables: [AgentKind: String] = [:]
    private var lastShellLookup = Date.distantPast

    /// Waar claude, codex en gemini staan. Eerst de bekende plekken; wat daar niet staat, vraagt Nook hooguit
    /// eens per minuut aan je eigen shell (voor nvm, asdf en dergelijke).
    private func locateExecutables() -> [AgentKind: String] {
        let fm = FileManager.default
        var missing: [AgentKind] = []
        for kind in AgentKind.allCases {
            if let known = foundExecutables[kind], fm.isExecutableFile(atPath: known) { continue }
            foundExecutables[kind] = nil
            if let hit = kind.executableCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
                foundExecutables[kind] = hit
            } else {
                missing.append(kind)
            }
        }
        if !missing.isEmpty, Date().timeIntervalSince(lastShellLookup) > 60 {
            lastShellLookup = Date()
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            // Elk antwoord krijgt een eigen voorvoegsel: een interactieve shell kan zelf ook iets printen.
            let script = missing.map { "printf 'NOOK-\($0.rawValue):%s\\n' \"$(command -v \($0.command) 2>/dev/null)\"" }
                .joined(separator: "; ")
            let lines = Self.run(shell, ["-ilc", script], timeout: 6)?.components(separatedBy: .newlines) ?? []
            for kind in missing {
                let prefix = "NOOK-\(kind.rawValue):"
                guard let line = lines.last(where: { $0.hasPrefix(prefix) }) else { continue }
                let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { foundExecutables[kind] = path }
            }
        }
        return foundExecutables
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        return String(data: data, encoding: .utf8)
    }

    // MARK: Gebruik

    private func summarize(_ parsed: [Parsed], excludingFolder ownFolder: String) -> AgentUsageSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var summary = AgentUsageSummary()
        var byDay: [Date: Int] = [:]
        var seen = Set<String>()

        for file in parsed {
            for entry in file.entries where entry.date >= weekStart {
                guard seen.insert(entry.key).inserted else { continue }
                let day = calendar.startOfDay(for: entry.date)
                byDay[day, default: 0] += entry.tokens.total
                summary.week += entry.tokens
                if day == today { summary.today += entry.tokens }
            }
            if let session = file.session, session.prompts > 0, session.cwd != ownFolder {
                if session.ended >= weekStart { summary.sessionsWeek += 1 }
                if session.ended >= today { summary.sessionsToday += 1 }
            }
        }
        summary.perDay = (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return (day, byDay[day] ?? 0)
        }
        return summary
    }

    // MARK: Bestanden zoeken

    static var claudeHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    private func attributes(_ url: URL) -> CacheKey? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return nil }
        return CacheKey(modified: modified, size: values.fileSize ?? 0)
    }

    /// ~/.claude/projects/<map>/<sessie>.jsonl
    private func claudeFiles(_ home: URL, since: Date) -> [(url: URL, key: CacheKey)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("projects", isDirectory: true)
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [(url: URL, key: CacheKey)] = []
        for project in projects {
            // Een map die al lang niet is aangeraakt, hoeft niet doorzocht te worden.
            if let modified = attributes(project)?.modified, modified < since { continue }
            guard let names = try? fm.contentsOfDirectory(atPath: project.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = project.appendingPathComponent(name)
                if let key = attributes(url), key.modified >= since { result.append((url, key)) }
            }
        }
        return result
    }

    /// ~/.codex/sessions/JJJJ/MM/DD/rollout-*.jsonl, alleen de mappen van de afgelopen dagen.
    private func codexFiles(_ home: URL, since: Date) -> [(url: URL, key: CacheKey)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var result: [(url: URL, key: CacheKey)] = []
        var seen = Set<String>()
        for offset in -1...Self.days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            let path = String(format: "%04d/%02d/%02d", y, m, d)
            guard seen.insert(path).inserted else { continue }
            let dir = root.appendingPathComponent(path, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                if let key = attributes(url) { result.append((url, key)) }
            }
        }
        return result
    }

    // MARK: Claude Code

    private static let claudeAssistant = Data(#""type":"assistant""#.utf8)
    private static let claudeUser = Data(#""type":"user""#.utf8)
    private static let claudeSummary = Data(#""type":"summary""#.utf8)
    private static let toolResult = Data(#""tool_result""#.utf8)

    private func parseClaude(_ url: URL) -> Parsed {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return Parsed(session: nil, entries: []) }
        var session = PastSession(
            agent: .claude, sessionID: url.deletingPathExtension().lastPathComponent,
            title: "", cwd: "", branch: "", model: "",
            started: .distantFuture, ended: .distantPast,
            prompts: 0, tokens: TokenTally(), lastPrompt: "", lastReply: ""
        )
        var summaryTitle = ""
        var entries: [UsageEntry] = []
        var seenUsage = Set<String>()

        forEachLine(data) { line in
            if line.range(of: Self.claudeSummary) != nil, summaryTitle.isEmpty,
               let object = json(line), object["type"] as? String == "summary" {
                summaryTitle = (object["summary"] as? String) ?? ""
                return
            }
            let isAssistant = line.range(of: Self.claudeAssistant) != nil
            let isUser = !isAssistant && line.range(of: Self.claudeUser) != nil && line.range(of: Self.toolResult) == nil
            guard isAssistant || isUser, let object = json(line) else { return }

            if let stamp = (object["timestamp"] as? String).flatMap({ self.date($0) }) {
                session.started = min(session.started, stamp)
                session.ended = max(session.ended, stamp)
            }
            if session.cwd.isEmpty, let cwd = object["cwd"] as? String { session.cwd = cwd }
            if let branch = object["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { session.branch = branch }
            let message = (object["message"] as? [String: Any]) ?? [:]

            if isAssistant {
                if let model = message["model"] as? String, !model.hasPrefix("<") { session.model = model }
                let text = Self.text(message["content"])
                if !text.isEmpty { session.lastReply = text }
                if let raw = message["usage"] as? [String: Any] {
                    let id = "\((message["id"] as? String) ?? ""):\((object["requestId"] as? String) ?? "")"
                    // Claude Code schrijft per antwoord een regel per blok, elk met hetzelfde gebruik.
                    guard id == ":" || seenUsage.insert(id).inserted else { return }
                    let tokens = TokenTally(
                        input: Self.int(raw["input_tokens"]),
                        output: Self.int(raw["output_tokens"]),
                        cacheRead: Self.int(raw["cache_read_input_tokens"]),
                        cacheWrite: Self.int(raw["cache_creation_input_tokens"])
                    )
                    session.tokens += tokens
                    let when = (object["timestamp"] as? String).flatMap({ self.date($0) }) ?? session.ended
                    entries.append(UsageEntry(key: id == ":" ? UUID().uuidString : id, date: when, tokens: tokens))
                }
            } else {
                if (object["isMeta"] as? Bool) == true || (object["isSidechain"] as? Bool) == true { return }
                let text = Self.text(message["content"])
                guard Self.isTypedPrompt(text) else { return }
                session.prompts += 1
                session.lastPrompt = text
                if session.title.isEmpty { session.title = text }
            }
        }

        guard session.ended > .distantPast else { return Parsed(session: nil, entries: entries) }
        if !summaryTitle.isEmpty { session.title = summaryTitle }
        session.title = Self.oneLine(session.title, 90)
        session.lastPrompt = Self.clip(session.lastPrompt, 600)
        session.lastReply = Self.clip(session.lastReply, 1_200)
        return Parsed(session: session, entries: entries)
    }

    /// Wat je zelf typte, niet wat Claude Code zelf toevoegt (opdrachten, uitvoer, onderbrekingen).
    private static func isTypedPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for prefix in ["<command-", "<local-command", "<system-reminder", "<bash-", "<user-memory", "Caveat:", "[Request interrupted"]
        where trimmed.hasPrefix(prefix) { return false }
        return true
    }

    /// ~/.claude.json: met welk account Claude Code is ingelogd.
    private func claudeAccount() -> AgentAccount? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [home.appendingPathComponent(".claude.json"), Self.claudeHome.appendingPathComponent(".config.json")]
        if ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil {
            candidates.insert(Self.claudeHome.appendingPathComponent(".claude.json"), at: 0)
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let oauth = root["oauthAccount"] as? [String: Any] {
                let email = (oauth["emailAddress"] as? String) ?? (oauth["displayName"] as? String) ?? "Claude-account"
                let org = (oauth["organizationName"] as? String) ?? ""
                // Een organisatie die gewoon "<email>'s Organization" heet, zegt niets extra's.
                let cleanOrg = org.contains(email) || org.hasSuffix("'s Organization") ? "" : org
                return AgentAccount(agent: .claude, name: email, organization: cleanOrg, plan: Self.claudePlan(oauth))
            }
            if root["primaryApiKey"] != nil {
                return AgentAccount(agent: .claude, name: "API-sleutel", organization: "", plan: "")
            }
        }
        return nil
    }

    private static func claudePlan(_ oauth: [String: Any]) -> String {
        for key in ["subscriptionType", "planType", "rateLimitTier"] {
            if let value = oauth[key] as? String, !value.isEmpty { return planName(value) }
        }
        return ""
    }

    // MARK: Codex

    private func parseCodex(_ url: URL) -> Parsed {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return Parsed(session: nil, entries: []) }
        // rollout-2026-10-14T10-12-33-<uuid>.jsonl: de uuid is wat `codex resume` wil.
        let base = url.deletingPathExtension().lastPathComponent
        let fallbackID = base.count > 36 ? String(base.suffix(36)) : base
        var session = PastSession(
            agent: .codex, sessionID: fallbackID,
            title: "", cwd: "", branch: "", model: "",
            started: .distantFuture, ended: .distantPast,
            prompts: 0, tokens: TokenTally(), lastPrompt: "", lastReply: ""
        )
        var entries: [UsageEntry] = []
        var previous = TokenTally()
        let markers = ["session_meta", "turn_context", "user_message", "agent_message", "token_count"].map { Data($0.utf8) }

        forEachLine(data) { line in
            guard markers.contains(where: { line.range(of: $0) != nil }), let object = json(line) else { return }
            let when = (object["timestamp"] as? String).flatMap({ self.date($0) })
            if let when {
                session.started = min(session.started, when)
                session.ended = max(session.ended, when)
            }
            let payload = (object["payload"] as? [String: Any]) ?? [:]
            switch object["type"] as? String {
            case "session_meta":
                if let id = payload["id"] as? String, !id.isEmpty { session.sessionID = id }
                if let cwd = payload["cwd"] as? String { session.cwd = cwd }
                if let git = payload["git"] as? [String: Any], let branch = git["branch"] as? String { session.branch = branch }
            case "turn_context":
                if let model = payload["model"] as? String { session.model = model }
                if session.cwd.isEmpty, let cwd = payload["cwd"] as? String { session.cwd = cwd }
            case "event_msg":
                switch payload["type"] as? String {
                case "user_message":
                    let text = (payload["message"] as? String) ?? ""
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    session.prompts += 1
                    session.lastPrompt = text
                    if session.title.isEmpty { session.title = text }
                case "agent_message":
                    if let text = payload["message"] as? String, !text.isEmpty { session.lastReply = text }
                case "token_count":
                    // Het totaal van de sessie tot nu toe; het verschil met de vorige regel is wat erbij kwam.
                    guard let info = payload["info"] as? [String: Any],
                          let total = info["total_token_usage"] as? [String: Any] else { return }
                    let cached = Self.int(total["cached_input_tokens"])
                    let current = TokenTally(
                        input: max(0, Self.int(total["input_tokens"]) - cached),
                        output: Self.int(total["output_tokens"]),
                        cacheRead: cached,
                        cacheWrite: 0
                    )
                    guard current.total > previous.total else { return }
                    let delta = TokenTally(
                        input: max(0, current.input - previous.input),
                        output: max(0, current.output - previous.output),
                        cacheRead: max(0, current.cacheRead - previous.cacheRead)
                    )
                    previous = current
                    session.tokens = current
                    entries.append(UsageEntry(key: "\(session.sessionID):\(current.total)", date: when ?? session.ended, tokens: delta))
                default:
                    break
                }
            default:
                break
            }
        }

        guard session.ended > .distantPast else { return Parsed(session: nil, entries: entries) }
        session.title = Self.oneLine(session.title, 90)
        session.lastPrompt = Self.clip(session.lastPrompt, 600)
        session.lastReply = Self.clip(session.lastReply, 1_200)
        return Parsed(session: session, entries: entries)
    }

    /// ~/.codex/auth.json: ingelogd met ChatGPT (e-mail en abonnement staan in het id-token) of met een API-sleutel.
    private func codexAccount(_ home: URL) -> AgentAccount? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let tokens = root["tokens"] as? [String: Any], let idToken = tokens["id_token"] as? String,
           let claims = Self.jwtClaims(idToken) {
            let auth = (claims["https://api.openai.com/auth"] as? [String: Any]) ?? [:]
            let plan = (auth["chatgpt_plan_type"] as? String).map(Self.planName) ?? ""
            return AgentAccount(agent: .codex, name: (claims["email"] as? String) ?? "ChatGPT-account", organization: "", plan: plan)
        }
        if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return AgentAccount(agent: .codex, name: "API-sleutel", organization: "", plan: "")
        }
        return nil
    }

    // MARK: Gemini CLI

    /// ~/.gemini/google_accounts.json (actief Google-account) en settings.json (hoe je bent ingelogd).
    private func geminiAccount(_ home: URL) -> AgentAccount? {
        let settings = (try? Data(contentsOf: home.appendingPathComponent("settings.json")))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let auth = (((settings["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String)
            ?? (settings["selectedAuthType"] as? String) ?? ""
        let accounts = (try? Data(contentsOf: home.appendingPathComponent("google_accounts.json")))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        if let email = accounts["active"] as? String, !email.isEmpty {
            return AgentAccount(agent: .gemini, name: email, organization: "", plan: auth == "vertex-ai" ? "Vertex AI" : "Google-account")
        }
        switch auth {
        case "gemini-api-key": return AgentAccount(agent: .gemini, name: "API-sleutel", organization: "", plan: "")
        case "vertex-ai": return AgentAccount(agent: .gemini, name: "Vertex AI", organization: "", plan: "")
        default: return nil
        }
    }

    /// Alleen het middelste deel van een JWT: de gegevens. Niets wordt gecontroleerd of verstuurd.
    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Hulpjes

    private func forEachLine(_ data: Data, _ body: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start { body(data[start..<end]) }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
    }

    private func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private func date(_ string: String) -> Date? {
        iso.date(from: string) ?? isoPlain.date(from: string)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// Tekst uit een bericht: een string, of de tekstblokken uit een lijst.
    private static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    private static func oneLine(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    /// "max" → "Max", "claude_max_20x" → "Max 20x", "plus" → "Plus".
    static func planName(_ raw: String) -> String {
        let words = raw.lowercased()
            .replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
        return words.map { word in word.prefix(1).uppercased() + word.dropFirst() }.joined(separator: " ")
    }
}
