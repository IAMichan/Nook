import Foundation

/// Automations from the chat: "check elke ochtend om 8 mijn mail, vertel wat er gebeurd is en zet antwoorden klaar".
/// The brain proposes `schedule_task`, the user approves it in the plan (it is never one of the `safeTools`, and the plan
/// runner writes it to the audit log), and from then on `ScheduledTaskStore` asks Nook Chat the task's prompt on its
/// schedule, each run in a conversation of its own (`ScheduledTaskTarget.nook`). A run only reads and proposes: the mail
/// drafts and plans it makes wait in that conversation for the user's click. `list_scheduled_tasks` reads what exists.
extension AppModel {
    func makeScheduleTools() -> [ToolSpec] {
        [
            ToolSpec(
                name: "schedule_task",
                description: "Creates an automation: a task Nook Chat runs by itself on a schedule (every day, on weekdays, on certain days, every so many minutes, or once), each run in a conversation of its own that the user opens from a notice. Use it when the user asks Nook to do something regularly or later (\"check my mail every morning at 8 and tell me what happened\", \"elke vrijdag een overzicht van mijn agenda\"). Write prompt as the complete request Nook gets on each run, in the user's language, with everything they asked for, for example: \"Check my mail since yesterday: tell me what happened, most important first, and draft a reply to every mail that needs one so I only have to click Send.\" A run only looks things up and proposes: mail drafts and actions wait for the user's approval, nothing is sent by itself. The user approves the automation itself with a click. Do not use it for a single reminder (create_reminder) or a recurring calendar event (create_event).",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "A short name for the list, e.g. \"Morning mail\"."],
                        "prompt": ["type": "string", "description": "The full request Nook answers on each run, in the user's language."],
                        "schedule": ["type": "string", "enum": NookSchedule.Kind.allCases.map(\.rawValue),
                                     "description": "daily (every day at time), weekdays (Monday to Friday at time), weekly (on days at time), interval (every every_minutes), once (at)."],
                        "time": ["type": "string", "description": "For daily, weekdays and weekly: the time as HH:mm (24 hours), e.g. 08:00."],
                        "days": ["type": "array", "items": ["type": "string"], "description": "For weekly: weekday names, e.g. [\"monday\", \"friday\"]."],
                        "every_minutes": ["type": "integer", "description": "For interval: minutes between runs, at least \(NookSchedule.minimumMinutes)."],
                        "at": ["type": "string", "description": "For once: the moment, e.g. 2026-11-20T09:00 (the user's own time)."]
                    ],
                    "required": ["prompt", "schedule"]
                ],
                kind: .action,
                summarize: { input in
                    NookSchedule.parse(input, now: Date()).draft.map(NookSchedule.summary) ?? tr("automation.nook.planIncomplete")
                },
                tag: { _ in (tr("automation.nook.tag"), .caution) },
                run: { input in
                    let parsed = NookSchedule.parse(input, now: Date())
                    guard let draft = parsed.draft else { throw NookError(parsed.problems.joined(separator: "; ")) }
                    let store = ScheduledTaskStore.shared
                    let task = ScheduledTask(title: draft.title, prompt: draft.prompt, rule: draft.rule, target: .nook, createdAt: Date())
                    store.save(task, permission: .ask)
                    let next = store.task(task.id)?.nextRun.map { " The first run is at \(NookDates.iso($0))." } ?? ""
                    return "Saved the automation \"\(draft.title)\" (\(NookSchedule.describe(draft.rule))).\(next) Each run is a conversation of its own in Nook Chat, and a notice says when it is ready. The user changes, pauses or removes it in Settings › Automation › Scheduled tasks."
                }
            ),
            ToolSpec(
                name: "list_scheduled_tasks",
                description: "Lists the user's automations (scheduled tasks): what each one does, when it runs, whether it is on, and how its last run went. Use it before proposing a new one that may exist already, or when the user asks which automations they have.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in tr("automation.nook.listPlan") },
                tag: { _ in ("", .good) },
                run: { _ in
                    let store = ScheduledTaskStore.shared
                    guard !store.tasks.isEmpty else { return "The user has no automations yet." }
                    return store.tasks.map { task -> String in
                        var line = "- \(task.title): \(NookSchedule.describe(task.rule)) · " + (task.enabled ? "on" : "off")
                        line += task.target.isNook ? " · answered by Nook Chat" : " · runs a coding agent"
                        if task.enabled, let next = task.nextRun { line += " · next \(NookDates.iso(next))" }
                        if let status = task.lastStatus { line += " · last run \(status.rawValue)" }
                        let prompt = task.prompt.replacingOccurrences(of: "\n", with: " ")
                        return line + "\n  " + (prompt.count > 200 ? String(prompt.prefix(200)) + "…" : prompt)
                    }.joined(separator: "\n")
                }
            )
        ]
    }
}
