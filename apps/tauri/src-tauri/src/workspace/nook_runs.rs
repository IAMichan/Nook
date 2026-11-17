//! Runs of automations for Nook Chat itself (`ScheduledTaskStore.runInNook` on the Mac): each run is a conversation of
//! its own, asked as if the user typed the task's prompt, with the run's note for the brain. Nook looks things up and
//! answers there; mail drafts and plans wait in that conversation for the user's click. Nothing is sent or changed by
//! the run itself. The rules (prompt note, quiet, reasons) are in `nook_core::workspace::{nook_schedule, scheduler}`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{Local, Utc};
use nook_core::brain::action_gate;
use nook_core::brain::service;
use nook_core::nooks::Conversation;
use nook_core::nooks::{PlanState, StepState};
use nook_core::workspace::autonomy::{self, AutonomyStep, NookAutonomy};
use nook_core::workspace::manager::Manager;
use nook_core::workspace::models::{NewRunConfig, PermissionPolicy, RunStatus};
use nook_core::workspace::nook_schedule;
use nook_core::workspace::schedule::{reason, ScheduledRunStatus};
use nook_core::workspace::scheduler::{NookRun, SessionHost};
use tauri::{AppHandle, Emitter, Manager as _};
use uuid::Uuid;

use super::automation::AutomationState;
use crate::commands::chat;
use crate::state::AppState;

/// The scheduler's host in the app: sessions go to the workspace manager, runs for Nook to Nook Chat.
pub struct AppHost {
    pub manager: Arc<Manager>,
    pub app: AppHandle,
}

impl SessionHost for AppHost {
    fn start_session(&self, config: NewRunConfig) -> Result<Uuid, String> {
        self.manager.start_session(config)
    }

    fn session(&self, id: Uuid) -> Option<(RunStatus, Option<String>, PermissionPolicy)> {
        self.manager.session(id)
    }

    fn send_to(&self, id: Uuid, text: &str, fresh: bool, note: &str) -> Result<(), String> {
        self.manager.send_to(id, text, fresh, note)
    }

    fn ask_nook(&self, run: NookRun) -> Result<(), String> {
        start(&self.app, run)
    }
}

/// Starts the run in a new conversation in the background, so the chat on screen stays as it is.
fn start(app: &AppHandle, run: NookRun) -> Result<(), String> {
    let state = app.state::<AppState>();
    let settings = state.settings();
    if !service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty())) {
        return Err(reason::NO_BRAIN.into());
    }
    let nook_id = state.with_chat(|c| {
        let conversation = Conversation::new();
        let id = conversation.id.clone();
        c.conversations.insert(0, conversation);
        id
    });
    let reply = chat::ask_scheduled(app, &nook_id, &run.prompt, run.note.clone())?;
    // The task's name, not the first words of its prompt; the marker ties the conversation to its automation.
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(&nook_id) {
            conv.title = run.title.clone();
            conv.scheduled_task = Some(run.task.to_string());
        }
    });
    chat::updated(app, &nook_id);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let (status, error) = watch(&app, &nook_id, reply.as_deref(), run.quiet).await;
        // The steps the user lets this task carry out by itself run now; the rest waits in the conversation.
        if status == ScheduledRunStatus::Succeeded && error.is_none() && run.autonomy != NookAutonomy::Ask {
            if let Some(reply) = reply.as_deref() {
                carry_out(&app, &nook_id, reply, &run).await;
            }
        }
        if let Some(auto) = app.try_state::<AutomationState>() {
            auto.scheduler.finish_run(run.task, status, error, Utc::now(), &Local);
        }
        let _ = app.emit("automation-changed", ());
    });
    Ok(())
}

