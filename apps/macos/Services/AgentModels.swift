import Foundation

// MARK: Permissions

enum ApprovalDecision {
    case allow      // this time
    case always     // and remember it (Claude Code persists the rule itself)
    case deny
    case terminal   // not here: the agent prompts in its own window
}

/// An agent requests permission. Displayed by Nook; the decision is passed via `AgentHub.decide`.
struct ApprovalRequest: Identifiable {
    let id: String
    let sessionKey: String
    let agentName: String
    let project: String
    let tool: String
    /// The command or a short description of what the agent wants.
    let summary: String
    /// For edits: the change as a diff.
    let diff: [DiffLine]
    let assessment: CommandAssessment
    let canAlways: Bool
    let created: Date

    var title: String {
        if assessment.level == .danger { return assessment.title }
        switch tool {
        case "Bash", "shell", "run_shell_command", "exec_command":
            return "May \(agentName) execute this?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "write_file", "replace", "apply_patch":
            return "May \(agentName) edit this file?"
        case "WebFetch", "web_fetch":
            return "May \(agentName) fetch this page?"
        case "WebSearch", "google_web_search":
            return "May \(agentName) search the web?"
        default:
            if let mcp = McpToolName(tool) { return tr("ws.approval.mcpTitle", agentName, mcp.toolLabel, mcp.serverLabel) }
            return "May \(agentName) use \(tool)?"
        }
    }
}

// MARK: Questions (AskUserQuestion)

struct AgentQuestionOption: Equatable {
    var label: String
    var description: String
}

struct AgentQuestionItem: Equatable {
    var question: String
    var header: String
    var options: [AgentQuestionOption]
    var multiSelect: Bool
}

/// An agent asks a multiple-choice question. Nook displays questions sequentially in the notch.
struct AgentQuestionRequest: Identifiable {
    let id: String
    let sessionKey: String
    let agentName: String
    let project: String
    let items: [AgentQuestionItem]

    /// Parses `tool_input` of AskUserQuestion. Returns nil if the format does not match expectations.
    static func parse(_ input: [String: Any]) -> [AgentQuestionItem]? {
        guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty, raw.count <= 4 else { return nil }
        var items: [AgentQuestionItem] = []
        for entry in raw {
            guard let question = entry["question"] as? String, !question.isEmpty,
                  let rawOptions = entry["options"] as? [[String: Any]], (2...6).contains(rawOptions.count) else { return nil }
            var options: [AgentQuestionOption] = []
            for option in rawOptions {
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                options.append(AgentQuestionOption(label: label, description: (option["description"] as? String) ?? ""))
            }
            items.append(AgentQuestionItem(
                question: question,
                header: String(((entry["header"] as? String) ?? "").prefix(16)),
                options: options,
                multiSelect: (entry["multiSelect"] as? Bool) ?? false
            ))
        }
        return items
    }

    /// Answers formatted for Claude Code: question string → chosen label (or list for multi-select).
    static func answers(items: [AgentQuestionItem], selections: [[String]]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (index, item) in items.enumerated() where index < selections.count {
            let chosen = selections[index]
            if item.multiSelect {
                result[item.question] = chosen
            } else if let first = chosen.first {
                result[item.question] = first
            }
        }
        return result
    }
}

// MARK: Plan Usage

struct PlanWindow: Equatable, Codable {
    var usedPercent: Double
    var resetsAt: Date

    /// After reset time, usage resets back to zero.
    var effectivePercent: Double { resetsAt <= Date() ? 0 : usedPercent }
}

/// Claude plan usage (Pro/Max) parsed from the Claude Code statusline.
struct PlanUsage: Equatable, Codable {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var updated: Date

    static func parse(_ event: [String: Any]) -> PlanUsage? {
        guard let limits = event["rate_limits"] as? [String: Any] else { return nil }
        let five = window(limits["five_hour"])
        let week = window(limits["seven_day"])
        guard five != nil || week != nil else { return nil }
        return PlanUsage(fiveHour: five, sevenDay: week, updated: Date())
    }

    /// Whether this reading shows other windows than `known`, or `known` is old enough to be refreshed.
    func differs(from known: PlanUsage, refreshAfter interval: TimeInterval = 60) -> Bool {
        fiveHour != known.fiveHour || sevenDay != known.sevenDay || updated.timeIntervalSince(known.updated) >= interval
    }

    private static func window(_ raw: Any?) -> PlanWindow? {
        guard let dict = raw as? [String: Any],
              let percent = (dict["used_percentage"] as? NSNumber)?.doubleValue,
              (0...200).contains(percent),
              let epoch = (dict["resets_at"] as? NSNumber)?.doubleValue, epoch > 0,
              epoch < Date().timeIntervalSince1970 + 400 * 86_400 else { return nil }
        return PlanWindow(usedPercent: min(100, percent), resetsAt: Date(timeIntervalSince1970: epoch))
    }

    /// "5h 34% · week 12%"
    var label: String {
        var parts: [String] = []
        if let fiveHour { parts.append("5h \(Int(fiveHour.effectivePercent.rounded()))%") }
        if let sevenDay { parts.append("week \(Int(sevenDay.effectivePercent.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    var highest: Double {
        max(fiveHour?.effectivePercent ?? 0, sevenDay?.effectivePercent ?? 0)
    }

    /// "reset 15:40" for the highest window.
    var resetLabel: String? {
        let window = (fiveHour?.effectivePercent ?? 0) >= (sevenDay?.effectivePercent ?? 0) ? fiveHour : sevenDay
        guard let window, window.resetsAt > Date() else { return nil }
        return "reset \(NookDates.short(window.resetsAt))"
    }
}
