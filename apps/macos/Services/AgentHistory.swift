import Foundation
import SwiftUI
import SQLite3

/// Which agent a past session or account belongs to. Nook reads the sessions of Claude Code, Codex, Gemini CLI and
/// Antigravity from disk; OpenCode, Cursor and Grok it runs over ACP and knows by their login.
enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case claude, codex, gemini, antigravity, opencode, cursor, grok, acp

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .acp: return "ACP"
        }
    }

    /// The terminal command.
    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .antigravity: return "agy"
        case .opencode: return "opencode"
        case .cursor: return "cursor-agent"
        case .grok: return "grok"
        // Each ACP agent has its own command (see CustomAgents); they start through your login shell.
        case .acp: return "npx"
        }
    }

    /// Short label, for buttons or headers.
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .acp: return "ACP"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(hex: 0xE08A5E)
        case .codex: return Color(hex: 0x6FCFB3)
        case .gemini: return Color(hex: 0x8AB4F8)
        case .antigravity: return Color(hex: 0xEA4335)
        case .opencode: return Color(hex: 0xF5A742)
        case .cursor: return Color(hex: 0x9AA4B2)
        case .grok: return Color(hex: 0xD9D9DE)
        case .acp: return Color(hex: 0xB59CF5)
        }
    }

    /// The integration in Settings › Agents that brings progress and permissions to the notch (Grok has none).
    var hookTarget: AgentConfigInstaller.Target? {
        switch self {
        case .claude: return .claudeHooks
        case .codex: return .codex
        case .gemini: return .gemini
        case .antigravity: return .antigravity
        case .opencode: return .openCode
        case .cursor: return .cursor
        case .grok, .acp: return nil
        }
    }

    /// Everything Nook connects for this agent with one click.
    var targets: [AgentConfigInstaller.Target] {
        switch self {
        case .claude: return [.claudeHooks, .claudeStatusLine]
        case .codex: return [.codex]
        case .gemini: return [.gemini]
        case .antigravity: return [.antigravity]
        case .opencode: return [.openCode]
        case .cursor: return [.cursor]
        case .grok, .acp: return []
        }
    }

    /// How to install the agent if it is not present yet.
    var installCommand: String {
        switch self {
        case .claude:
            return #"curl -fsSL https://claude.ai/install.sh | bash && export PATH="$HOME/.local/bin:$PATH""#
        case .codex:
            return "if command -v npm >/dev/null 2>&1; then npm install -g @openai/codex; else brew install --cask codex; fi"
        case .gemini:
            return "if command -v npm >/dev/null 2>&1; then npm install -g @google/gemini-cli; else brew install gemini-cli; fi"
        case .antigravity:
            return "brew install --cask antigravity"
        case .opencode:
            return "curl -fsSL https://opencode.ai/install | bash"
        case .cursor:
            return "curl https://cursor.com/install -fsS | bash"
        case .grok:
            return "npm install -g @xai-official/grok"
        // Registry agents run with npx or uvx, which come with Node.js and uv.
        case .acp:
            return "brew install node uv"
        }
    }

    /// Log in command. Claude Code and Gemini CLI prompt automatically on first launch; Codex has a dedicated command.
    var loginCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex login"
        case .gemini: return "gemini"
        case .antigravity: return "agy"
        case .opencode: return "opencode auth login"
        case .cursor: return "cursor-agent login"
        case .grok: return "grok"
        // ACP agents sign in themselves during the first session.
        case .acp: return ""
        }
    }

    /// Candidate paths for the agent, in addition to what your shell finds.
    var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/Library/pnpm"]
        if self == .claude { paths.insert("\(home)/.claude/local", at: 0) }
        if self == .opencode { paths.insert("\(home)/.opencode/bin", at: 0) }
        if self == .antigravity {
            paths.insert("\(home)/.gemini/antigravity/bin", at: 0)
            paths.insert("\(home)/.antigravity/antigravity/bin", at: 0)
            paths.insert("/Applications/Antigravity.app/Contents/Resources/app/bin", at: 0)
        }
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        return paths.map { "\($0)/\(command)" }
    }

    /// The default directory of the agent where the primary account resides.
    var defaultHome: URL {
        switch self {
        case .claude: return HistoryScanner.claudeHome
        case .codex: return CodexUsage.codexHome
        case .gemini, .antigravity: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
        case .opencode: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode", isDirectory: true)
        case .cursor: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor", isDirectory: true)
        case .grok: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
        case .acp: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nook/acp", isDirectory: true)
        }
    }

    init?(agentName: String) {
        switch agentName {
        case "Claude Code", "Claude (app)": self = .claude
        case "Codex": self = .codex
        case "Gemini CLI": self = .gemini
        case "Antigravity": self = .antigravity
        case "OpenCode": self = .opencode
        case "Cursor": self = .cursor
        case "Grok", "Grok Build": self = .grok
        default: return nil
        }
    }
}

/// Tokens from a transcript. `cacheRead` represents cached reads: cheap, but still counted against rate limits.
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

    /// "845k", "1.2M".
    static func format(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<100_000: return String(format: "%.1fk", Double(count) / 1_000).replacingOccurrences(of: ".", with: ",")
        case ..<1_000_000: return "\(count / 1_000)k"
        default: return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        }
    }
}

/// A completed (or still running) session, from the transcript saved by the agent itself.
struct PastSession: Identifiable, Equatable {
    let agent: AgentKind
    var sessionID: String
    var title: String
    var cwd: String
    /// The folder the session was last working in (after a `cd`); empty when it never left `cwd`.
    var lastCwd = ""
    var branch: String
    var model: String
    var started: Date
    var ended: Date
    var prompts: Int
    var tokens: TokenTally
    var lastPrompt: String
    var lastReply: String
    /// Which account (`AgentProfile.id`) this session ran with.
    var profileID = ""
    /// The transcript file the session was read from.
    var path = ""
    /// A session in Anthropic's cloud (started in the Claude app or on claude.ai): no transcript or folder on this Mac.
    var cloud: CloudSession?
    /// The ids of earlier transcripts of this same conversation (it was resumed into a new file); `sessionID` is the latest.
    var earlierIDs: [String] = []