/// Waits for the run's answer (at most `RUN_LIMIT_SECONDS`) and says how the run ended.
async fn watch(app: &AppHandle, nook_id: &str, reply: Option<&str>, quiet: bool) -> (ScheduledRunStatus, Option<String>) {
    let state = app.state::<AppState>();
    let deadline = Instant::now() + Duration::from_secs(nook_schedule::RUN_LIMIT_SECONDS);
    let busy = || state.with_chat(|c| c.get(nook_id).is_some_and(|conv| conv.busy));
    while busy() && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    if busy() {
        chat::stop(app, nook_id);
        return (ScheduledRunStatus::Failed, Some(reason::NOOK_TIMEOUT.into()));
    }
    // A quick answer (no brain needed) has no reply id: the last answer of the conversation is the run's.
    let (answer, asked) = state.with_chat(|c| {
        let Some(conv) = c.get(nook_id) else { return (None, 0) };
        let asked = conv.messages.iter().filter(|m| m.from_user).count();
        let answer = match reply {
            Some(id) => conv.messages.iter().find(|m| m.id == id),
            None => conv.messages.iter().rev().find(|m| !m.from_user),
        };
        (answer.cloned(), asked)
    });
    // The user deleted the conversation meanwhile: the run happened, there is just nothing to show.
    let Some(answer) = answer else { return (ScheduledRunStatus::Succeeded, None) };
    // Nothing new: no conversation stays behind, unless the user went on with it.
    if quiet && nook_schedule::is_nothing_new(&answer.text) {
        if asked <= 1 {
            state.with_chat(|c| c.remove(nook_id));
            chat::updated(app, nook_id);
        }
        return (ScheduledRunStatus::Succeeded, Some(reason::NOTHING_NEW.into()));
    }
    if answer.is_error {
        return (ScheduledRunStatus::Failed, Some(answer.text));
    }
    if answer.text.trim().is_empty() && answer.mails.is_empty() && answer.actions.is_empty() && answer.charts.is_empty() {
        return (ScheduledRunStatus::Failed, Some(reason::NOOK_EMPTY.into()));
    }
    // The answer waits for the user: the conversation shows as unread in the list.
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(nook_id) {
            conv.unread = true;
        }
    });
    chat::updated(app, nook_id);
    (ScheduledRunStatus::Succeeded, None)
}

