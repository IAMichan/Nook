import Foundation

/// Eén account van een agent, zoals je het in Nook ziet: "Claude · Persoonlijk", "Claude · Bettr".
/// Elk account heeft zijn eigen map met instellingen en login. Het eerste account is de gewone map van de agent
/// (~/.claude, ~/.codex); een extra account krijgt een eigen map (~/.claude-werk) die de agent vindt via
/// CLAUDE_CONFIG_DIR of CODEX_HOME. Zo staan een persoonlijk en een zakelijk account gewoon naast elkaar.
struct AgentProfile: Codable, Identifiable, Hashable {
    /// "claude" voor het eerste account, "claude-werk" voor een extra account.
    var id: String
    var kind: AgentKind
    /// Wat je zelf koos ("Werk"). Leeg bij het eerste account: dan noemt Nook het naar de organisatie.
    var label: String
    /// Nil: de gewone map van de agent. Anders het volledige pad van de eigen map.
    var home: String?
    /// Hoe dit account inlogt. Nil: via de agent zelf (abonnement/OAuth in de terminal).
    var auth: AgentAuthMethod? = nil

    /// Inloggen met een API-sleutel in plaats van een abonnement.
    var usesAPIKey: Bool { auth == .apiKey }

    /// Onder deze naam staat de API-sleutel van dit account in de Keychain (alleen Claude Code; Codex bewaart hem zelf).
    var keychainAccount: String { "agent.apikey." + id }

    var isDefault: Bool { home == nil }

    var homeURL: URL {
        home.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? kind.defaultHome
    }

    /// De omgevingsvariabele die de agent naar deze map laat kijken; leeg voor het eerste account.
    var environment: [String: String] {
        guard let home, let variable = kind.homeVariable else { return [:] }
        return [variable: home]
    }

    /// "CLAUDE_CONFIG_DIR=~/.claude-werk " voor voor een commando in de terminal; leeg voor het eerste account.
    var commandPrefix: String {
        var prefix = ""
        if let home, let variable = kind.homeVariable { prefix = "\(variable)=\(AgentProfile.shellPath(home)) " }
        // De sleutel zelf staat nooit in het commando: de shell haalt hem op het moment zelf uit de Keychain.
        if kind == .claude, usesAPIKey {
            prefix = "ANTHROPIC_API_KEY=\"$(security find-generic-password -s \(Keychain.service) -a \(keychainAccount) -w)\" " + prefix
        }
        return prefix
    }

    /// Het commando waarmee je de agent met dit account start.
    var launchCommand: String { commandPrefix + kind.command }

    /// "~/.claude-werk" in plaats van het volledige pad, voor op het scherm.
    var displayHome: String { AgentProfile.tildePath(homeURL.path) }

    static func defaultProfile(_ kind: AgentKind) -> AgentProfile {
        AgentProfile(id: kind.rawValue, kind: kind, label: "", home: nil)
    }

    /// Vergelijkbaar pad: zonder ~, zonder slash aan het eind.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
    }

    /// Een pad voor de shell: "$HOME"/.claude-werk als dat kan (leesbaar en het werkt), anders volledig gequote.
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

/// Hoe een account inlogt.
enum AgentAuthMethod: String, Codable, CaseIterable, Identifiable {
    /// Via de agent zelf: je abonnement (Claude Pro/Max, ChatGPT) of een login die de CLI bewaart.
    case cli
    /// Met een API-sleutel. Claude Code: in de Keychain van Nook; Codex: bewaard door `codex login --with-api-key`.
    case apiKey

    var id: String { rawValue }
}

extension AgentKind {
    /// Kan deze agent met meerdere accounts naast elkaar werken? Gemini CLI kent geen eigen map per account.
    var supportsProfiles: Bool { homeVariable != nil }

    var homeVariable: String? {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .gemini: return nil
        }
    }

    /// Waar Nook een nieuwe map voor een extra account voorstelt: ~/.claude-werk.
    func suggestedHome(slug: String) -> URL {
        let base = self == .claude ? ".claude" : (self == .codex ? ".codex" : ".gemini")
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("\(base)-\(slug)", isDirectory: true)
    }
}

/// Bewaart welke accounts je in Nook hebt en welke per agent de standaard is.
@MainActor
final class AgentProfileStore: ObservableObject {
    /// Alle accounts, het eerste account van elke agent vooraan.
    @Published private(set) var all: [AgentProfile] = []
    /// Per agent het account waarmee Nook nieuwe sessies start (en denkt, bij Claude Code).
    @Published private(set) var preferred: [AgentKind: String] = [:]

