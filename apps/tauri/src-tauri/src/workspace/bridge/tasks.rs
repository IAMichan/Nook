//! Delegating for agents (`WorkspaceBridge.delegation` on the Mac): `orchestrator_capabilities`, `delegate_task`,
//! `task_status`, `task_wait` and `task_cancel`. The rules (rights never above the parent, depth, how many at once,
//! where a task works) are in `core/src/workspace/delegation.rs`; this file reads the sessions and waits.
//!
//! A parent that does not wait for a task hears when it ends: `turn_finished` sends it `wake_message` as a new message
//! (queued when the parent is busy).

use std::time::{Duration, Instant};

use nook_core::agents::find_executable;
use nook_core::i18n::{tr, trf};
use nook_core::workspace::bridge::{BridgeCaller, BridgeTool, Reason, ToolResult, Verdict};
use nook_core::workspace::delegation::{self, Role, Snapshot, MAX_ACTIVE_CHILDREN, MAX_DEPTH};
use nook_core::workspace::driver::session_executable;
use nook_core::workspace::models::{ExecutionMode, PermissionPolicy, RunProvider, WorkspaceRun};
use serde_json::{Map, Value};
use tauri::{AppHandle, Manager};
use uuid::Uuid;

use super::{audit, check, refusal, workspace, Context};
use crate::workspace::automation::AutomationState;

const NOT_A_RUN: &str = "Delegating works from a session that Nook runs. Start this session from Nook to delegate tasks.";
const NO_SUCH_TASK: &str = "No such task. Use the task id that delegate_task returned.";

pub(super) async fn call(
    app: &AppHandle,
    tool: BridgeTool,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let parent = caller.run.as_deref().and_then(|r| Uuid::parse_str(r).ok()).and_then(|id| ws.manager.run(id)).ok_or(NOT_A_RUN)?;
    match tool {
        BridgeTool::OrchestratorCapabilities => Ok(ToolResult::text(capabilities(app, &parent))),
        BridgeTool::DelegateTask => delegate_task(app, a, &parent, caller, context).await,
        BridgeTool::TaskStatus => {
            let task = task_of(app, parent.id, a.get("task_id"))?;
            Ok(ToolResult::text(snapshot(app, &task).render(false)))
        }
        BridgeTool::TaskWait => task_wait(app, a, parent.id).await,
        BridgeTool::TaskCancel => {
            if let Verdict::Refuse(reason) = check(app, tool, caller, None) {
                return Err(refusal(reason).into());
            }
            let task = task_of(app, parent.id, a.get("task_id"))?;
            let before = snapshot(app, &task);
            if before.state.is_terminal() {
                return Ok(ToolResult::text(before.render(false)));
            }
            cancel(app, task.id);
            audit(app, tool, caller, &task.title, "gestopt");
            let mut after = snapshot(app, &task);
            after.state = delegation::TaskState::Cancelled;
            Ok(ToolResult::text(after.render(false)))
        }
        _ => Err("Not a delegation tool.".into()),
    }
}

fn links(app: &AppHandle) -> Option<tauri::State<'_, AutomationState>> {
    app.try_state::<AutomationState>()
}

fn snapshot(app: &AppHandle, run: &WorkspaceRun) -> Snapshot {
    let ws = workspace(app).expect("workspace state");
    let current = ws.manager.run(run.id).unwrap_or_else(|| run.clone());
    delegation::snapshot(&ws.manager, &current)
}

/// A task of this parent by its id; another session's task is not the caller's to read or stop.
fn task_of(app: &AppHandle, parent: Uuid, id: Option<&Value>) -> Result<WorkspaceRun, String> {
    let id = id.and_then(Value::as_str).and_then(|s| Uuid::parse_str(s.trim()).ok()).ok_or(NO_SUCH_TASK)?;
    let linked = links(app).and_then(|l| l.links.link(id)).is_some_and(|l| l.parent == parent);
    if !linked {
        return Err(NO_SUCH_TASK.into());
    }
    workspace(app).and_then(|w| w.manager.run(id)).ok_or_else(|| NO_SUCH_TASK.into())
}

fn active_children(app: &AppHandle, parent: Uuid) -> usize {
    let (Some(ws), Some(l)) = (workspace(app), links(app)) else { return 0 };
    l.links.children(parent).into_iter().filter(|c| ws.manager.run(*c).is_some_and(|r| r.status.is_active())).count()
}

fn installed(provider: RunProvider) -> bool {
    let found = find_executable(provider.kind()).map(|p| p.to_string_lossy().into_owned());
    session_executable(provider, found).is_some()
}

fn policy_name(p: PermissionPolicy) -> &'static str {
    match p {
        PermissionPolicy::Ask => "ask",
        PermissionPolicy::AcceptEdits => "acceptEdits",
        PermissionPolicy::Bypass => "bypass",
    }
}