    /// Whether `id` names this conversation: its latest session id or an earlier one.
    func isConversation(_ id: String) -> Bool { sessionID == id || earlierIDs.contains(id) }

    var id: String { "\(agent.rawValue):\(sessionID)" }

    var project: String {
        if let cloud { return cloud.repository.isEmpty ? "cloud" : URL(fileURLWithPath: cloud.repository).lastPathComponent }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return cwd.isEmpty || name.isEmpty || name == "/" ? "no folder" : name
    }

    /// Where to continue: the folder the session ended in, unless that is gone or off limits (then the one it started in).
    /// Nook never runs an agent in the home folder, so a session that began there continues in the project it moved to.
    var resumeFolder: String {
        for candidate in [lastCwd, cwd] where !candidate.isEmpty {
            if WorkspacePathPolicy.verdict(for: candidate) == .ok { return candidate }
        }
        return cwd
    }

    var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }

    /// The command to resume where you left off.
    var resumeArguments: [String] {
        switch agent {
        case .claude: return ["--resume", sessionID]
        case .codex: return ["resume", sessionID]
        case .gemini: return ["--resume", sessionID]
        case .antigravity: return ["--resume", sessionID]
        case .opencode: return ["--session", sessionID]
        case .cursor, .grok: return ["--resume", sessionID]
        // ACP agents load their sessions over the protocol (session/load), not from the command line.
        case .acp: return []
        }
    }
}

/// Which account an agent is logged in with, from its own configuration.
struct AgentAccount: Equatable {
    let agent: AgentKind
    /// Email address, or "API key" if there is no account.
    var name: String
    var organization: String
    var plan: String
}

/// Progress of one-click connecting.
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

/// Usage over a period of time, for a single agent.
struct AgentUsageSummary: Equatable {
    var today = TokenTally()
    var week = TokenTally()
    var sessionsToday = 0
    var sessionsWeek = 0
    /// Tokens per day for the last 7 days, oldest first.
    var perDay: [(day: Date, tokens: Int)] = []

    static func == (lhs: AgentUsageSummary, rhs: AgentUsageSummary) -> Bool {
        lhs.today == rhs.today && lhs.week == rhs.week && lhs.sessionsToday == rhs.sessionsToday
            && lhs.sessionsWeek == rhs.sessionsWeek && lhs.perDay.map { $0.tokens } == rhs.perDay.map { $0.tokens }
    }
}

/// Past sessions, token usage, and accounts from Claude Code and Codex. Only reads their own files on this Mac
/// (~/.claude and ~/.codex) in the background, re-reading a transcript only when it has changed.
@MainActor
final class AgentHistory: ObservableObject {
    @Published private(set) var sessions: [PastSession] = []
    /// Per account (`AgentProfile.id`): who is logged in.
    @Published private(set) var profileAccounts: [String: AgentAccount] = [:]
    /// Per account: tokens and sessions for today and this week.
    @Published private(set) var profileUsage: [String: AgentUsageSummary] = [:]
    /// Which agents are installed on this Mac (presence of ~/.claude or ~/.codex).
    @Published private(set) var installed: Set<AgentKind> = []
    /// Agents whose executable exists on this Mac.
    @Published private(set) var executables: [AgentKind: String] = [:]
    @Published private(set) var loading = false
    /// Per Claude account (`AgentProfile.id`): why its cloud sessions could not be read the last time; absent when they could.
    @Published private(set) var cloudProblems: [String: CloudSessionProblem] = [:]

    /// Which accounts Nook reads; AppModel keeps this in sync with `AgentProfileStore`.
    var profiles: [AgentProfile] = AgentKind.allCases.map(AgentProfile.defaultProfile)

    private let scanner = HistoryScanner()
    private var lastRefresh = Date.distantPast

    /// The default account for each agent (the standard directory, as used by `claude` in the terminal).
    var accounts: [AgentKind: AgentAccount] {
        var result: [AgentKind: AgentAccount] = [:]
        for kind in AgentKind.allCases { result[kind] = profileAccounts[kind.rawValue] }
        return result
    }

