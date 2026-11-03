import Foundation

// Sessions on another machine, over SSH. The agent runs
// there and speaks over the SSH connection exactly as it does locally: Claude Code's stream-json, Codex's app-server and
// ACP all use stdin and stdout. Git runs there too, over ssh: status, diff, commit, push, snapshots per turn and
// worktrees (in ~/.nook/worktrees on that machine). Only the workspace bridge needs this Mac and stays off. Foundation only, so tests can use it independently.

/// A machine you can reach with `ssh`: an alias from ~/.ssh/config or user@host, with a key (your agent, your config or
/// a key file here) or a password you type once per run of Nook (see RemotePasswords). Only how to reach it is kept, in
/// the defaults; keys stay in ~/.ssh and your agent, and a password is never written anywhere.
struct RemoteMachine: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String
    var host: String
    var port: Int? = nil
    /// A key file for this machine only ("~/.ssh/buildbox_ed25519"); nil uses your ssh config and agent.
    var identityFile: String? = nil
    /// When a connection test passed or a session started there last.
    var lastUsedAt: Date? = nil
    /// Logs in with a password: Nook asks for it before the first session, then keeps it in memory until it quits (or in
    /// the Keychain, when you chose that).
    var passwordLogin: Bool? = nil

    var usesPassword: Bool { passwordLogin == true }
}

/// SSH passwords you typed: in memory for this run of Nook, and in the Keychain only when you chose "Keep in Keychain"
/// (then a machine is unlocked again after a restart). Never anywhere else on disk. ssh gets one through SSH_ASKPASS
/// (see RemoteLaunch.environment), so a password is typed once, not on every git call or turn.
final class RemotePasswords: @unchecked Sendable {
    static let shared = RemotePasswords()

    /// Where kept passwords live; the app sets Nook's Keychain vault at launch (see `keychainAccount`). Nil in tests,
    /// where nothing is kept beyond memory.
    struct Keychain: Sendable {
        var read: @Sendable (String) -> String?
        var write: @Sendable (String, String) -> Bool
        var remove: @Sendable (String) -> Void
    }

    private let lock = NSLock()
    private var passwords: [String: String] = [:]
    /// Machines whose Keychain entry was looked up this run, found or not: one lookup each, not one per ssh call.
    private var looked: Set<String> = []
    private var kept: Set<String> = []
    private var keychainStore: Keychain?

    init(keychain: Keychain? = nil) {
        keychainStore = keychain
    }

    var keychain: Keychain? {
        get { lock.lock(); defer { lock.unlock() }; return keychainStore }
        set { lock.lock(); keychainStore = newValue; looked = []; lock.unlock() }
    }

    /// The account of a machine's password in the Keychain vault.
    static func keychainAccount(_ machineID: String) -> String { "ssh.password." + machineID }

    /// The password Nook has for the machine: typed in this run, or kept in the Keychain.
    func password(for machineID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let password = passwords[machineID] { return password }
        guard let keychainStore, looked.insert(machineID).inserted else { return nil }
        // Base64, because the vault trims its values and a password may start or end with a space.
        guard let stored = keychainStore.read(Self.keychainAccount(machineID)),
              let data = Data(base64Encoded: stored), let password = String(data: data, encoding: .utf8),
              !password.isEmpty else { return nil }
        passwords[machineID] = password
        kept.insert(machineID)
        return password
    }

    /// Keeps a password in memory, and in the Keychain when `keep`; nil or empty forgets it in both. Returns false
    /// when it should have gone to the Keychain and could not (it is still kept for this run).
    @discardableResult
    func set(_ password: String?, for machineID: String, keep: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let account = Self.keychainAccount(machineID)
        // Never looked up: an older kept password may be there, so not keeping now removes it too.
        let mayBeKept = kept.remove(machineID) != nil || !looked.contains(machineID)
        looked.insert(machineID)
        guard let password, !password.isEmpty else {
            passwords[machineID] = nil
            if mayBeKept { keychainStore?.remove(account) }
            return true
        }
        passwords[machineID] = password
        guard keep else {
            if mayBeKept { keychainStore?.remove(account) }
            return true
        }
        guard let keychainStore, keychainStore.write(account, Data(password.utf8).base64EncodedString()) else { return false }
        kept.insert(machineID)
        return true
    }