fn mode_name(m: ExecutionMode) -> &'static str {
    match m {
        ExecutionMode::Agent => "agent",
        ExecutionMode::Plan => "plan",
    }
}

fn capabilities(app: &AppHandle, parent: &WorkspaceRun) -> String {
    let depth = links(app).map(|l| l.links.depth(parent.id)).unwrap_or(0);
    let mut lines = vec![
        "# Agents Nook can run for you".to_string(),
        format!(
            "You: {}, mode {}, rights {}{}",
            parent.provider.display_name(),
            mode_name(parent.mode),
            policy_name(parent.permission),
            if parent.model.is_empty() { String::new() } else { format!(", model {}", parent.model) }
        ),
        format!("Delegation depth: {depth} of {MAX_DEPTH} · running tasks: {} of {MAX_ACTIVE_CHILDREN}", active_children(app, parent.id)),
        String::new(),
    ];
    for provider in RunProvider::ALL {
        let mut line = format!(
            "- {} ({}): {}",
            provider.id(),
            provider.display_name(),
            if installed(provider) { "available" } else { "not installed" }
        );
        let models = provider.suggested_models();
        if !models.is_empty() {
            line += &format!(" · models: {}", models.join(", "));
        }
        let rights: Vec<&str> = provider.capabilities().policies.iter().map(|p| policy_name(*p)).collect();
        line += &format!(" · rights: {}", rights.join(", "));
        lines.push(line);
    }
    lines.push(String::new());
    lines.push("A task never has more rights than you. research, review and design tasks run in Plan mode.".into());
    lines.join("\n")
}

async fn delegate_task(
    app: &AppHandle,
    a: &Map<String, Value>,
    parent: &WorkspaceRun,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let text = |k: &str| a.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
    let task = text("task");
    if task.is_empty() {
        return Err("Give the complete brief for the task.".into());
    }
    let wait = a.get("wait").and_then(Value::as_bool).unwrap_or(false);
    let timeout = delegation::wait_seconds(a.get("timeout_seconds").and_then(Value::as_i64));
    let key = text("client_request_id");
    // A retry of the same call returns the task that is already there.
    if let Some(existing) = links(app).and_then(|l| l.links.child_with_key(parent.id, &key)) {
        return finish(app, existing, wait, timeout).await;
    }
    if let Verdict::Refuse(reason) = check(app, BridgeTool::DelegateTask, caller, None) {
        return Err(refusal(reason).into());
    }
    let agent = text("agent").to_lowercase();
    let provider = if agent.is_empty() {
        parent.provider
    } else {
        RunProvider::ALL
            .into_iter()
            .find(|p| p.id() == agent || p.display_name().to_lowercase() == agent)
            .ok_or_else(|| format!("Unknown agent \"{agent}\". Call orchestrator_capabilities for the list."))?
    };
    if !installed(provider) {
        return Err(format!("{} is not installed on this computer.", provider.display_name()));
    }
    let role = Role::named(&text("role")).unwrap_or(Role::General);
    let mode = a.get("plan").and_then(Value::as_bool).map(|p| if p { ExecutionMode::Plan } else { ExecutionMode::Agent });
    let permission = match a.get("rights").and_then(Value::as_str) {
        None => None,
        Some("ask") => Some(PermissionPolicy::Ask),
        Some("acceptEdits") => Some(PermissionPolicy::AcceptEdits),
        Some("bypass") => Some(PermissionPolicy::Bypass),
        Some(_) => return Err("rights must be ask, acceptEdits or bypass.".into()),
    };
    // The same checks the start makes, before the user is asked: no card for a task that cannot start.
    let (mode_now, permission_now) =
        delegation::resolve(parent.mode, parent.permission, mode, permission, role, provider).map_err(|d| d.message())?;
    let depth = links(app).map(|l| l.links.depth(parent.id)).unwrap_or(0);
    if let Some(denial) = delegation::admit(depth, active_children(app, parent.id)) {
        return Err(denial.message());
    }
    // What the user approves is everything the other agent will be told and allowed.
    if let Verdict::Ask(_) = check(app, BridgeTool::DelegateTask, caller, None) {
        let mut detail = format!("{} · {} · {}\n\n{task}", provider.display_name(), mode_name(mode_now), policy_name(permission_now));
        if !role.instruction().is_empty() {
            detail += &format!("\n\n{}", role.instruction());
        }
        let ws = workspace(app).ok_or("Nook is not ready.")?;
        let title = trf(
            "{agent} wil een taak aan een andere agent geven",
            "{agent} wants to hand a task to another agent",
            &[("agent", &caller.agent)],
        );
        let note = tr(
            "De agent krijgt alleen deze opdracht te zien, nooit je gesprek, en heeft nooit meer rechten dan de sessie die hem start.",
            "The agent sees only this brief, never your conversation, and never has more rights than the session that starts it.",
        );
        if !ws.bridge.ask(app, caller, BridgeTool::DelegateTask, title, detail, note.into(), &context.connection).await {
            audit(app, BridgeTool::DelegateTask, caller, &task, "niet toegestaan");
            return Err(refusal(Reason::Delegation).into());
        }
    }
    let request = delegation::Request {
        task: task.clone(),
        title: text("title"),
        role: Some(role),
        agent: Some(provider),
        mode,
        permission,
        key,
        model: text("model"),
        isolation: text("isolation"),
        wake: !wait,
    };
    let child = match crate::commands::automation::delegate(app, parent.id, request) {
        Ok(child) => child,
        Err(e) => {
            audit(app, BridgeTool::DelegateTask, caller, &task, &format!("mislukt: {e}"));
            return Err(format!("Nook could not start the task: {e}"));
        }
    };
    audit(app, BridgeTool::DelegateTask, caller, &format!("{} · {task}", provider.display_name()), &child.to_string());
    finish(app, child, wait, timeout).await
}