    /// Refreshes if more than `minimumInterval` has elapsed. Called by the Agents tab when opened.
    func refresh(minimumInterval: TimeInterval = 20) {
        refreshCloud(minimumInterval: max(minimumInterval, Self.cloudInterval))
        guard !loading, Date().timeIntervalSince(lastRefresh) >= minimumInterval else { return }
        loading = true
        lastRefresh = Date()
        let scanner = scanner
        let ownFolder = NookPaths.supportDirectory.standardizedFileURL.path
        let homes = profiles.map { profile in
            ProfileHome(id: profile.id, kind: profile.kind, url: profile.homeURL, isDefault: profile.isDefault,
                        apiKey: profile.kind == .claude && profile.usesAPIKey && !(Keychain.read(profile.keychainAccount) ?? "").isEmpty)
        }
        // Accounts first: the full scan below can take seconds, but who is logged in is known almost instantly.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let quick = scanner.quickScan(homes)
            Task { @MainActor in
                guard let self else { return }
                if self.profileAccounts != quick.accounts { self.profileAccounts = quick.accounts }
                for (kind, path) in quick.executables where self.executables[kind] == nil { self.executables[kind] = path }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scanner.scan(homes, excludingFolder: ownFolder)
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                self.localSessions = result.sessions
                self.publishSessions()
                if self.profileAccounts != result.accounts { self.profileAccounts = result.accounts }
                if self.profileUsage != result.usage { self.profileUsage = result.usage }
                if self.installed != result.installed { self.installed = result.installed }
                if self.executables != result.executables { self.executables = result.executables }
            }
        }
    }

    // MARK: Cloud

    private var localSessions: [PastSession] = []
    /// Per account (`AgentProfile.id`): its sessions in Anthropic's cloud.
    private var cloudSessions: [String: [PastSession]] = [:]
    private var lastCloudRefresh = Date.distantPast
    private var cloudLoading = false
    /// The cloud list is a network request: at most this often, also when the local scan runs more often.
    private static let cloudInterval: TimeInterval = 60

    private func publishSessions() {
        // Two accounts signed in to the same organization see the same cloud sessions: list each once.
        var seen = Set<String>()
        let cloud = cloudSessions.keys.sorted().flatMap { cloudSessions[$0] ?? [] }.filter { seen.insert($0.id).inserted }
        let all = (localSessions + cloud).sorted { $0.ended > $1.ended }
        if sessions != all { sessions = all }
    }

    /// Sessions of every Claude subscription account that run in the cloud: started in the Claude app (desktop or phone)
    /// or on claude.ai/code. They are read with the account's own login, like the usage limits (`ClaudeUsage`).
    private func refreshCloud(minimumInterval: TimeInterval) {
        guard !cloudLoading, Date().timeIntervalSince(lastCloudRefresh) >= minimumInterval else { return }
        let accounts = profiles.filter { $0.kind == .claude && !$0.usesAPIKey }
            .map { (id: $0.id, home: $0.homeURL, isDefault: $0.isDefault) }
        guard !accounts.isEmpty else { return }
        cloudLoading = true
        lastCloudRefresh = Date()
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: [PastSession]] = [:]
            var problems: [String: CloudSessionProblem] = [:]
            for account in accounts {
                switch CloudSessionFetch.sessions(home: account.home, isDefault: account.isDefault) {
                case .success(let list): found[account.id] = list.map { CloudSessionFetch.pastSession($0, profileID: account.id) }
                case .failure(let problem): problems[account.id] = problem
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.cloudLoading = false
                // An account that could not be read (offline, token just expired) keeps what it had, so rows don't flicker away.
                for (id, list) in found { self.cloudSessions[id] = list }
                for id in self.cloudSessions.keys where !accounts.contains(where: { $0.id == id }) { self.cloudSessions[id] = nil }
                if self.cloudProblems != problems { self.cloudProblems = problems }
                self.publishSessions()
            }
        }
    }

    func sessions(for agent: AgentKind) -> [PastSession] {
        sessions.filter { $0.agent == agent }
    }

    func sessions(for profile: AgentProfile) -> [PastSession] {
        sessions.filter { $0.profileID == profile.id }
    }
}

/// An account as needed by the scanner: which directory, for which agent.
struct ProfileHome: Sendable {
    var id: String
    var kind: AgentKind
    var url: URL
    var isDefault: Bool
    /// This account logs in using an API key from Nook's Keychain (Claude Code).
    var apiKey = false
}

// MARK: Cloud sessions

/// Reads an account's cloud sessions from Anthropic, with the login Claude Code keeps for it. Read-only; the token is used
/// only for this request and never stored or logged.
enum CloudSessionFetch {
    /// How far back cloud sessions are listed, like the transcripts on this Mac.
    static let days = 30

    /// The account's recent cloud sessions, or why they could not be read.
    static func sessions(home: URL, isDefault: Bool) -> Result<[CloudSession], CloudSessionProblem> {
        let token: String
        switch ClaudeUsage.login(home: home, isDefault: isDefault) {
        case .valid(let value): token = value
        case .expired: return .failure(.loginExpired)
        case .missing: return .failure(.notSignedIn)
        }
        // Claude Code keeps the organization in its account file; without it, ask Anthropic who is signed in, like Claude Code does.
        var org = ClaudeCloudSessions.organizationID(configHome: home, isDefault: isDefault)
        if org == nil, case (200, let data?) = get(ClaudeCloudSessions.profileEndpoint, token: token, beta: "oauth-2025-04-20") {
            org = ClaudeCloudSessions.organization(fromProfile: data)
        }
        var (status, payload) = get(ClaudeCloudSessions.endpoint, token: token, beta: ClaudeCloudSessions.beta, org: org)
        // Earlier Claude Code versions list sessions without a beta header: should Anthropic stop accepting this one, ask that way.
        if status == 400 || status == 404 {
            (status, payload) = get(ClaudeCloudSessions.endpoint, token: token, beta: nil, org: org)
        }
        guard status == 200, let payload else {
            Log.agents.error("Cloud sessions: HTTP \(status, privacy: .public)")
            if status == 401 { return .failure(.loginExpired) }
            return .failure(status == 0 ? .unreachable : .refused(status))
        }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        return .success(ClaudeCloudSessions.parse(payload).filter { $0.isActive || $0.updated >= since })
    }

    /// A read-only request with the account's login; the status is 0 without an answer.
    private static func get(_ url: URL, token: String, beta: String?, org: String? = nil) -> (Int, Data?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        if let org { request.setValue(org, forHTTPHeaderField: "x-organization-uuid") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 20) == .success else { return (0, nil) }
        return (status, payload)
    }

    static func pastSession(_ cloud: CloudSession, profileID: String) -> PastSession {
        var session = PastSession(
            agent: .claude, sessionID: cloud.id,
            title: cloud.title.isEmpty ? cloud.repository : cloud.title,
            cwd: "", branch: cloud.branch, model: cloud.model,
            started: cloud.created, ended: cloud.updated,
            prompts: 0, tokens: TokenTally(), lastPrompt: "", lastReply: ""
        )
        session.profileID = profileID
        session.cloud = cloud
        return session
    }
}

// MARK: Reading

/// Performs file scanning and parsing. Used only from one background task at a time (see `AgentHistory.loading`).
private final class HistoryScanner: @unchecked Sendable {
    struct Result {
        var sessions: [PastSession]
        var accounts: [String: AgentAccount]
        var usage: [String: AgentUsageSummary]
        var installed: Set<AgentKind>
        var executables: [AgentKind: String]
    }

    /// A single token entry, with a key to deduplicate entries across transcripts.
    struct UsageEntry {
        var key: String
        var date: Date
        var tokens: TokenTally
    }

    struct Parsed {
        var session: PastSession?
        var entries: [UsageEntry]
        /// What ties this transcript to the other files of the same conversation (`ResumedConversations`).
        var links: Set<String> = []
    }

    private struct CacheKey: Equatable {
        var modified: Date
        var size: Int
    }

    private var cache: [String: (key: CacheKey, parsed: Parsed)] = [:]
    private let lock = NSLock()

    /// How many days back to read transcripts.
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

