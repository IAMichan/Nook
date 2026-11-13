import Foundation

/// Which session started which. A session Claude desktop starts from a task another session suggested (its `spawn_task`
/// tool) opens with that task's prompt, so a session whose first prompt one of them carried is that session's child.
/// Foundation only.
enum SpawnedSessions {
    /// How much of a prompt two sessions are matched on: enough to tell tasks apart, short enough to survive a prompt
    /// the app adds a line to.
    static let keyLength = 160

    /// A prompt's words, single-spaced, cut to `keyLength`.
    static func key(_ prompt: String) -> String {
        String(normalized(prompt).prefix(keyLength))
    }

    /// A prompt's words, single-spaced.
    static func normalized(_ prompt: String) -> String {
        prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The keys of the tasks an assistant message's content started (`…spawn_task` tool calls).
    static func taskKeys(in content: Any?) -> [String] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_use", (block["name"] as? String)?.hasSuffix("spawn_task") == true,
                  let prompt = (block["input"] as? [String: Any])?["prompt"] as? String else { return nil }
            let task = key(prompt)
            return task.isEmpty ? nil : task
        }
    }

    /// Each child's parent. `firstPrompts` holds every session's first prompt (normalized), `tasks` the task keys every
    /// session started. A session is the child of the one whose task its first prompt starts with or contains; when two
    /// sessions started the same task, the first id in sorted order wins, so the answer does not flicker.
    static func parents(firstPrompts: [String: String], tasks: [String: [String]]) -> [String: String] {
        var owner: [String: String] = [:]
        for (id, keys) in tasks.sorted(by: { $0.key < $1.key }) {
            for key in keys where owner[key] == nil { owner[key] = id }
        }
        guard !owner.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for (id, prompt) in firstPrompts where !prompt.isEmpty {
            if let parent = owner[key(prompt)] ?? owner.first(where: { prompt.contains($0.key) })?.value, parent != id {
                result[id] = parent
            }
        }
        return result
    }
}

/// Sessions an agent started itself from its shell (`claude -p "…"`, `codex exec "…"`): a test run, a helper, a check.
/// Such a session opens with a prompt that one of the parent's shell commands carries, so the two are matched on that.
/// Without it the session shows up as a chat you never started. Foundation only.
enum LaunchedSessions {
    /// The agent command lines a shell command can start a session with.
    static let agentCommands = ["claude", "codex", "gemini", "agy", "cursor-agent", "opencode", "grok", "pi", "copilot", "qwen"]
    /// How much of a command is kept: enough for a prompt and the lines around it.
    static let commandLength = 4_000
    /// How many of a session's launch commands are kept (the latest).
    static let maxCommands = 20
    /// A shorter opening matches too much by chance ("fix it").
    static let minimumKey = 16
    /// How far a launched session may start outside its parent's span (clock and write delays).
    static let slack: TimeInterval = 120

    private static let pattern: NSRegularExpression? = {
        let names = agentCommands.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?:^|[\s|;&(/])(?:"# + names + #")(?:\s|$)"#)
    }()

    /// The command, single-spaced and cut to `commandLength`, when it runs an agent's command line; nil otherwise.
    static func launch(_ command: String) -> String? {
        guard !command.isEmpty, let pattern,
              pattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil else { return nil }
        return String(SpawnedSessions.normalized(command).prefix(commandLength))
    }

    /// Adds `command` to `commands` when it launches an agent: the latest `maxCommands`, each once.
    static func record(_ command: String, into commands: inout [String]) {
        guard let launch = launch(command), !commands.contains(launch) else { return }
        commands.append(launch)
        if commands.count > maxCommands { commands.removeFirst(commands.count - maxCommands) }
    }

    /// What of a prompt is looked for in a command: its words, single-spaced, up to the first character a shell or JSON
    /// writes differently (a quote, a backslash, `$`), cut to `SpawnedSessions.keyLength`. Nil when that is too short.
    static func key(_ prompt: String) -> String? {
        let plain = SpawnedSessions.normalized(prompt).prefix { !"\"'\\`$".contains($0) }
        let key = String(plain.prefix(SpawnedSessions.keyLength)).trimmingCharacters(in: .whitespaces)
        return key.count >= minimumKey ? key : nil
    }

    struct Child {
        var id: String
        var prompt: String
        var started: Date
    }

    struct Launcher {
        var id: String
        var commands: [String]
        var started: Date
        var ended: Date
    }

    /// Each launched session's parent: a session that ran one of its shell commands while the child started, and whose
    /// command carries the child's opening prompt. When several did, the one that started last before it wins (then the
    /// first id), so the answer does not flicker.
    static func parents(children: [Child], launchers: [Launcher]) -> [String: String] {
        let launchers = launchers.filter { !$0.commands.isEmpty }
            .sorted { $0.started != $1.started ? $0.started > $1.started : $0.id < $1.id }
        guard !launchers.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for child in children {
            guard let key = key(child.prompt) else { continue }
            let parent = launchers.first { launcher in
                launcher.id != child.id
                    && child.started >= launcher.started.addingTimeInterval(-slack)
                    && child.started <= launcher.ended.addingTimeInterval(slack)
                    && launcher.commands.contains { $0.contains(key) }
            }
            if let parent { result[child.id] = parent.id }
        }
        return result
    }

    /// The shell command of a Codex tool call: `exec_command` writes it as `cmd`, `shell` as `command` (a string or the
    /// argument list, `["bash", "-lc", "…"]`).
    static func codexCommand(_ payload: [String: Any]) -> String {
        guard let raw = payload["arguments"] as? String, let data = raw.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        if let command = (arguments["cmd"] as? String) ?? (arguments["command"] as? String) { return command }
        if let list = (arguments["cmd"] as? [String]) ?? (arguments["command"] as? [String]) { return list.joined(separator: " ") }
        return ""
    }
}
