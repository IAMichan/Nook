//! Commando's rond het brein: geheugen beheren, lokale modellen kiezen en installeren, mailconcepten versturen,
//! bijlagen lezen, startvragen, en het brein testen en meten.

use base64::Engine;
use nook_core::brain::memory::MemoryItem;
use nook_core::brain::model_download::{self, PullProgress};
use nook_core::brain::profile::{self, Recommendation, Server, ServerModel};
use nook_core::brain::quality::eval;
use nook_core::brain::service::{self, BrainEnv};
use nook_core::brain::sources;
use nook_core::brain::suggestions::{self, Moment};
use nook_core::nooks::MailDraft;
use nook_core::provider::AIProvider;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

use super::chat::{self, Attachment};
use crate::brain::BrainState;
use crate::state::AppState;
use crate::tools;

type Res<T> = Result<T, String>;

fn env(app: &AppHandle) -> BrainEnv {
    let state = app.state::<AppState>();
    let settings = state.settings();
    BrainEnv {
        key: state.key_for(settings.provider),
        memory_gb: crate::brain::memory_gb(),
        country: crate::brain::country(),
        timezone: crate::brain::timezone(),
    }
}

// Geheugen

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryView {
    #[serde(flatten)]
    item: MemoryItem,
    short_id: String,
    /// Hoe zeker Nook nu is, 0…100.
    certainty: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryOverview {
    items: Vec<MemoryView>,
    learned_words: usize,
    /// Kennisgrafen van de MCP-geheugenserver op deze computer: pad en aantal.
    importable: Vec<(String, usize)>,
    /// Geheugen staat bij Privacy op "alleen op dit apparaat".
    local_only_source: bool,
}

#[tauri::command]
pub fn memory_overview(app: AppHandle, brain: State<'_, BrainState>) -> MemoryOverview {
    let now = chrono::Utc::now();
    let mut items: Vec<MemoryView> = brain
        .memory
        .items()
        .into_iter()
        .map(|item| MemoryView { short_id: item.short_id(), certainty: (item.current_strength(now) * 100.0).round() as u32, item })
        .collect();
    items.sort_by_key(|v| std::cmp::Reverse(v.item.updated));
    let home = dirs::home_dir().unwrap_or_default();
    MemoryOverview {
        items,
        learned_words: brain.memory.learned_words(),
        importable: brain.memory.importable(&home).into_iter().map(|(p, n)| (p.to_string_lossy().to_string(), n)).collect(),
        local_only_source: app.state::<AppState>().settings().local_only_sources.contains(sources::MEMORY),
    }
}

#[tauri::command]
pub fn memory_add(app: AppHandle, text: String) -> Res<()> {
    chat::remember_told(&app, &text)
}

#[tauri::command]
pub fn memory_edit(brain: State<'_, BrainState>, id: String, text: String) -> Res<()> {
    brain.memory.edit(&id, &text).map_err(crate::tools::memory_rejected)
}

#[tauri::command]
pub fn memory_delete(brain: State<'_, BrainState>, id: String) {
    brain.memory.delete(&id);
}

#[tauri::command]
pub fn memory_set_pinned(brain: State<'_, BrainState>, id: String, pinned: bool) {
    brain.memory.set_pinned(&id, pinned);
}

#[tauri::command]
pub fn memory_set_local_only(brain: State<'_, BrainState>, id: String, local_only: bool) {
    brain.memory.set_local_only(&id, local_only);
}

#[tauri::command]
pub fn memory_clear(brain: State<'_, BrainState>) {
    brain.memory.clear();
}

#[tauri::command]
pub fn memory_import(brain: State<'_, BrainState>, path: String) -> Res<usize> {
    let home = dirs::home_dir().unwrap_or_default();
    // Alleen een graaf die Nook zelf vond: geen willekeurig bestand.
    if !brain.memory.importable(&home).iter().any(|(p, _)| p.to_string_lossy() == path) {
        return Err("Dit bestand is geen kennisgraaf van de MCP-geheugenserver.".into());
    }
    Ok(brain.memory.import_graph(std::path::Path::new(&path)))
}

// Lokale modellen

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrainAdvice {
    memory_gb: u64,
    recommendations: Vec<Recommendation>,
    servers: Vec<ServerModel>,
    ollama_running: bool,
}

#[tauri::command]
pub async fn brain_advice() -> BrainAdvice {
    let servers = model_download::server_models().await;
    let installed: Vec<String> = servers.iter().filter(|s| s.server == Server::Ollama).map(|s| s.name.clone()).collect();
    let memory_gb = crate::brain::memory_gb();
    let ollama_running = reqwest::Client::new()
        .get(format!("{}/api/version", nook_core::brain::conversations::ollama_base_url()))
        .timeout(std::time::Duration::from_millis(1_500))
        .send()
        .await
        .is_ok_and(|r| r.status().is_success());
    BrainAdvice { memory_gb, recommendations: profile::recommend(memory_gb, &installed, &servers), servers, ollama_running }
}

/// Installeert een model bij Ollama. De voortgang komt als event `model-pull`.
#[tauri::command]
pub async fn pull_model(app: AppHandle, model: String) -> Res<()> {
    let brain = app.state::<BrainState>();
    if !brain.pulling.lock().unwrap_or_else(|e| e.into_inner()).insert(model.clone()) {
        return Err(format!("{model} wordt al gedownload."));
    }
    let emitter = app.clone();
    let result = model_download::pull(&model, &move |progress: PullProgress| {
        let _ = emitter.emit("model-pull", progress);
    })
    .await;
    brain.pulling.lock().unwrap_or_else(|e| e.into_inner()).remove(&model);
    result.map_err(|e| e.0)
}

/// Maakt een lokaal model het brein: Ollama of LM Studio, met dit model.
#[tauri::command]
pub fn use_local_model(app: AppHandle, state: State<'_, AppState>, server: String, model: String) -> nook_core::settings::Settings {
    let provider = if server == "lmstudio" { AIProvider::Lmstudio } else { AIProvider::Ollama };
    let saved = state.update_settings(|s| {
        s.provider = provider;
        s.set_provider_model(&model);
    });
    let _ = app.emit("settings-changed", &saved);
    saved
}

#[tauri::command]
pub async fn brain_test(app: AppHandle) -> Res<String> {
    let settings = app.state::<AppState>().settings();
    service::test(&settings, &env(&app)).await.map_err(|e| e.0)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalResult {
    id: String,
    question: String,
    answer: String,
    passed: bool,
    missing: Vec<String>,
    forbidden: Vec<String>,
}

/// Meet dit brein: twintig vragen met bekende antwoorden, met de documenten die Nook gevonden zou hebben.
#[tauri::command]
pub async fn brain_eval(app: AppHandle) -> Vec<EvalResult> {
    let settings = app.state::<AppState>().settings();
    let env = env(&app);
    let mut results = vec![];
    for (index, case) in eval::CASES.iter().enumerate() {
        let request = service::BrainRequest { text: case.question.into(), context: eval::context(case), ..Default::default() };
        let answer = match service::run(&settings, &env, request, None).await {
            Ok(plan) => plan.text,
            Err(e) => format!("Fout: {e}"),
        };
        let verdict = eval::judge(&answer, case);
        let _ = app.emit("brain-eval", (index + 1, eval::CASES.len()));
        results.push(EvalResult {
            id: case.id.into(),
            question: case.question.into(),
            answer,
            passed: verdict.passed,
            missing: verdict.missing,
            forbidden: verdict.forbidden,
        });
    }
    results
}

// Mail

fn find_draft(app: &AppHandle, nook_id: &str, draft_id: &str) -> Option<(String, MailDraft)> {
    app.state::<AppState>().with_chat(|c| {
        c.get(nook_id)?.messages.iter().find_map(|m| m.mails.iter().find(|d| d.id == draft_id).map(|d| (m.id.clone(), d.clone())))
    })
}

fn set_draft(app: &AppHandle, nook_id: &str, message_id: &str, draft: MailDraft) {
    chat::update(app, nook_id, message_id, |m| {
        if let Some(existing) = m.mails.iter_mut().find(|d| d.id == draft.id) {
            *existing = draft;
        }
    });
    app.state::<AppState>().save_chat();
}

/// Bewaart wat de gebruiker in het concept veranderde.
#[tauri::command]
pub fn mail_update(app: AppHandle, nook_id: String, draft: MailDraft) -> Res<()> {
    let (message_id, current) = find_draft(&app, &nook_id, &draft.id).ok_or("Dit concept bestaat niet meer.")?;
    if current.state == "sent" {
        return Err("Deze mail is al verstuurd.".into());
    }
    set_draft(&app, &nook_id, &message_id, MailDraft { state: "draft".into(), error: String::new(), ..draft });
    Ok(())
}

/// Versturen (de klik van de gebruiker): het concept gaat naar het mailprogramma, klaar om te verzenden.
#[tauri::command]
pub fn mail_send(app: AppHandle, nook_id: String, draft: MailDraft) -> Res<()> {
    let (message_id, _) = find_draft(&app, &nook_id, &draft.id).ok_or("Dit concept bestaat niet meer.")?;
    match tools::send_mail(&app, &draft) {
        Ok(()) => {
            app.state::<AppState>().store.audit("send_mail", &format!("{} · {}", draft.to, draft.subject), "naar het mailprogramma");
            set_draft(&app, &nook_id, &message_id, MailDraft { state: "sent".into(), error: String::new(), ..draft });
            Ok(())
        }
        Err(error) => {
            set_draft(&app, &nook_id, &message_id, MailDraft { state: "failed".into(), error: error.clone(), ..draft });
            Err(error)
        }
    }
}

#[tauri::command]
pub fn mail_open(app: AppHandle, nook_id: String, draft: MailDraft) -> Res<()> {
    let (message_id, _) = find_draft(&app, &nook_id, &draft.id).ok_or("Dit concept bestaat niet meer.")?;
    tools::open_mail(&app, &draft)?;
    set_draft(&app, &nook_id, &message_id, MailDraft { state: "opened".into(), error: String::new(), ..draft });
    Ok(())
}

// Bijlagen, bronkiezer, startvragen

/// Leest de tekst uit een bestand dat op de chat gesleept is.
#[tauri::command]
pub async fn read_attachment(name: String, base64: String) -> Res<Attachment> {
    tauri::async_runtime::spawn_blocking(move || {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(base64.as_bytes())
            .map_err(|_| "Dit bestand kon Nook niet lezen.".to_string())?;
        let text = nook_core::attachments::read_text(&name, &bytes).map_err(|e| e.0)?;
        Ok(Attachment { name, text })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceChoice {
    id: String,
    title: String,
    /// Mag nu niet: alleen op dit apparaat terwijl een externe AI antwoordt.
    private: bool,
}

/// De bronnen voor de bronkiezer naast het invoerveld: alles waar Nook nu tools voor heeft.
#[tauri::command]
pub fn source_choices(app: AppHandle) -> Vec<SourceChoice> {
    let ctx = tools::ToolCtx::new(&app, "");
    let private = ctx.settings.private_sources();
    let mut ids: Vec<String> = tools::all_tools(&ctx).into_iter().filter_map(|t| t.source).collect();
    ids.push(sources::SCREEN.into());
    let order = sources::order();
    ids.sort_by_key(|id| (sources::rank(id, &order), id.clone()));
    ids.dedup();
    ids.into_iter().map(|id| SourceChoice { title: sources::title(&id), private: private.contains(&id), id }).collect()
}

#[tauri::command]
pub fn set_scope(app: AppHandle, state: State<'_, AppState>, nook_id: String, scope: Option<sources::SourceScope>) -> String {
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(&nook_id) {
            conv.scope = scope.clone().filter(|s| s.is_restricted());
        }
    });
    state.save_chat();
    chat::updated(&app, &nook_id);
    scope.map(|s| s.label()).unwrap_or_else(|| "Automatisch".into())
}

/// Startvragen die bij het moment passen.
#[tauri::command]
pub fn start_suggestions(app: AppHandle) -> Vec<String> {
    use chrono::{Datelike, Timelike};
    let now = chrono::Local::now();
    let state = app.state::<AppState>();
    let ctx = tools::ToolCtx::new(&app, "");
    let mut active: Vec<String> = tools::active(&tools::tools(&ctx)).into_iter().collect();
    active.sort();
    let moment = Moment {
        hour: now.hour(),
        weekday: now.weekday().number_from_monday(),
        loops: state.store.open_loops().into_iter().map(|l| l.title).collect(),
        active_sources: active,
        ..Default::default()
    };
    suggestions::start(&moment)
}

#[tauri::command]
pub fn retry_last(app: AppHandle, nook_id: String) -> Res<Option<String>> {
    chat::retry_last(&app, &nook_id)
}

#[tauri::command]
pub fn plan_edit(app: AppHandle, nook_id: String, message_id: String, index: usize, key: String, value: String) -> Res<Vec<String>> {
    super::plans::edit_action(&app, &nook_id, &message_id, index, &key, &value)
}

#[tauri::command]
pub fn plan_include(app: AppHandle, nook_id: String, message_id: String, index: usize, included: bool) {
    super::plans::set_included(&app, &nook_id, &message_id, index, included);
}

#[tauri::command]
pub async fn plan_run_again(app: AppHandle, nook_id: String, message_id: String, index: usize) -> Res<()> {
    let included = app
        .state::<AppState>()
        .with_chat(|c| {
            c.get(&nook_id).and_then(|conv| conv.messages.iter().find(|m| m.id == message_id)).map(|m| m.action_included.clone())
        })
        .unwrap_or_default();
    // Een stap die als dubbel gemarkeerd is, opnieuw: alleen met deze klik.
    app.state::<AppState>().with_chat(|c| {
        if let Some(m) = c.get_mut(&nook_id).and_then(|conv| conv.messages.iter_mut().find(|m| m.id == message_id)) {
            m.plan_state = Some(nook_core::nooks::PlanState::Pending);
        }
    });
    super::plans::run_plan(&app, &nook_id, &message_id, &included, None, &[index]).await
}
