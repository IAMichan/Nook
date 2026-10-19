import Foundation
import Darwin

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

    static func scan() async -> [DetectedAgent] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scanNow())
            }
        }
    }

    /// Reads the process table straight from the kernel, as `ps`, `ps -E` and `lsof` would, but without starting any of
    /// them: this runs every ten seconds, and three short-lived processes per scan cost far more than the reads themselves.
    private static func scanNow() -> [DetectedAgent] {
        let me = ProcessInfo.processInfo.processIdentifier
        var buffer = [UInt8](repeating: 0, count: argumentsMax)
        var found: [DetectedAgent] = []
        for pid in allProcesses() where pid > 0 && pid != me {
            // Fails for other users' processes, like `ps` does; those are never your agents.
            guard let process = arguments(pid, buffer: &buffer), !process.arguments.isEmpty,
                  let name = identify(process.arguments.joined(separator: " ")),
                  let parent = parentProcess(pid), parent != me else { continue }   // Ignore Nook's own helper processes (codex app-server, claude -p)
            // The same line `ps -E` prints: the command line, then the environment.
            let line = (process.arguments + process.environment).joined(separator: " ")
            guard !AgentProcessEnvironment.isNookOwned(line) else { continue }
            let home = AgentProcessEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: line)
                ?? AgentProcessEnvironment.value(of: "CODEX_HOME", in: line) ?? ""
            found.append(DetectedAgent(pid: pid, name: name, cwd: workingDirectory(pid) ?? "", home: home))
        }
        return found.sorted { $0.pid < $1.pid }
    }

    // MARK: Kernel reads

    /// The size of the largest argument area a process can have (`kern.argmax`).
    private static let argumentsMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 1 << 20
    }()

    private static func allProcesses() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(min(Int(filled), pids.count)))
    }

    /// The command line and environment of a process (`kern.procargs2`).
    private static func arguments(_ pid: pid_t, buffer: inout [UInt8]) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArguments(buffer, count: size)
    }

    /// Splits a `kern.procargs2` area: argc, the executable path, then argc arguments and the environment, each ending
    /// in a zero byte. Nil when it is too short to hold argc.
    static func parseArguments(_ buffer: [UInt8], count: Int) -> (arguments: [String], environment: [String])? {
        let size = min(count, buffer.count)
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the zero bytes that pad it.
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var environment: [String] = []
        while index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            // An empty string ends the environment.
            if index == start && arguments.count >= argc { break }
            let text = String(decoding: buffer[start..<index], as: UTF8.self)
            if arguments.count < argc { arguments.append(text) } else { environment.append(text) }
            index += 1
        }
        return (arguments, environment)
    }

    private static func parentProcess(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbsi_ppid)
    }

    /// The working directory, as `lsof -d cwd` reports it.
    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
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
}