    /// Whether the machine's password is in the Keychain, not only in memory.
    func isKept(_ machineID: String) -> Bool {
        _ = password(for: machineID)
        lock.lock(); defer { lock.unlock() }
        return kept.contains(machineID)
    }

    /// Whether a session there can start: a machine with a key always, one with a password once Nook has it.
    func isUnlocked(_ machine: RemoteMachine) -> Bool {
        !machine.usesPassword || password(for: machine.id) != nil
    }
}

/// The small program ssh runs to ask for a password (SSH_ASKPASS). It answers only a password prompt, with the password
/// Nook put in its environment; a host key question or anything else gets no answer, so ssh stops instead of trusting
/// a new machine on your behalf.
enum RemoteAskpass {
    static let variable = "NOOK_SSH_PASSWORD"

    static let script = """
    #!/bin/sh
    # Nook: answers ssh's password prompt with the password you typed in Nook (kept in memory, passed in the environment).
    case "$1" in
      *assword*) ;;
      *) exit 1 ;;
    esac
    [ -n "${\(variable)+x}" ] || exit 1
    printf '%s\\n' "$\(variable)"
    """

    /// The script in Nook's support folder (only you can enter it), written when missing or changed.
    static func path(in directory: URL = NookPaths.supportDirectory) -> String? {
        let url = directory.appendingPathComponent("ssh-askpass")
        let manager = FileManager.default
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return manager.isExecutableFile(atPath: url.path) ? url.path : nil
    }
}

/// Where a session runs on a remote machine. The folder is a path on that machine ("~/code/app" or "/srv/app").
struct RemoteTarget: Codable, Equatable, Sendable {
    var machineID: String
    var name: String
    var host: String
    var port: Int? = nil
    var identityFile: String? = nil
    var directory: String

    init(machine: RemoteMachine, directory: String) {
        machineID = machine.id
        name = machine.name
        host = machine.host
        port = machine.port
        identityFile = machine.identityFile
        self.directory = directory
    }
}

enum RemoteMachines {
    static let defaultsKey = "agents.remoteMachines"

