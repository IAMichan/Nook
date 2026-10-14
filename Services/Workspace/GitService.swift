import Foundation

/// Draait een programma met een lijst argumenten (nooit via een shell) en geeft uitvoer en foutuitvoer terug.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut = false
    }

    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 60) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Beide pijpen tegelijk leegmaken, anders loopt een proces met veel uitvoer vast.
        let outData = DataBox()
        let errData = DataBox()
        let group = DispatchGroup()
        try process.run()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = group.wait(timeout: .now() + 5)
        }
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: outData.data, as: UTF8.self),
                      stderr: String(decoding: errData.data, as: UTF8.self),
                      timedOut: timedOut)
    }

    /// Uitvoer die een achtergrondtaak vult; gelezen pas na `DispatchGroup.wait`.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

struct GitError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Soort wijziging van een bestand, zoals Git hem meldt.
enum GitChangeKind: String, Codable, Sendable {
    case added, modified, deleted, renamed, copied, untracked, conflicted, typeChanged

    var letter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "U"
        case .conflicted: return "!"
        case .typeChanged: return "T"
        }
    }
}

struct GitFileChange: Equatable, Identifiable, Sendable {
    var path: String
    var oldPath: String?
    var kind: GitChangeKind
    var staged: Bool
    var unstaged: Bool
    var added: Int?
    var removed: Int?

    var id: String { path }
}

struct GitStatus: Equatable, Sendable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var detached = false
    var files: [GitFileChange] = []

    var isClean: Bool { files.isEmpty }
}

struct GitWorktree: Equatable, Identifiable, Sendable {
    var path: String
    var head: String
    var branch: String?
    var isMain: Bool
    var locked: Bool
    var prunable: Bool
    var id: String { path }
}

/// Alles wat Nook met Git doet. Elke functie is synchroon: roep hem aan buiten de hoofdthread.
/// Argumenten gaan als lijst naar Git, dus een branchnaam of pad kan nooit als shell-commando worden uitgevoerd.
struct GitService: Sendable {
    let executable: String

