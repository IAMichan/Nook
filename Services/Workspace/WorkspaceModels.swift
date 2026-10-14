import Foundation

// De werkruimte voor coding-agents: sessies die Nook zelf start en volgt (niet in een terminal).
// Alles in dit bestand is alleen Foundation, zodat de tests het los kunnen gebruiken.

/// Welke agent een werkruimte-sessie draait. Alleen agents met een echte headless-modus die Nook kan volgen.
enum RunProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Wat deze agent in de headless-modus echt kan. De UI toont wat er niet is als "niet beschikbaar".
    var capabilities: ProviderCapabilities {
        switch self {
        case .claude:
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass])
        case .codex:
            return ProviderCapabilities(approvals: false, interrupt: true, streamingText: false, planMode: true,
                                        reportsCost: false, reportsContextWindow: false, reportsCacheTokens: true,
                                        policies: [.acceptEdits, .bypass])
        }
    }

    /// Modellen die je snel kiest. Leeg betekent: de standaard van de agent zelf. Je kunt ook een eigen naam typen.
    var suggestedModels: [String] {
        switch self {
        case .claude: return ["", "sonnet", "opus", "haiku"]
        case .codex: return ["", "gpt-5-codex", "gpt-5"]
        }
    }
}

struct ProviderCapabilities: Equatable, Sendable {
    var approvals: Bool
    var interrupt: Bool
    var streamingText: Bool
    var planMode: Bool
    var reportsCost: Bool
    var reportsContextWindow: Bool
    var reportsCacheTokens: Bool
    var policies: [PermissionPolicy]
}

/// Agent: mag werken. Plan: alleen lezen en een plan maken, niets aanpassen.
enum ExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case agent, plan
    var id: String { rawValue }
}

/// Wat de agent zonder te vragen mag.
enum PermissionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Elke bewerking en elk commando vraagt eerst (alleen Claude Code).
    case ask
    /// Bestanden in de werkmap aanpassen mag; commando's vragen eerst (Claude) of draaien in de sandbox (Codex).
    case acceptEdits
    /// Alles zonder vragen. Alleen als je dat bewust kiest.
    case bypass
    var id: String { rawValue }
}

/// In de map zelf werken, of in een eigen Git-worktree met een eigen branch.
enum IsolationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case folder, worktree
    var id: String { rawValue }
}

/// De toestand van een sessie. Elke wijziging gaat via `RunStatus.canMove(to:)`.
enum RunStatus: String, Codable, CaseIterable, Sendable {
    /// Map of worktree klaarzetten, agent starten.
    case preparing
    /// De agent werkt.
    case running
    /// De agent wacht op jouw goedkeuring voor een tool.
    case waitingApproval
    /// De beurt is klaar; je kunt verder met een nieuw bericht.
    case completed
    /// Er ging iets mis.
    case failed
    /// Jij stopte hem, of het proces verdween (bijvoorbeeld na een herstart van Nook).
    case stopped

    /// Er hoort een proces bij dat nu draait.
    var isActive: Bool {
        switch self {
        case .preparing, .running, .waitingApproval: return true
        case .completed, .failed, .stopped: return false
        }
    }

    func canMove(to next: RunStatus) -> Bool {
        if next == self { return true }
        switch self {
        case .preparing: return [.running, .failed, .stopped].contains(next)
        case .running: return [.waitingApproval, .completed, .failed, .stopped].contains(next)
        case .waitingApproval: return [.running, .completed, .failed, .stopped].contains(next)
        case .completed, .failed, .stopped: return [.preparing, .running].contains(next)
        }
    }

    /// Na een herstart draait er geen proces meer: een sessie die "actief" was, is gestopt.
    var afterRelaunch: RunStatus { isActive ? .stopped : self }
}

/// Tokens en kosten. Nil betekent: de agent gaf dit niet door. Nooit raden.
struct RunUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    /// Kosten zoals de agent ze zelf berekent (Claude Code: tegen API-prijzen, ook als je een abonnement hebt).
    var reportedCostUSD: Double?
    /// Tokens in de context bij de laatste modelaanroep.
    var contextTokens: Int?
    /// Maximale contextgrootte van het model, als de agent die doorgeeft.
    var contextWindow: Int?
    var turns = 0
    /// Hoe lang de agent in totaal werkte, in seconden (som van de beurten).
    var activeSeconds: Double = 0

    var totalTokens: Int? {
        let parts = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }

    /// Telt een afgeronde beurt op. Velden die de beurt niet kent, blijven zoals ze waren.
    mutating func add(_ turn: TurnUsage) {
        inputTokens = Self.sum(inputTokens, turn.inputTokens)
        outputTokens = Self.sum(outputTokens, turn.outputTokens)
        cacheReadTokens = Self.sum(cacheReadTokens, turn.cacheReadTokens)
        cacheWriteTokens = Self.sum(cacheWriteTokens, turn.cacheWriteTokens)
        if let cost = turn.reportedCostUSD { reportedCostUSD = (reportedCostUSD ?? 0) + cost }
        if let context = turn.contextTokens { contextTokens = context }
        if let window = turn.contextWindow { contextWindow = window }
        turns += 1
        activeSeconds += max(0, turn.durationSeconds ?? 0)
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): return nil
        default: return (a ?? 0) + (b ?? 0)
        }
    }
}

