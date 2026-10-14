import Foundation

/// Een agent die als proces op deze Mac draait, ook zonder dat hooks zijn gekoppeld.
struct DetectedAgent: Hashable {
    let pid: Int32
    let name: String
    let cwd: String
}

/// Zoekt draaiende AI-agents (Claude Code, Codex, Gemini CLI, Aider, OpenCode, Copilot CLI, Amp, Hermes, …) in de lijst met processen.
/// Zo staan ze meteen in Nook; hooks zijn alleen nodig voor details en goedkeuring.
/// De namen zijn dezelfde als in AgentHub, zodat een agent die ook via hooks meldt er niet dubbel staat.
enum LocalAgentScanner {
    private struct Kind {
        let name: String
        let commands: Set<String>      // naam van het programma
        let packages: [String]         // stukje pad als het via node of python draait
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
                  pid != me, parent != me else { continue }   // Nooks eigen hulpprocessen (codex app-server, claude -p) niet
            let command = String(fields[2])
            if let name = identify(command) { found.append((pid, name)) }
        }
        guard !found.isEmpty else { return [] }

        // Werkmap per proces, in één keer.
        var folders: [Int32: String] = [:]
        let pids = found.map { String($0.pid) }.joined(separator: ",")
        if let out = run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-Fpn"]) {
            var current: Int32?
            for line in out.split(separator: "\n") {
                if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
                else if line.hasPrefix("n"), let pid = current { folders[pid] = String(line.dropFirst()) }
            }
        }
        return found.map { DetectedAgent(pid: $0.pid, name: $0.name, cwd: folders[$0.pid] ?? "") }
    }

    /// Herkent een agent aan de opdrachtregel; apps (.app) en zoekopdrachten tellen niet mee.
    private static func identify(_ command: String) -> String? {
        let lower = command.lowercased()
        if lower.contains(".app/contents") || lower.hasPrefix("grep ") || lower.contains(" grep ") { return nil }

        let tokens = lower.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        // Achtergronddiensten van een agent (voor een editor of app) zijn geen sessie van jou.
        if tokens.contains(where: { backgroundModes.contains($0) }) { return nil }
        let program = URL(fileURLWithPath: first).lastPathComponent

        // Het eerste woord, of bij node/python het script dat daarna komt.
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
