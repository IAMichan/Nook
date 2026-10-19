import Foundation

/// A session as a Markdown document, to save or share. Your messages and the agent's answers in full, the work in between as a short folded list, no thinking.
/// Foundation only, so tests can use it independently.
enum SessionExport {
    static func markdown(_ run: WorkspaceRun, events: [RunEvent], date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var meta = [run.provider.displayName]
        if let model = run.resolvedModel ?? (run.model.isEmpty ? nil : run.model) { meta.append(model) }
        meta.append(run.projectName)
        if let branch = run.branch { meta.append(branch) }
        meta.append(formatter.string(from: run.createdAt))
        var out = ["# " + run.title, "", "_" + meta.joined(separator: " · ") + "_", ""]
        var work: [String] = []
        func flushWork() {
            guard !work.isEmpty else { return }
            out.append("<details><summary>\(work.count) \(work.count == 1 ? "step" : "steps")</summary>")
            out.append("")
            out += work.map { "- " + $0 }
            out.append("")
            out.append("</details>")
            out.append("")
            work = []
        }
        for event in events {
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch event.kind {
            case .user:
                flushWork()
                out += ["## You", "", text, ""]
            case .assistant:
                flushWork()
                out += ["## " + run.provider.displayName, "", text, ""]
            case .tool, .fileChange:
                if !text.isEmpty { work.append("`" + ToolSummary.oneLine(text, 160).replacingOccurrences(of: "`", with: "'") + "`") }
            case .error:
                flushWork()
                out += ["> **Error:** " + ToolSummary.oneLine(text, 400), ""]
            case .thinking, .approval, .system, .result:
                continue
            }
        }
        flushWork()
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// "fix-login-bug.md".
    static func fileName(_ run: WorkspaceRun) -> String {
        WorktreeNaming.slug(run.title, limit: 60) + ".md"
    }
}
