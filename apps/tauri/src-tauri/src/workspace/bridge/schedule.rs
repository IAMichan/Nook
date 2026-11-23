//! Scheduled task bridge tools (`schedule_task`, `list_scheduled_tasks`, `update_scheduled_task`,
//! `run_scheduled_task_now`, AG-09). Wraps [`nook_core::workspace::scheduler::Scheduler`] via [`AutomationState`].
//!
//! Safety: creating, updating, deleting, or running a scheduled task ALWAYS asks the user for approval (even under
//! Bypass rights), and scheduled tasks are never given Bypass rights.

use chrono::{Local, Utc};
use nook_core::i18n::{tr, trf};
use nook_core::workspace::bridge::{
    describe_schedule_rule, parse_schedule_create, parse_schedule_update, render_scheduled_task, render_scheduled_tasks, BridgeCaller,
    BridgeTool, Reason, ScheduleUpdate, ToolResult, Verdict,
};
use nook_core::workspace::models::RunProvider;
use nook_core::workspace::paths;
use nook_core::workspace::schedule::{ScheduledTask, ScheduledTaskTarget};
use nook_core::workspace::scheduler::RunNow;
use serde_json::{Map, Value};
use tauri::{AppHandle, Emitter, Manager};
use uuid::Uuid;

use super::sessions::{answered, once_key, remember};
use super::{audit, check, refusal, workspace, Context};
use crate::agents::lock;
use crate::workspace::automation::{self, AutomationState};

fn matches_caller(task: &ScheduledTask, caller: &BridgeCaller) -> bool {
    let caller_dir = paths::normalize(&caller.directory);
    let caller_run = caller.run.as_deref().and_then(|s| Uuid::parse_str(s).ok());
    match &task.target {
        ScheduledTaskTarget::NewSession { project_path, .. } => !caller_dir.is_empty() && paths::normalize(project_path) == caller_dir,
        ScheduledTaskTarget::ExistingSession { id, .. } => caller_run == Some(*id),
        ScheduledTaskTarget::Nook => false,
    }
}

pub(super) fn list_scheduled_tasks(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    if let Verdict::Refuse(reason) = check(app, BridgeTool::ListScheduledTasks, caller, None) {
        return Err(refusal(reason).into());
    }
    let auto = app.try_state::<AutomationState>().ok_or("Nook automation is not ready.")?;
    let show_all = a.get("all").and_then(Value::as_bool).unwrap_or(false);
    let tasks: Vec<ScheduledTask> = auto.scheduler.tasks().into_iter().filter(|t| show_all || matches_caller(t, caller)).collect();
    let global_on = auto.settings().scheduled_tasks;
    Ok(ToolResult::text(render_scheduled_tasks(&tasks, global_on)))
}

