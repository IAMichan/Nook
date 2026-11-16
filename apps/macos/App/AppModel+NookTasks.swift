import Foundation

/// Nook as the user's secretary: from the chat, Nook schedules work for itself ("elke ochtend om 9:00 een overzicht van
/// wat er binnenkwam"). `schedule_nook_task` proposes a scheduled task whose runs ask Nook in a new conversation
/// (`ScheduledTaskTarget.nook`); like every action it waits for the user's click (it is never one of the access levels'
/// tools), runs through the plan runner and its audit log, and can be undone. `list_nook_tasks` reads them back and
/// `delete_nook_task` stops one. The tasks themselves live in `ScheduledTaskStore`, beside the agents' scheduled tasks.
extension AppModel {
    static let scheduleNookTool = "schedule_nook_task"
    static let listNookTasksTool = "list_nook_tasks"
    static let deleteNookTaskTool = "delete_nook_task"

    // MARK: Tools

    func makeNookTaskTools() -> [ToolSpec] {
        [
            ToolSpec(
                name: Self.scheduleNookTool,
                description: "Schedules work for Nook itself, so Nook acts as the user's secretary without being asked each time: at a time of day (optionally on certain weekdays), every so many minutes, or once at a moment. Each run Nook gets the prompt in a new conversation, answers it with all its tools and sources, and the user gets the answer as a notice; actions in it still wait for the user's approval. Use it whenever the user wants something done regularly or later by Nook (\"every morning at 9 tell me what came in\", \"elke vrijdag een weekoverzicht\", \"jeden Abend meine Mails zusammenfassen\"), instead of saying you only work when asked or making a reminder. Give exactly one of time, every_minutes or at.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short name for the task in the user's language, e.g. \"Ochtendupdate berichten\"."],
                        "prompt": ["type": "string", "description": "What Nook does each run, as a complete request to Nook in the user's language that stands on its own (the run does not see this conversation), e.g. \"Geef me een overzicht van de berichten die ik sinds de vorige keer heb ontvangen in WhatsApp, Berichten, Mail en mijn andere chatapps, per onderwerp, met wat op antwoord wacht bovenaan.\""],
                        "time": ["type": "string", "description": "Time of day, 24-hour HH:mm in the user's local time, e.g. \"09:00\"."],
                        "days": ["type": "string", "description": "With time: \"every day\" (default), \"weekdays\", \"weekend\", or English day names like \"mon, wed, fri\"."],
                        "every_minutes": ["type": "integer", "description": "Instead of time: run every this many minutes (at least 1), counted from the end of the previous run."],
                        "at": ["type": "string", "description": "Instead of time: one run at this moment, ISO 8601 with timezone."]
                    ],
                    "required": ["title", "prompt"]
                ],
                kind: .action,
                summarize: { input in Self.nookTaskPlanLine(input) },
                tag: { _ in
                    WorkspaceSettings.shared.scheduledTasksEnabled ? (tr("nookTask.tag"), .good) : (tr("nookTask.tag.turnsOn"), .caution)
                },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    return try self.scheduleNookTask(input)
                }
            ),
            ToolSpec(
                name: Self.listNookTasksTool,
                description: "Lists the work the user scheduled for Nook itself (schedule_nook_task): id, title, when it runs, the next run, the last outcome and the prompt. Use it before changing or stopping one, or when the user asks what Nook does for them on its own.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in tr("nookTask.listPlan") },
                tag: { _ in ("", .good) },
                run: { _ in Self.nookTaskOverview(ScheduledTaskStore.shared) }
            ),
            ToolSpec(
                name: Self.deleteNookTaskTool,
                description: "Stops and removes work scheduled for Nook (by the id from list_nook_tasks or schedule_nook_task). To change a task, remove it and schedule the new version in the same plan.",
                schema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Id of the scheduled task."],
                        "title": ["type": "string", "description": "Title of the task, shown in the plan. Optional."]
                    ],
                    "required": ["id"]
                ],
                kind: .action,
                summarize: { input in
                    let id = (input["id"] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
                    let title = id.flatMap { ScheduledTaskStore.shared.task($0)?.title } ?? (input["title"] as? String) ?? tr("sched.untitled")
                    return tr("nookTask.deletePlan", title)
                },
                tag: { _ in (tr("nookTask.tag.removes"), .caution) },
                run: { input in
                    let store = ScheduledTaskStore.shared
                    guard let id = (input["id"] as? String).flatMap({ UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }),
                          let task = store.task(id), task.target.isNook else {
                        throw NookError(tr("nookTask.error.unknown"))
                    }
                    store.delete(id)
                    return tr("nookTask.deleted", task.title)
                }
            )
        ]
    }

    /// Creates the task the user approved. Approving it also switches scheduled tasks on when they were off: the plan's
    /// tag said so before the click.
    func scheduleNookTask(_ input: [String: Any]) throws -> String {
        let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = ((input["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw NookError(tr("sched.invalid.prompt")) }
        let rule: ScheduleRule
        switch NookTaskSchedule.rule(input, parseDate: NookDates.parse) {
        case .success(let value): rule = value
        case .failure(let problem): throw NookError(Self.nookTaskProblem(problem))
        }
        let name = title.isEmpty ? String(prompt.prefix(60)) : String(title.prefix(80))
        let task = ScheduledTask(title: name, prompt: prompt, rule: rule, target: .nook, createdAt: Date())
        let store = ScheduledTaskStore.shared
        store.save(task, permission: .ask)
        if !WorkspaceSettings.shared.scheduledTasksEnabled { WorkspaceSettings.shared.scheduledTasksEnabled = true }
        let next = store.task(task.id)?.nextRun.map { " · " + tr("sched.next", ScheduledTaskText.date($0)) } ?? ""
        return tr("nookTask.created", name, ScheduledTaskText.summary(rule)) + next + " (id \(task.id.uuidString))"
    }

    /// What is wrong with a proposed schedule, checked before the user can approve it (`actionProblems`).
    static func nookTaskProblems(_ input: [String: Any]) -> [String] {
        if case .failure(let problem) = NookTaskSchedule.rule(input, parseDate: NookDates.parse) { return [nookTaskProblem(problem)] }
        return []
    }

    static func nookTaskProblem(_ problem: NookTaskSchedule.Problem) -> String {
        switch problem {
        case .when: return tr("nookTask.invalid.when")
        case .time: return tr("nookTask.invalid.time")
        case .days: return tr("nookTask.invalid.days")
        case .interval: return tr("sched.invalid.interval")
        case .moment: return tr("automation.sched.invalid.past")
        }
    }

    /// "Nook plant: Ochtendupdate berichten · Elke dag om 09:00", the line on the plan card.
    static func nookTaskPlanLine(_ input: [String: Any]) -> String {
        let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? tr("sched.untitled") : title
        guard case .success(let rule) = NookTaskSchedule.rule(input, parseDate: NookDates.parse) else {
            return tr("nookTask.plan", name, tr("nookTask.plan.noTime"))
        }
        return tr("nookTask.plan", name, ScheduledTaskText.summary(rule))
    }

    /// The scheduled work for Nook, as the brain reads it.
    static func nookTaskOverview(_ store: ScheduledTaskStore) -> String {
        let tasks = store.tasks.filter { $0.target.isNook }
        var lines = [store.isEnabled ? "Scheduled tasks are switched on."
                                     : "Scheduled tasks are switched off in Settings: nothing runs until they are switched on (scheduling a new one switches them on)."]
        if tasks.isEmpty { lines.append("Nothing is scheduled for Nook yet.") }
        let iso = ISO8601DateFormatter()
        for task in tasks {
            var line = "- id \(task.id.uuidString) · \(task.title) · \(ScheduledTaskText.summary(task.rule)) · " + (task.enabled ? "on" : "paused")
            if store.isRunning(task.id) { line += " · running now" }
            if let next = task.nextRun { line += " · next \(iso.string(from: next))" }
            if task.isDone { line += " · done" }
            if let last = task.lastRun { line += " · last \(iso.string(from: last))" + (task.lastStatus.map { " (\($0.rawValue))" } ?? "") }
            line += "\n  prompt: " + task.prompt.replacingOccurrences(of: "\n", with: " ")
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
