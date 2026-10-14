import Foundation

/// Tracks daily agent activity for weekly recap. Stored in a local file on your Mac.
@MainActor
final class RecapStore {
    struct Day: Codable {
        var sessions: [String] = []
        var prompts = 0
        var toolUses = 0
        var commands = 0
        var edits = 0
        var linesAdded = 0
        var linesRemoved = 0
        var allowed = 0
        var denied = 0
        var questions = 0
        var activeSeconds: Double = 0
        var projects: [String: Double] = [:]
        var agents: [String: Int] = [:]
    }

    struct WeekSummary {
        var start: Date
        var activeSeconds: Double
        var sessions: Int
        var prompts: Int
        var commands: Int
        var edits: Int
        var linesAdded: Int
        var linesRemoved: Int
        var allowed: Int
        var denied: Int
        var questions: Int
        var topProject: String?
        var topAgent: String?
        var busiestDay: Date?
        var busiestSeconds: Double

        var isEmpty: Bool { prompts == 0 && sessions == 0 }
    }

    private var days: [String: Day] = [:]
    private var turnStarts: [String: (Date, String)] = [:]
    private var saveTask: Task<Void, Never>?
    private let url = NookPaths.supportDirectory.appendingPathComponent("recap.json")

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = stored
        }
    }

    // MARK: Tracking

    func prompt(session: String, project: String, agent: String) {
        update { day in
            day.prompts += 1
            if !day.sessions.contains(session) { day.sessions.append(session) }
            day.agents[agent, default: 0] += 1
        }
        turnStarts[session] = (Date(), project)
    }

    func toolUse(_ tool: String) {
        update { day in
            day.toolUses += 1
            if ["Bash", "shell", "run_shell_command", "exec_command"].contains(tool) { day.commands += 1 }
        }
    }

    func edit(added: Int, removed: Int) {
        update { day in
            day.edits += 1
            day.linesAdded += added
            day.linesRemoved += removed
        }
    }

    func decision(allowed: Bool) {
        update { day in if allowed { day.allowed += 1 } else { day.denied += 1 } }
    }

    func questionAnswered() {
        update { $0.questions += 1 }
    }

    /// An agent turn finished: duration since prompt counts toward active time (at most two hours).
    func turnEnded(session: String) {
        guard let entry = turnStarts.removeValue(forKey: session) else { return }
        let (start, project) = entry
        let seconds = min(Date().timeIntervalSince(start), 2 * 3600)
        guard seconds > 0 else { return }
        update { day in
            day.activeSeconds += seconds
            day.projects[project, default: 0] += seconds
        }
    }

    func clear() {
        days = [:]
        turnStarts = [:]
        scheduleSave()
    }

    private func update(_ change: (inout Day) -> Void) {
        let key = Self.keyFormatter.string(from: Date())
        var day = days[key] ?? Day()
        change(&day)
        days[key] = day
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        // Keep only the last ten weeks.
        let cutoff = Self.keyFormatter.string(from: Date().addingTimeInterval(-70 * 86_400))
        days = days.filter { $0.key >= cutoff }
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Summary

    /// The week (Monday through Sunday) containing `date`.
    func summary(weekOf date: Date) -> WeekSummary {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)

        var result = WeekSummary(
            start: start, activeSeconds: 0, sessions: 0, prompts: 0, commands: 0, edits: 0,
            linesAdded: 0, linesRemoved: 0, allowed: 0, denied: 0, questions: 0,
            topProject: nil, topAgent: nil, busiestDay: nil, busiestSeconds: 0
        )
        var projects: [String: Double] = [:]
        var agents: [String: Int] = [:]
        for offset in 0..<7 {
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: start),
                  let day = days[Self.keyFormatter.string(from: dayDate)] else { continue }
            result.activeSeconds += day.activeSeconds
            result.sessions += day.sessions.count
            result.prompts += day.prompts
            result.commands += day.commands
            result.edits += day.edits
            result.linesAdded += day.linesAdded
            result.linesRemoved += day.linesRemoved
            result.allowed += day.allowed
            result.denied += day.denied
            result.questions += day.questions
            for (name, seconds) in day.projects { projects[name, default: 0] += seconds }
            for (name, count) in day.agents { agents[name, default: 0] += count }
            if day.activeSeconds > result.busiestSeconds {
                result.busiestSeconds = day.activeSeconds
                result.busiestDay = dayDate
            }
        }
        result.topProject = projects.max { $0.value < $1.value }?.key
        result.topAgent = agents.max { $0.value < $1.value }?.key
        return result
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