/// Wat één beurt (één proces) aan gebruik meldde.
struct TurnUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reportedCostUSD: Double?
    var contextTokens: Int?
    var contextWindow: Int?
    var durationSeconds: Double?
}

/// Eén sessie in de werkruimte. Bewaard in `RunStore`, ook na een herstart.
struct WorkspaceRun: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    /// De eerste opdracht.
    var task: String
    var provider: RunProvider
    /// Met welk account (`AgentProfile.id`).
    var profileID: String
    /// Leeg: de standaard van de agent.
    var model: String
    /// Het model dat de agent echt gebruikte, zoals hij het zelf meldde.
    var resolvedModel: String?
    var mode: ExecutionMode
    var permission: PermissionPolicy
    var isolation: IsolationMode
    /// De map of repository die je koos.
    var projectPath: String
    /// Waar de agent echt werkt: de map zelf, of de worktree.
    var workingDirectory: String
    /// De root van de Git-repository, nil als het geen repository is.
    var repoRoot: String?
    var branch: String?
    var baseBranch: String?
    var worktreePath: String?
    /// Extra instructies voor deze sessie (naast CLAUDE.md / AGENTS.md van het project).
    var instructions: String
    var status: RunStatus
    /// Uitleg bij de toestand: een foutmelding, of waarom hij stopte.
    var statusDetail: String?
    /// De sessie-ID van de agent zelf, om verder te gaan (`claude --resume`, `codex exec resume`).
    var providerSessionID: String?
    var createdAt: Date
    var updatedAt: Date
    var archived: Bool
    var usage: RunUsage
    /// Begin van de beurt die nu loopt.
    var turnStartedAt: Date?
    /// Laatste keer dat je de wijzigingen bekeek; daarna gewijzigd = "niet bekeken".
    var reviewedAt: Date?
    /// Laatste keer dat de agent iets veranderde.
    var lastChangeAt: Date?
    /// Aantal gewijzigde bestanden bij de laatste Git-controle, voor in de lijst.
    var changedFiles: Int?

    var projectName: String {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    var hasUnreviewedChanges: Bool {
        guard let changed = lastChangeAt, (changedFiles ?? 1) > 0 else { return false }
        return reviewedAt.map { $0 < changed } ?? true
    }

    /// Kan je deze sessie een nieuw bericht sturen? Pas als de vorige beurt klaar is.
    var canContinue: Bool { !status.isActive }

    /// Een sessie wordt gestart met een gekozen toestand; andere wijzigingen gaan via `move(to:)`.
    @discardableResult
    mutating func move(to next: RunStatus, detail: String? = nil, now: Date = Date()) -> Bool {
        guard status.canMove(to: next) else { return false }
        status = next
        statusDetail = detail
        updatedAt = now
        if next == .running, turnStartedAt == nil { turnStartedAt = now }
        if !next.isActive { turnStartedAt = nil }
        return true
    }
}

/// Eén regel in de tijdlijn van een sessie.
struct RunEvent: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user, assistant, thinking, tool, fileChange, approval, error, system, result
    }

    enum State: String, Codable, Sendable {
        case running, done, failed, pending, allowed, denied, expired
    }

    var id: UUID
    var date: Date
    var kind: Kind
    /// De hoofdtekst: bericht, samenvatting van de tool, foutmelding.
    var text: String
    /// Naam van de tool, of soort wijziging (added/modified/deleted).
    var tool: String?
    /// ID van de tool-aanroep (of van de goedkeuringsvraag), om de uitkomst te koppelen.
    var callID: String?
    /// Invoer van de tool als JSON, of het pad van een bestand.
    var detail: String?
    /// Uitkomst van de tool, ingekort.
    var output: String?
    var state: State?

    init(kind: Kind, text: String, tool: String? = nil, callID: String? = nil, detail: String? = nil,
         output: String? = nil, state: State? = nil, date: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
        self.tool = tool
        self.callID = callID
        self.detail = detail
        self.output = output
        self.state = state
    }

    /// Lange tool-uitkomsten ingekort; de volledige versie staat in het transcript van de agent zelf.
    static let outputLimit = 16_000

    static func clip(_ text: String, _ limit: Int = outputLimit) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}

/// Wat je invult bij "Nieuwe sessie". Wordt gecontroleerd voor er iets start.
struct NewRunConfig: Equatable, Sendable {
    var title = ""
    var task = ""
    var provider: RunProvider = .claude
    var profileID = "claude"
    var model = ""
    var mode: ExecutionMode = .agent
    var permission: PermissionPolicy = .acceptEdits
    var isolation: IsolationMode = .folder
    var projectPath = ""
    var baseBranch = ""
    var branchName = ""
    var worktreeRoot = ""
    var instructions = ""