    func scan(_ homes: [ProfileHome], excludingFolder ownFolder: String) -> Result {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let since = Date().addingTimeInterval(-Double(Self.days) * 86_400)
        var installed: Set<AgentKind> = []
        var files: [(url: URL, agent: AgentKind, profile: String, key: CacheKey)] = []
        var seenFolders = Set<String>()

        for home in homes {
            // Two accounts with the same directory: read only once.
            guard fm.fileExists(atPath: home.url.path), seenFolders.insert(home.url.standardizedFileURL.path).inserted else { continue }
            installed.insert(home.kind)
            let found: [(url: URL, key: CacheKey)]
            switch home.kind {
            case .claude: found = claudeFiles(home.url, since: since)
            case .codex: found = codexFiles(home.url, since: since)
            case .gemini: found = geminiFiles(home.url, since: since)
            case .antigravity: found = antigravityFiles(home.url, since: since)
            // Run over ACP: their history comes from the agent itself (session/load), not from files.
            case .opencode, .cursor, .grok, .acp: found = []
            }
            files += found.map { ($0.url, home.kind, home.id, $0.key) }
        }
        files.sort { $0.key.modified > $1.key.modified }
        files = Array(files.prefix(Self.maxFiles))

        let antigravitySummaries = readAntigravitySummaries(homes)
        var fresh: [String: (key: CacheKey, parsed: Parsed)] = [:]
        var parsedAll: [(profile: String, parsed: Parsed)] = []
        for file in files {
            let path = file.url.path
            var parsed: Parsed
            if let hit = cache[path], hit.key == file.key {
                parsed = hit.parsed
            } else {
                switch file.agent {
                case .claude: parsed = parseClaude(file.url, key: file.key)
                case .codex: parsed = parseCodex(file.url, key: file.key)
                case .gemini: parsed = parseGemini(file.url)
                case .antigravity: parsed = parseAntigravity(file.url, summaries: antigravitySummaries)
                case .opencode, .cursor, .grok, .acp: parsed = Parsed(session: nil, entries: [])
                }
            }
            parsed.session?.profileID = file.profile
            parsed.session?.path = file.url.path
            fresh[path] = (file.key, parsed)
            parsedAll.append((file.profile, parsed))
        }
        cache = fresh
        claudeProgress = claudeProgress.filter { fresh[$0.key] != nil }
        codexProgress = codexProgress.filter { fresh[$0.key] != nil }

        // Sessions for the list: excluding conversations Nook itself runs via Claude Code (its own directory).
        let listed = parsedAll.compactMap { entry in entry.parsed.session.map { (session: $0, links: entry.parsed.links) } }
            .filter { $0.session.prompts > 0 && $0.session.cwd != ownFolder }
            .sorted { $0.session.ended > $1.session.ended }
        let sessions = Self.joinResumed(listed)

        var usage: [String: AgentUsageSummary] = [:]
        for home in homes where fm.fileExists(atPath: home.url.path) {
            usage[home.id] = summarize(parsedAll.filter { $0.profile == home.id }.map { $0.parsed }, excludingFolder: ownFolder)
        }
        let accounts = readAccounts(homes)
        for kind in [AgentKind.gemini, .antigravity] where homes.contains(where: { $0.kind == kind && fm.fileExists(atPath: $0.url.path) }) { installed.insert(kind) }

        let executables = locateExecutables()
        installed.formUnion(executables.keys)
        return Result(sessions: sessions, accounts: accounts, usage: usage, installed: installed, executables: executables)
    }

    /// One session per conversation: the transcripts of a chat that was resumed into new files become one, under the
    /// latest file (newest first in `listed`), with when the chat began and how it was named.
    private static func joinResumed(_ listed: [(session: PastSession, links: Set<String>)]) -> [PastSession] {
        let transcripts = listed.map { item in
            // Only files of the same agent and account can be one conversation.
            ResumedConversations.Transcript(
                links: Set(item.links.map { "\(item.session.agent.rawValue)|\(item.session.profileID)|\($0)" })
            )
        }
        return ResumedConversations.groups(transcripts).map { group in
            var latest = listed[group[0]].session
            guard group.count > 1 else { return latest }
            let parts = group.map { listed[$0].session }
            let first = parts.min { $0.started < $1.started } ?? latest
            latest.started = first.started
            if !first.title.isEmpty { latest.title = first.title }
            latest.prompts = parts.map(\.prompts).max() ?? latest.prompts
            latest.earlierIDs = parts.dropFirst().map(\.sessionID).filter { $0 != latest.sessionID }
            return latest
        }
    }

    /// Who is logged in per account. Only reads small config files, so it is fast.
    private func readAccounts(_ homes: [ProfileHome]) -> [String: AgentAccount] {
        var accounts: [String: AgentAccount] = [:]
        for home in homes where FileManager.default.fileExists(atPath: home.url.path) {
            switch home.kind {
            case .claude:
                if home.apiKey {
                    // An API key takes precedence, even if an old login remains in the directory.
                    accounts[home.id] = AgentAccount(agent: .claude, name: "API-sleutel", organization: "", plan: "API")
                } else if let account = claudeAccount(home.url, isDefault: home.isDefault) {
                    accounts[home.id] = account
                }
            case .codex:
                if let account = codexAccount(home.url) { accounts[home.id] = account }
            case .gemini:
                if let account = geminiAccount(home.url) { accounts[home.id] = account }
            case .antigravity:
                if let account = antigravityAccount(home.url) { accounts[home.id] = account }
            case .opencode, .cursor, .grok:
                if let account = acpAgentAccount(home.kind, home.url) { accounts[home.id] = account }
            case .acp:
                // An ACP agent you added: its account is there as long as the agent is configured.
                if let agent = CustomAgents.agent(for: home.id) {
                    accounts[home.id] = AgentAccount(agent: .acp, name: agent.name, organization: "", plan: "ACP")
                }
            }
        }
        return accounts
    }

