//! Automations from the chat (the Mac's `AppModel+ScheduleTools`): "check my mail every morning at eight and draft the
//! replies". The brain proposes `schedule_task`, the user approves it in the plan (it is never run without asking), and
//! from then on the scheduler asks Nook Chat the task's prompt on its schedule, each run in a conversation of its own
//! (`ScheduledTaskTarget::Nook`, `workspace::nook_runs`). A run only reads and proposes. `list_scheduled_tasks` reads
//! what exists; `update_scheduled_task` and `set_up_secretary` are actions too. The rules are in
//! `nook_core::workspace::nook_schedule`.

use chrono::{Local, Utc};
use nook_core::brain::LoopTool;
use nook_core::i18n::{tr, trf};
use nook_core::workspace::autonomy::NookAutonomy;
use nook_core::workspace::nook_schedule::{self, Change};
use nook_core::workspace::schedule::{ScheduledTask, ScheduledTaskTarget};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager as _};

use super::{text, ToolCtx, ToolSource};
use crate::workspace::automation::AutomationState;

pub struct Schedule;

const SCHEDULE_TASK: &str = "schedule_task";
const SECRETARY: &str = "set_up_secretary";
const LIST: &str = "list_scheduled_tasks";
const UPDATE: &str = "update_scheduled_task";

fn schedule_fields() -> serde_json::Map<String, Value> {
    let fields = json!({
        "schedule": {"type": "string", "enum": nook_schedule::KINDS, "description": "daily (every day at time), weekdays (Monday to Friday at time), weekly (on days at time), interval (every every_minutes), once (at)."},
        "time": {"type": "string", "description": "For daily, weekdays and weekly: the time as HH:mm (24 hours), e.g. 08:00."},
        "days": {"type": "array", "items": {"type": "string"}, "description": "For weekly: weekday names, e.g. [\"monday\", \"friday\"]."},
        "every_minutes": {"type": "integer", "description": format!("For interval: minutes between runs, at least {}.", nook_schedule::MINIMUM_MINUTES)},
        "at": {"type": "string", "description": "For once: the moment, e.g. 2026-11-20T09:00 (the user's own time)."},
        "quiet": {"type": "boolean", "description": "Only speak up when something new needs the user (no conversation otherwise). Default: true for interval, false for an overview at a set time."},
        "autonomy": autonomy_schema()
    });
    fields.as_object().cloned().unwrap_or_default()
}

/// The `autonomy` field of the automation tools.
fn autonomy_schema() -> Value {
    json!({"type": "string", "enum": NookAutonomy::ALL.map(NookAutonomy::id), "description": "What Nook carries out by itself after each run: ask (default: every step waits for the user), decide (Nook carries out the routine steps itself and asks for the rest), auto (Nook carries out every step it may do unattended: messages, calendar, reminders, notes, comments). Deleting, merging, commands, settings and payments always wait for the user. Set it only as the user asks: \"without asking me\", \"send it yourself\", \"you decide\" are decide or auto."})
}

fn schedule_schema() -> Value {
    let mut properties = schedule_fields();
    properties.insert("title".into(), json!({"type": "string", "description": "A short name for the list, e.g. \"Morning mail\"."}));
    properties.insert(
        "prompt".into(),
        json!({"type": "string", "description": "The full request Nook answers on each run, in the user's language."}),
    );
    json!({"type": "object", "properties": properties, "required": ["prompt", "schedule"]})
}

fn update_schema() -> Value {
    let mut properties = schedule_fields();
    properties.insert("task".into(), json!({"type": "string", "description": "The automation's name as list_scheduled_tasks shows it."}));
    properties.insert("title".into(), json!({"type": "string", "description": "A new name."}));
    properties.insert("prompt".into(), json!({"type": "string", "description": "The new full request, in the user's language."}));
    properties.insert("enabled".into(), json!({"type": "boolean", "description": "false pauses it, true resumes it."}));
    json!({"type": "object", "properties": properties, "required": ["task"]})
}

/// A change in the user's language, for the plan.
fn describe(change: &Change) -> String {
    let mut parts = vec![];
    if let Some(title) = &change.title {
        parts.push(trf("nieuwe naam ‘{title}’", "new name “{title}”", &[("title", title)]));
    }
    if change.prompt.is_some() {
        parts.push(tr("nieuwe opdracht", "new instructions").to_string());
    }
    if let Some(rule) = &change.rule {
        parts.push(nook_schedule::summary(rule));
    }
    if let Some(enabled) = change.enabled {
        parts.push(if enabled { tr("hervatten", "resume") } else { tr("pauzeren", "pause") }.to_string());
    }
    if let Some(level) = change.autonomy {
        parts.push(level.label().to_string());
    }
    if let Some(quiet) = change.quiet {
        parts.push(
            if quiet {
                tr("alleen melden als er iets nieuws is", "only speak up for something new")
            } else {
                tr("altijd melden", "always report")
            }
            .to_string(),
        );
    }
    parts.join(" · ")
}

