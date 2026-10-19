//! Plannen: per stap alle details, tekstvelden aanpassen, stappen uitzetten, en uitvoeren na de klik. Een stap die al
//! lukte, draait nooit opnieuw; mislukt er halverwege iets, dan ga je verder zonder dat iets dubbel gebeurt.

use nook_core::brain::action_gate::{self, ActionField, PlanExecutor, Step};
use nook_core::brain::sources::SourceScope;
use nook_core::brain::{undo, LoopTool};
use nook_core::nooks::{PlanState, StepState};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Manager};

use super::chat::{action_problems, update};
use crate::brain::BrainState;
use crate::state::AppState;
use crate::tools::{self, ToolCtx};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanStep {
    pub tool: String,
    pub summary: String,
    /// Alle velden, volledig, zodat je alles kunt controleren voor het uitgevoerd wordt.
    pub fields: Vec<ActionField>,
    /// "vervangt", "vergeet": een woordje bij de stap als hij iets weghaalt of vervangt.
    pub tag: String,
}

fn scope_of(app: &AppHandle, nook_id: &str) -> SourceScope {
    app.state::<AppState>().with_chat(|c| c.get(nook_id).and_then(|conv| conv.scope.clone())).unwrap_or_default()
}

pub fn plan_steps(app: &AppHandle, nook_id: &str, message_id: &str) -> Vec<PlanStep> {
    let ctx = ToolCtx::new(app, "");
    let all = tools::all_tools(&ctx);
    let actions = app
        .state::<AppState>()
        .with_chat(|c| c.get(nook_id).and_then(|conv| conv.messages.iter().find(|m| m.id == message_id)).map(|m| m.actions.clone()))
        .unwrap_or_default();
    actions
        .iter()
        .map(|a| {
            let schema = all.iter().find(|t| t.name == a.tool).map(|t| t.schema.clone()).unwrap_or(Value::Null);
            let tag = match a.tool.as_str() {
                "remember" if !tools::text(&a.input, "replaces").is_empty() => "vervangt",
                "forget" => "vergeet",
                "delete_event" | "delete_reminder" => "verwijdert",
                _ => "",
            };
            PlanStep {
                tool: a.tool.clone(),
                summary: tools::summarize(&a.tool, &a.input),
                fields: action_gate::fields(&a.input, &schema),
                tag: tag.into(),
            }
        })
        .collect()
}

/// Past een tekstveld van een voorgestelde stap aan en controleert hem opnieuw.
pub fn edit_action(app: &AppHandle, nook_id: &str, message_id: &str, index: usize, key: &str, value: &str) -> Result<Vec<String>, String> {
    let ctx = ToolCtx::new(app, "");
    let all = tools::all_tools(&ctx);
    let scope = scope_of(app, nook_id);
    let brain = app.state::<BrainState>();
    let state = app.state::<AppState>();
    let problems = state.with_chat(|c| {
        let message = c.get_mut(nook_id)?.messages.iter_mut().find(|m| m.id == message_id)?;
        if message.action_states.get(index).and_then(StepState::result).is_some() {
            return None;
        }
        let action = message.actions.get_mut(index)?;
        // De waarde van voor de eerste aanpassing, zodat Nook bij het uitvoeren ziet wat je veranderde.
        let token = format!("{message_id}#{index}#{key}");
        let old = action.input.get(key).map(|v| v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string())).unwrap_or_default();
        brain.edit_origins.lock().unwrap_or_else(|e| e.into_inner()).entry(token).or_insert(old);
        action.input[key] = Value::String(value.to_string());
        if let Some(spec) = all.iter().find(|t| t.name == action.tool) {
            action.input = action_gate::normalized(&action.input, &spec.schema);
        }
        let problems = action_problems(&all, action, &scope);
        if message.action_problems.len() < message.actions.len() {
            message.action_problems.resize(message.actions.len(), vec![]);
        }
        message.action_problems[index] = problems.clone();
        Some(problems)
    });
    let problems = problems.ok_or("Deze stap kan niet meer aangepast worden.")?;
    state.save_chat();
    super::chat::updated(app, nook_id);
    Ok(problems)
}

pub fn set_included(app: &AppHandle, nook_id: &str, message_id: &str, index: usize, on: bool) {
    update(app, nook_id, message_id, |m| {
        if m.action_included.len() < m.actions.len() {
            m.action_included.resize(m.actions.len(), true);
        }
        let finished = m.action_states.get(index).is_some_and(StepState::is_finished);
        if index < m.action_included.len() && !(finished && on) {
            m.action_included[index] = on;
        }
    });
}

