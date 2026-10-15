import Foundation

/// An agent running as a process on this Mac, even without hooks configured.
struct DetectedAgent: Hashable {
    let pid: Int32
    let name: String
    let cwd: String
    /// CLAUDE_CONFIG_DIR or CODEX_HOME from process environment: which account it runs under. Empty if unknown.
    var home: String = ""
}

/// Scans running AI agents (Claude Code, Codex, Gemini CLI, Aider, OpenCode, Copilot CLI, Amp, Hermes, …) from process table.
/// Enables immediate visibility in Nook; hooks are only needed for rich details and approvals.
/// Names match AgentHub so agents reporting via hooks are not duplicated.
enum LocalAgentScanner {
    private struct Kind {
        let name: String
        let commands: Set<String>      // executable name
        let packages: [String]         // path substring if running via node or python
    }

    private static let kinds: [Kind] = [
        Kind(name: "Claude Code", commands: ["claude"], packages: ["@anthropic-ai/claude-code"]),
        Kind(name: "Codex", commands: ["codex"], packages: ["@openai/codex"]),
        Kind(name: "Gemini CLI", commands: ["gemini"], packages: ["@google/gemini-cli"]),
        Kind(name: "Aider", commands: ["aider"], packages: []),
        Kind(name: "OpenCode", commands: ["opencode"], packages: ["opencode-ai"]),
        Kind(name: "Copilot CLI", commands: ["copilot"], packages: ["@github/copilot"]),
        Kind(name: "Amp", commands: ["amp"], packages: ["@sourcegraph/amp"]),
        Kind(name: "Cursor", commands: ["cursor-agent"], packages: []),
        Kind(name: "Antigravity", commands: ["agy"], packages: []),
        Kind(name: "Hermes", commands: ["hermes"], packages: ["hermes-agent", "hermes_cli"]),
        Kind(name: "Muse Code", commands: ["muse"], packages: []),
        Kind(name: "Qwen Code", commands: ["qwen"], packages: ["@qwen-code/qwen-code"])
    ]

    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]
    private static let backgroundModes: Set<String> = ["app-server", "mcp-server", "mcp", "proto"]

    static func scan() async -> [DetectedAgent] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scanNow())
            }
        }
    }

    private static func scanNow() -> [DetectedAgent] {
        guard let list = run("/bin/ps", ["-axo", "pid=,ppid=,command="]) else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier

        var found: [(pid: Int32, name: String)] = []
        for line in list.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  pid != me, parent != me else { continue }   // Ignore Nook's own helper processes (codex app-server, claude -p)
            let command = String(fields[2])
            if let name = identify(command) { found.append((pid, name)) }
        }
        guard !found.isEmpty else { return [] }

        // Working directory per process, in batch.
        var folders: [Int32: String] = [:]
        let pids = found.map { String($0.pid) }.joined(separator: ",")
        if let out = run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-Fpn"]) {
            var current: Int32?
            for line in out.split(separator: "\n") {
                if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
                else if line.hasPrefix("n"), let pid = current { folders[pid] = String(line.dropFirst()) }
            }
        }
        // The environment of each process: which account it runs under, and whether Nook started it itself.
        let environments = environmentLines(pids)
        return found.compactMap { item in
            let line = environments[item.pid] ?? ""
            guard !AgentProcessEnvironment.isNookOwned(line) else { return nil }
            let home = AgentProcessEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: line)
                ?? AgentProcessEnvironment.value(of: "CODEX_HOME", in: line) ?? ""
            return DetectedAgent(pid: item.pid, name: item.name, cwd: folders[item.pid] ?? "", home: home)
        }
    }

    /// The command line and environment of each process (`ps -E`), by pid. Empty if unavailable: then every session
    /// belongs to the primary account and none is recognised as Nook's own.
    private static func environmentLines(_ pids: String) -> [Int32: String] {
        guard let out = run("/bin/ps", ["-E", "-ww", "-o", "pid=,command=", "-p", pids]) else { return [:] }
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            result[pid] = String(fields[1])
        }
        return result
    }

    /// Identifies an agent from its command line; excludes .app bundles and search commands.
    private static func identify(_ command: String) -> String? {
        let lower = command.lowercased()
        if lower.contains(".app/contents") || lower.hasPrefix("grep ") || lower.contains(" grep ") { return nil }

        let tokens = lower.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        // Background daemon services for an editor/app are not user interactive sessions.
        if tokens.contains(where: { backgroundModes.contains($0) }) { return nil }
        let program = URL(fileURLWithPath: first).lastPathComponent

        // The first command token, or for node/python the script argument following it.
        var candidates = [program]
        if interpreters.contains(program) {
            candidates += tokens.dropFirst().prefix(3).filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        for kind in kinds {
            if candidates.contains(where: { kind.commands.contains($0) }) { return kind.name }
            if interpreters.contains(program), kind.packages.contains(where: { lower.contains($0) }) { return kind.name }
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