fn nook_tasks(tasks: Vec<ScheduledTask>) -> Vec<ScheduledTask> {
    tasks.into_iter().filter(|t| t.target == ScheduledTaskTarget::Nook).collect()
}

/// What the brain hears when automations are off in Settings: saved, but nothing runs until the user turns them on.
fn off_note(auto: &AutomationState) -> &'static str {
    if auto.settings().scheduled_tasks {
        ""
    } else {
        " Scheduled tasks are off in Settings › Agents › Automation: tell the user it runs once they turn them on there."
    }
}

fn changed(app: &AppHandle) {
    let _ = app.emit("automation-changed", ());
}

#[async_trait::async_trait]
impl ToolSource for Schedule {
    fn id(&self) -> &'static str {
        "automation"
    }

    fn is_source(&self) -> bool {
        false
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let app = ctx.app.clone();
        vec![
            LoopTool::action(
                SCHEDULE_TASK,
                "Creates an automation: a task Nook Chat runs by itself on a schedule (every day, on weekdays, on certain days, every so many minutes, or once), each run in a conversation of its own in Nook Chat. It works for anything Nook can read or do: mail, chats, the calendar, reminders and open loops, files, pull requests, coding agents, the web and connected services. Use it when the user asks Nook to do something regularly or later (\"check my mail every morning at 8 and draft the replies\", \"every Friday an overview of my week\", \"every evening: which pull requests wait for me\"). Write prompt as the complete request Nook gets on each run, in the user's language, with everything they asked for. Each run works as the user's secretary: it says what matters and prepares every step as a proposal. With autonomy ask (the default) the user approves each step; with decide Nook carries out the routine steps itself and asks for the rest; with auto it carries out every step it may do unattended and only asks for the rest. The user approves the automation itself with a click. Do not use it for a single reminder or a recurring calendar event. For a full personal secretary across everything, use set_up_secretary.",
                schedule_schema(),
            ),
            LoopTool::action(
                SECRETARY,
                "Sets up Nook as the user's personal secretary in one step: three automations across everything Nook can see (mail, chats, calendar, reminders, open loops, pull requests, coding agents): a briefing every morning at 08:00, a quiet check on weekdays at 13:00 that only speaks up when something new needs the user, and a wrap-up on weekdays at 17:30 that prepares tomorrow. Each run says what matters and prepares every reply and action for the user to approve. Use it when the user asks for a secretary, a personal assistant that keeps track of everything, or a daily routine across all their stuff.",
                json!({"type": "object", "properties": {"autonomy": autonomy_schema()}, "required": []}),
            ),
            LoopTool::read(
                LIST,
                "Lists the user's automations (scheduled tasks): what each one does, when it runs, whether it is on, and how its last run went. Use it before proposing a new one that may exist already, or when the user asks which automations they have.",
                json!({"type": "object", "properties": {}, "required": []}),
                move |_input: Value| {
                    let app = app.clone();
                    async move {
                        let auto = app.try_state::<AutomationState>().ok_or_else(|| nook_core::NookError::new("Nook is not ready."))?;
                        let tasks = auto.scheduler.tasks();
                        if tasks.is_empty() {
                            return Ok("The user has no automations yet.".to_string());
                        }
                        let lines: Vec<String> = tasks.iter().map(nook_schedule::list_line).collect();
                        Ok(lines.join("\n") + off_note(&auto))
                    }
                },
            ),
            LoopTool::action(
                UPDATE,
                "Changes one of the user's existing automations for Nook: pause or resume it (enabled), rename it, change what it does (prompt), give it a new schedule (the same fields as schedule_task), or make it quiet or not. Use it when the user asks to change, pause or move an automation (\"pause the midday check\", \"move my Friday overview to 16:00\"). Call list_scheduled_tasks first to find its name. The user approves the change with a click.",
                update_schema(),
            ),
        ]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            SCHEDULE_TASK => Some(match nook_schedule::parse(input, Utc::now(), &Local) {
                Ok(draft) => nook_schedule::plan_line(&draft),
                Err(_) => tr("Automatisering (nog niet compleet)", "Automation (not complete yet)").to_string(),
            }),
            SECRETARY => {
                let lines: Vec<String> =
                    nook_schedule::secretary().iter().map(|d| format!("{} ({})", d.title, nook_schedule::summary(&d.rule))).collect();
                let level = NookAutonomy::parse(&text(input, "autonomy")).unwrap_or_default();
                Some(
                    trf(
                        "Persoonlijke secretaris instellen: {tasks}",
                        "Set up the personal secretary: {tasks}",
                        &[("tasks", &lines.join("; "))],
                    ) + &nook_schedule::level_suffix(level),
                )
            }
            LIST => Some(tr("Automatiseringen bekijken", "Read automations").to_string()),
            UPDATE => {
                let name = text(input, "task");
                Some(match nook_schedule::parse_change(input, Utc::now(), &Local) {
                    Ok(change) => format!(
                        "{}: {}",
                        trf("Automatisering ‘{title}’ wijzigen", "Change automation “{title}”", &[("title", &name)]),
                        describe(&change)
                    ),
                    Err(_) => trf(
                        "Automatisering ‘{title}’ wijzigen (nog niet compleet)",
                        "Change automation “{title}” (not complete yet)",
                        &[("title", &name)],
                    ),
                })
            }
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        let result = match tool {
            SCHEDULE_TASK => schedule(&ctx.app, input),
            SECRETARY => secretary(&ctx.app, NookAutonomy::parse(&text(input, "autonomy")).unwrap_or_default()),
            UPDATE => update(&ctx.app, input),
            _ => return None,
        };
        Some(result)
    }
}

