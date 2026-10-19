//! Commando's voor agents: overzicht, toestemming, vragen, koppelen, accounts, eerdere sessies en de terminal.

use std::path::PathBuf;

use nook_core::agents::history::HistoryResult;
use nook_core::agents::installer::{self, State as LinkState, Target};
use nook_core::agents::line_diff::DiffLine;
use nook_core::agents::models::{AgentApproval, AgentSession, ApprovalDecision, PlanUsage, QuestionRequest};
use nook_core::agents::profiles::{AgentAuthMethod, AgentProfile};
use nook_core::agents::transcript::{self, AgentChatMessage};
use nook_core::agents::{scanner, AgentKind};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::agents::{self, lock, AgentsState};
use crate::state::AppState;

type Res<T> = Result<T, String>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    sessions: Vec<AgentSession>,
    approvals: Vec<AgentApproval>,
    questions: Vec<QuestionRequest>,
    plan_usage: Option<PlanUsage>,
    profile_plan_usage: std::collections::BTreeMap<String, PlanUsage>,
    marks: Value,
}

/// Alles wat de tab Agents en de balk nodig hebben, in één keer.
#[tauri::command]
pub fn agents_overview(app: AppHandle, state: State<'_, AgentsState>) -> Overview {
    let mut sessions = state.hub.sessions();
    sessions.extend(state.hub.detected());
    let mut approvals: Vec<AgentApproval> = state.hub.approvals().iter().map(AgentApproval::from_hook).collect();
    approvals.extend(crate::workspace::pending_approvals(&app));
    approvals.sort_by_key(|a| a.created);
    let (plan_usage, profile_plan_usage) = state.hub.plan_usage();
    let mut questions = state.hub.questions();
    questions.extend(crate::workspace::pending_questions(&app));
    Overview { sessions, approvals, questions, plan_usage, profile_plan_usage, marks: lock(&state.marks).snapshot() }
}

/// Beslist over een toestemmingsvraag, waar hij ook vandaan kwam.
#[tauri::command]
pub fn agents_decide(app: AppHandle, state: State<'_, AgentsState>, id: String, decision: ApprovalDecision) -> Res<()> {
    if let Some(request) = id.strip_prefix("hook-") {
        state.hub.decide(request, decision);
        return Ok(());
    }
    crate::workspace::decide_approval(&app, &id, decision)
}

#[tauri::command]
pub fn agents_answer(app: AppHandle, state: State<'_, AgentsState>, id: String, selections: Vec<Vec<String>>) -> Res<()> {
    if id.starts_with("runq:") {
        return crate::workspace::answer_question(&app, &id, &selections);
    }
    state.hub.answer_question(&id, &selections);
    Ok(())
}

/// "In terminal": de vraag gaat terug naar de agent, en Nook haalt zijn venster naar voren.
#[tauri::command]
pub fn agents_answer_in_terminal(state: State<'_, AgentsState>, id: String) -> Res<()> {
    if id.starts_with("runq:") {
        return Err("Deze sessie draait in Nook zelf, niet in een terminal. Beantwoord de vraag hier.".into());
    }
    let host = state
        .hub
        .questions()
        .into_iter()
        .find(|q| q.id == id)
        .and_then(|q| state.hub.sessions().into_iter().find(|s| s.id == q.session_key).map(|s| s.host));
    state.hub.answer_question_in_terminal(&id);
    agents::terminal::activate(&host.unwrap_or_default())
}

/// Weigert toestemming hier en haalt het venster van de agent naar voren, zodat je het daar beantwoordt.
#[tauri::command]
pub fn agents_decide_in_terminal(state: State<'_, AgentsState>, id: String) -> Res<()> {
    if !id.starts_with("hook-") {
        return Err("Deze sessie draait in Nook zelf, niet in een terminal. Beslis hier.".into());
    }
    let request = id.strip_prefix("hook-").unwrap_or(&id).to_string();
    let host = state.hub.sessions().into_iter().find(|s| s.approval_id.as_deref() == Some(request.as_str())).map(|s| s.host);
    state.hub.decide(&request, ApprovalDecision::Terminal);
    agents::terminal::activate(&host.unwrap_or_default())
}

/// Beëindigt het proces van een sessie: netjes (zodat de agent zijn gesprek bewaart), na een paar seconden geforceerd.
#[tauri::command]
pub fn agents_end(state: State<'_, AgentsState>, session_id: String) -> Res<()> {
    let name =
        state.hub.sessions().into_iter().chain(state.hub.detected()).find(|s| s.id == session_id).map(|s| s.name).unwrap_or_default();
    let Some(pid) = state.hub.process_id(&session_id) else {
        return Err(format!("Nook weet niet zeker welk proces van {name} dit is, dus beëindigt het niets."));
    };
    if !scanner::terminate(pid) {
        return Err(format!("{name} kon niet worden beëindigd."));
    }
    state.hub.forget(&session_id);
    Ok(())
}

#[tauri::command]
pub fn agents_forget(state: State<'_, AgentsState>, session_id: String) {
    state.hub.forget(&session_id);
}