/// The answer for a task: its state now, or after waiting for it. A wait that runs out leaves the task running and
/// makes sure the parent hears when it ends.
async fn finish(app: &AppHandle, id: Uuid, wait: bool, timeout: u64) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let deadline = Instant::now() + Duration::from_secs(timeout);
    loop {
        let run = ws.manager.run(id).ok_or("The task is gone.")?;
        let now = delegation::snapshot(&ws.manager, &run);
        // A question ends the wait too: only the user or the parent can answer it.
        if !wait || now.is_settled() {
            return Ok(ToolResult::text(now.render(false)));
        }
        if Instant::now() >= deadline {
            wake_parent_when_done(app, id);
            return Ok(ToolResult::text(now.render(true)));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn task_wait(app: &AppHandle, a: &Map<String, Value>, parent: Uuid) -> Result<ToolResult, String> {
    let ids: Vec<&Value> = a.get("task_ids").and_then(Value::as_array).map(|v| v.iter().collect()).unwrap_or_default();
    if ids.is_empty() || ids.len() > 8 {
        return Err("Pass between 1 and 8 task ids from delegate_task.".into());
    }
    let tasks = ids
        .into_iter()
        .map(|v| task_of(app, parent, Some(v)))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| "No such task among these ids. Use the task ids that delegate_task returned.".to_string())?;
    let all = a.get("mode").and_then(Value::as_str) == Some("all");
    let timeout = delegation::wait_seconds(a.get("timeout_seconds").and_then(Value::as_i64));
    let deadline = Instant::now() + Duration::from_secs(timeout);
    loop {
        let snapshots: Vec<Snapshot> = tasks.iter().map(|t| snapshot(app, t)).collect();
        if delegation::wait_is_over(&snapshots, all) {
            return Ok(ToolResult::text(delegation::render_wait(&snapshots, false)));
        }
        if Instant::now() >= deadline {
            // The tasks go on; each tells the parent when it finishes.
            for (task, s) in tasks.iter().zip(&snapshots) {
                if !s.is_settled() {
                    wake_parent_when_done(app, task.id);
                }
            }
            return Ok(ToolResult::text(delegation::render_wait(&snapshots, true)));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

fn wake_parent_when_done(app: &AppHandle, id: Uuid) {
    if links(app).is_some_and(|l| l.links.set_wake(id, true)) {
        // It may have finished while the parent was still waiting.
        if let Some(run) = workspace(app).and_then(|w| w.manager.run(id)) {
            turn_finished(app, &run);
        }
    }
}

/// Stops a task and every task it delegated; nobody is woken for any of them.
fn cancel(app: &AppHandle, id: Uuid) {
    let (Some(ws), Some(l)) = (workspace(app), links(app)) else { return };
    l.links.set_wake(id, false);
    for child in l.links.children(id) {
        cancel(app, child);
    }
    if ws.manager.run(id).is_some_and(|r| r.status.is_active()) {
        ws.manager.stop(id);
    }
}

/// A session's turn ended: when it is a task its parent did not wait for, and nothing it still has to do waits in its
/// queue, the parent gets the result as a message. Each result goes out once.
pub fn turn_finished(app: &AppHandle, run: &WorkspaceRun) {
    let (Some(ws), Some(l)) = (workspace(app), links(app)) else { return };
    let Some(link) = l.links.link(run.id).filter(|l| l.wake) else { return };
    let queue = ws.manager.queue(run.id);
    if !delegation::may_deliver(run.status, !queue.is_empty() && !queue.is_held()) {
        return;
    }
    if ws.manager.run(link.parent).is_none() {
        return;
    }
    l.links.set_wake(run.id, false);
    let message = delegation::wake_message(&delegation::snapshot(&ws.manager, run));
    if let Err(e) = ws.manager.send(link.parent, &message) {
        log::warn!("Could not tell session {} that its task ended: {e}", link.parent);
    }
}