struct Executor {
    app: AppHandle,
    ctx: ToolCtx,
    all: Vec<LoopTool>,
    scope: SourceScope,
    nook_id: String,
    message_id: String,
}

#[async_trait::async_trait]
impl PlanExecutor for Executor {
    fn check(&self, step: &Step) -> Vec<String> {
        action_problems(&self.all, &nook_core::brain::PlannedAction::new(&step.tool, step.input.clone()), &self.scope)
    }

    async fn execute(&self, step: &Step) -> Result<String, String> {
        let state = self.app.state::<AppState>();
        let args = step.input.to_string();
        match tools::execute(&self.ctx, &step.tool, &step.input).await {
            Ok(result) => {
                state.store.audit(&step.tool, &args, &result);
                Ok(result)
            }
            Err(error) => {
                state.store.audit(&step.tool, &args, &format!("FOUT: {error}"));
                Err(error)
            }
        }
    }

    fn executed_before(&self, key: &str) -> Option<String> {
        let when = self.app.state::<AppState>().store.executed_action(key, action_gate::DUPLICATE_WINDOW_SECS)?;
        Some(nook_core::brain::dates::short(&when.with_timezone(&chrono::Local)))
    }

    fn record_executed(&self, key: &str, step: &Step, result: &str) {
        self.app.state::<AppState>().store.record_executed(key, &step.tool, result);
        self.app.state::<BrainState>().remember_done(&step.tool, &step.input, result);
    }

    fn progress(&self, states: &[StepState]) {
        let states = states.to_vec();
        update(&self.app, &self.nook_id, &self.message_id, |m| m.action_states = states);
    }

    async fn verify(&self, step: &Step, result: &str) -> Option<bool> {
        tools::verify(&self.ctx, &step.tool, &step.input, result).await
    }
}

/// Wat er na het uitvoeren onder het plan staat.
pub fn outcome(states: &[StepState]) -> PlanState {
    let mut done = vec![];
    let mut failure = None;
    for (index, state) in states.iter().enumerate() {
        match state {
            StepState::Done(r) | StepState::Verified(r) => done.push(r.clone()),
            StepState::Failed(e) => {
                failure.get_or_insert(format!("Stap {} mislukt: {e}", index + 1));
            }
            StepState::Duplicate(_) => {
                failure.get_or_insert("Een stap is kort geleden al precies zo uitgevoerd en is niet herhaald.".into());
            }
            _ => {}
        }
    }
    match (failure, done.len()) {
        (Some(f), 0) => PlanState::Failed(f),
        (Some(f), n) => PlanState::Failed(format!("{n} van {} gelukt. {f}", states.len())),
        (None, 0) => PlanState::Done("Niets uitgevoerd".into()),
        (None, 1) => PlanState::Done(done.remove(0)),
        (None, n) => PlanState::Done(format!("{n} acties uitgevoerd")),
    }
}

