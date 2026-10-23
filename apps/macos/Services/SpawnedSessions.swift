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
