import Foundation

// What a session produced that is worth looking at next to the conversation: the agent's task list, the plans it
// proposed, and the files it wrote that are made to be seen (a design as HTML or SVG, a document in Markdown, an
// image). All of it comes from the session's own events; code it changed stays in the changes view. Everything in this
// file depends only on Foundation so tests can use it independently.

/// One thing in a session's outputs panel.
struct SessionOutput: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The agent's task list.
        case tasks([RunTaskStep])
        /// A plan it proposed, in Markdown.
        case plan(String)
        /// A page or drawing: HTML or SVG, shown as it renders.
        case design
        /// A Markdown document.
        case document
        case image
    }

    var id: String
    var kind: Kind
    var title: String
    /// The file, for a design, a document or an image: an absolute path.
    var path: String?
    var date: Date

    var isFile: Bool { path != nil }
}

enum SessionOutputs {
    /// What a file is, by its extension; nil for everything else (code, configuration, data).
    static func kind(path: String) -> SessionOutput.Kind? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html", "htm", "svg": return .design
        case "md", "markdown", "mdx": return .document
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp": return .image
        default: return nil
        }
    }

    /// An absolute path for one the agent named relative to its folder.
    static func resolve(_ path: String, in directory: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !directory.isEmpty else { return trimmed }
        return URL(fileURLWithPath: directory).appendingPathComponent(trimmed).standardizedFileURL.path
    }

    /// A session's outputs, newest first: its task list (`tasks`, the one it keeps now, else the last one it wrote),
    /// every plan it proposed, and each file worth seeing once, at the last time it was written.
    static func collect(_ events: [RunEvent], tasks: [RunTaskStep]?, directory: String) -> [SessionOutput] {
        var outputs: [SessionOutput] = []
        var files: [String: Int] = [:]
        var latestTasks: (steps: [RunTaskStep], date: Date)?
        func add(_ raw: String, at date: Date) {
            let path = resolve(raw, in: directory)
            guard !path.isEmpty, let kind = kind(path: path) else { return }
            let output = SessionOutput(id: "file:" + path, kind: kind, title: URL(fileURLWithPath: path).lastPathComponent,
                                       path: path, date: date)
            if let index = files[path] { outputs[index] = output } else { files[path] = outputs.count; outputs.append(output) }
        }
        for event in events {
            switch event.kind {
            case .assistant where event.tool == "plan":
                let title = PlanPreview.title(from: event.text) ?? ""
                outputs.append(SessionOutput(id: "plan:" + event.id.uuidString, kind: .plan(event.text), title: title, path: nil,
                                             date: event.date))
            case .tool:
                let input = AgentActivity.input(event.detail) ?? [:]
                if let steps = taskList(tool: event.tool ?? "", input: input) {
                    latestTasks = (steps, event.date)
                } else if ToolCategory.of(tool: event.tool ?? "") == .edit, event.state != .failed, let path = ToolSummary.path(input) {
                    add(path, at: event.date)
                }
            case .fileChange where event.tool != "deleted":
                add(event.detail ?? event.text, at: event.date)
            default:
                continue
            }
        }
        if let steps = tasks.flatMap({ $0.isEmpty ? nil : $0 }) ?? latestTasks?.steps {
            let date = latestTasks?.date ?? events.last?.date ?? Date()
            outputs.append(SessionOutput(id: "tasks", kind: .tasks(steps), title: "", path: nil, date: date))
        }
        return outputs.sorted { $0.date > $1.date }
    }

    /// Tools that set the agent's task list, by name (an MCP tool by its own name).
    static let taskTools: Set<String> = ["TodoWrite", "update_plan", "Plan", "todo_write", "write_todos"]

    /// A task list a tool call sets: Claude Code's TodoWrite (`todos`), Codex's update_plan (`plan`), or the same
    /// shapes from another agent's tool of that name.
    static func taskList(tool: String, input: [String: Any]) -> [RunTaskStep]? {
        let name = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool) : tool
        guard taskTools.contains(name) else { return nil }
        return RunTasks.claude(input) ?? RunTasks.codex(input)
    }

    /// Something new since `seen` (the outputs you last looked at), for the dot on the panel's button.
    static func hasNew(_ outputs: [SessionOutput], seen: Set<String>) -> Bool {
        outputs.contains { !seen.contains(signature($0)) }
    }

    /// Changes when an output does: a file written again, a list that moved on.
    static func signature(_ output: SessionOutput) -> String {
        switch output.kind {
        case .tasks(let steps): return "tasks:" + steps.map { $0.status.rawValue }.joined(separator: ",")
        default: return output.id + "@" + String(output.date.timeIntervalSince1970)
        }
    }
}