fn state(app: &AppHandle) -> Result<tauri::State<'_, AutomationState>, String> {
    app.try_state::<AutomationState>().ok_or_else(|| "Nook is not ready.".to_string())
}

fn schedule(app: &AppHandle, input: &Value) -> Result<String, String> {
    let auto = state(app)?;
    let draft = nook_schedule::parse(input, Utc::now(), &Local).map_err(|p| p.join("; "))?;
    let task = auto.scheduler.save_task(draft.task(Utc::now()), Utc::now(), &Local);
    changed(app);
    let next = task.next_run.map(|at| format!(" The first run is at {}.", at.with_timezone(&Local).to_rfc3339())).unwrap_or_default();
    let quiet = if task.quiet { " It only speaks up when something new needs the user." } else { "" };
    Ok(format!(
        "Saved the automation \"{}\" ({}).{next}{quiet} After each run {}. Each run is a conversation of its own in Nook Chat. The user changes, pauses or removes it in Settings › Agents › Automation.{}",
        task.title,
        nook_schedule::describe(&task.rule),
        task.autonomy.describe(),
        off_note(&auto)
    ))
}

/// The secretary's three tasks; one that exists already (the same preset) is left as it is.
fn secretary(app: &AppHandle, level: NookAutonomy) -> Result<String, String> {
    let auto = state(app)?;
    let existing = auto.scheduler.tasks();
    let mut added = vec![];
    for draft in nook_schedule::secretary() {
        if existing.iter().any(|t| t.preset.is_some() && t.preset == draft.preset) {
            continue;
        }
        let mut task = draft.task(Utc::now());
        task.autonomy = level;
        let task = auto.scheduler.save_task(task, Utc::now(), &Local);
        let quiet = if task.quiet { ", only when something new needs the user" } else { "" };
        added.push(format!("{} ({}{quiet})", task.title, nook_schedule::describe(&task.rule)));
    }
    changed(app);
    if added.is_empty() {
        return Ok("The secretary's automations exist already; nothing was added.".into());
    }
    Ok(format!(
        "Set up the personal secretary: {}. Each run is a conversation of its own in Nook Chat with everything prepared for approval; the user changes times or pauses them in Settings › Agents › Automation.{}",
        added.join("; "),
        off_note(&auto)
    ))
}

fn update(app: &AppHandle, input: &Value) -> Result<String, String> {
    let auto = state(app)?;
    let name = text(input, "task");
    let tasks = nook_tasks(auto.scheduler.tasks());
    let found = nook_schedule::find(&name, &tasks)
        .cloned()
        .ok_or_else(|| format!("No single automation for Nook is called \"{name}\"; call list_scheduled_tasks and use its exact name."))?;
    let change = nook_schedule::parse_change(input, Utc::now(), &Local).map_err(|p| p.join("; "))?;
    let edited = change.apply(&found);
    if edited != found {
        auto.scheduler.save_task(edited, Utc::now(), &Local);
    }
    if let Some(enabled) = change.enabled {
        auto.scheduler.set_enabled(found.id, enabled, Utc::now(), &Local);
    }
    changed(app);
    let now = auto.scheduler.task(found.id).unwrap_or(found);
    let mut line = format!(
        "Updated the automation \"{}\": {}, {}; after a run {}.",
        now.title,
        nook_schedule::describe(&now.rule),
        if now.enabled { "on" } else { "paused" },
        now.autonomy.describe()
    );
    if let Some(next) = now.next_run.filter(|_| now.enabled) {
        line += &format!(" Next run at {}.", next.with_timezone(&Local).to_rfc3339());
    }
    Ok(line + off_note(&auto))
}
