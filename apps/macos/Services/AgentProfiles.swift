import Foundation

/// A single agent account as presented in Nook: "Claude · Personal", "Claude · Work".
/// Each account has its own configuration directory and login state. The primary account uses the agent's default
/// directory (~/.claude, ~/.codex); additional accounts use custom directories (~/.claude-work) pointed to by
/// CLAUDE_CONFIG_DIR or CODEX_HOME, allowing personal and work accounts side-by-side.
struct AgentProfile: Codable, Identifiable, Hashable {
    /// "claude" for primary account, "claude-work" for additional accounts.
    var id: String
    var kind: AgentKind
    /// User-chosen label ("Work"). Empty for default account: Nook names it after the organization.
    var label: String
    /// Nil: default agent directory. Otherwise full path to custom directory.
    var home: String?
    /// How this account authenticates. Nil: via the agent itself (subscription/OAuth in terminal).
    var auth: AgentAuthMethod? = nil

    /// Authenticate with an API key instead of subscription.
    var usesAPIKey: Bool { auth == .apiKey }

    /// Keychain account name for this account's API key (Claude Code only; Codex stores its own).
    var keychainAccount: String { "agent.apikey." + id }

    var isDefault: Bool { home == nil }

    var homeURL: URL {
        home.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? kind.defaultHome
    }

    /// Environment variable directing the agent to this directory; empty for primary account.
    var environment: [String: String] {
        guard let home, let variable = kind.homeVariable else { return [:] }
        return [variable: kind.homeValue(home)]
    }

    /// "CLAUDE_CONFIG_DIR=~/.claude-work " prefix for terminal commands; empty for primary account.
    var commandPrefix: String {
        var prefix = ""
        if let home, let variable = kind.homeVariable { prefix = "\(variable)=\(AgentProfile.shellPath(kind.homeValue(home))) " }
        // The raw key is never written into the command: shell retrieves it at invocation time from Keychain.
        if kind == .claude, usesAPIKey {
            prefix = "ANTHROPIC_API_KEY=\"$(security find-generic-password -s \(Keychain.service) -a \(keychainAccount) -w)\" " + prefix
        }
        return prefix
    }

    /// Launch command for the agent under this account.
    var launchCommand: String { commandPrefix + kind.command }

    /// "~/.claude-work" formatted display path.
    var displayHome: String { AgentProfile.tildePath(homeURL.path) }

    static func defaultProfile(_ kind: AgentKind) -> AgentProfile {
        AgentProfile(id: kind.rawValue, kind: kind, label: "", home: nil)
    }

    /// Normalized comparable path: expands tilde, standardizes trailing slashes.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
    }

    /// Shell-escaped path: "$HOME"/.claude-work when possible, otherwise safely quoted.
    static func shellPath(_ path: String) -> String {
        let tilde = tildePath(path)
        if tilde.hasPrefix("~/") {
            let rest = String(tilde.dropFirst(2))
            if rest.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) { return "\"$HOME\"/" + rest }
        }
        return TerminalLauncher.shellQuote(normalize(path))
    }

    static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let full = normalize(path)
        return full.hasPrefix(home + "/") ? "~" + full.dropFirst(home.count) : full
    }
}

/// Authentication method for an agent account.
enum AgentAuthMethod: String, Codable, CaseIterable, Identifiable {
    /// Via the agent CLI: subscription (Claude Pro/Max, ChatGPT) or stored CLI credentials.
    case cli
    /// With an API key. Claude Code: stored in Nook Keychain; Codex: managed by `codex login --with-api-key`.
    case apiKey

    var id: String { rawValue }
}

extension AgentKind {
    /// Can this agent run multiple profiles concurrently? Only when it has a variable for its folder.
    var supportsProfiles: Bool { homeVariable != nil }

