import Foundation

// What a session produced that is worth looking at next to the conversation: the agent's task list, the plans it
// proposed, and the files it wrote that are made to be seen (a design as HTML or SVG, a document in Markdown, an
// image). All of it comes from the session's own events; code it changed stays in the changes view, and the subagents it
// started have a side panel of their own (`Subagents`). Everything in this
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
        /// A video, played in place.
        case video
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
        case "mp4", "mov", "m4v": return .video
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
            let output = SessionOutput(id: "file:" + path, kind: kind, title: (path as NSString).lastPathComponent,
                                       path: path, date: date)
            if let index = files[path] { outputs[index] = output } else { files[path] = outputs.count; outputs.append(output) }
        }
        for event in events {
            switch event.kind {
            case .assistant where event.tool == "plan":
                let title = PlanPreview.title(from: event.text) ?? ""
                outputs.append(SessionOutput(id: "plan:" + event.id.uuidString, kind: .plan(event.text), title: title, path: nil,
                                             date: event.date))
            case .tool where SharedFiles.isShare(event):
                for path in SharedFiles.paths(AgentActivity.input(event.detail) ?? [:]) { add(path, at: event.date) }
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
    static let taskTools: Set<String> = ["TodoWrite", "update_plan", "Plan", "todo_write", "todowrite", "write_todos"]

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

/// Files the agent handed to you on purpose (Claude Code's SendUserFile): a video, a picture or a document it made for
/// you to look at, not a step of its work. The conversation shows them in a row of their own, never folded away, and the
/// outputs panel keeps them.
enum SharedFiles {
    /// The tools that hand files over, by name (an MCP tool by its own name).
    /// Codex's generated pictures count too (`CodexAppServerMapper.imageTool`).
    static let tools: Set<String> = ["SendUserFile", "image_generation"]

    static func isTool(_ tool: String) -> Bool {
        tools.contains(tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool) : tool)
    }

    /// A call that handed files over (and did not fail).
    static func isShare(_ event: RunEvent) -> Bool {
        event.kind == .tool && event.state != .failed && isTool(event.tool ?? "")
            && !paths(AgentActivity.input(event.detail) ?? [:]).isEmpty
    }

    /// The files of the call, as the agent named them (`files`, or one `file` or `path`).
    static func paths(_ input: [String: Any]) -> [String] {
        let listed = (input["files"] as? [String]) ?? [input["file"], input["path"]].compactMap { $0 as? String }
        return listed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// What the agent said with them.
    static func caption(_ input: [String: Any]) -> String? {
        (input["caption"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}