    private static let profilesKey = "agentProfiles"
    private static let preferredKey = "agentPreferredProfiles"
    /// Mappen van accounts die je uit Nook haalde: die neemt Nook niet vanzelf weer op.
    private static let dismissedKey = "agentDismissedHomes"
    /// Gelezen door ClaudeCodeBrain, buiten de hoofdthread: de map van het standaard-Claude-account.
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

    func isPreferred(_ profile: AgentProfile) -> Bool {
        preferredProfile(profile.kind).id == profile.id
    }

    /// Bij welk account hoort een sessie met deze map (CLAUDE_CONFIG_DIR of CODEX_HOME)? Leeg = het eerste account.
    func profile(kind: AgentKind, home: String) -> AgentProfile? {
        let wanted = AgentProfile.normalize(home)
        if wanted.isEmpty || wanted == AgentProfile.normalize(kind.defaultHome.path) { return profile(id: kind.rawValue) }
        return profiles(for: kind).first { AgentProfile.normalize($0.homeURL.path) == wanted }
    }

    // MARK: Aanpassen

    /// Maakt een extra account met een eigen map. Bestaat die map al (je gebruikte hem al), dan neemt Nook hem over.
    func add(kind: AgentKind, label: String, home: URL? = nil) -> AgentProfile {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.slug(name.isEmpty ? "werk" : name)
        var folder = home ?? kind.suggestedHome(slug: slug)
        if home == nil {
            // Een map die al bij een ander account in Nook hoort, nooit delen.
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
        let profile = AgentProfile(id: id, kind: kind, label: name.isEmpty ? "Werk" : name, home: folder.path)
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
        // Een extra account heeft altijd een naam; het eerste account mag terug naar automatisch.
        if clean.isEmpty && !all[index].isDefault { return }
        all[index].label = String(clean.prefix(30))
        save()
    }

    /// Haalt het account uit Nook. De map en de login blijven op je Mac staan.
    func remove(_ id: String) {
        guard let profile = profile(id: id), !profile.isDefault else { return }
        all.removeAll { $0.id == id }
        dismissed.insert(AgentProfile.normalize(profile.homeURL.path))
        Keychain.write("", account: profile.keychainAccount)
        if preferred[profile.kind] == id { preferred[profile.kind] = nil }
        save()
    }

    func setAuth(_ id: String, _ method: AgentAuthMethod) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].auth = method == .cli ? nil : method
        save()
    }

    /// Bewaart (of wist, bij een lege tekst) de API-sleutel van een Claude-account in de Keychain.
    func setAPIKey(_ key: String, for profile: AgentProfile) {
        Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.keychainAccount)
        objectWillChange.send()
    }

    func hasAPIKey(_ profile: AgentProfile) -> Bool {
        guard profile.kind == .claude else { return false }
        return !(Keychain.read(profile.keychainAccount) ?? "").isEmpty
    }

    /// Voor een sessie die Nook zelf start: de omgeving van dit account, met de sleutel als het met een sleutel inlogt.
    /// Gaat rechtstreeks naar het proces; komt nooit op het scherm of in een bestand.
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

    /// Neemt accounts op die al op je Mac staan maar nog niet in Nook: mappen als ~/.claude-werk met een login,
    /// en de map (CLAUDE_CONFIG_DIR of CODEX_HOME) van een sessie die nu draait. Zo staan de sessies van al je
    /// accounts samen in de lijst. Een account dat je zelf uit Nook haalde, blijft eruit.
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

    /// "~/.claude-werk" → "Werk"; een map zonder achtervoegsel heet naar zichzelf.
    static func label(forFolder url: URL) -> String {
        let folder = url.lastPathComponent
        var name = String(folder.drop { $0 != "-" && $0 != "_" }.dropFirst())
        if name.isEmpty { name = folder.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        if name.isEmpty { name = "Werk" }
        return String((name.prefix(1).uppercased() + name.dropFirst()).prefix(30))
    }

    /// Mappen als ~/.claude-werk of ~/.codex-klant waarin al een login staat, maar die nog niet in Nook zitten.
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

    // MARK: Bewaren

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
        return result.isEmpty ? "werk" : String(result.prefix(24))
    }
}
