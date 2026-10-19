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

    /// The names of the agents the process scan can recognise.
    static var agentNames: [String] { kinds.map(\.name) }

    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]
    private static let backgroundModes: Set<String> = ["app-server", "mcp-server", "mcp", "proto"]

    private struct CachedProcess {
        let command: String
        var cwd: String
        var cwdUpdatedAt: Date
        let envLine: String
    }

    private static let cacheLock = NSLock()
    private static var processCache: [Int32: CachedProcess] = [:]
    private static let cwdTTL: TimeInterval = 30

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

        var found: [(pid: Int32, name: String, command: String)] = []
        for line in list.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  pid != me, parent != me else { continue }   // Ignore Nook's own helper processes (codex app-server, claude -p)
            let command = String(fields[2])
            if let name = identify(command) { found.append((pid, name, command)) }
        }
        guard !found.isEmpty else {
            cacheLock.lock()
            processCache.removeAll()
            cacheLock.unlock()
            return []
        }

        let now = Date()
        let activePIDs = Set(found.map(\.pid))
        var needLsof: [Int32] = []
        var needEnv: [Int32] = []
        var folders: [Int32: String] = [:]
        var environments: [Int32: String] = [:]

        cacheLock.lock()
        processCache = processCache.filter { activePIDs.contains($0.key) }
        for item in found {
            if let cached = processCache[item.pid], cached.command == item.command {
                environments[item.pid] = cached.envLine
                if !cached.cwd.isEmpty, now.timeIntervalSince(cached.cwdUpdatedAt) < cwdTTL {
                    folders[item.pid] = cached.cwd
                } else {
                    needLsof.append(item.pid)
                }
            } else {
                needLsof.append(item.pid)
                needEnv.append(item.pid)
            }
        }
        cacheLock.unlock()

        // Working directory per process, in batch (with -b -w so lsof never blocks on network/FUSE mounts).
        if !needLsof.isEmpty {
            let lsofPIDs = needLsof.map(String.init).joined(separator: ",")
            if let out = run("/usr/sbin/lsof", ["-b", "-w", "-a", "-p", lsofPIDs, "-d", "cwd", "-Fpn"]) {
                var current: Int32?
                for line in out.split(separator: "\n") {
                    if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
                    else if line.hasPrefix("n"), let pid = current { folders[pid] = String(line.dropFirst()) }
                }
            }
        }

        // The environment of each new process: which account it runs under, and whether Nook started it itself.
        if !needEnv.isEmpty {
            let envPIDs = needEnv.map(String.init).joined(separator: ",")
            let fetched = environmentLines(envPIDs)
            for pid in needEnv {
                environments[pid] = fetched[pid] ?? ""
            }
        }

        cacheLock.lock()
        for item in found {
            let previous = processCache[item.pid]
            let cwd = folders[item.pid] ?? previous?.cwd ?? ""
            let envLine = environments[item.pid] ?? previous?.envLine ?? ""
            let cwdUpdated = needLsof.contains(item.pid) ? now : (previous?.cwdUpdatedAt ?? now)
            processCache[item.pid] = CachedProcess(command: item.command, cwd: cwd, cwdUpdatedAt: cwdUpdated, envLine: envLine)
            folders[item.pid] = cwd
            environments[item.pid] = envLine
        }
        cacheLock.unlock()

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
        if lower.hasPrefix("grep ") || lower.contains(" grep ") { return nil }

        let tokens = lower.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        // Background daemon services for an editor/app are not user interactive sessions.
        if tokens.contains(where: { backgroundModes.contains($0) }) { return nil }
        let program = URL(fileURLWithPath: first).lastPathComponent
        // The helpers of an app (Antigravity.app/Contents/…) are no sessions, but an agent's own command line tool
        // is, even when the app ships it inside its bundle (agy lives in Antigravity.app).
        let isAgentCommand = kinds.contains { $0.commands.contains(program) }
        if lower.contains(".app/contents") && !isAgentCommand { return nil }

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

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 3.0) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let readGroup = DispatchGroup()
        var outData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = output.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        _ = readGroup.wait(timeout: .now() + 0.5)
        return String(data: outData, encoding: .utf8)
    }
}