    /// The variable that points the agent at an account's folder. Gemini CLI's (0.25 and newer) stands in for your home
    /// folder: it keeps its data in `$GEMINI_CLI_HOME/.gemini` (see `homeValue`).
    var homeVariable: String? {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .gemini: return "GEMINI_CLI_HOME"
        case .antigravity, .opencode, .cursor, .grok, .acp: return nil
        }
    }

    /// What `homeVariable` gets for an account kept in `home`: the folder itself, or for Gemini CLI the one around its
    /// `.gemini` folder (an account's `home` is always where the agent's data is, as `defaultHome` is).
    func homeValue(_ home: String) -> String {
        switch self {
        case .gemini:
            let url = URL(fileURLWithPath: home, isDirectory: true)
            return url.lastPathComponent == ".gemini" ? url.deletingLastPathComponent().path : home
        case .claude, .codex, .antigravity, .opencode, .cursor, .grok, .acp:
            return home
        }
    }

    /// Nook keeps an API key for an account of this agent itself (Claude Code in the Keychain; Codex with
    /// `codex login --with-api-key`); the others sign in their own way.
    var takesAPIKeyAccounts: Bool {
        switch self {
        case .claude, .codex: return true
        case .gemini, .antigravity, .opencode, .cursor, .grok, .acp: return false
        }
    }

    /// Why an agent without account folders has one account in Nook (Settings › Agents), when there is a reason to say.
    var singleAccountNote: String? {
        switch self {
        case .antigravity: return "accounts.antigravitySingle"
        case .claude, .codex, .gemini, .opencode, .cursor, .grok, .acp: return nil
        }
    }

    /// How the agent names itself in Nook's hook events (`--agent`).
    var hookAgentID: String {
        switch self {
        case .claude: return "claude-code"
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .acp: return rawValue
        }
    }

    /// The reverse of `homeValue`: the account folder a running agent's `homeVariable` points at.
    func home(fromVariable value: String) -> String {
        switch self {
        case .gemini: return URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent(".gemini", isDirectory: true).path
        case .claude, .codex, .antigravity, .opencode, .cursor, .grok, .acp: return value
        }
    }

    /// Suggested location for a profile directory: ~/.claude-work, or for Gemini CLI ~/.gemini-work/.gemini.
    func suggestedHome(slug: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        // Each ACP agent gets a folder of its own under Nook's; the agent may keep its state there.
        case .acp: return defaultHome.appendingPathComponent(slug, isDirectory: true)
        case .claude: return home.appendingPathComponent(".claude-\(slug)", isDirectory: true)
        case .codex: return home.appendingPathComponent(".codex-\(slug)", isDirectory: true)
        case .gemini, .antigravity, .opencode, .cursor, .grok:
            return home.appendingPathComponent(".gemini-\(slug)", isDirectory: true).appendingPathComponent(".gemini", isDirectory: true)
        }
    }
}

/// Persists configured agent profiles and the default account per agent.
@MainActor
final class AgentProfileStore: ObservableObject {
    /// All accounts, with primary account for each agent listed first.
    @Published private(set) var all: [AgentProfile] = []
    /// Default account per agent for launching sessions and background thinking.
    @Published private(set) var preferred: [AgentKind: String] = [:]
    /// The account Nook's own brain thinks through per agent, picked in the chat's model picker; else `preferred`.
    @Published private(set) var brainPreferred: [AgentKind: String] = [:]

    private static let profilesKey = "agentProfiles"
    private static let preferredKey = "agentPreferredProfiles"
    private static let brainPreferredKey = "agentBrainProfiles"
    /// Folders of accounts you removed from Nook: never adopted again automatically.
    private static let dismissedKey = "agentDismissedHomes"
    /// Read by ClaudeCodeBrain across threads: config dir of the Claude account the brain thinks through.
    nonisolated static let brainHomeKey = "claudeBrainConfigDir"

    init() {
        let defaults = UserDefaults.standard
        var stored: [AgentProfile] = []
        if let data = defaults.data(forKey: Self.profilesKey) {
            // Account by account; if any cannot be read, a copy of the stored list is kept in Nook's folder.
            let backup = NookPaths.supportDirectory.appendingPathComponent("agentProfiles.json")
            stored = SafeStorage.decode(LossyArray<AgentProfile>.self, data: data, original: backup, skipped: { $0.skipped })
                .value?.elements ?? []
        }
        var result: [AgentProfile] = []
        for kind in AgentKind.allCases {
            result.append(stored.first { $0.kind == kind && $0.isDefault } ?? .defaultProfile(kind))
            result += stored.filter { $0.kind == kind && !$0.isDefault }
        }
        all = result
        if let raw = defaults.dictionary(forKey: Self.preferredKey) as? [String: String] {
            for (key, value) in raw {
                if let kind = AgentKind(rawValue: key), result.contains(where: { $0.id == value }) { preferred[kind] = value }
            }
        }
        if let raw = defaults.dictionary(forKey: Self.brainPreferredKey) as? [String: String] {
            for (key, value) in raw {
                if let kind = AgentKind(rawValue: key), result.contains(where: { $0.id == value }) { brainPreferred[kind] = value }
            }
        }
        syncBrainHome()
    }

