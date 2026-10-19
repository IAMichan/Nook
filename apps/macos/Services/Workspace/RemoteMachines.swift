import Foundation

// Sessions on another machine, over SSH. The agent runs
// there and speaks over the SSH connection exactly as it does locally: Claude Code's stream-json, Codex's app-server and
// ACP all use stdin and stdout. What needs the folder on this Mac (git, checkpoints, worktrees, the diff, the workspace
// bridge) is off for such a session. Foundation only, so tests can use it independently.

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

    /// "~/code/app" stays relative to the remote home: the tilde unquoted, the rest quoted.
    static func quotedDirectory(_ path: String) -> String {
        let clean = path.trimmingCharacters(in: .whitespaces)
        if clean == "~" { return "~" }
        if clean.hasPrefix("~/") { return "~/" + CustomAgents.quote(String(clean.dropFirst(2))) }
        return CustomAgents.quote(clean)
    }
}