#[tauri::command]
pub fn agents_can_end(state: State<'_, AgentsState>, session_id: String) -> bool {
    state.hub.process_id(&session_id).is_some()
}

/// Het gesprek uit het transcript van de agent.
#[tauri::command]
pub async fn agents_transcript(path: String) -> Vec<AgentChatMessage> {
    tauri::async_runtime::spawn_blocking(move || transcript::recent(&path, transcript::FULL_LIMIT)).await.unwrap_or_default()
}

/// Eerdere sessies, accounts en gebruik. `force`: opnieuw lezen, ook als de laatste keer kort geleden was.
#[tauri::command]
pub async fn agents_history(app: AppHandle, force: bool) -> Res<HistoryResult> {
    let cached = lock(&app.state::<AgentsState>().last_history).clone();
    if !force && (!cached.sessions.is_empty() || !cached.accounts.is_empty()) {
        // Op de achtergrond verversen; de interface krijgt `agents-history` als het klaar is.
        let app2 = app.clone();
        tauri::async_runtime::spawn(async move {
            let result = agents::refresh_history(&app2).await;
            let _ = app2.emit("agents-history", result);
        });
        return Ok(cached);
    }
    Ok(agents::refresh_history(&app).await)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Integration {
    target: Target,
    agent: Option<AgentKind>,
    profile_id: Option<String>,
    title: String,
    detail: String,
    path: String,
    state: LinkState,
}

fn profile_home(state: &AgentsState, profile_id: Option<&str>) -> Option<PathBuf> {
    let profile = profile_id.and_then(|id| lock(&state.profiles).profile(id))?;
    profile.home.map(PathBuf::from)
}

/// Elke koppeling met zijn stand, ook per extra account van Claude Code en Codex.
#[tauri::command]
pub fn agents_integrations(state: State<'_, AgentsState>) -> Vec<Integration> {
    let agent_of = |t: Target| AgentKind::ALL.into_iter().find(|k| k.targets().contains(&t));
    let mut list: Vec<Integration> = Target::ALL
        .into_iter()
        .map(|t| Integration {
            target: t,
            agent: agent_of(t),
            profile_id: None,
            title: t.title().into(),
            detail: t.detail().into(),
            path: t.display_path(None),
            state: installer::state(t, None),
        })
        .collect();
    let profiles = lock(&state.profiles).all();
    for p in profiles.iter().filter(|p| !p.is_default()) {
        for t in p.kind.targets() {
            let home = p.home.as_ref().map(PathBuf::from);
            list.push(Integration {
                target: t,
                agent: Some(p.kind),
                profile_id: Some(p.id.clone()),
                title: format!("{} · {}", t.title(), p.label),
                detail: t.detail().into(),
                path: t.display_path(home.as_deref()),
                state: installer::state(t, home.as_deref()),
            });
        }
    }
    list
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkPreview {
    id: String,
    title: String,
    path: String,
    install: bool,
    preview: Vec<DiffLine>,
    /// Er verandert niets (al gekoppeld, of niets om weg te halen).
    unchanged: bool,
}

/// "Koppel…": bereidt de wijziging voor en laat precies zien wat er verandert. Er wordt nog niets geschreven.
#[tauri::command]
pub fn agents_prepare_link(state: State<'_, AgentsState>, target: Target, install: bool, profile_id: Option<String>) -> Res<LinkPreview> {
    let home = profile_home(&state, profile_id.as_deref());
    let change = installer::prepare(target, install, home.as_deref()).map_err(|e| e.0)?;
    let id = uuid::Uuid::new_v4().to_string();
    let unchanged = change.files.iter().all(|f| f.original == f.updated);
    let preview = LinkPreview {
        id: id.clone(),
        title: target.title().into(),
        path: target.display_path(home.as_deref()),
        install,
        preview: change.preview.clone(),
        unchanged,
    };
    lock(&state.changes).insert(id, change);
    Ok(preview)
}

/// OK: schrijft precies de getoonde wijziging, na een backup. Geeft het pad van de backup terug.
#[tauri::command]
pub fn agents_apply_link(app: AppHandle, state: State<'_, AgentsState>, id: String) -> Res<Option<String>> {
    let change = lock(&state.changes).remove(&id).ok_or("Deze wijziging is verlopen; kies opnieuw Koppel.")?;
    let backup = installer::apply(&change).map_err(|e| e.0)?;
    app.state::<AppState>().store.audit(
        if change.install { "agents_link" } else { "agents_unlink" },
        &change.target.display_path(change.home.as_deref()),
        &backup.as_ref().map(|b| format!("backup: {}", b.display())).unwrap_or_else(|| "geschreven".into()),
    );
    let _ = app.emit("agents-changed", ());
    Ok(backup.map(|b| nook_core::agents::tilde(&b.to_string_lossy())))
}

#[tauri::command]
pub fn agents_discard_link(state: State<'_, AgentsState>, id: String) {
    lock(&state.changes).remove(&id);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileView {
    #[serde(flatten)]
    profile: AgentProfile,
    title: String,
    display_home: String,
    preferred: bool,
    has_key: bool,
    launch_command: String,
    login_command: String,
}

#[tauri::command]
pub fn agents_profiles(app: AppHandle, state: State<'_, AgentsState>) -> Vec<ProfileView> {
    let secrets = app.state::<AppState>().secrets.clone();
    let store = lock(&state.profiles);
    store
        .all()
        .into_iter()
        .map(|p| ProfileView {
            title: p.title(),
            display_home: p.display_home(),
            preferred: store.preferred(p.kind).id == p.id,
            has_key: p.kind == AgentKind::Claude && secrets.read(&p.secret_account()).is_some(),
            launch_command: p.launch_command(),
            login_command: p.login_command(),
            profile: p,
        })
        .collect()
}

fn changed(app: &AppHandle) {
    let _ = app.emit("agents-changed", ());
}

#[tauri::command]
pub fn agents_profile_add(app: AppHandle, state: State<'_, AgentsState>, kind: AgentKind, label: String) -> Res<AgentProfile> {
    if !kind.supports_profiles() {
        return Err(format!("{} kent geen accounts per map.", kind.name()));
    }
    let p = lock(&state.profiles).add(kind, &label, None);
    changed(&app);
    Ok(p)
}

#[tauri::command]
pub fn agents_profile_rename(app: AppHandle, state: State<'_, AgentsState>, id: String, label: String) {
    lock(&state.profiles).rename(&id, &label);
    changed(&app);
}

/// Haalt een account uit Nook. De map en de inlog op schijf blijven staan; de sleutel in de kluis gaat weg.
#[tauri::command]
pub fn agents_profile_remove(app: AppHandle, state: State<'_, AgentsState>, id: String) -> Res<()> {
    let secret = lock(&state.profiles).remove(&id).ok_or("Het hoofdaccount blijft altijd.")?;
    let _ = app.state::<AppState>().secrets.remove(&secret);
    changed(&app);
    Ok(())
}

#[tauri::command]
pub fn agents_profile_prefer(app: AppHandle, state: State<'_, AgentsState>, id: String) {
    lock(&state.profiles).set_preferred(&id);
    changed(&app);
}

#[tauri::command]
pub fn agents_profile_auth(app: AppHandle, state: State<'_, AgentsState>, id: String, method: AgentAuthMethod) {
    lock(&state.profiles).set_auth(&id, method);
    changed(&app);
}

/// Bewaart de API-sleutel van een Claude-account in de kluis (leeg = weghalen). Gaat nooit naar een bestand.
#[tauri::command]
pub fn agents_profile_key(app: AppHandle, state: State<'_, AgentsState>, id: String, key: String) -> Res<bool> {
    let profile = lock(&state.profiles).profile(&id).ok_or("Onbekend account")?;
    app.state::<AppState>().secrets.write(&profile.secret_account(), &key)?;
    changed(&app);
    Ok(app.state::<AppState>().secrets.read(&profile.secret_account()).is_some())
}

#[tauri::command]
pub fn agents_mark_finished(app: AppHandle, state: State<'_, AgentsState>, key: String, finished: bool) {
    let mut marks = lock(&state.marks);
    if finished {
        marks.mark(&key);
    } else {
        marks.reopen_by_user(&key, chrono::Utc::now());
    }
    drop(marks);
    changed(&app);
}

#[tauri::command]
pub fn agents_visit(state: State<'_, AgentsState>, id: String, unread: Option<bool>) {
    let mut marks = lock(&state.marks);
    if unread == Some(true) {
        marks.mark_unread(&id);
    } else {
        marks.visit(&id, chrono::Utc::now());
    }
}

/// Haalt het venster van een agent naar voren.
#[tauri::command]
pub fn agents_activate_terminal(host: String) -> Res<()> {
    agents::terminal::activate(&host)
}

/// Opent een nieuw terminalvenster dat `command` draait in `folder` (inloggen, installeren, verdergaan in de terminal).
#[tauri::command]
pub fn agents_run_in_terminal(command: String, folder: Option<String>) -> Res<()> {
    let folder = folder.filter(|f| !f.is_empty()).map(PathBuf::from).unwrap_or_else(nook_core::agents::home_dir);
    agents::terminal::run(&command, &folder)
}

#[tauri::command]
pub fn agents_terminal_name(host: String) -> String {
    agents::terminal::name(&host)
}

/// Een eigen geluid uit `<Nook-map>/Sounds` (`attention`, `done`, `error`) als data-URL; `None` = het ingebouwde.
#[tauri::command]
pub fn agents_sound(kind: String) -> Option<String> {
    if !matches!(kind.as_str(), "attention" | "done" | "error") {
        return None;
    }
    let folder = nook_core::paths::support_directory().join("Sounds");
    for (ext, mime) in [("wav", "audio/wav"), ("mp3", "audio/mpeg"), ("ogg", "audio/ogg"), ("m4a", "audio/mp4")] {
        let path = folder.join(format!("{kind}.{ext}"));
        if let Ok(bytes) = std::fs::read(&path) {
            if bytes.len() < 4_000_000 {
                return Some(format!("data:{mime};base64,{}", nook_core::agents::history::base64_encode(&bytes)));
            }
        }
    }
    None
}
