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
        return [variable: home]
    }

    /// "CLAUDE_CONFIG_DIR=~/.claude-work " prefix for terminal commands; empty for primary account.
    var commandPrefix: String {
        var prefix = ""
        if let home, let variable = kind.homeVariable { prefix = "\(variable)=\(AgentProfile.shellPath(home)) " }
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
    /// Can this agent run multiple profiles concurrently? Gemini CLI lacks per-directory profiles.
    var supportsProfiles: Bool { homeVariable != nil }

    var homeVariable: String? {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .gemini: return nil
        }
    }

    /// Suggested location for a profile directory: ~/.claude-work.
    func suggestedHome(slug: String) -> URL {
        let base = self == .claude ? ".claude" : (self == .codex ? ".codex" : ".gemini")
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("\(base)-\(slug)", isDirectory: true)
    }
}

/// Persists configured agent profiles and the default account per agent.
@MainActor
final class AgentProfileStore: ObservableObject {
    /// All accounts, with primary account for each agent listed first.
    @Published private(set) var all: [AgentProfile] = []
    /// Default account per agent for launching sessions and background thinking.
    @Published private(set) var preferred: [AgentKind: String] = [:]

    private static let profilesKey = "agentProfiles"
    private static let preferredKey = "agentPreferredProfiles"
    /// Read by ClaudeCodeBrain across threads: config dir of preferred Claude account.
    nonisolated static let brainHomeKey = "claudeBrainConfigDir"

    init() {
        let defaults = UserDefaults.standard
        var stored: [AgentProfile] = []
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([AgentProfile].self, from: data) {
            stored = decoded
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
        syncBrainHome()
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
        Keychain.write("", account: profile.keychainAccount)
        if preferred[profile.kind] == id { preferred[profile.kind] = nil }
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
        syncBrainHome()
    }

    private func syncBrainHome() {
        let claude = preferredProfile(.claude)
        if let home = claude.home {
            UserDefaults.standard.set(home, forKey: Self.brainHomeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.brainHomeKey)
        }
    }

    /// "Bettr Health" → "bettr-health".
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
