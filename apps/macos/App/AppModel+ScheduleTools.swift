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
                description: "Creates an automation: a task Nook Chat runs by itself on a schedule (every day, on weekdays, on certain days, every so many minutes, or once), each run in a conversation of its own that the user opens from a notice. It works for anything Nook can read or do: mail, WhatsApp and every other chat app, the calendar and invitations, reminders and open loops, notes, files, pull requests and CI, coding agents, the web and connected services. Use it when the user asks Nook to do something regularly or later (\"check my mail every morning at 8 and draft the replies\", \"elke vrijdag een overzicht van mijn week\", \"every evening: which pull requests wait for me\"), or as soon as something happens: schedule message runs the moment a new message arrives in a chat app or Mail, filtered by app, sender and words (\"zodra Lisa op WhatsApp schrijft, zet een antwoord klaar\", \"when a mail about an invoice comes in, add a reminder to pay it\"). Write prompt as the complete request Nook gets on each run, in the user's language, with everything they asked for. Each run works as the user's secretary: it says what matters and prepares every step as a proposal (replies to send, appointments, reminders, reviews, answers to agents) that the user only approves or changes; nothing is sent or changed by itself. The user approves the automation itself with a click. Do not use it for a single reminder (create_reminder) or a recurring calendar event (create_event). For a full personal secretary across everything, use set_up_secretary.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "A short name for the list, e.g. \"Morning mail\"."],
                        "prompt": ["type": "string", "description": "The full request Nook answers on each run, in the user's language."],
                        "schedule": ["type": "string", "enum": NookSchedule.Kind.allCases.map(\.rawValue),
                                     "description": "daily (every day at time), weekdays (Monday to Friday at time), weekly (on days at time), interval (every every_minutes), once (at), message (as soon as a new message arrives that matches apps, from and keywords)."],
                        "time": ["type": "string", "description": "For daily, weekdays and weekly: the time as HH:mm (24 hours), e.g. 08:00."],
                        "days": ["type": "array", "items": ["type": "string"], "description": "For weekly: weekday names, e.g. [\"monday\", \"friday\"]."],
                        "every_minutes": ["type": "integer", "description": "For interval: minutes between runs, at least \(NookSchedule.minimumMinutes)."],
                        "at": ["type": "string", "description": "For once: the moment, e.g. 2026-11-20T09:00 (the user's own time)."],
                        "apps": ["type": "array", "items": ["type": "string"], "description": "For message: the apps to listen to, e.g. [\"whatsapp\", \"mail\"] (whatsapp, messages, mail, telegram, slack, teams, signal, instagram, messenger, linkedin, discord, snapchat). Empty: every app."],
                        "from": ["type": "string", "description": "For message: part of the person's or chat's name or address, e.g. \"Lisa\" or \"@client.com\". Empty: anyone."],
                        "keywords": ["type": "array", "items": ["type": "string"], "description": "For message: words of which one must be in the message, e.g. [\"invoice\", \"factuur\"]. Empty: any message."],
                        "groups": ["type": "boolean", "description": "For message: group chats count too (default false)."],
                        "quiet": ["type": "boolean", "description": "Only speak up when something new needs the user (no conversation and no notice otherwise). Default: true for interval, false for an overview at a set time."]
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
                    store.save(task, permission: .ask, quiet: draft.quiet)
                    let next = store.task(task.id)?.nextRun.map { " The first run is at \(NookDates.iso($0))." } ?? ""
                    let quiet = draft.quiet ? " It only speaks up when something new needs the user." : ""
                    return "Saved the automation \"\(draft.title)\" (\(NookSchedule.describe(draft.rule))).\(next)\(quiet) Each run is a conversation of its own in Nook Chat, and a notice says when it is ready. The user changes, pauses or removes it in Settings › Automation › Scheduled tasks."
                }
            ),
            ToolSpec(
                name: "set_up_secretary",
                description: "Sets up Nook as the user's personal secretary in one step: three automations across everything Nook can see (mail, every chat app, calendar, reminders, open loops, pull requests, coding agents): a briefing every morning at 08:00, a quiet check on weekdays at 13:00 that only speaks up when something new needs the user, and a wrap-up on weekdays at 17:30 that prepares tomorrow. Each run says what matters and prepares every reply and action for the user to approve or change. Use it when the user asks for a secretary, a personal assistant that keeps track of everything, or a daily routine across all their stuff. The user can change the times afterwards in Settings › Automation › Scheduled tasks or by asking.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .action,
                summarize: { _ in
                    tr("automation.secretary.plan", NookSchedule.secretary().map { NookSchedule.describe($0.rule) }.joined(separator: "; "))
                },
                tag: { _ in (tr("automation.nook.tag"), .caution) },
                run: { [weak self] _ in
                    guard self != nil else { throw NookError(tr("app.unavailable")) }
                    return AppModel.addSecretary()
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
                        if task.target.isNook, store.isQuiet(task.id) { line += " · only speaks up for something new" }
                        if task.enabled, let next = task.nextRun { line += " · next \(NookDates.iso(next))" }
                        if let status = task.lastStatus { line += " · last run \(status.rawValue)" }
                        let prompt = task.prompt.replacingOccurrences(of: "\n", with: " ")
                        return line + "\n  " + (prompt.count > 200 ? String(prompt.prefix(200)) + "…" : prompt)
                    }.joined(separator: "\n")
                }
            )
        ]
    }

    /// The secretary's three tasks (`NookSchedule.secretary`); one that exists already (same title, for Nook) is left as it is.
    @discardableResult
    static func addSecretary() -> String {
        let store = ScheduledTaskStore.shared
        var added: [String] = []
        for draft in NookSchedule.secretary() where !store.tasks.contains(where: { $0.target.isNook && $0.title == draft.title }) {
            let task = ScheduledTask(title: draft.title, prompt: draft.prompt, rule: draft.rule, target: .nook, createdAt: Date())
            store.save(task, permission: .ask, quiet: draft.quiet)
            added.append("\(draft.title) (\(NookSchedule.describe(draft.rule))\(draft.quiet ? ", only when something new needs the user" : ""))")
        }
        guard !added.isEmpty else { return "The secretary's automations exist already; nothing was added." }
        return "Set up the personal secretary: " + added.joined(separator: "; ")
            + ". Each run is a conversation of its own in Nook Chat with everything prepared for approval; the user changes times or pauses them in Settings › Automation › Scheduled tasks."
    }
}
