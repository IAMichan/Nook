import Foundation

// A goal the agent keeps working toward over several turns (`/goal`), as the agent itself reports it. Every agent that
// reports one goes through `SessionGoalUpdate`; each only translates its own output here.

/// The goal of a session, as its agent last reported it.
struct SessionGoal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case active, paused, blocked, usageLimited, budgetLimited, complete
    }

    var objective: String
    var status: Status
    /// How often the agent checked the goal and went on.
    var checks: Int? = nil
    /// What the last check said was still missing.
    var lastCheck: String? = nil
    var tokensUsed: Int? = nil
    var tokenBudget: Int? = nil
    var timeUsedSeconds: Int? = nil
}

/// What an agent said about its goal.
enum SessionGoalUpdate: Equatable, Sendable {
    case set(SessionGoal)
    /// A check found the goal not met yet; the text starts with the objective in brackets (see `SessionGoals.apply`).
    case check(String)
    case cleared
}

/// `/goal` as you typed it.
enum SessionGoalCommand: Equatable, Sendable {
    case show, clear, pause, resume
    case set(String)
}

enum SessionGoals {
    /// The `/goal` command in a message, nil for any other message.
    static func command(in text: String) -> SessionGoalCommand? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.lowercased().hasPrefix("/goal") else { return nil }
        let rest = clean.dropFirst("/goal".count)
        if let first = rest.first, !first.isWhitespace { return nil }
        let argument = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        switch argument.lowercased() {
        case "": return .show
        case "clear": return .clear
        case "pause": return .pause
        case "resume": return .resume
        default: return .set(argument)
        }
    }

    /// Claude Code answers `/goal` itself, in a message of the model `<synthetic>`.
    static func claude(synthetic text: String) -> SessionGoalUpdate? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("Goal set: ") {
            let objective = String(clean.dropFirst("Goal set: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return objective.isEmpty ? nil : .set(SessionGoal(objective: objective, status: .active, checks: 0))
        }
        if clean.hasPrefix("Goal cleared: ") || clean.hasPrefix("No goal set") { return .cleared }
        guard clean.hasPrefix("Goal active: "), let open = clean.range(of: " (", options: .backwards) else { return nil }
        let objective = String(clean[clean.index(clean.startIndex, offsetBy: "Goal active: ".count)..<open.lowerBound])
        let note = clean[open.upperBound...]
        guard !objective.isEmpty, note.hasPrefix("not yet evaluated") || note.contains("turn") else { return nil }
        let checks = Int(note.prefix { $0.isNumber }) ?? 0
        return .set(SessionGoal(objective: objective, status: .active, checks: checks))
    }

    /// Claude Code's goal check runs as a Stop hook; what it found comes back as a synthetic message of yours.
    static func claude(hookFeedback text: String) -> SessionGoalUpdate? {
        let prefix = "Stop hook feedback:\n"
        return text.hasPrefix(prefix + "[") ? .check(String(text.dropFirst(prefix.count))) : nil
    }

    /// Codex's `thread/goal/updated`.
    static func codex(_ goal: [String: Any]?) -> SessionGoalUpdate? {
        guard let goal, let objective = (goal["objective"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !objective.isEmpty else { return nil }
        let status = (goal["status"] as? String).flatMap(SessionGoal.Status.init(rawValue:)) ?? .active
        func count(_ key: String) -> Int? { (goal[key] as? NSNumber).map { max(0, $0.intValue) } }
        return .set(SessionGoal(objective: objective, status: status, tokensUsed: count("tokensUsed"),
                                tokenBudget: count("tokenBudget"), timeUsedSeconds: count("timeUsedSeconds")))
    }

    static func apply(_ update: SessionGoalUpdate, to current: SessionGoal?) -> SessionGoal? {
        switch update {
        case .cleared:
            return nil
        case .set(var goal):
            // A repeat of the same goal keeps what its checks found.
            if let current, current.objective == goal.objective {
                goal.lastCheck = current.lastCheck
                goal.checks = max(goal.checks ?? 0, current.checks ?? 0)
                if goal.checks == 0, current.checks == nil { goal.checks = nil }
            }
            return goal
        case .check(let text):
            guard var goal = current else { return nil }
            let prefix = "[" + goal.objective + "]: "
            guard text.hasPrefix(prefix) else { return goal }
            goal.status = .active
            goal.checks = (goal.checks ?? 0) + 1
            goal.lastCheck = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return goal
        }
    }

    /// The first turn of a goal: a bare objective reads like a statement, and the model would only repeat it.
    static func firstTurn(objective: String) -> String { "Start working toward this goal: " + objective }
    static let resumeTurn = "Continue working toward the goal."
}