    /// OpenCode, Cursor and Grok: signed in when their login file is there (with the email when it names one).
    private func acpAgentAccount(_ kind: AgentKind, _ home: URL) -> AgentAccount? {
        let file: URL
        switch kind {
        case .opencode: file = home.appendingPathComponent("auth.json")
        case .cursor: file = home.appendingPathComponent("cli-config.json")
        default: file = home.appendingPathComponent("auth.json")
        }
        guard let data = try? Data(contentsOf: file) else {
            // Grok keeps its login elsewhere in its folder: the folder itself means it was set up.
            return kind == .grok ? AgentAccount(agent: kind, name: kind.name, organization: "", plan: "") : nil
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if kind == .cursor {
            let auth = object["authInfo"] as? [String: Any]
            guard let auth else { return nil }
            return AgentAccount(agent: kind, name: (auth["email"] as? String) ?? kind.name, organization: "", plan: "")
        }
        if kind == .opencode {
            // auth.json lists the providers you signed in to ("anthropic", "openai", …).
            let providers = object.keys.sorted()
            guard !providers.isEmpty else { return nil }
            return AgentAccount(agent: kind, name: providers.joined(separator: ", "), organization: "", plan: "")
        }
        let email = (object["email"] as? String) ?? ((object["user"] as? [String: Any])?["email"] as? String)
        return AgentAccount(agent: kind, name: email ?? kind.name, organization: "", plan: "")
    }

    /// Fast first pass for the Accounts view: logins and executables at known locations, without reading transcripts
    /// or consulting the user's shell.
    func quickScan(_ homes: [ProfileHome]) -> (accounts: [String: AgentAccount], executables: [AgentKind: String]) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var found = foundExecutables
        for kind in AgentKind.allCases where found[kind] == nil && kind != .acp {
            if let hit = kind.executableCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) { found[kind] = hit }
        }
        found[.acp] = Self.acpLauncher()
        return (readAccounts(homes), found)
    }

    // MARK: Executables

    private var foundExecutables: [AgentKind: String] = [:]
    private var lastShellLookup = Date.distantPast

    /// Where claude, codex, and gemini are located. First checks known locations; for anything missing, Nook
    /// queries the user's shell at most once per minute (for nvm, asdf, etc.).
    private func locateExecutables() -> [AgentKind: String] {
        let fm = FileManager.default
        var missing: [AgentKind] = []
        for kind in AgentKind.allCases {
            if kind == .acp {
                foundExecutables[.acp] = Self.acpLauncher()
                continue
            }
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
            // Each response receives its own prefix: an interactive shell may output extraneous text.
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

    /// ACP agents you added start through your login shell (see CustomAgents): that is their program, once there is one.
    static func acpLauncher() -> String? {
        guard !CustomAgents.load().isEmpty else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
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

    // MARK: Usage

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

    // MARK: File Discovery

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

    /// ~/.claude/projects/<dir>/<session>.jsonl
    private func claudeFiles(_ home: URL, since: Date) -> [(url: URL, key: CacheKey)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("projects", isDirectory: true)
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [(url: URL, key: CacheKey)] = []
        for project in projects {
            // A directory that hasn't been modified recently does not need to be searched.
            if let modified = attributes(project)?.modified, modified < since { continue }
            guard let names = try? fm.contentsOfDirectory(atPath: project.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = project.appendingPathComponent(name)
                if let key = attributes(url), key.modified >= since { result.append((url, key)) }
            }
        }
        return result
    }

    /// ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, only directories from recent days.
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

    // MARK: Gemini CLI

    /// ~/.gemini/tmp/<project>/chats/session-*.json
    private func geminiFiles(_ home: URL, since: Date) -> [(url: URL, key: CacheKey)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("tmp", isDirectory: true)
        guard let projects = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [(url: URL, key: CacheKey)] = []
        for project in projects {
            let chats = root.appendingPathComponent(project, isDirectory: true).appendingPathComponent("chats", isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: chats.path) else { continue }
            for name in names where name.hasSuffix(".json") {
                let url = chats.appendingPathComponent(name)
                if let key = attributes(url), key.modified >= since { result.append((url, key)) }
            }
        }
        return result
    }

    private func parseGemini(_ url: URL) -> Parsed {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return Parsed(session: nil, entries: []) }
        // The folder is not in the chat file; newer versions keep it next to the chats in `.project_root`.
        let projectRoot = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".project_root")
        let cwd = (try? String(contentsOf: projectRoot, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modified = attributes(url)?.modified ?? Date()
        var session = PastSession(
            agent: .gemini, sessionID: (root["sessionId"] as? String) ?? url.deletingPathExtension().lastPathComponent,
            title: "", cwd: cwd, branch: "", model: "",
            started: (root["startTime"] as? String).flatMap { date($0) } ?? modified,
            ended: (root["lastUpdated"] as? String).flatMap { date($0) } ?? modified,
            prompts: 0, tokens: TokenTally(), lastPrompt: "", lastReply: ""
        )
        var entries: [UsageEntry] = []
        for message in messages {
            let text = Self.geminiText(message["content"])
            switch message["type"] as? String {
            case "user":
                guard !text.isEmpty else { continue }
                session.prompts += 1
                session.lastPrompt = text
                if session.title.isEmpty { session.title = text }
            case "gemini":
                if !text.isEmpty { session.lastReply = text }
                if let model = message["model"] as? String, !model.isEmpty { session.model = model }
                if let raw = message["tokens"] as? [String: Any] {
                    // Gemini counts cached tokens inside its input; keep them apart like the other agents do.
                    let cached = Self.int(raw["cached"])
                    let tally = TokenTally(input: max(0, Self.int(raw["input"]) - cached),
                                           output: Self.int(raw["output"]) + Self.int(raw["thoughts"]),
                                           cacheRead: cached, cacheWrite: 0)
                    session.tokens += tally
                    let when = (message["timestamp"] as? String).flatMap { date($0) } ?? session.ended
                    let id = (message["id"] as? String) ?? "\(entries.count)"
                    entries.append(UsageEntry(key: "gemini:\(session.sessionID):\(id)", date: when, tokens: tally))
                }
            default:
                continue
            }
        }
        session.title = Self.oneLine(InjectedPrompt.title(session.title), 90)
        session.lastPrompt = Self.clip(session.lastPrompt, 4_000)
        session.lastReply = Self.clip(session.lastReply, 12_000)
        return Parsed(session: session, entries: entries)
    }

    /// Message content is a string, or a list of parts with a `text`.
    private static func geminiText(_ content: Any?) -> String {
        if let string = content as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: Antigravity

    /// ~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl
    private func antigravityFiles(_ home: URL, since: Date) -> [(url: URL, key: CacheKey)] {
        let fm = FileManager.default
        let brain = home.path.hasSuffix("antigravity")
            ? home.appendingPathComponent("brain", isDirectory: true)
            : home.appendingPathComponent("antigravity/brain", isDirectory: true)
        guard let conversations = try? fm.contentsOfDirectory(at: brain, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [(url: URL, key: CacheKey)] = []
        for conv in conversations {
            let url = conv.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if let key = attributes(url), key.modified >= since { result.append((url, key)) }
        }
        return result
    }

    /// Fast lookup of session title and workspace root from ~/.gemini/antigravity/conversation_summaries.db
    private func readAntigravitySummaries(_ homes: [ProfileHome]) -> [String: (title: String, cwd: String)] {
        var result: [String: (title: String, cwd: String)] = [:]
        let fm = FileManager.default
        for home in homes where home.kind == .antigravity {
            let dbURL = home.url.path.hasSuffix("antigravity")
                ? home.url.appendingPathComponent("conversation_summaries.db")
                : home.url.appendingPathComponent("antigravity/conversation_summaries.db")
            guard fm.fileExists(atPath: dbURL.path) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { continue }
            var stmt: OpaquePointer?
            let sql = "SELECT conversation_id, title, workspace_uris FROM conversation_summaries"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cId = sqlite3_column_text(stmt, 0) else { continue }
                    let id = String(cString: cId)
                    let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let uris = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    var cwd = ""
                    if let data = uris.data(using: .utf8),
                       let list = (try? JSONSerialization.jsonObject(with: data)) as? [String],
                       let first = list.first {
                        if first.hasPrefix("file://") {
                            cwd = URL(string: first)?.path ?? String(first.dropFirst(7))
                        } else {
                            cwd = first
                        }
                    }
                    result[id] = (title: title, cwd: cwd)
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }
        return result
    }

    private static let antigravityPlanner = Data(#""PLANNER_RESPONSE""#.utf8)
    private static let antigravityUser = Data(#""USER_INPUT""#.utf8)

    private func parseAntigravity(_ url: URL, summaries: [String: (title: String, cwd: String)]) -> Parsed {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return Parsed(session: nil, entries: []) }
        // .../brain/<conversation_id>/.system_generated/logs/transcript.jsonl
        let sessionID = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let summary = summaries[sessionID]
        var session = PastSession(
            agent: .antigravity, sessionID: sessionID,
            title: summary?.title ?? "", cwd: summary?.cwd ?? "", branch: "", model: "",
            started: .distantFuture, ended: .distantPast,
            prompts: 0, tokens: TokenTally(), lastPrompt: "", lastReply: ""
        )
        var entries: [UsageEntry] = []

        forEachLine(data) { line in
            let isPlanner = line.range(of: Self.antigravityPlanner) != nil
            let isUser = !isPlanner && line.range(of: Self.antigravityUser) != nil
            guard isPlanner || isUser, let object = json(line) else { return }

            if let stamp = (object["created_at"] as? String).flatMap({ self.date($0) }) {
                session.started = min(session.started, stamp)
                session.ended = max(session.ended, stamp)
            }

            if isUser {
                if let content = object["content"] as? String {
                    let text = AgentTranscript.cleanAntigravityPrompt(content)
                    guard !text.isEmpty else { return }
                    session.prompts += 1
                    session.lastPrompt = text
                    if session.title.isEmpty { session.title = text }
                }
            } else if isPlanner {
                if let content = object["content"] as? String {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { session.lastReply = trimmed }
                } else if session.lastReply.isEmpty, let thinking = object["thinking"] as? String {
                    let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { session.lastReply = trimmed }
                }
                if session.cwd.isEmpty, let toolCalls = object["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        if let args = tc["args"] as? [String: Any] {
                            let rawCwd = (args["Cwd"] as? String) ?? (args["cwd"] as? String) ?? ""
                            let clean = rawCwd.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\n\r\t "))
                            if !clean.isEmpty {
                                session.cwd = clean
                                break
                            }
                        }
                    }
                }
                let input = Self.int(object["input_tokens"])
                let output = Self.int(object["output_tokens"])
                let cacheRead = Self.int(object["cache_read_tokens"])
                if input > 0 || output > 0 || cacheRead > 0 {
                    let tally = TokenTally(input: input, output: output, cacheRead: cacheRead, cacheWrite: 0)
                    session.tokens += tally
                    let when = (object["created_at"] as? String).flatMap({ self.date($0) }) ?? session.ended
                    let step = (object["step_index"] as? Int) ?? entries.count
                    entries.append(UsageEntry(key: "antigravity:\(sessionID):\(step)", date: when, tokens: tally))
                }
            }
        }

        let fallbackDate = attributes(url)?.modified ?? Date()
        if session.started == .distantFuture { session.started = session.ended > .distantPast ? session.ended : fallbackDate }
        if session.ended == .distantPast { session.ended = session.started }

        guard session.prompts > 0 || !session.title.isEmpty || !session.lastReply.isEmpty else {
            return Parsed(session: nil, entries: entries)
        }
        session.title = Self.oneLine(InjectedPrompt.title(session.title), 90)
        session.lastPrompt = Self.clip(session.lastPrompt, 4_000)
        session.lastReply = Self.clip(session.lastReply, 12_000)
        return Parsed(session: session, entries: entries)
    }

    // MARK: Claude Code

    private static let claudeAssistant = Data(#""type":"assistant""#.utf8)
    private static let claudeUser = Data(#""type":"user""#.utf8)
    private static let claudeSummary = Data(#""type":"summary""#.utf8)
    private static let toolResult = Data(#""tool_result""#.utf8)

    /// How far a transcript has been read: the state after every complete line up to `offset`. Transcripts only grow, so
    /// while a session runs, the next scan reads just its new lines instead of the whole file again.
    private struct Progress<State> {
        var state: State
        var offset: Int
        var size: Int
    }

    private struct ClaudeState {
        var session: PastSession
        var summaryTitle = ""
        var entries: [UsageEntry] = []
        var seenUsage = Set<String>()
        /// For `ResumedConversations`: the session ids the lines were written under, and the first and last message.
        var sessionIDs = Set<String>()
        var firstMessage = ""
        var firstParent = ""
        var lastMessage = ""
        var firstPrompt = ""
        var firstPromptAt = ""
    }

    private struct CodexState {
        var session: PastSession
        var entries: [UsageEntry] = []
        var previous = TokenTally()
    }

    private var claudeProgress: [String: Progress<ClaudeState>] = [:]
    private var codexProgress: [String: Progress<CodexState>] = [:]
    /// Only transcripts touched this recently keep their progress: older ones rarely grow, and this bounds the memory.
    private static let progressWindow: TimeInterval = 6 * 3600

    /// Reads `url` line by line from where the previous scan stopped, or from the start when the file is new or was
    /// rewritten. Gives the same state as reading the whole file. Nil when the file can't be read.
    private func readLines<State>(_ url: URL, key: CacheKey, progress: inout [String: Progress<State>],
                                  initial: () -> State, line: (Data, inout State) -> Void) -> State? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            progress[url.path] = nil
            return nil
        }
        var saved: Progress<State>
        if let known = progress[url.path], known.offset <= data.count, known.size <= data.count,
           known.offset == 0 || data[data.startIndex + known.offset - 1] == 0x0A {
            saved = known
        } else {
            saved = Progress(state: initial(), offset: 0, size: 0)
        }
        // Complete lines advance the saved state; a line still being written is read on top of a copy only.
        let fresh = data[(data.startIndex + saved.offset)...]
        let complete = fresh.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? fresh.startIndex
        forEachLine(data[fresh.startIndex..<complete]) { line($0, &saved.state) }
        saved.offset = complete - data.startIndex
        saved.size = data.count
        progress[url.path] = Date().timeIntervalSince(key.modified) < Self.progressWindow ? saved : nil
        var state = saved.state
        if complete < data.endIndex { forEachLine(data[complete...]) { line($0, &state) } }
        return state
    }

    private func parseClaude(_ url: URL, key: CacheKey) -> Parsed {
        let initial = {
            ClaudeState(session: PastSession(
                agent: .claude, sessionID: url.deletingPathExtension().lastPathComponent,
                title: "", cwd: "", branch: "", model: "",
                started: .distantFuture, ended: .distantPast,
                prompts: 0, tokens: TokenTally(), lastPrompt: "", lastReply: ""
            ))
        }
        guard let result = readLines(url, key: key, progress: &claudeProgress, initial: initial, line: claudeLine) else {
            return Parsed(session: nil, entries: [])
        }
        var session = result.session
        guard session.ended > .distantPast else { return Parsed(session: nil, entries: result.entries) }
        if !result.summaryTitle.isEmpty { session.title = result.summaryTitle }
        session.title = Self.oneLine(InjectedPrompt.title(session.title), 90)
        session.lastPrompt = Self.clip(session.lastPrompt, 4_000)
        session.lastReply = Self.clip(session.lastReply, 12_000)
        let links = ResumedConversations.links(
            sessionIDs: result.sessionIDs.union([session.sessionID]), firstMessage: result.firstMessage, firstParent: result.firstParent,
            lastMessage: result.lastMessage, firstPrompt: Self.oneLine(result.firstPrompt, 200), firstPromptAt: result.firstPromptAt
        )
        return Parsed(session: session, entries: result.entries, links: links)
    }

    private func claudeLine(_ line: Data, into progress: inout ClaudeState) {
        if line.range(of: Self.claudeSummary) != nil, progress.summaryTitle.isEmpty,
           let object = json(line), object["type"] as? String == "summary" {
            progress.summaryTitle = (object["summary"] as? String) ?? ""
            return
        }
        let isAssistant = line.range(of: Self.claudeAssistant) != nil
        let isUser = !isAssistant && line.range(of: Self.claudeUser) != nil && line.range(of: Self.toolResult) == nil
        guard isAssistant || isUser, let object = json(line) else { return }

        if let stamp = (object["timestamp"] as? String).flatMap({ self.date($0) }) {
            progress.session.started = min(progress.session.started, stamp)
            progress.session.ended = max(progress.session.ended, stamp)
        }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty {
            if progress.session.cwd.isEmpty { progress.session.cwd = cwd }
            progress.session.lastCwd = cwd == progress.session.cwd ? "" : cwd
        }
        if let branch = object["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { progress.session.branch = branch }
        let message = (object["message"] as? [String: Any]) ?? [:]
        if (object["isSidechain"] as? Bool) != true {
            if let id = object["sessionId"] as? String, !id.isEmpty { progress.sessionIDs.insert(id) }
            if let uuid = object["uuid"] as? String, !uuid.isEmpty {
                if progress.firstMessage.isEmpty {
                    progress.firstMessage = uuid
                    progress.firstParent = (object["parentUuid"] as? String) ?? ""
                }
                progress.lastMessage = uuid
            }
        }

        if isAssistant {
            if let model = message["model"] as? String, !model.hasPrefix("<") { progress.session.model = model }
            let text = Self.text(message["content"])
            if !text.isEmpty { progress.session.lastReply = text }
            if let raw = message["usage"] as? [String: Any] {
                let id = "\((message["id"] as? String) ?? ""):\((object["requestId"] as? String) ?? "")"
                // Claude Code writes a line per block for each reply, each containing identical usage.
                guard id == ":" || progress.seenUsage.insert(id).inserted else { return }
                let tokens = TokenTally(
                    input: Self.int(raw["input_tokens"]),
                    output: Self.int(raw["output_tokens"]),
                    cacheRead: Self.int(raw["cache_read_input_tokens"]),
                    cacheWrite: Self.int(raw["cache_creation_input_tokens"])
                )
                progress.session.tokens += tokens
                let when = (object["timestamp"] as? String).flatMap({ self.date($0) }) ?? progress.session.ended
                progress.entries.append(UsageEntry(key: id == ":" ? UUID().uuidString : id, date: when, tokens: tokens))
            }
        } else {
            if (object["isMeta"] as? Bool) == true || (object["isSidechain"] as? Bool) == true { return }
            let text = Self.text(message["content"])
            guard Self.isTypedPrompt(text) else { return }
            progress.session.prompts += 1
            progress.session.lastPrompt = text
            if progress.session.title.isEmpty { progress.session.title = text }
            if progress.firstPrompt.isEmpty {
                progress.firstPrompt = text
                progress.firstPromptAt = (object["timestamp"] as? String) ?? ""
            }
        }
    }

    /// User-typed input, excluding what Claude Code injects automatically (commands, output, interrupts).
    private static func isTypedPrompt(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !InjectedPrompt.isInjected(text)
    }

    /// ~/.claude.json: which account Claude Code is logged in with. When using a custom directory (CLAUDE_CONFIG_DIR),
    /// the file is stored in that directory.
    private func claudeAccount(_ configHome: URL, isDefault: Bool) -> AgentAccount? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [configHome.appendingPathComponent(".claude.json"), configHome.appendingPathComponent(".config.json")]
        if isDefault && ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil {
            candidates.insert(home.appendingPathComponent(".claude.json"), at: 0)
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let oauth = root["oauthAccount"] as? [String: Any] {
                let email = (oauth["emailAddress"] as? String) ?? (oauth["displayName"] as? String) ?? "Claude-account"
                let org = (oauth["organizationName"] as? String) ?? ""
                // An organization simply named "<email>'s Organization" adds no useful detail.
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

    private static let codexMarkers = ["session_meta", "turn_context", "user_message", "agent_message", "token_count"].map { Data($0.utf8) }

    private func parseCodex(_ url: URL, key: CacheKey) -> Parsed {
        // rollout-2026-10-14T10-12-33-<uuid>.jsonl: the uuid is what `codex resume` expects.
        let base = url.deletingPathExtension().lastPathComponent
        let fallbackID = base.count > 36 ? String(base.suffix(36)) : base
        let initial = {
            CodexState(session: PastSession(
                agent: .codex, sessionID: fallbackID,
                title: "", cwd: "", branch: "", model: "",
                started: .distantFuture, ended: .distantPast,
                prompts: 0, tokens: TokenTally(), lastPrompt: "", lastReply: ""
            ))
        }
        guard let result = readLines(url, key: key, progress: &codexProgress, initial: initial, line: codexLine) else {
            return Parsed(session: nil, entries: [])
        }
        var session = result.session
        guard session.ended > .distantPast else { return Parsed(session: nil, entries: result.entries) }
        session.title = Self.oneLine(InjectedPrompt.title(session.title), 90)
        session.lastPrompt = Self.clip(session.lastPrompt, 4_000)
        session.lastReply = Self.clip(session.lastReply, 12_000)
        return Parsed(session: session, entries: result.entries)
    }

    private func codexLine(_ line: Data, into state: inout CodexState) {
        guard Self.codexMarkers.contains(where: { line.range(of: $0) != nil }), let object = json(line) else { return }
        let when = (object["timestamp"] as? String).flatMap({ self.date($0) })
        if let when {
            state.session.started = min(state.session.started, when)
            state.session.ended = max(state.session.ended, when)
        }
        let payload = (object["payload"] as? [String: Any]) ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            if let id = payload["id"] as? String, !id.isEmpty { state.session.sessionID = id }
            if let cwd = payload["cwd"] as? String { state.session.cwd = cwd }
            if let git = payload["git"] as? [String: Any], let branch = git["branch"] as? String { state.session.branch = branch }
        case "turn_context":
            if let model = payload["model"] as? String { state.session.model = model }
            if state.session.cwd.isEmpty, let cwd = payload["cwd"] as? String { state.session.cwd = cwd }
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message":
                let text = (payload["message"] as? String) ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !InjectedPrompt.isInjected(text) else { return }
                state.session.prompts += 1
                state.session.lastPrompt = text
                if state.session.title.isEmpty { state.session.title = text }
            case "agent_message":
                if let text = payload["message"] as? String, !text.isEmpty { state.session.lastReply = text }
            case "token_count":
                // Cumulative session total so far; the delta with the previous line is the incremental usage.
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else { return }
                let cached = Self.int(total["cached_input_tokens"])
                let current = TokenTally(
                    input: max(0, Self.int(total["input_tokens"]) - cached),
                    output: Self.int(total["output_tokens"]),
                    cacheRead: cached,
                    cacheWrite: 0
                )
                guard current.total > state.previous.total else { return }
                let delta = TokenTally(
                    input: max(0, current.input - state.previous.input),
                    output: max(0, current.output - state.previous.output),
                    cacheRead: max(0, current.cacheRead - state.previous.cacheRead)
                )
                state.previous = current
                state.session.tokens = current
                state.entries.append(UsageEntry(key: "\(state.session.sessionID):\(current.total)", date: when ?? state.session.ended, tokens: delta))
            default:
                break
            }
        default:
            break
        }
    }

    /// ~/.codex/auth.json: logged in with ChatGPT (email and plan in id-token) or with an API key.
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

    /// ~/.gemini/google_accounts.json (active Google account) and settings.json (login method).
    /// Antigravity signs in with a Google account and keeps its hook configuration next to Gemini CLI's files.
    private func antigravityAccount(_ home: URL) -> AgentAccount? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: home.appendingPathComponent("antigravity").path)
                || fm.fileExists(atPath: home.appendingPathComponent("config/hooks.json").path) else { return nil }
        if let google = geminiAccount(home) {
            return AgentAccount(agent: .antigravity, name: google.name, organization: "", plan: google.plan)
        }
        return AgentAccount(agent: .antigravity, name: "Google-account", organization: "", plan: "")
    }

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

    /// Extracts only the payload part of a JWT. Nothing is verified or transmitted externally.
    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Helpers

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

    /// Text extracted from a message: either a direct string or concatenated text blocks from an array.
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