pub(super) async fn schedule_task(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let auto = app.try_state::<AutomationState>().ok_or("Nook automation is not ready.")?;
    let default_provider = lock(&ws.settings).default_provider;
    let mut task = parse_schedule_create(a, &caller.directory, default_provider, caller.permission, Utc::now())?;

    // Validate the target folder or session before asking the user.
    match &mut task.target {
        ScheduledTaskTarget::NewSession { project_path, provider, .. } => {
            let expanded = super::expand_tilde(project_path);
            let normalized = paths::normalize(&expanded);
            if normalized.is_empty() || paths::verdict(&normalized) != paths::Verdict::Ok {
                return Err(format!("That folder cannot be used for a scheduled task: {project_path}"));
            }
            if !super::tasks::installed(*provider) {
                return Err(format!("{} is not installed.", provider.display_name()));
            }
            *project_path = normalized;
        }
        ScheduledTaskTarget::ExistingSession { id, .. } => {
            if ws.manager.run(*id).is_none() {
                return Err(format!("No such session: {id}. Use an id from session_list."));
            }
        }
        ScheduledTaskTarget::Nook => {}
    }

    let key = once_key(BridgeTool::ScheduleTask, caller, a);
    if let Some(prev) = answered(&key) {
        return Ok(prev);
    }

    match check(app, BridgeTool::ScheduleTask, caller, None) {
        Verdict::Refuse(reason) => return Err(refusal(reason).into()),
        Verdict::Ask(_) => {
            let title = trf(
                "{agent} wil een geplande taak aanmaken: “{title}”",
                "{agent} wants to create a scheduled task: “{title}”",
                &[("agent", &caller.agent), ("title", &task.title)],
            );
            let rule_desc = describe_schedule_rule(&task.rule);
            let target_desc = match &task.target {
                ScheduledTaskTarget::NewSession { project_path, provider, .. } => {
                    format!("{} · {}", provider.display_name(), nook_core::agents::tilde(project_path))
                }
                ScheduledTaskTarget::ExistingSession { id, fresh } => {
                    format!("session {id}{}", if *fresh { " (fresh)" } else { "" })
                }
                ScheduledTaskTarget::Nook => "Nook Chat".into(),
            };
            let detail = format!("{rule_desc} · {target_desc}\n\n{}", task.prompt);
            let note = tr(
                "Geplande taken draaien op de achtergrond zonder volledige Bypass-rechten. Je kunt ze altijd pauzeren bij Automatisering.",
                "Scheduled tasks run on the schedule without full Bypass rights. You can pause them anytime under Automation.",
            );
            if !ws.bridge.ask(app, caller, BridgeTool::ScheduleTask, title, detail, note.into(), &context.connection).await {
                audit(app, BridgeTool::ScheduleTask, caller, &task.title, "niet toegestaan");
                return Err(refusal(Reason::Schedule).into());
            }
        }
        Verdict::Allow => {}
    }

    let saved = auto.scheduler.save_task(task, Utc::now(), &Local);
    let _ = app.emit("automation-changed", ());
    audit(app, BridgeTool::ScheduleTask, caller, &saved.title, &saved.id.to_string());

    let global_note = if auto.settings().scheduled_tasks {
        String::new()
    } else {
        "\nNote: Global scheduled tasks are currently off in Nook (Settings › Automation).".into()
    };
    let result = ToolResult::text(format!("Scheduled task created:\n{}{global_note}", render_scheduled_task(&saved)));
    remember(&key, &result);
    Ok(result)
}

pub(super) async fn update_scheduled_task(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let auto = app.try_state::<AutomationState>().ok_or("Nook automation is not ready.")?;
    let raw_id = super::arg(a, "task_id");
    let task_id = Uuid::parse_str(raw_id).map_err(|_| format!("\"{raw_id}\" is not a valid task_id from list_scheduled_tasks."))?;
    let existing = auto
        .scheduler
        .task(task_id)
        .ok_or_else(|| format!("No scheduled task found with id {task_id}. Call list_scheduled_tasks to check."))?;

    let update = parse_schedule_update(a, &existing, caller.permission)?;

    match check(app, BridgeTool::UpdateScheduledTask, caller, None) {
        Verdict::Refuse(reason) => return Err(refusal(reason).into()),
        Verdict::Ask(_) => {
            let (title, detail) = match &update {
                ScheduleUpdate::Delete(_) => (
                    trf(
                        "{agent} wil de geplande taak “{title}” verwijderen",
                        "{agent} wants to delete the scheduled task “{title}”",
                        &[("agent", &caller.agent), ("title", &existing.title)],
                    ),
                    format!("Delete scheduled task {} ({})", existing.title, existing.id),
                ),
                ScheduleUpdate::Save(next, changes) => (
                    trf(
                        "{agent} wil de geplande taak “{title}” aanpassen",
                        "{agent} wants to update the scheduled task “{title}”",
                        &[("agent", &caller.agent), ("title", &existing.title)],
                    ),
                    format!("Changes:\n- {}\n\nPrompt:\n{}", changes.join("\n- "), next.prompt),
                ),
            };
            let note = tr(
                "Het aanpassen of verwijderen van een geplande taak vraagt altijd om jouw bevestiging.",
                "Updating or deleting a scheduled task always requires your approval.",
            );
            if !ws.bridge.ask(app, caller, BridgeTool::UpdateScheduledTask, title, detail, note.into(), &context.connection).await {
                audit(app, BridgeTool::UpdateScheduledTask, caller, &existing.title, "niet toegestaan");
                return Err(refusal(Reason::Schedule).into());
            }
        }
        Verdict::Allow => {}
    }

    match update {
        ScheduleUpdate::Delete(id) => {
            auto.scheduler.delete(id);
            let _ = app.emit("automation-changed", ());
            audit(app, BridgeTool::UpdateScheduledTask, caller, &existing.title, "verwijderd");
            Ok(ToolResult::text(format!("Deleted scheduled task \"{}\" ({id}).", existing.title)))
        }
        ScheduleUpdate::Save(next, changes) => {
            let saved = auto.scheduler.save_task(*next, Utc::now(), &Local);
            let _ = app.emit("automation-changed", ());
            audit(app, BridgeTool::UpdateScheduledTask, caller, &saved.title, &changes.join(", "));
            Ok(ToolResult::text(format!("Updated scheduled task:\n{}", render_scheduled_task(&saved))))
        }
    }
}