/// Voert de aangevinkte stappen uit. `force`: stappen die als dubbel gemarkeerd waren, mogen toch.
pub async fn run_plan(
    app: &AppHandle,
    nook_id: &str,
    message_id: &str,
    included: &[bool],
    inputs: Option<Vec<Value>>,
    force: &[usize],
) -> Result<(), String> {
    let state = app.state::<AppState>();
    let brain = app.state::<BrainState>();
    let settings = state.settings();
    let message = state.with_chat(|c| {
        let message = c.get_mut(nook_id)?.messages.iter_mut().find(|m| m.id == message_id)?;
        if matches!(message.plan_state, Some(PlanState::Running) | Some(PlanState::Cancelled)) {
            return None;
        }
        if matches!(message.plan_state, Some(PlanState::Done(_))) && force.is_empty() {
            return None;
        }
        if let Some(inputs) = &inputs {
            for (action, input) in message.actions.iter_mut().zip(inputs) {
                action.input = input.clone();
            }
        }
        message.action_included = included.to_vec();
        message.plan_state = Some(PlanState::Running);
        Some(message.clone())
    });
    let Some(message) = message else { return Err("Dit plan kan niet (meer) uitgevoerd worden.".into()) };
    super::chat::updated(app, nook_id);

    // Velden die de gebruiker aanpaste voor het uitvoeren, leren Nook zijn gewoontes.
    let prefix = format!("{message_id}#");
    let origins: Vec<(String, String)> = {
        let mut map = brain.edit_origins.lock().unwrap_or_else(|e| e.into_inner());
        let mine: Vec<(String, String)> = map.iter().filter(|(k, _)| k.starts_with(&prefix)).map(|(k, v)| (k.clone(), v.clone())).collect();
        map.retain(|k, _| !k.starts_with(&prefix));
        mine
    };
    if settings.learn_from_chats {
        for (index, action) in message.actions.iter().enumerate().filter(|(i, _)| included.get(*i).copied().unwrap_or(true)) {
            for (key, value) in action.input.as_object().into_iter().flatten() {
                if let Some((_, old)) = origins.iter().find(|(k, _)| *k == format!("{prefix}{index}#{key}")) {
                    let new = value.as_str().map(str::to_string).unwrap_or_else(|| value.to_string());
                    brain.memory.observe_edit(&action.tool, key, old, &new);
                }
            }
        }
    }
    let summaries: Vec<String> = message
        .actions
        .iter()
        .enumerate()
        .filter(|(i, _)| included.get(*i).copied().unwrap_or(true))
        .map(|(_, a)| tools::summarize(&a.tool, &a.input))
        .collect();
    state.store.audit("plan_goedgekeurd", &summaries.join(" | "), "");

    let ctx = ToolCtx::new(app, "").for_reply(nook_id, message_id);
    let scope = scope_of(app, nook_id);
    let executor =
        Executor { app: app.clone(), all: tools::all_tools(&ctx), ctx, scope, nook_id: nook_id.into(), message_id: message_id.into() };
    let steps: Vec<Step> = message.actions.iter().map(|a| Step { tool: a.tool.clone(), input: a.input.clone() }).collect();
    let states = action_gate::run_plan(&executor, &steps, &message.action_states, included, force).await;

    // Wat lukte en wat mislukte: lessen voor de volgende keer (Nooks eigen geheugenacties leren hier niets).
    if settings.learn_from_chats {
        for (action, step) in message.actions.iter().zip(&states).filter(|(a, _)| a.tool != "remember" && a.tool != "forget") {
            match step {
                StepState::Done(_) | StepState::Verified(_) => brain.memory.observe_outcome(&action.tool, &action.input, None),
                StepState::Failed(error) => brain.memory.observe_outcome(&action.tool, &action.input, Some(error)),
                _ => {}
            }
        }
    }
    let undoable = message.actions.iter().zip(&states).any(|(a, s)| s.result().is_some_and(|r| undo::step(&a.tool, &a.input, r).is_some()));
    let final_state = outcome(&states);
    update(app, nook_id, message_id, |m| {
        m.action_states = states;
        m.plan_state = Some(final_state);
        if undoable && !m.offers.iter().any(|o| o == "Maak ongedaan") {
            m.offers.push("Maak ongedaan".into());
        }
    });
    state.save_chat();
    Ok(())
}

pub fn cancel(app: &AppHandle, nook_id: &str, message_id: &str) {
    let state = app.state::<AppState>();
    let summaries = state
        .with_chat(|c| {
            c.get(nook_id)
                .and_then(|conv| conv.messages.iter().find(|m| m.id == message_id))
                .map(|m| m.actions.iter().map(|a| tools::summarize(&a.tool, &a.input)).collect::<Vec<_>>())
        })
        .unwrap_or_default();
    state.store.audit("plan_geannuleerd", &summaries.join(" | "), "");
    update(app, nook_id, message_id, |m| m.plan_state = Some(PlanState::Cancelled));
    state.save_chat();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outcomes_say_what_happened() {
        assert_eq!(outcome(&[StepState::Done("Gemaakt".into())]), PlanState::Done("Gemaakt".into()));
        assert_eq!(outcome(&[StepState::Done("a".into()), StepState::Verified("b".into())]), PlanState::Done("2 acties uitgevoerd".into()));
        assert_eq!(
            outcome(&[StepState::Done("a".into()), StepState::Failed("kapot".into()), StepState::NotRun]),
            PlanState::Failed("1 van 3 gelukt. Stap 2 mislukt: kapot".into())
        );
        assert_eq!(outcome(&[StepState::Skipped]), PlanState::Done("Niets uitgevoerd".into()));
    }
}