    static func load(defaults: UserDefaults = .standard) -> [RemoteMachine] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RemoteMachine].self, from: data)) ?? []
    }

    static func save(_ machines: [RemoteMachine], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(machines), forKey: defaultsKey)
    }

    static func upsert(_ machine: RemoteMachine, defaults: UserDefaults = .standard) {
        var machines = load(defaults: defaults).filter { $0.id != machine.id }
        machines.append(machine)
        save(machines, defaults: defaults)
    }

    static func remove(id: String, defaults: UserDefaults = .standard) {
        save(load(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    /// Changes one saved machine where it is in the list; nothing when it was removed.
    @discardableResult
    static func update(id: String, defaults: UserDefaults = .standard, _ change: (inout RemoteMachine) -> Void) -> RemoteMachine? {
        var machines = load(defaults: defaults)
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return nil }
        change(&machines[index])
        save(machines, defaults: defaults)
        return machines[index]
    }

    /// Notes that the machine answered: a connection test passed, or a session started there.
    static func markUsed(id: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        update(id: id, defaults: defaults) { $0.lastUsedAt = date }
    }

    /// An ssh destination: an alias or user@host, never something ssh would read as an option.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.-_:[]"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A key file on this Mac: absolute or from your home ("~/.ssh/id_buildbox"), one line.
    static func isValidIdentityFile(_ path: String) -> Bool {
        let clean = path.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.count <= 1024, !clean.contains("\n"), !clean.contains("\0") else { return false }
        return clean.hasPrefix("/") || clean.hasPrefix("~/")
    }

    /// A folder on the remote machine: absolute, or from its home ("~", "~/code").
    static func isValidDirectory(_ path: String) -> Bool {
        let clean = path.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains("\n"), !clean.contains("\0") else { return false }
        return clean.hasPrefix("/") || clean == "~" || clean.hasPrefix("~/")
    }
}

/// Turns a local launch into the same agent started on the remote machine.
enum RemoteLaunch {
    static let ssh = "/usr/bin/ssh"

    /// `ssh -T … -- host 'exec "$SHELL" -lc "cd … && exec agent …"'`. The remote login shell finds the agent the way your
    /// terminal there would; without a password typed in Nook `BatchMode` makes a missing key fail at once instead of
    /// waiting for a prompt nobody sees. Only `environment` goes along (a local account folder means nothing over there).
    static func wrap(_ spec: LaunchSpec, target: RemoteTarget, environment: [String: String] = [:]) -> LaunchSpec {
        let secret = password(target)
        var arguments = ["-T"] + authentication(password: secret) + ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4"]
        arguments += destination(port: target.port, identityFile: target.identityFile)
        arguments += ["--", target.host, command(executable: spec.executable, arguments: spec.arguments,
                                                   directory: target.directory, environment: environment)]
        return LaunchSpec(executable: ssh, arguments: arguments, extraEnvironment: askpassEnvironment(password: secret),
                          workingDirectory: NSHomeDirectory(), initialInput: spec.initialInput, keepsInputOpen: spec.keepsInputOpen)
    }

    /// The command line the remote side runs.
    static func command(executable: String, arguments: [String], directory: String, environment: [String: String] = [:]) -> String {
        let agent: String
        // An ACP agent you added already comes as "<login shell> -ilc '<exec …>'": its line runs as it is.
        if arguments.count == 2, arguments[0] == "-ilc" {
            agent = arguments[1]
        } else {
            let program = URL(fileURLWithPath: executable).lastPathComponent
            agent = "exec " + ([program] + arguments).map(CustomAgents.quote).joined(separator: " ")
        }
        let exports = environment.keys.sorted().filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
            .map { "export \($0)=" + CustomAgents.quote(environment[$0] ?? "") + "; " }.joined()
        let inner = exports + "cd " + quotedDirectory(directory) + " && " + agent
        return #"exec "${SHELL:-/bin/sh}" -lc "# + CustomAgents.quote(inner)
    }

    /// The ssh arguments for one git command on the remote machine, in `directory` there (a leading `-C <folder>` becomes
    /// the folder). One shared connection per machine (ControlMaster) keeps the many small git calls fast.
    static func git(_ arguments: [String], target: RemoteTarget, directory: String?, environment: [String: String] = [:]) -> [String] {
        var rest = arguments
        var folder = directory
        if rest.count >= 2, rest[0] == "-C" {
            folder = rest[1]
            rest.removeFirst(2)
        }
        var variables = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        for (key, value) in environment { variables[key] = value }
        return run("git", rest, target: target, directory: folder, environment: variables)
    }

    /// One program on the remote machine, in `directory` there, with `environment` set; over the shared connection.
    static func run(_ program: String, _ arguments: [String], target: RemoteTarget, directory: String?,
                    environment: [String: String] = [:], password: String? = nil) -> [String] {
        let exports = environment.keys.sorted().filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
            .map { $0 + "=" + CustomAgents.quote(environment[$0] ?? "") + " " }.joined()
        var line = exports + "exec " + ([program] + arguments).map(CustomAgents.quote).joined(separator: " ")
        if let folder = directory { line = "cd " + quotedDirectory(folder) + " && " + line }
        var ssh = ["-T"] + authentication(password: password ?? self.password(target)) + ["-o", "ConnectTimeout=10",
                   "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/nook-ssh-%C", "-o", "ControlPersist=120"]
        ssh += destination(port: target.port, identityFile: target.identityFile)
        return ssh + ["--", target.host, #"exec "${SHELL:-/bin/sh}" -lc "# + CustomAgents.quote(line)]
    }

    /// The password typed for the target's machine in this run of Nook, if any.
    static func password(_ target: RemoteTarget) -> String? {
        RemotePasswords.shared.password(for: target.machineID)
    }

    /// Without a password ssh never prompts (`BatchMode`); with one it may ask once, through SSH_ASKPASS, so a wrong
    /// password fails at once instead of locking the account.
    static func authentication(password: String?) -> [String] {
        password == nil ? ["-o", "BatchMode=yes"] : ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"]
    }

    /// What ssh needs in its environment to get the password: Nook's askpass program, forced even without a display,
    /// and the password itself. Empty without a password, or when the program cannot be written.
    static func askpassEnvironment(password: String?, askpass: String? = nil) -> [String: String] {
        guard let password, let program = askpass ?? RemoteAskpass.path() else { return [:] }
        return ["SSH_ASKPASS": program, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", RemoteAskpass.variable: password]
    }

    /// This process's environment plus the password for `target`'s machine: for every ssh call Nook runs itself.
    static func environment(for target: RemoteTarget, password: String? = nil) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(askpassEnvironment(password: password ?? self.password(target))) { $1 }
    }

    /// The port and key file options every ssh call to a machine takes. With its own key file ssh offers only that key
    /// (`IdentitiesOnly`), so a full agent does not use up the server's attempts first.
    static func destination(port: Int?, identityFile: String?) -> [String] {
        var options: [String] = []
        if let port { options += ["-p", String(port)] }
        if let key = identityFile?.trimmingCharacters(in: .whitespaces), RemoteMachines.isValidIdentityFile(key) {
            options += ["-i", key, "-o", "IdentitiesOnly=yes"]
        }
        return options
    }

    /// "~/code/app" stays relative to the remote home: the tilde unquoted, the rest quoted.
    static func quotedDirectory(_ path: String) -> String {
        let clean = path.trimmingCharacters(in: .whitespaces)
        if clean == "~" { return "~" }
        if clean.hasPrefix("~/") { return "~/" + CustomAgents.quote(String(clean.dropFirst(2))) }
        return CustomAgents.quote(clean)
    }
}

/// Small questions to the remote machine, over the shared connection. Synchronous: call off the main thread.
enum RemoteShell {
    /// $HOME there: where Nook keeps its worktrees on that machine.
    static func home(_ target: RemoteTarget) -> String? {
        guard let output = try? ProcessRunner.run(RemoteLaunch.ssh, RemoteLaunch.run("printenv", ["HOME"], target: target, directory: nil),
                                                  environment: RemoteLaunch.environment(for: target), timeout: 20),
              output.status == 0 else { return nil }
        let home = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.hasPrefix("/") ? home : nil
    }

    static func exists(_ path: String, on target: RemoteTarget) -> Bool {
        (try? ProcessRunner.run(RemoteLaunch.ssh, RemoteLaunch.run("test", ["-e", path], target: target, directory: nil),
                                environment: RemoteLaunch.environment(for: target), timeout: 20))?.status == 0
    }

    /// One login to the machine that also finds which of `commands` (the agents' CLIs) are on its PATH, the way a
    /// session's login shell would. Prints one found command per line.
    static func agentCheck(_ commands: [String], target: RemoteTarget, password: String? = nil) -> [String] {
        let names = commands.filter { $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }
        let script = names.isEmpty ? "true" : "for c in " + names.joined(separator: " ") + #"; do command -v "$c" >/dev/null 2>&1 && printf '%s\n' "$c"; done; true"#
        return RemoteLaunch.run("sh", ["-c", script], target: target, directory: nil, password: password)
    }

    /// Logs in once with `password` (and finds the agents there): what unlocking a machine checks before Nook keeps the
    /// password. Synchronous: call off the main thread.
    static func check(_ machine: RemoteMachine, password: String?, commands: [String]) -> Result<[String], CheckError> {
        let target = RemoteTarget(machine: machine, directory: "~")
        let output: ProcessRunner.Output
        do {
            output = try ProcessRunner.run(RemoteLaunch.ssh, agentCheck(commands, target: target, password: password),
                                           environment: RemoteLaunch.environment(for: target, password: password), timeout: 25)
        } catch {
            return .failure(CheckError(message: error.localizedDescription, status: -1, needsPassword: false))
        }
        guard output.status == 0, !output.timedOut else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CheckError(message: String(message.prefix(300)), status: output.status,
                                       needsPassword: message.contains("Permission denied")
                                           && (message.contains("password") || message.contains("keyboard-interactive"))))
        }
        return .success(foundAgents(output.stdout, asked: commands))
    }

    struct CheckError: Error, Equatable {
        var message: String
        var status: Int32
        /// The server takes a password and no key got in: worth asking for one.
        var needsPassword: Bool
    }

    /// The commands from `agentCheck`'s output, in the order they were asked for.
    static func foundAgents(_ output: String, asked commands: [String]) -> [String] {
        let found = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return commands.filter(found.contains)
    }

    /// Where a session's worktree goes on the remote machine: ~/.nook/worktrees/<repository>/<branch>.
    static func worktreeRoot(home: String) -> String {
        (home as NSString).appendingPathComponent(".nook/worktrees")
    }
}