pub(super) async fn run_scheduled_task_now(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let auto = app.try_state::<AutomationState>().ok_or("Nook automation is not ready.")?;
    let raw_id = super::arg(a, "task_id");
    let task_id = Uuid::parse_str(raw_id).map_err(|_| format!("\"{raw_id}\" is not a valid task_id from list_scheduled_tasks."))?;
    let existing = auto
        .scheduler
        .task(task_id)
        .ok_or_else(|| format!("No scheduled task found with id {task_id}. Call list_scheduled_tasks to check."))?;

    match check(app, BridgeTool::RunScheduledTaskNow, caller, None) {
        Verdict::Refuse(reason) => return Err(refusal(reason).into()),
        Verdict::Ask(_) => {
            let title = trf(
                "{agent} wil de geplande taak “{title}” nu uitvoeren",
                "{agent} wants to run the scheduled task “{title}” now",
                &[("agent", &caller.agent), ("title", &existing.title)],
            );
            let detail = format!("{}\n\n{}", render_scheduled_task(&existing), existing.prompt);
            let note = tr(
                "De taak start direct één keer met zijn eigen opdracht en rechten.",
                "The task runs once right now with its own prompt and rights.",
            );
            if !ws.bridge.ask(app, caller, BridgeTool::RunScheduledTaskNow, title, detail, note.into(), &context.connection).await {
                audit(app, BridgeTool::RunScheduledTaskNow, caller, &existing.title, "niet toegestaan");
                return Err(refusal(Reason::Schedule).into());
            }
        }
        Verdict::Allow => {}
    }

    let scheduler = auto.scheduler.clone();
    let global_enabled = auto.settings().scheduled_tasks;
    let manager = ws.manager.clone();
    let app2 = app.clone();
    let outcome = tauri::async_runtime::spawn_blocking(move || {
        let profile = |p: RunProvider| automation::default_profile(&app2, p);
        let host = crate::workspace::nook_runs::AppHost { manager, app: app2.clone() };
        scheduler.run_now(&host, global_enabled, task_id, &profile, Utc::now(), &Local)
    })
    .await
    .map_err(|e| e.to_string())?;
    let _ = app.emit("automation-changed", ());

    let msg = match outcome {
        RunNow::Started => {
            audit(app, BridgeTool::RunScheduledTaskNow, caller, &existing.title, "gestart");
            format!("Started scheduled task \"{}\" ({task_id}).", existing.title)
        }
        RunNow::Busy => {
            audit(app, BridgeTool::RunScheduledTaskNow, caller, &existing.title, "al bezig");
            format!("Scheduled task \"{}\" ({task_id}) is already running.", existing.title)
        }
        RunNow::NotAvailable => {
            audit(app, BridgeTool::RunScheduledTaskNow, caller, &existing.title, "niet beschikbaar");
            return Err(format!(
                "Could not run \"{}\" right now (scheduled tasks may be turned off in Settings › Automation, or the target is unavailable).",
                existing.title
            ));
        }
    };
    Ok(ToolResult::text(msg))
}