    /// Zoekt Git. Nil als het er niet is (op macOS: zonder Command Line Tools werkt /usr/bin/git niet).
    static func locate(fileManager: FileManager = .default) -> GitService? {
        for path in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            let service = GitService(executable: path)
            if let output = try? service.raw(["--version"], in: nil, timeout: 15), output.status == 0,
               output.stdout.hasPrefix("git version") {
                return service
            }
        }
        return nil
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Nooit blijven hangen op een wachtwoordvraag; je eigen credential helper (Keychain) werkt gewoon.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        return env
    }

    func raw(_ arguments: [String], in directory: String?, timeout: TimeInterval = 60) throws -> ProcessRunner.Output {
        try ProcessRunner.run(executable, arguments, in: directory, environment: environment, timeout: timeout)
    }

    /// Draait git en gooit een fout met Gits eigen melding als het niet lukt.
    @discardableResult
    func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 60, okStatuses: Set<Int32> = [0]) throws -> String {
        let output = try raw(["-C", directory] + arguments, in: directory, timeout: timeout)
        if output.timedOut { throw GitError("git \(arguments.first ?? "") duurde te lang en is gestopt.") }
        guard okStatuses.contains(output.status) else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message.isEmpty ? "git \(arguments.first ?? "") mislukte (\(output.status))." : message)
        }
        return output.stdout
    }

    // MARK: Repository

    /// De root van de repository waar `path` in ligt, of nil als het geen repository is.
    func repositoryRoot(for path: String) -> String? {
        guard let text = try? run(["rev-parse", "--show-toplevel"], in: path) else { return nil }
        let root = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// De gedeelde .git-map: dezelfde voor de hoofdmap en al zijn worktrees.
    func commonDirectory(for path: String) -> String? {
        guard let text = try? run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path) else { return nil }
        let dir = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    func hasCommits(_ repo: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: repo)) != nil
    }

    func currentBranch(_ repo: String) -> String? {
        guard let text = try? run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repo) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Lokale branches, en branches van remotes (zonder origin/HEAD).
    func branches(_ repo: String) throws -> (local: [String], remote: [String]) {
        let text = try run(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], in: repo)
        var local: [String] = []
        var remote: [String] = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("refs/heads/") {
                local.append(String(line.dropFirst("refs/heads/".count)))
            } else if line.hasPrefix("refs/remotes/"), !line.hasSuffix("/HEAD") {
                remote.append(String(line.dropFirst("refs/remotes/".count)))
            }
        }
        return (local, remote)
    }

    /// De standaard-branch van de remote (origin/main), anders de huidige branch.
    func defaultBaseBranch(_ repo: String) -> String? {
        if let text = try? run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repo) {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let short = name.hasPrefix("origin/") ? String(name.dropFirst(7)) : name
                if (try? branches(repo).local.contains(short)) == true { return short }
                return name
            }
        }
        return currentBranch(repo)
    }

    func refExists(_ ref: String, in repo: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: repo)) != nil
    }

    func localBranchExists(_ name: String, in repo: String) -> Bool {
        (try? run(["show-ref", "--verify", "--quiet", "refs/heads/" + name], in: repo)) != nil
    }

    /// Vraagt Git zelf of dit een geldige branchnaam is.
    func isValidBranchName(_ name: String, in repo: String) -> Bool {
        guard WorktreeNaming.isPlausibleBranchName(name) else { return false }
        return (try? run(["check-ref-format", "--branch", name], in: repo)) != nil
    }

    func remotes(_ repo: String) -> [String] {
        ((try? run(["remote"], in: repo)) ?? "").split(separator: "\n").map(String.init)
    }

    func remoteURL(_ repo: String, remote: String = "origin") -> String? {
        let text = (try? run(["remote", "get-url", remote], in: repo))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: Status en wijzigingen

    func status(_ directory: String) throws -> GitStatus {
        let text = try run(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"], in: directory)
        var status = Self.parseStatus(text)
        // Regels erbij: voor wat Git volgt uit de diff, voor nieuwe bestanden uit het bestand zelf.
        if let numstat = try? run(["diff", "--numstat", "-z", "HEAD"], in: directory) {
            let counts = Self.parseNumstat(numstat)
            for index in status.files.indices {
                if let count = counts[status.files[index].path] {
                    status.files[index].added = count.added
                    status.files[index].removed = count.removed
                } else if status.files[index].kind == .untracked {
                    status.files[index].added = Self.lineCount(of: URL(fileURLWithPath: directory).appendingPathComponent(status.files[index].path).path)
                    status.files[index].removed = 0
                }
            }
        }
        return status
    }

    /// Hoeveel commits deze branch voor (en achter) loopt op `base`.
    func divergence(_ directory: String, base: String) -> (ahead: Int, behind: Int)? {
        guard let text = try? run(["rev-list", "--left-right", "--count", base + "...HEAD"], in: directory) else { return nil }
        let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (ahead: parts[1], behind: parts[0])
    }

    /// De diff van één bestand ten opzichte van HEAD (of de lege boom als er nog geen commits zijn).
    func diff(_ directory: String, file: GitFileChange) throws -> String {
        if file.kind == .untracked {
            // Exitcode 1 betekent hier "er zijn verschillen", geen fout.
            return try run(["diff", "--no-color", "--no-index", "--", "/dev/null", file.path], in: directory, okStatuses: [0, 1])
        }
        let base = hasCommits(directory) ? "HEAD" : Self.emptyTree
        var arguments = ["diff", "--no-color", "-M", base, "--"]
        if let old = file.oldPath { arguments.append(old) }
        arguments.append(file.path)
        return try run(arguments, in: directory)
    }

    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    // MARK: Worktrees

    func worktrees(_ repo: String) throws -> [GitWorktree] {
        Self.parseWorktrees(try run(["worktree", "list", "--porcelain"], in: repo))
    }

    /// Maakt een nieuwe worktree met een nieuwe branch vanaf `base`. Je huidige map en branch blijven zoals ze zijn.
    func addWorktree(repo: String, path: String, branch: String, base: String) throws {
        guard hasCommits(repo) else { throw GitError("Deze repository heeft nog geen commits; een worktree kan pas na de eerste commit.") }
        guard refExists(base, in: repo) else { throw GitError("De basis-branch '\(base)' bestaat niet.") }
        guard isValidBranchName(branch, in: repo) else { throw GitError("'\(branch)' is geen geldige branchnaam.") }
        guard !localBranchExists(branch, in: repo) else { throw GitError("De branch '\(branch)' bestaat al. Kies een andere naam.") }
        guard !FileManager.default.fileExists(atPath: path) else { throw GitError("De map \(path) bestaat al.") }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try run(["worktree", "add", "-b", branch, path, base], in: repo, timeout: 180)
    }

    /// Haalt een worktree weg. Alleen een worktree die Git voor deze repository kent, en nooit de hoofdmap.
    /// Zonder `force` weigert Git als er nog niet-gecommitte wijzigingen zijn.
    func removeWorktree(repo: String, path: String, force: Bool) throws {
        let target = WorkspacePathPolicy.normalize(path)
        let known = try worktrees(repo)
        guard let match = known.first(where: { WorkspacePathPolicy.normalize($0.path) == target }) else {
            throw GitError("Git kent geen worktree op \(path).")
        }
        guard !match.isMain else { throw GitError("Dit is de hoofdmap van de repository; die haalt Nook nooit weg.") }
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(match.path)
        try run(arguments, in: repo, timeout: 120)
    }

    /// Verwijdert een branch alleen als hij al is samengevoegd (`git branch -d`, nooit -D).
    func deleteMergedBranch(repo: String, branch: String) throws {
        try run(["branch", "-d", branch], in: repo)
    }

    // MARK: Klonen

    /// Alleen gewone Git-adressen (https, ssh, git@host:pad); nooit iets dat als optie gelezen kan worden.
    static func isCloneURL(_ url: String) -> Bool {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("-"), !clean.contains(" "), clean.count < 500 else { return false }
        if clean.hasPrefix("https://") || clean.hasPrefix("ssh://") { return URL(string: clean)?.host != nil }
        // scp-stijl: git@github.com:owner/repo.git
        return clean.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/~-]+$"#, options: .regularExpression) != nil
    }

    /// De mapnaam die git clone zelf zou kiezen: "repo" uit ".../repo.git".
    static func cloneFolderName(_ url: String) -> String {
        var last = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while last.hasSuffix("/") { last.removeLast() }
        last = String(last.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "repo")
        if last.hasSuffix(".git") { last.removeLast(4) }
        return WorktreeNaming.slug(last, limit: 60)
    }

    /// Kloont naar <parent>/<naam>. De map mag nog niet bestaan.
    func clone(url: String, into parent: String) throws -> String {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isCloneURL(clean) else { throw GitError("Dit lijkt geen Git-adres (https://… of git@host:pad).") }
        let target = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(Self.cloneFolderName(clean)).path
        guard !FileManager.default.fileExists(atPath: target) else { throw GitError("De map \(target) bestaat al.") }
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let output = try raw(["clone", "--", clean, target], in: parent, timeout: 900)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message.isEmpty ? "Klonen mislukte." : message)
        }
        return target
    }

    // MARK: Committen en pushen

    /// Zet precies deze bestanden klaar en commit ze met jouw bericht.
    func commit(_ directory: String, message: String, paths: [String]) throws -> String {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw GitError("Een commit heeft een bericht nodig.") }
        guard !paths.isEmpty else { throw GitError("Kies minstens één bestand.") }
        try run(["add", "-A", "--"] + paths, in: directory)
        try run(["commit", "-m", clean], in: directory, timeout: 120)
        return try run(["rev-parse", "--short", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pusht de huidige branch naar `remote` en zet de upstream. Nooit force.
    func push(_ directory: String, remote: String, branch: String) throws {
        guard remotes(directory).contains(remote) else { throw GitError("Er is geen remote '\(remote)'.") }
        try run(["push", "--set-upstream", remote, "HEAD:refs/heads/" + branch], in: directory, timeout: 300)
    }

    // MARK: Lezen van Git-uitvoer (los te testen)

    static func parseStatus(_ text: String) -> GitStatus {
        var status = GitStatus()
        var entries = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        if let first = entries.first, first.hasPrefix("## ") {
            entries = entries.dropFirst()
            parseBranchLine(String(first.dropFirst(3)), into: &status)
        }
        while let entry = entries.first {
            entries = entries.dropFirst()
            guard entry.count >= 4 else { continue }
            let chars = Array(entry)
            let x = chars[0]
            let y = chars[1]
            let path = String(chars[3...])
            var oldPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                oldPath = entries.first
                entries = entries.dropFirst()
            }
            let kind: GitChangeKind
            if x == "?" {
                kind = .untracked
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                kind = .conflicted
            } else if x == "R" || y == "R" {
                kind = .renamed
            } else if x == "C" || y == "C" {
                kind = .copied
            } else if x == "A" {
                kind = .added
            } else if x == "D" || y == "D" {
                kind = .deleted
            } else if x == "T" || y == "T" {
                kind = .typeChanged
            } else {
                kind = .modified
            }
            if x == "!" { continue }
            status.files.append(GitFileChange(path: path, oldPath: oldPath, kind: kind,
                                              staged: x != " " && x != "?", unstaged: y != " "))
        }
        return status
    }

    private static func parseBranchLine(_ line: String, into status: inout GitStatus) {
        var head = line
        if let bracket = head.range(of: " [") {
            let info = head[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if words.count == 2, let count = Int(words[1]) {
                    if words[0] == "ahead" { status.ahead = count }
                    if words[0] == "behind" { status.behind = count }
                }
            }
            head = String(head[..<bracket.lowerBound])
        }
        if head.hasPrefix("HEAD (no branch)") {
            status.detached = true
            return
        }
        if head.hasPrefix("No commits yet on ") {
            status.branch = String(head.dropFirst("No commits yet on ".count))
            return
        }
        let parts = head.components(separatedBy: "...")
        status.branch = parts[0]
        if parts.count > 1 { status.upstream = parts[1] }
    }

    /// `git diff --numstat -z`: per pad hoeveel regels erbij en eraf (nil bij binaire bestanden).
    static func parseNumstat(_ text: String) -> [String: (added: Int?, removed: Int?)] {
        var result: [String: (added: Int?, removed: Int?)] = [:]
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let entry = fields.first {
            fields = fields.dropFirst()
            let parts = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            let added = Int(parts[0])
            let removed = Int(parts[1])
            var path = parts[2]
            if path.isEmpty {
                // Hernoemd: daarna volgen het oude en het nieuwe pad.
                fields = fields.dropFirst()
                path = fields.first ?? ""
                fields = fields.dropFirst()
            }
            if !path.isEmpty { result[path] = (added, removed) }
        }
        return result
    }

    static func parseWorktrees(_ text: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        for block in text.components(separatedBy: "\n\n") {
            var path = ""
            var head = ""
            var branch: String?
            var locked = false
            var prunable = false
            var bare = false
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst(7))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
                }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
                else if line == "bare" { bare = true }
            }
            guard !path.isEmpty, !bare else { continue }
            result.append(GitWorktree(path: path, head: head, branch: branch, isMain: result.isEmpty,
                                      locked: locked, prunable: prunable))
        }
        return result
    }

    /// Regels in een nieuw tekstbestand; nil voor grote of binaire bestanden.
    static func lineCount(of path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size < 2_000_000,
              let data = FileManager.default.contents(atPath: path), !data.contains(0) else { return nil }
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }
}