    private var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.dismissedKey) }
    }

    func profiles(for kind: AgentKind) -> [AgentProfile] {
        all.filter { $0.kind == kind }
    }

    func profile(id: String) -> AgentProfile? {
        all.first { $0.id == id }
    }

    func preferredProfile(_ kind: AgentKind) -> AgentProfile {
        preferred[kind].flatMap(profile(id:)) ?? profile(id: kind.rawValue) ?? .defaultProfile(kind)
    }

    /// The account Nook's brain thinks through for an agent: the one picked for it, else the agent's default.
    func brainProfile(_ kind: AgentKind) -> AgentProfile {
        brainPreferred[kind].flatMap(profile(id:)) ?? preferredProfile(kind)
    }

    func setBrainProfile(_ profile: AgentProfile) {
        brainPreferred[profile.kind] = profile.id
        save()
    }

    func isPreferred(_ profile: AgentProfile) -> Bool {
        preferredProfile(profile.kind).id == profile.id
    }

    /// Matches an account to a given config directory (CLAUDE_CONFIG_DIR or CODEX_HOME). Empty = primary account.
    func profile(kind: AgentKind, home: String) -> AgentProfile? {
        let wanted = AgentProfile.normalize(home)
        if wanted.isEmpty || wanted == AgentProfile.normalize(kind.defaultHome.path) { return profile(id: kind.rawValue) }
        return profiles(for: kind).first { AgentProfile.normalize($0.homeURL.path) == wanted }
    }

    // MARK: Mutation

    /// Creates an additional profile with custom folder. If the folder already exists, Nook adopts it.
    func add(kind: AgentKind, label: String, home: URL? = nil) -> AgentProfile {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.slug(name.isEmpty ? "work" : name)
        var folder = home ?? kind.suggestedHome(slug: slug)
        if home == nil {
            // Never share a folder already assigned to another profile in Nook.
            var counter = 2
            while all.contains(where: { AgentProfile.normalize($0.homeURL.path) == AgentProfile.normalize(folder.path) }) {
                folder = kind.suggestedHome(slug: "\(slug)-\(counter)")
                counter += 1
            }
        }
        if let existing = profile(kind: kind, home: folder.path) { return existing }
        dismissed.remove(AgentProfile.normalize(folder.path))
        var id = "\(kind.rawValue)-\(slug)"
        var counter = 2
        while all.contains(where: { $0.id == id }) {
            id = "\(kind.rawValue)-\(slug)-\(counter)"
            counter += 1
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let profile = AgentProfile(id: id, kind: kind, label: name.isEmpty ? "Work" : name, home: folder.path)
        var updated = all
        let insertAt = (updated.lastIndex { $0.kind == kind } ?? (updated.count - 1)) + 1
        updated.insert(profile, at: insertAt)
        all = updated
        save()
        return profile
    }

    func rename(_ id: String, to label: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Additional accounts must have a label; primary account may revert to automatic naming.
        if clean.isEmpty && !all[index].isDefault { return }
        all[index].label = String(clean.prefix(30))
        save()
    }

    /// Removes account from Nook. Local folder and credentials remain on disk.
    func remove(_ id: String) {
        guard let profile = profile(id: id), !profile.isDefault else { return }
        all.removeAll { $0.id == id }
        dismissed.insert(AgentProfile.normalize(profile.homeURL.path))
        Keychain.write("", account: profile.keychainAccount)
        if preferred[profile.kind] == id { preferred[profile.kind] = nil }
        if brainPreferred[profile.kind] == id { brainPreferred[profile.kind] = nil }
        save()
    }

    func setAuth(_ id: String, _ method: AgentAuthMethod) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].auth = method == .cli ? nil : method
        save()
    }

    /// Persists (or deletes when empty) the Claude account API key in Keychain.
    func setAPIKey(_ key: String, for profile: AgentProfile) {
        Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.keychainAccount)
        objectWillChange.send()
    }

    func hasAPIKey(_ profile: AgentProfile) -> Bool {
        guard profile.kind == .claude else { return false }
        return !(Keychain.read(profile.keychainAccount) ?? "").isEmpty
    }

    /// Environment variables for launched sessions, including API key if using key-based auth.
    /// Passed directly to process; never logged or written to disk.
    func launchEnvironment(_ profile: AgentProfile) -> [String: String] {
        var env = profile.environment
        if profile.kind == .claude, profile.usesAPIKey, let key = Keychain.read(profile.keychainAccount), !key.isEmpty {
            env["ANTHROPIC_API_KEY"] = key
        }
        return env
    }

    func setPreferred(_ profile: AgentProfile) {
        preferred[profile.kind] = profile.id
        save()
    }

    /// Adopts accounts that exist on this Mac but not yet in Nook: folders like ~/.claude-work with a login,
    /// and the folder (CLAUDE_CONFIG_DIR or CODEX_HOME) of a running session. That way sessions of all your
    /// accounts show up in one list. Accounts you removed from Nook stay out.
    func adoptExisting(running: [(kind: AgentKind, home: String)] = []) {
        let skip = dismissed
        var folders = discover()
        for item in running where !item.home.isEmpty && item.kind.supportsProfiles {
            let url = URL(fileURLWithPath: AgentProfile.normalize(item.home), isDirectory: true)
            guard profile(kind: item.kind, home: url.path) == nil,
                  !folders.contains(where: { $0.url.standardizedFileURL.path == url.path }),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            folders.append((item.kind, url))
        }
        for folder in folders where !skip.contains(AgentProfile.normalize(folder.url.path)) {
            _ = add(kind: folder.kind, label: Self.label(forFolder: folder.url), home: folder.url)
        }
    }

    /// "~/.claude-work" → "Work"; a folder without a suffix is named after itself.
    static func label(forFolder url: URL) -> String {
        // ~/.gemini-work/.gemini is named after the folder around it.
        let folder = url.lastPathComponent == ".gemini" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
        var name = String(folder.drop { $0 != "-" && $0 != "_" }.dropFirst())
        if name.isEmpty { name = folder.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        if name.isEmpty { name = tr("agents.work") }
        return String((name.prefix(1).uppercased() + name.dropFirst()).prefix(30))
    }

    /// Discovers profile folders (e.g. ~/.claude-work, ~/.codex-client) with existing logins not yet added to Nook.
    func discover() -> [(kind: AgentKind, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        guard let names = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }
        var found: [(kind: AgentKind, url: URL)] = []
        for name in names.sorted() {
            let url = home.appendingPathComponent(name, isDirectory: true)
            let kind: AgentKind
            let marker: String
            if name.hasPrefix(".claude-") || name.hasPrefix(".claude_") {
                kind = .claude; marker = ".claude.json"
            } else if name.hasPrefix(".codex-") || name.hasPrefix(".codex_") {
                kind = .codex; marker = "auth.json"
            } else if name.hasPrefix(".gemini-") || name.hasPrefix(".gemini_") {
                // GEMINI_CLI_HOME stands in for the home folder: the account's data is in its .gemini.
                let data = url.appendingPathComponent(".gemini", isDirectory: true)
                guard ["oauth_creds.json", "google_accounts.json"].contains(where: { fm.fileExists(atPath: data.appendingPathComponent($0).path) }),
                      profile(kind: .gemini, home: data.path) == nil else { continue }
                found.append((.gemini, data))
                continue
            } else {
                continue
            }
            guard fm.fileExists(atPath: url.appendingPathComponent(marker).path),
                  profile(kind: kind, home: url.path) == nil else { continue }
            found.append((kind, url))
        }
        return found
    }

    // MARK: Persistence

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.profilesKey) }
        defaults.set(Dictionary(uniqueKeysWithValues: preferred.map { ($0.key.rawValue, $0.value) }), forKey: Self.preferredKey)
        defaults.set(Dictionary(uniqueKeysWithValues: brainPreferred.map { ($0.key.rawValue, $0.value) }), forKey: Self.brainPreferredKey)
        syncBrainHome()
    }

    private func syncBrainHome() {
        let claude = brainProfile(.claude)
        if let home = claude.home {
            UserDefaults.standard.set(home, forKey: Self.brainHomeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.brainHomeKey)
        }
    }

    /// "Acme Corp" → "acme-corp".
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var result = ""
        for character in folded {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
            } else if !result.isEmpty && result.last != "-" {
                result.append("-")
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "work" : String(result.prefix(24))
    }
}
