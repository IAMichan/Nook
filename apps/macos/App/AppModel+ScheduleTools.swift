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
                description: "Creates an automation: a task Nook Chat runs by itself on a schedule (every day, on weekdays, on certain days, every so many minutes, or once), each run in a conversation of its own that the user opens from a notice. It works for anything Nook can read or do: mail, WhatsApp and every other chat app, the calendar and invitations, reminders and open loops, notes, files, pull requests and CI, coding agents, the web and connected services. Use it when the user asks Nook to do something regularly or later (\"check my mail every morning at 8 and draft the replies\", \"elke vrijdag een overzicht van mijn week\", \"every evening: which pull requests wait for me\"), or as soon as something happens: schedule message runs the moment a new message arrives in a chat app or Mail, filtered by app, sender and words (\"zodra Lisa op WhatsApp schrijft, zet een antwoord klaar\", \"when a mail about an invoice comes in, add a reminder to pay it\"). Write prompt as the complete request Nook gets on each run, in the user's language, with everything they asked for. Each run works as the user's secretary: it says what matters and prepares every step as a proposal (replies to send, appointments, reminders, reviews, answers to agents). With autonomy ask (the default) the user approves each step; with decide Nook carries out the routine steps itself and asks for the rest; with auto it carries out every step it may do unattended (messages, mail, calendar, reminders, notes, comments) and only asks for the rest. Deleting, merging, commands, settings and payments always wait for the user. Set autonomy only as the user asks: \"without asking me\", \"send it yourself\", \"you decide\" are decide or auto. The user approves the automation itself with a click. Do not use it for a single reminder (create_reminder) or a recurring calendar event (create_event). For a full personal secretary across everything, use set_up_secretary.",
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
                        "quiet": ["type": "boolean", "description": "Only speak up when something new needs the user (no conversation and no notice otherwise). Default: true for interval, false for an overview at a set time."],
                        "autonomy": Self.autonomySchema
                    ],
                    "required": ["prompt", "schedule"]
                ],
                kind: .action,
                summarize: { input in
                    // The plan shows it in the user's language; the brain and the audit log read NookSchedule.summary.
                    NookSchedule.parse(input, now: Date()).draft.map {
                        tr("automation.nook.planLine", $0.title, ScheduledTaskText.summary($0.rule)) + Self.autonomyPlanSuffix($0.autonomy)
                    } ?? tr("automation.nook.planIncomplete")
                },
                tag: { input in Self.autonomyTag(NookAutonomy.parse((input["autonomy"] as? String) ?? "") ?? .ask) },
                run: { input in
                    let parsed = NookSchedule.parse(input, now: Date())
                    guard let draft = parsed.draft else { throw NookError(parsed.problems.joined(separator: "; ")) }
                    let store = ScheduledTaskStore.shared
                    let task = ScheduledTask(title: draft.title, prompt: draft.prompt, rule: draft.rule, target: .nook, createdAt: Date())
                    store.save(task, permission: .ask, quiet: draft.quiet, autonomy: draft.autonomy)
                    let next = store.task(task.id)?.nextRun.map { " The first run is at \(NookDates.iso($0))." } ?? ""
                    let quiet = draft.quiet ? " It only speaks up when something new needs the user." : ""
                    return "Saved the automation \"\(draft.title)\" (\(NookSchedule.describe(draft.rule))).\(next)\(quiet) After each run \(draft.autonomy.describe). Each run is a conversation of its own in Nook Chat, and a notice says when it is ready. The user changes, pauses or removes it in Settings › Automation › Scheduled tasks."
                }
            ),
            ToolSpec(
                name: "set_up_secretary",
                description: "Sets up Nook as the user's personal secretary in one step: three automations across everything Nook can see (mail, every chat app, calendar, reminders, open loops, pull requests, coding agents): a briefing every morning at 08:00, a quiet check on weekdays at 13:00 that only speaks up when something new needs the user, and a wrap-up on weekdays at 17:30 that prepares tomorrow. Each run says what matters and prepares every reply and action for the user to approve or change. Use it when the user asks for a secretary, a personal assistant that keeps track of everything, or a daily routine across all their stuff. The user can change the times afterwards in Settings › Automation › Scheduled tasks or by asking.",
                schema: ["type": "object", "properties": ["autonomy": Self.autonomySchema], "required": [String]()],
                kind: .action,
                summarize: { input in
                    tr("automation.secretary.plan", NookSchedule.secretary().map { "\($0.title) (\(ScheduledTaskText.summary($0.rule)))" }
                        .joined(separator: "; ")) + Self.autonomyPlanSuffix(NookAutonomy.parse((input["autonomy"] as? String) ?? "") ?? .ask)
                },
                tag: { input in Self.autonomyTag(NookAutonomy.parse((input["autonomy"] as? String) ?? "") ?? .ask) },
                run: { [weak self] input in
                    guard self != nil else { throw NookError(tr("app.unavailable")) }
                    return AppModel.addSecretary(autonomy: NookAutonomy.parse((input["autonomy"] as? String) ?? "") ?? .ask)
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
                        if task.target.isNook { line += " · after a run " + store.autonomy(for: task.id).describe }
                        if task.enabled, let next = task.nextRun { line += " · next \(NookDates.iso(next))" }
                        if let status = task.lastStatus { line += " · last run \(status.rawValue)" }
                        let prompt = task.prompt.replacingOccurrences(of: "\n", with: " ")
                        return line + "\n  " + (prompt.count > 200 ? String(prompt.prefix(200)) + "…" : prompt)
                    }.joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "update_scheduled_task",
                description: "Changes one of the user's existing automations for Nook: pause or resume it (enabled), rename it, change what it does (prompt), give it a new schedule (the same fields as schedule_task), make it quiet or not, or change its autonomy (ask: every step waits for the user; decide: Nook carries out the routine steps and asks for the rest; auto: Nook carries out every step it may do unattended). Use it when the user asks to change, pause or speed up an automation (\"laat de ochtendmail voortaan zelf antwoorden versturen\", \"pause the midday check\", \"move my Friday overview to 16:00\"). Call list_scheduled_tasks first to find its name. The user approves the change with a click.",
                schema: [
                    "type": "object",
                    "properties": [
                        "task": ["type": "string", "description": "The automation's name as list_scheduled_tasks shows it."],
                        "title": ["type": "string", "description": "A new name."],
                        "prompt": ["type": "string", "description": "The new full request, in the user's language."],
                        "schedule": ["type": "string", "enum": NookSchedule.Kind.allCases.map(\.rawValue), "description": "A new schedule; then give its fields as for schedule_task."],
                        "time": ["type": "string"], "days": ["type": "array", "items": ["type": "string"]],
                        "every_minutes": ["type": "integer"], "at": ["type": "string"],
                        "apps": ["type": "array", "items": ["type": "string"]], "from": ["type": "string"],
                        "keywords": ["type": "array", "items": ["type": "string"]], "groups": ["type": "boolean"],
                        "enabled": ["type": "boolean", "description": "false pauses it, true resumes it."],
                        "quiet": ["type": "boolean", "description": "Only speak up when something new needs the user."],
                        "autonomy": Self.autonomySchema
                    ],
                    "required": ["task"]
                ],
                kind: .action,
                summarize: { input in
                    let name = (input["task"] as? String) ?? ""
                    let found = NookSchedule.find(name, in: ScheduledTaskStore.shared.tasks.filter(\.target.isNook))
                    guard let found, let change = NookSchedule.parseChange(input, now: Date()).change else {
                        return tr("autonomy.update.planIncomplete", name)
                    }
                    return tr("autonomy.update.plan", found.title) + ": " + Self.describe(change)
                },
                tag: { input in Self.autonomyTag(NookAutonomy.parse((input["autonomy"] as? String) ?? "") ?? .ask) },
                run: { input in
                    let store = ScheduledTaskStore.shared
                    let name = (input["task"] as? String) ?? ""
                    guard let found = NookSchedule.find(name, in: store.tasks.filter(\.target.isNook)) else {
                        throw NookError("No single automation for Nook is called \"\(name)\"; call list_scheduled_tasks and use its exact name.")
                    }
                    let parsed = NookSchedule.parseChange(input, now: Date())
                    guard let change = parsed.change else { throw NookError(parsed.problems.joined(separator: "; ")) }
                    var task = found
                    if let title = change.title { task.title = title }
                    if let prompt = change.prompt { task.prompt = prompt }
                    if let rule = change.rule { task.rule = rule }
                    if change.title != nil || change.prompt != nil || change.rule != nil || change.quiet != nil || change.autonomy != nil {
                        store.save(task, permission: .ask, quiet: change.quiet, autonomy: change.autonomy)
                    }
                    if let enabled = change.enabled { store.setEnabled(task.id, enabled) }
                    let now = store.task(task.id) ?? task
                    var line = "Updated the automation \"\(now.title)\": \(NookSchedule.describe(now.rule)), " + (now.enabled ? "on" : "paused")
                    line += "; after a run " + store.autonomy(for: now.id).describe + "."
                    if now.enabled, let next = now.nextRun { line += " Next run at \(NookDates.iso(next))." }
                    return line
                }
            )
        ]
    }

    /// The `autonomy` field of the automation tools.
    static let autonomySchema: [String: Any] = [
        "type": "string", "enum": NookAutonomy.allCases.map(\.rawValue),
        "description": "What Nook carries out by itself after each run: ask (default: every step waits for the user), decide (Nook carries out the routine steps itself and asks for the rest), auto (Nook carries out every step it may do unattended: messages, mail, calendar, reminders, notes, comments). Deleting, merging, commands, settings and payments always wait for the user."
    ]

    /// The plan line's ending for a level that acts by itself, so the user sees it before approving.
    static func autonomyPlanSuffix(_ level: NookAutonomy) -> String {
        level == .ask ? "" : " · " + level.label
    }

    /// An automation that acts by itself is tagged as such in the plan.
    static func autonomyTag(_ level: NookAutonomy) -> (String, StepTone) {
        level == .ask ? (tr("automation.nook.tag"), .caution) : (tr("autonomy.tag"), .caution)
    }

    /// A change in the user's language, for the plan.
    static func describe(_ change: NookSchedule.Change) -> String {
        var parts: [String] = []
        if let title = change.title { parts.append(tr("autonomy.change.title", title)) }
        if change.prompt != nil { parts.append(tr("autonomy.change.prompt")) }
        if let rule = change.rule { parts.append(ScheduledTaskText.summary(rule)) }
        if let enabled = change.enabled { parts.append(tr(enabled ? "nookTask.resume" : "nookTask.pause")) }
        if let quiet = change.quiet { parts.append(tr(quiet ? "autonomy.change.quiet" : "autonomy.change.notQuiet")) }
        if let level = change.autonomy { parts.append(level.label) }
        return parts.joined(separator: " · ")
    }

    /// The secretary's three tasks (`NookSchedule.secretary`); one that exists already (same title, for Nook) is left as it is.
    @discardableResult
    static func addSecretary(autonomy: NookAutonomy = .ask) -> String {
        let store = ScheduledTaskStore.shared
        var added: [String] = []
        for draft in NookSchedule.secretary() where !(draft.preset.map(store.hasPreset) ?? false) {
            let task = ScheduledTask(title: draft.title, prompt: draft.prompt, rule: draft.rule, target: .nook, createdAt: Date())
            store.save(task, permission: .ask, quiet: draft.quiet, preset: draft.preset, autonomy: autonomy)
            added.append("\(draft.title) (\(NookSchedule.describe(draft.rule))\(draft.quiet ? ", only when something new needs the user" : ""))")
        }
        guard !added.isEmpty else { return "The secretary's automations exist already; nothing was added." }
        return "Set up the personal secretary: " + added.joined(separator: "; ")
            + ". Each run is a conversation of its own in Nook Chat with everything prepared for approval; the user changes times or pauses them in Settings › Automation › Scheduled tasks."
    }
}
