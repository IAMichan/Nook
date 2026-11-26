//! The steps Nook suggests from what a conversation says (`ChatActionSuggestions`, `AppModel.suggestActions` on the Mac):
//! once new lines could ask for something, the brain reads them with a few of Nook's tools and proposes what it can do
//! (`service::propose`: action tools never run there); the interface shows it above the field and nothing runs until
//! the user clicks Do it (`run_suggested_actions`). The same for every conversation with a field; Nook Chat asks first.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use nook_core::brain::action_suggestion::{self as rules, Line, Place};
use nook_core::brain::{action_gate, dates, service, ToolKind};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Manager};

use crate::state::AppState;
use crate::tools::{self, ToolCtx};

type Res<T> = Result<T, String>;

/// What the pace remembers of a conversation: the last line read, the last look, what was already offered.
#[derive(Default)]
struct History {
    seen: Option<String>,
    last_look: Option<DateTime<Utc>>,
    offered: Vec<String>,
}

static HISTORY: Mutex<Option<HashMap<String, History>>> = Mutex::new(None);
/// Every look in the last hour, over all conversations.
static LOOKS: Mutex<Vec<DateTime<Utc>>> = Mutex::new(Vec::new());

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SuggestRequest {
    /// The conversation's key ("nook:<id>", "chat:<key>", "run:<id>").
    pub conversation: String,
    pub place: Place,
    /// Its newest lines, oldest first.
    pub lines: Vec<Line>,
    /// When its newest message came: an old one gets no look.
    pub date: Option<DateTime<Utc>>,
    /// A suggestion there still waits for the user: no new look meanwhile.
    #[serde(default)]
    pub waiting: bool,
    /// When the user last dismissed a suggestion there: quiet for a while after.
    #[serde(default)]
    pub dismissed: Option<DateTime<Utc>>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SuggestedStep {
    pub tool: String,
    pub input: Value,
    /// How the step reads on the card.
    #[serde(default)]
    pub summary: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Suggestion {
    pub actions: Vec<SuggestedStep>,
    pub reason: Option<String>,
}

/// The user's project folders, favorites first, for a coding task's folder.
fn projects(app: &AppHandle) -> Vec<String> {
    #[cfg(desktop)]
    if let Some(ws) = app.try_state::<crate::workspace::WorkspaceState>() {
        let s = ws.settings.lock().unwrap_or_else(|e| e.into_inner());
        return s.favorite_projects.iter().chain(s.recent_projects.iter()).cloned().collect();
    }
    let _ = app;
    vec![]
}

/// Looks at a conversation's new lines and proposes steps, or nothing. Nothing as well when the setting is off, no brain
/// is ready, the lines are old, only a reaction came, or the pace says wait.
#[tauri::command]
pub async fn suggest_actions(app: AppHandle, request: SuggestRequest) -> Res<Option<Suggestion>> {
    let state = app.state::<AppState>();
    let mut settings = state.settings();
    let now = Utc::now();
    if !settings.suggest_chat_actions || request.lines.is_empty() || rules::is_stale(request.date, now) {
        return Ok(None);
    }
    if !service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty())) {
        return Ok(None);
    }
    let fresh = {
        let mut all = lock(&HISTORY);
        let past = all.get_or_insert_with(HashMap::new).entry(request.conversation.clone()).or_default();
        let fresh = rules::new_lines(&request.lines, past.seen.as_deref());
        if fresh.is_empty() || !rules::worth_a_look(&fresh, &request.place) {
            // Nothing that could ask for a step: the next look starts after these lines.
            past.seen = request.lines.last().map(Line::key).or(past.seen.take());
            return Ok(None);
        }
        let mut looks = lock(&LOOKS);
        looks.retain(|l| (now - *l).num_seconds() < 3600);
        let pace =
            rules::Pace { last_look: past.last_look, waiting: request.waiting, looks_this_hour: looks.len(), dismissed: request.dismissed };
        // Not now: these lines stay new, so the next look still reads them.
        if !pace.allows(now) {
            return Ok(None);
        }
        past.seen = request.lines.last().map(Line::key).or(past.seen.take());
        past.last_look = Some(now);
        looks.push(now);
        fresh.len()
    };
    let handled = lock(&HISTORY).as_ref().and_then(|h| h.get(&request.conversation)).map(|p| p.offered.clone()).unwrap_or_default();

    // The model chosen for suggestions, else the brain's own.
    let model = settings.action_suggestion_model.trim().to_string();
    if !model.is_empty() {
        settings.set_provider_model(&model);
    }
    // Only the tools a suggestion can use: a small request answers fast.
    let ctx = ToolCtx::new(&app, &rules::request(&request.lines));
    let offered: Vec<_> = tools::tools(&ctx).into_iter().filter(|t| rules::PREFERRED_TOOLS.contains(&t.name.as_str())).collect();
    if !offered.iter().any(|t| t.kind == ToolKind::Action) {
        return Ok(None);
    }
    let prompt =
        rules::prompt(&request.place, &request.lines, fresh, &projects(&app), &handled, &dates::date_sheet(&chrono::Local::now(), 8));
    let env = super::chat::brain_env(&app, &settings);
    let system = rules::system();
    let plan = match tokio::time::timeout(
        Duration::from_secs(rules::TIMEOUT_SECONDS),
        service::propose(&settings, &env, &system, &prompt, offered, rules::ROUNDS),
    )
    .await
    {
        Ok(Ok(plan)) => plan,
        _ => return Ok(None),
    };
    let steps: Vec<SuggestedStep> = plan
        .actions
        .into_iter()
        .filter(|a| rules::complete(&a.tool, &a.input))
        .map(|a| SuggestedStep { summary: tools::summarize(&a.tool, &a.input), tool: a.tool, input: a.input })
        .collect();
    let kept = rules::keep(steps, |s| s.tool.clone(), |s| s.summary.clone(), &handled);
    // Steps the brain does not back with its closing line (or with "NONE") are not shown.
    let Some(reason) = rules::reason(&plan.text) else { return Ok(None) };
    if kept.is_empty() {
        return Ok(None);
    }
    if let Some(past) = lock(&HISTORY).as_mut().and_then(|h| h.get_mut(&request.conversation)) {
        past.offered.extend(kept.iter().map(|s| s.summary.clone()));
    }
    Ok(Some(Suggestion { reason: Some(reason), actions: kept }))
}

/// Do it: the steps run one after another, each checked against its tool's fields first, as a plan in Nook Chat does.
/// Returns what each step did; stops at the first that fails.
#[tauri::command]
pub async fn run_suggested_actions(app: AppHandle, nook_id: Option<String>, steps: Vec<SuggestedStep>) -> Res<Vec<String>> {
    let mut ctx = ToolCtx::new(&app, "");
    if let Some(id) = nook_id.as_deref() {
        ctx = ctx.in_nook(id);
    }
    let all = tools::all_tools(&ctx);
    let mut done = vec![];
    for step in steps {
        let spec = all
            .iter()
            .find(|t| t.name == step.tool && t.kind == ToolKind::Action)
            .ok_or_else(|| format!("Nook cannot do {} now.", step.tool))?;
        let input = action_gate::normalized(&step.input, &spec.schema);
        let problems = action_gate::problems(&step.tool, &input, &spec.schema);
        if !problems.is_empty() {
            return Err(problems.join(" "));
        }
        done.push(tools::execute(&ctx, &step.tool, &input).await?);
    }
    Ok(done)
}
