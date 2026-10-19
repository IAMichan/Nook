import Foundation

// Sessions on another machine, over SSH. The agent runs
// there and speaks over the SSH connection exactly as it does locally: Claude Code's stream-json, Codex's app-server and
// ACP all use stdin and stdout. Git runs there too, over ssh: status, diff, commit, push, snapshots per turn and
// worktrees (in ~/.nook/worktrees on that machine). Only the workspace bridge needs this Mac and stays off. Foundation only, so tests can use it independently.

/// A machine you can reach with `ssh` without typing a password (a key, or your agent): an alias from ~/.ssh/config or
/// user@host.
struct RemoteMachine: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String
    var host: String
    var port: Int? = nil
}

/// Where a session runs on a remote machine. The folder is a path on that machine ("~/code/app" or "/srv/app").
struct RemoteTarget: Codable, Equatable, Sendable {
    var machineID: String
    var name: String
    var host: String
    var port: Int? = nil
    var directory: String

    init(machine: RemoteMachine, directory: String) {
        machineID = machine.id
        name = machine.name
        host = machine.host
        port = machine.port
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

    /// An ssh destination: an alias or user@host, never something ssh would read as an option.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.-_:[]"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
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
    /// terminal there would; `BatchMode` makes a missing key fail at once instead of waiting for a password Nook cannot
    /// type. Only `environment` goes along (a local account folder means nothing over there).
    static func wrap(_ spec: LaunchSpec, target: RemoteTarget, environment: [String: String] = [:]) -> LaunchSpec {
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4"]
        if let port = target.port { arguments += ["-p", String(port)] }
        arguments += ["--", target.host, command(executable: spec.executable, arguments: spec.arguments,
                                                   directory: target.directory, environment: environment)]
        return LaunchSpec(executable: ssh, arguments: arguments, extraEnvironment: [:],
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
                    environment: [String: String] = [:]) -> [String] {
        let exports = environment.keys.sorted().filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
            .map { $0 + "=" + CustomAgents.quote(environment[$0] ?? "") + " " }.joined()
        var line = exports + "exec " + ([program] + arguments).map(CustomAgents.quote).joined(separator: " ")
        if let folder = directory { line = "cd " + quotedDirectory(folder) + " && " + line }
        var ssh = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                   "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/nook-ssh-%C", "-o", "ControlPersist=120"]
        if let port = target.port { ssh += ["-p", String(port)] }
        return ssh + ["--", target.host, #"exec "${SHELL:-/bin/sh}" -lc "# + CustomAgents.quote(line)]
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
                                                  environment: ProcessInfo.processInfo.environment, timeout: 20),
              output.status == 0 else { return nil }
        let home = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.hasPrefix("/") ? home : nil
    }

    static func exists(_ path: String, on target: RemoteTarget) -> Bool {
        (try? ProcessRunner.run(RemoteLaunch.ssh, RemoteLaunch.run("test", ["-e", path], target: target, directory: nil),
                                environment: ProcessInfo.processInfo.environment, timeout: 20))?.status == 0
    }

    /// Where a session's worktree goes on the remote machine: ~/.nook/worktrees/<repository>/<branch>.
    static func worktreeRoot(home: String) -> String {
        (home as NSString).appendingPathComponent(".nook/worktrees")
    }
}