/// Carries out what the task may do by itself (`AppModel+Autonomy` on the Mac): the unattended steps at once (`auto`)
/// or after Nook's judge found them routine (`decide`). Everything else stays in the plan for the user's click. Each
/// step runs through the plan runner, which writes the audit log, and the answer ends with what ran and what waits.
async fn carry_out(app: &AppHandle, nook_id: &str, reply: &str, run: &NookRun) {
    let state = app.state::<AppState>();
    let Some(message) = state.with_chat(|c| c.get(nook_id)?.messages.iter().find(|m| m.id == reply).cloned()) else { return };
    if message.plan_state != Some(PlanState::Pending) || message.actions.is_empty() {
        return;
    }
    let ctx = crate::tools::ToolCtx::new(app, "").in_nook(nook_id);
    let all = crate::tools::all_tools(&ctx);
    let mut indices = vec![];
    let mut steps = vec![];
    for (index, action) in message.actions.iter().enumerate() {
        let included = message.action_included.get(index).copied().unwrap_or(true);
        let clean = message.action_problems.get(index).is_none_or(Vec::is_empty);
        let open = !message.action_states.get(index).is_some_and(StepState::is_finished);
        if !(included && clean && open) {
            continue;
        }
        let schema = all.iter().find(|t| t.name == action.tool).map(|t| t.schema.clone()).unwrap_or_default();
        let detail: Vec<String> = action_gate::fields(&action.input, &schema).iter().map(|f| format!("{}: {}", f.label, f.value)).collect();
        let recipient =
            ["to", "name", "chat", "repo"].iter().map(|k| crate::tools::text(&action.input, k)).find(|v| !v.is_empty()).unwrap_or_default();
        indices.push(index);
        steps.push(AutonomyStep {
            tool: action.tool.clone(),
            summary: crate::tools::summarize(&action.tool, &action.input),
            detail: detail.join("\n"),
            recipient,
        });
    }
    if steps.is_empty() {
        return;
    }
    let (run_now, to_judge) = autonomy::split(&steps, run.autonomy);
    let mut chosen: std::collections::BTreeSet<usize> = run_now.iter().copied().collect();
    let mut reasons: std::collections::HashMap<usize, String> = std::collections::HashMap::new();
    for (i, step) in steps.iter().enumerate() {
        if !run_now.contains(&i) && !to_judge.contains(&i) {
            reasons.insert(i, autonomy::waiting_reason(&step.tool).to_string());
        }
    }
    if !to_judge.is_empty() {
        let task = app.try_state::<AutomationState>().and_then(|a| a.scheduler.task(run.task));
        let prompt_text = task.map(|t| t.prompt).unwrap_or_else(|| run.prompt.clone());
        let numbered: Vec<(usize, &AutonomyStep)> = to_judge.iter().map(|&i| (i + 1, &steps[i])).collect();
        let prompt = autonomy::judge_prompt(&run.title, &prompt_text, &numbered, run.from_outside);
        let settings = state.settings();
        let env = service::BrainEnv {
            key: state.key_for(settings.provider),
            memory_gb: crate::brain::memory_gb(),
            country: crate::brain::country(),
            timezone: crate::brain::timezone(),
        };
        // No answer from the judge (no brain, a timeout): every step waits, as it would without the setting.
        let answer = tokio::time::timeout(Duration::from_secs(90), service::complete(&settings, &env, autonomy::JUDGE_SYSTEM, &prompt))
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default();
        let verdicts = autonomy::verdicts(&answer);
        for &i in &to_judge {
            match verdicts.get(&(i + 1)) {
                Some(v) if v.run => {
                    chosen.insert(i);
                }
                Some(v) if !v.reason.is_empty() => {
                    reasons.insert(i, v.reason.clone());
                }
                _ => {}
            }
        }
    }
    let (mut ran, mut failed) = (0, 0);
    if !chosen.is_empty() {
        state.store.audit("scheduled_autonomy", &format!("{} ({})", run.title, run.autonomy.id()), "");
        let chosen_actions: Vec<usize> = chosen.iter().map(|&i| indices[i]).collect();
        let before = message.action_included.clone();
        let included: Vec<bool> = (0..message.actions.len()).map(|i| chosen_actions.contains(&i)).collect();
        let _ = crate::commands::plans::run_plan(app, nook_id, reply, &included, None, &[]).await;
        let after = state.with_chat(|c| c.get(nook_id)?.messages.iter().find(|m| m.id == reply).cloned());
        if let Some(after) = after {
            for &i in &chosen_actions {
                match after.action_states.get(i) {
                    Some(StepState::Done(_) | StepState::Verified(_)) => ran += 1,
                    Some(StepState::Failed(_)) => failed += 1,
                    _ => {}
                }
            }
        }
        // What was left for the user is theirs to run: switched on as it was, and the plan open again.
        let remains = (0..message.actions.len()).any(|i| !chosen_actions.contains(&i) && before.get(i).copied().unwrap_or(true));
        chat::update(app, nook_id, reply, |m| {
            m.action_included =
                (0..m.actions.len()).map(|i| chosen_actions.contains(&i) || before.get(i).copied().unwrap_or(true)).collect();
            if remains && matches!(m.plan_state, Some(PlanState::Done(_))) {
                m.plan_state = Some(PlanState::Pending);
            }
        });
    }
    let waiting: Vec<(String, Option<String>)> =
        (0..steps.len()).filter(|i| !chosen.contains(i)).map(|i| (steps[i].summary.clone(), reasons.get(&i).cloned())).collect();
    let block = autonomy::note(ran, failed, &waiting, run.autonomy);
    if !block.is_empty() {
        chat::update(app, nook_id, reply, |m| m.text.push_str(&block));
    }
    state.save_chat();
}