    /// Wat er mis is, of nil als alles klopt. Controleert alleen de invoer; Git en paden controleert de manager.
    var problem: ConfigProblem? {
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingTask }
        if projectPath.isEmpty { return .missingWorkspace }
        if !provider.capabilities.policies.contains(permission) { return .unsupportedPolicy }
        if isolation == .worktree {
            if baseBranch.isEmpty { return .missingBaseBranch }
            if !WorktreeNaming.isPlausibleBranchName(branchName) { return .invalidBranchName }
        }
        return nil
    }
}

enum ConfigProblem: String, Equatable, Sendable {
    case missingTask, missingWorkspace, unsupportedPolicy, missingBaseBranch, invalidBranchName
}

/// Namen voor sessies, branches en worktree-mappen, afgeleid van de opdracht.
enum WorktreeNaming {
    /// "Fix de login-bug in Safari!" → "fix-de-login-bug-in-safari".
    static func slug(_ text: String, limit: Int = 40) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        for character in folded {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
            } else if !result.isEmpty && result.last != "-" {
                result.append("-")
            }
            if result.count >= limit { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "sessie" : result
    }

    /// Een korte titel uit de eerste regel van de opdracht.
    static func title(from task: String, limit: Int = 60) -> String {
        let firstLine = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Nieuwe sessie" }
        if clean.count <= limit { return clean }
        let cut = clean.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// "nook/fix-login-bug-3fa2": herkenbaar, en uniek dankzij een stukje van de ID.
    static func branchName(task: String, id: UUID) -> String {
        "nook/" + slug(task, limit: 32) + "-" + String(id.uuidString.prefix(4)).lowercased()
    }

    /// Snelle controle zonder Git; `GitService.isValidBranchName` vraagt het Git zelf.
    static func isPlausibleBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"),
              !name.contains("@{"), name != "@" else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters).union(.whitespacesAndNewlines)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// Waar de worktree komt: <root>/<repo>/<slug>. Bestaat die map al, dan met een volgnummer.
    static func worktreePath(root: String, repoName: String, slug: String, exists: (String) -> Bool) -> String {
        let base = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(Self.slug(repoName, limit: 40), isDirectory: true)
        var candidate = base.appendingPathComponent(slug, isDirectory: true).path
        var counter = 2
        while exists(candidate) {
            candidate = base.appendingPathComponent("\(slug)-\(counter)", isDirectory: true).path
            counter += 1
        }
        return candidate
    }
}

/// Welke mappen een agent mag krijgen. Nooit de systeemmappen of de hele schijf.
enum WorkspacePathPolicy {
    enum Verdict: Equatable {
        case ok
        case missing
        case notDirectory
        case unreadable
        case forbidden
    }

    private static let forbiddenRoots = ["/", "/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/etc",
                                         "/var", "/dev", "/cores", "/opt", "/Applications", "/Volumes"]

    static func verdict(for raw: String, fileManager: FileManager = .default, home: String = NSHomeDirectory()) -> Verdict {
        let path = normalize(raw)
        guard !path.isEmpty else { return .missing }
        if path == normalize(home) || forbiddenRoots.contains(path) { return .forbidden }
        // Systeemmappen zelf, en ook alles daarin behalve /opt/… en /Volumes/… (externe schijven, Homebrew-projecten).
        for root in ["/System", "/bin", "/sbin", "/usr", "/etc", "/dev", "/private/etc", "/private/var/db"]
        where path.hasPrefix(root + "/") { return .forbidden }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notDirectory }
        guard fileManager.isReadableFile(atPath: path) else { return .unreadable }
        return .ok
    }

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Korte, taal-neutrale omschrijving van een tool-aanroep: "Bash · npm test", "Edit · Login.swift".
enum ToolSummary {
    static func describe(tool: String, input: [String: Any]) -> String {
        if let command = command(input) { return "\(tool) · \(oneLine(command, 120))" }
        if let path = path(input) { return "\(tool) · \(URL(fileURLWithPath: path).lastPathComponent)" }
        for key in ["pattern", "query", "url", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return "\(tool) · \(oneLine(value, 100))" }
        }
        if tool == "TodoWrite", let todos = input["todos"] as? [Any] { return "\(tool) · \(todos.count)" }
        return tool
    }

    static func command(_ input: [String: Any]) -> String? {
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [String], !parts.isEmpty {
            if parts.count >= 3, ["bash", "sh", "zsh"].contains(URL(fileURLWithPath: parts[0]).lastPathComponent),
               parts[1].hasPrefix("-") {
                return parts[2...].joined(separator: " ")
            }
            return parts.joined(separator: " ")
        }
        return nil
    }

    static func path(_ input: [String: Any]) -> String? {
        for key in ["file_path", "notebook_path", "absolute_path", "path"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Bestanden die deze tool aanpast, met de soort wijziging.
    static func fileChanges(tool: String, input: [String: Any]) -> [(path: String, kind: String)] {
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit":
            return path(input).map { [($0, "modified")] } ?? []
        case "Write":
            return path(input).map { [($0, "written")] } ?? []
        default:
            return []
        }
    }

    static func oneLine(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    /// JSON voor in de tijdlijn, netjes en gesorteerd.
    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "\(object)" }
        return text
    }
}
