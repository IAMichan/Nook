import Foundation

// MARK: Toestemming

enum ApprovalDecision {
    case allow      // deze keer
    case always     // en onthoud het (Claude Code bewaart de regel zelf)
    case deny
    case terminal   // niet hier: de agent vraagt het in zijn eigen venster
}

/// Een agent vraagt of hij iets mag. Wat Nook toont; het antwoord gaat via `AgentHub.decide`.
struct ApprovalRequest: Identifiable {
    let id: String
    let sessionKey: String
    let agentName: String
    let project: String
    let tool: String
    /// Het commando of een korte omschrijving van wat de agent wil.
    let summary: String
    /// Voor bewerkingen: de wijziging als diff.
    let diff: [DiffLine]
    let assessment: CommandAssessment
    let canAlways: Bool
    let created: Date

    var title: String {
        if assessment.level == .danger { return assessment.title }
        switch tool {
        case "Bash", "shell", "run_shell_command", "exec_command":
            return "Mag \(agentName) dit uitvoeren?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "write_file", "replace", "apply_patch":
            return "Mag \(agentName) dit bestand aanpassen?"
        case "WebFetch", "web_fetch":
            return "Mag \(agentName) deze pagina ophalen?"
        case "WebSearch", "google_web_search":
            return "Mag \(agentName) op internet zoeken?"
        default:
            if tool.hasPrefix("mcp__") { return "Mag \(agentName) deze koppeling gebruiken?" }
            return "Mag \(agentName) \(tool) gebruiken?"
        }
    }
}

// MARK: Vragen (AskUserQuestion)

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

/// Een agent stelt je een meerkeuzevraag. Nook toont de vragen één voor één in de notch.
struct AgentQuestionRequest: Identifiable {
    let id: String
    let sessionKey: String
    let agentName: String
    let project: String
    let items: [AgentQuestionItem]

    /// Leest `tool_input` van AskUserQuestion. Nil als het er anders uitziet dan verwacht: dan vraagt de agent het zelf.
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

    /// Antwoorden zoals Claude Code ze verwacht: vraagtekst → gekozen label (of lijst bij meerkeuze).
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

// MARK: Abonnementsgebruik

struct PlanWindow: Equatable, Codable {
    var usedPercent: Double
    var resetsAt: Date

    /// Na het resetmoment telt het weer vanaf nul.
    var effectivePercent: Double { resetsAt <= Date() ? 0 : usedPercent }
}

/// Hoeveel van je Claude-abonnement (Pro/Max) je gebruikt, uit de statusregel van Claude Code.
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

    private static func window(_ raw: Any?) -> PlanWindow? {
        guard let dict = raw as? [String: Any],
              let percent = (dict["used_percentage"] as? NSNumber)?.doubleValue,
              (0...200).contains(percent),
              let epoch = (dict["resets_at"] as? NSNumber)?.doubleValue, epoch > 0,
              epoch < Date().timeIntervalSince1970 + 400 * 86_400 else { return nil }
        return PlanWindow(usedPercent: min(100, percent), resetsAt: Date(timeIntervalSince1970: epoch))
    }

    /// "5u 34% · week 12%"
    var label: String {
        var parts: [String] = []
        if let fiveHour { parts.append("5u \(Int(fiveHour.effectivePercent.rounded()))%") }
        if let sevenDay { parts.append("week \(Int(sevenDay.effectivePercent.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    var highest: Double {
        max(fiveHour?.effectivePercent ?? 0, sevenDay?.effectivePercent ?? 0)
    }

    /// "reset om 15:40" voor het venster dat het hoogst staat.
    var resetLabel: String? {
        let window = (fiveHour?.effectivePercent ?? 0) >= (sevenDay?.effectivePercent ?? 0) ? fiveHour : sevenDay
        guard let window, window.resetsAt > Date() else { return nil }
        return "reset \(NookDates.short(window.resetsAt))"
    }
}
