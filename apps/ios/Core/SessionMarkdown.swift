import Foundation

// A session as a Markdown document from what the phone has of its conversation, in the form of the Mac's
// `SessionExport` ("Copy conversation" in the session's header menu): your messages and the agent's answers in full, the
// work in between as a short folded list. Foundation only, so it is tested on the Mac (NookTests).

enum SessionMarkdown {
    static func markdown(title: String, agent: String, folder: String, branch: String?, entries: [TimelineEntry],
                         you: String = "You") -> String {
        var meta = [agent, folder]
        if let branch, !branch.isEmpty { meta.append(branch) }
        meta = meta.filter { !$0.isEmpty }
        var out = ["# " + title, ""]
        if !meta.isEmpty { out += ["_" + meta.joined(separator: " · ") + "_", ""] }
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
        for entry in entries {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch entry.kind {
            case .user:
                flushWork()
                out += ["## " + you, "", text, ""]
            case .assistant:
                flushWork()
                out += ["## " + (agent.isEmpty ? "Agent" : agent), "", text, ""]
            case .tool, .change:
                let line = oneLine(text.isEmpty ? (entry.detail ?? "") : text, 160)
                if !line.isEmpty { work.append("`" + line.replacingOccurrences(of: "`", with: "'") + "`") }
            case .error:
                flushWork()
                out += ["> **Error:** " + oneLine(text, 400), ""]
            case .notice:
                continue
            }
        }
        flushWork()
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// The text on one line, cut to `limit` characters with an ellipsis.
    static func oneLine(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
