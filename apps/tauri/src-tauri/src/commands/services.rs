//! De commando's van de platformdiensten: muziek, stem, Flow, de Notetaker, meekijken en meedenken, Vandaag, het
//! weekoverzicht, geluiden en het schermdeel.

use base64::Engine as _;
use chrono::{Datelike, Local};
use nook_core::platform::{MediaCommand, NowPlaying};
use nook_core::services::flow::{self, FlowSettings};
use nook_core::services::notes::{Note, NoteStatus};
use nook_core::services::prefs::ServicePrefs;
use nook_core::services::recap::{self, WeekSummary};
use nook_core::services::sounds::{self, NookSound};
use nook_core::services::think_along::Nudge;
use serde::Serialize;
use tauri::{AppHandle, Manager, State};

use crate::services::{self, notes, think, voice, Services};

type Res<T> = Result<T, String>;

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Res<T> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| e.to_string())
}

// Instellingen

#[tauri::command]
pub fn services_prefs(services: State<'_, Services>) -> ServicePrefs {
    services.prefs()
}

#[tauri::command]
pub fn save_services_prefs(app: AppHandle, services: State<'_, Services>, prefs: ServicePrefs) -> ServicePrefs {
    let before = services.prefs();
    let saved = services.update_prefs(|p| *p = prefs);
    #[cfg(desktop)]
    if before.screen_part_shortcut != saved.screen_part_shortcut || before.notes_shortcut != saved.notes_shortcut {
        crate::platform::desktop::register_shortcuts(&app);
    }
    #[cfg(not(desktop))]
    let _ = (app, before);
    saved
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceInfo {
    /// whisper.cpp op het PATH (de naam van het programma), als het er is.
    whisper: Option<String>,
    /// Of er een OpenAI- en Groq-sleutel is.
    openai_key: bool,
    groq_key: bool,
    speech_engine_ready: Option<String>,
}

#[tauri::command]
pub fn voice_info(app: AppHandle) -> VoiceInfo {
    let state = app.state::<crate::state::AppState>();
    VoiceInfo {
        whisper: voice::whisper_binary().map(String::from),
        openai_key: state.key_for(nook_core::provider::AIProvider::Openai).is_some(),
        groq_key: state.key_for(nook_core::provider::AIProvider::Groq).is_some(),
        speech_engine_ready: voice::engine_ready(&app, true).err(),
    }
}

// Muziek

#[tauri::command]
pub async fn now_playing(app: AppHandle) -> Res<Option<NowPlaying>> {
    blocking(move || app.state::<Services>().platform.media.now_playing()).await
}

#[tauri::command]
pub async fn media_command(app: AppHandle, action: String) -> Res<()> {
    let command = match action.as_str() {
        "next" => MediaCommand::Next,
        "previous" => MediaCommand::Previous,
        _ => MediaCommand::PlayPause,
    };
    let handle = app.clone();
    blocking(move || handle.state::<Services>().platform.media.send(command)).await??;
    services::media::refresh_soon(&app);
    Ok(())
}

#[tauri::command]
pub async fn media_seek(app: AppHandle, seconds: f64) -> Res<()> {
    let handle = app.clone();
    blocking(move || handle.state::<Services>().platform.media.seek(seconds)).await??;
    services::media::refresh_soon(&app);
    Ok(())
}

#[tauri::command]
pub async fn media_shuffle(app: AppHandle, on: bool) -> Res<()> {
    let handle = app.clone();
    blocking(move || handle.state::<Services>().platform.media.set_shuffle(on)).await??;
    services::media::refresh_soon(&app);
    Ok(())
}

#[tauri::command]
pub async fn media_repeat(app: AppHandle, on: bool) -> Res<()> {
    let handle = app.clone();
    blocking(move || handle.state::<Services>().platform.media.set_repeat(on)).await??;
    services::media::refresh_soon(&app);
    Ok(())
}

#[tauri::command]
pub async fn media_volume(app: AppHandle, percent: u8) -> Res<()> {
    blocking(move || app.state::<Services>().platform.media.set_player_volume(percent)).await?
}

// Stem

#[tauri::command]
pub fn voice_start(app: AppHandle) -> Res<()> {
    voice::start(&app, voice::Purpose::Talk)
}

#[tauri::command]
pub fn voice_finish(app: AppHandle) {
    voice::request_finish(&app);
}

#[tauri::command]
pub fn voice_cancel(app: AppHandle) {
    voice::cancel(&app);
}

/// Het antwoord op een gesproken vraag wordt voorgelezen (als dat aanstaat).
#[tauri::command]
pub fn voice_follow(app: AppHandle, nook_id: String, message_id: String) {
    services::speech::follow(&app, &nook_id, &message_id);
}

#[tauri::command]
pub fn speak_text(services: State<'_, Services>, app: AppHandle, text: String) -> Res<()> {
    let settings = app.state::<crate::state::AppState>().settings();
    let plain = nook_core::services::spoken::plain(&text);
    services.platform.speech.speak(&plain, nook_core::services::spoken::voice_language(&settings.language, &plain))
}

#[tauri::command]
pub fn speak_stop(services: State<'_, Services>) {
    services.platform.speech.stop();
}

// Flow

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlowView {
    settings: FlowSettings,
    dictionary: String,
    history: Vec<flow::FlowEntry>,
    words: usize,
    words_per_minute: usize,
    minutes_saved: f64,
    streak: usize,
}

#[tauri::command]
pub fn flow_view(services: State<'_, Services>) -> FlowView {
    let store = services.flow.lock().unwrap_or_else(|e| e.into_inner());
    let (words, seconds) = (store.stats.total_words(), store.stats.total_seconds());
    FlowView {
        settings: store.settings.clone(),
        dictionary: store.dictionary_text(),
        history: store.history.iter().take(8).cloned().collect(),
        words,
        words_per_minute: flow::words_per_minute(words, seconds),
        minutes_saved: flow::minutes_saved(words, seconds),
        streak: store.stats.streak(Local::now().date_naive()),
    }
}

#[tauri::command]
pub fn save_flow_settings(app: AppHandle, services: State<'_, Services>, settings: FlowSettings) {
    services.flow.lock().unwrap_or_else(|e| e.into_inner()).set_settings(settings);
    #[cfg(desktop)]
    crate::platform::desktop::register_shortcuts(&app);
    #[cfg(not(desktop))]
    let _ = app;
}

#[tauri::command]
pub fn save_flow_dictionary(services: State<'_, Services>, text: String) {
    services.flow.lock().unwrap_or_else(|e| e.into_inner()).set_dictionary_text(&text);
}

#[tauri::command]
pub fn flow_clear_history(services: State<'_, Services>) {
    services.flow.lock().unwrap_or_else(|e| e.into_inner()).clear_history();
}

#[tauri::command]
pub fn flow_cancel(app: AppHandle) {
    services::flow::cancel(&app);
}

#[tauri::command]
pub fn flow_hands_free(app: AppHandle) {
    services::flow::start_hands_free(&app);
}

// Notetaker

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteSummary {
    id: String,
    title: String,
    start: chrono::DateTime<chrono::Utc>,
    minutes: i64,
    status: NoteStatus,
    summary: Option<String>,
    todos: usize,
    error: Option<String>,
}

fn summary(note: &Note) -> NoteSummary {
    NoteSummary {
        id: note.id.clone(),
        title: note.title.clone(),
        start: note.start,
        minutes: ((note.duration() / 60.0).round() as i64).max(1),
        status: note.status,
        summary: note.summary.clone(),
        todos: note.todos.len(),
        error: note.error.clone(),
    }
}

#[tauri::command]
pub fn notes_list(services: State<'_, Services>) -> Vec<NoteSummary> {
    services.notes.lock().unwrap_or_else(|e| e.into_inner()).notes.iter().take(30).map(summary).collect()
}

#[tauri::command]
pub fn note_markdown(services: State<'_, Services>, id: String) -> Option<String> {
    services.notes.lock().unwrap_or_else(|e| e.into_inner()).get(&id).map(nook_core::services::notes::markdown)
}

#[tauri::command]
pub fn note_delete(services: State<'_, Services>, id: String) {
    services.notes.lock().unwrap_or_else(|e| e.into_inner()).delete(&id);
}

#[tauri::command]
pub fn note_toggle(app: AppHandle) {
    notes::toggle(&app);
}

#[tauri::command]
pub fn note_live(app: AppHandle) -> notes::NoteLive {
    notes::live(&app)
}

// Meekijken en meedenken

#[tauri::command]
pub async fn look_along(app: AppHandle) -> Res<()> {
    think::look_along(&app).await
}

#[tauri::command]
pub fn nudge_current(services: State<'_, Services>) -> Option<Nudge> {
    services.nudge.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

#[tauri::command]
pub async fn nudge_answer(app: AppHandle, id: String, answer: String) -> Res<()> {
    think::answer(&app, &id, &answer).await
}

#[tauri::command]
pub fn aside_expand(app: AppHandle, large: bool) {
    #[cfg(desktop)]
    services::windows::place_aside(&app, large);
    #[cfg(not(desktop))]
    let _ = (app, large);
}

/// Het aanbod weer naast de balk, als er nog een openstaat (na het sluiten van de balk).
#[tauri::command]
pub fn aside_show(app: AppHandle, services: State<'_, Services>) {
    let pending =
        services.nudge.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|n| n.still_fresh(chrono::Utc::now().timestamp()));
    #[cfg(desktop)]
    if pending {
        services::windows::show_aside(&app);
    }
    #[cfg(not(desktop))]
    let _ = (app, pending);
}

#[tauri::command]
pub fn aside_hide(app: AppHandle) {
    #[cfg(desktop)]
    services::windows::hide_aside(&app);
    #[cfg(not(desktop))]
    let _ = app;
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenStatus {
    available: bool,
    status: String,
    windows: Vec<String>,
    displays: usize,
}

#[tauri::command]
pub fn screen_status(app: AppHandle, services: State<'_, Services>) -> ScreenStatus {
    let live = services::screen::cached(&app).map(|(l, _)| l);
    ScreenStatus {
        available: services.platform.screen.available(),
        status: services.platform.screen.status(),
        windows: live.as_ref().map(|l| l.windows.clone()).unwrap_or_default(),
        displays: live.map(|l| l.displays).unwrap_or(0),
    }
}

// Energy, meetings and screen sharing

/// The energy plan and the status line for Settings › General › Energy.
#[tauri::command]
pub fn energy_status(app: AppHandle) -> services::energy::EnergyView {
    services::energy::view(&app)
}

/// What Nook notices about meetings and screen sharing right now. `watching`: Settings shows the line, so the situation
/// is read even when both choices are "change nothing".
#[tauri::command]
pub async fn quiet_status(app: AppHandle, watching: bool) -> Res<services::quiet::QuietView> {
    blocking(move || services::quiet::view(&app, watching)).await
}

// Schermdeel

#[tauri::command]
pub fn screen_part_begin(app: AppHandle) {
    services::part::begin(&app);
}

#[tauri::command]
pub fn screen_part_image(app: AppHandle) -> Option<String> {
    services::part::image(&app)
}

#[tauri::command]
pub fn screen_part_finish(app: AppHandle, x: f64, y: f64, w: f64, h: f64, copy: bool) -> Res<()> {
    services::part::finish(&app, x, y, w, h, copy)
}

#[tauri::command]
pub fn screen_part_cancel(app: AppHandle) {
    services::part::cancel(&app);
}

// Vandaag en weekoverzicht

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TodayItem {
    id: String,
    /// "nudge", "recording", "note", "recap".
    kind: String,
    title: String,
    subtitle: String,
    action: String,
}

#[tauri::command]
pub fn today_items(app: AppHandle, services: State<'_, Services>) -> Vec<TodayItem> {
    let mut items = Vec::new();
    let now = chrono::Utc::now();
    if let Some(nudge) = services.nudge.lock().unwrap_or_else(|e| e.into_inner()).as_ref().filter(|n| n.still_fresh(now.timestamp())) {
        let at = chrono::DateTime::from_timestamp(nudge.date, 0)
            .map(|d| d.with_timezone(&Local).format("%H:%M").to_string())
            .unwrap_or_default();
        items.push(TodayItem {
            id: nudge.id.clone(),
            kind: "nudge".into(),
            title: nudge.line.clone(),
            subtitle: format!("Meegedacht in {} om {at}", nudge.app),
            action: "Bekijk".into(),
        });
    }
    let live = notes::live(&app);
    if live.recording {
        items.push(TodayItem {
            id: "recording".into(),
            kind: "recording".into(),
            title: "Gesprek wordt genoteerd".into(),
            subtitle: format!("{} min · {} regels", (live.seconds / 60.0) as i64, live.lines),
            action: "Stop".into(),
        });
    }
    {
        let store = services.notes.lock().unwrap_or_else(|e| e.into_inner());
        for note in store.notes.iter().filter(|n| (now - n.start).num_hours() < 12).take(2) {
            let subtitle = match note.status {
                NoteStatus::Processing | NoteStatus::Recording => "Notities worden geschreven…".to_string(),
                NoteStatus::Failed => note.error.clone().unwrap_or_else(|| "Mislukt".into()),
                NoteStatus::Ready => format!("{} to-do's · {}", note.todos.len(), note.start.with_timezone(&Local).format("%H:%M")),
            };
            items.push(TodayItem {
                id: note.id.clone(),
                kind: "note".into(),
                title: note.title.clone(),
                subtitle,
                action: "Bekijk".into(),
            });
        }
    }
    let today = Local::now().date_naive();
    if today.weekday() == chrono::Weekday::Mon {
        let store = services.recap.lock().unwrap_or_else(|e| e.into_inner());
        let last = store.summary(today - chrono::Duration::days(7));
        if !last.is_empty() && services.prefs().recap_seen != today.to_string() {
            items.push(TodayItem {
                id: "recap".into(),
                kind: "recap".into(),
                title: "Je week met je agents".into(),
                subtitle: format!("{} gewerkt in {} sessies", recap::duration(last.active_seconds), last.sessions),
                action: "Bekijk".into(),
            });
        }
    }
    items
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecapView {
    label: String,
    summary: WeekSummary,
    duration: String,
    busiest: Option<String>,
}

#[tauri::command]
pub fn recap_view(services: State<'_, Services>) -> RecapView {
    let today = Local::now().date_naive();
    let (summary, label) = recap::recap_week(&services.recap.lock().unwrap_or_else(|e| e.into_inner()), today);
    services.update_prefs(|p| p.recap_seen = today.to_string());
    const DAYS: [&str; 7] = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"];
    RecapView {
        label: format!("{label} (sinds {})", summary.start.format("%-d-%-m")),
        duration: recap::duration(summary.active_seconds),
        busiest: summary
            .busiest_day
            .map(|d| format!("{} · {}", DAYS[d.weekday().num_days_from_monday() as usize], recap::duration(summary.busiest_seconds))),
        summary,
    }
}

// Geluiden

/// Het eigen geluid als data-URL, of niets (dan speelt de interface het ingebouwde).
#[tauri::command]
pub fn sound_file(name: String) -> Option<String> {
    let path = NookSound::parse(&name)?.custom_file()?;
    let bytes = std::fs::read(&path).ok().filter(|b| b.len() < 3_000_000)?;
    Some(format!("data:{};base64,{}", sounds::mime(&path), base64::engine::general_purpose::STANDARD.encode(bytes)))
}

#[tauri::command]
pub fn open_sounds_folder(app: AppHandle) -> Res<String> {
    use tauri_plugin_opener::OpenerExt;
    let folder = sounds::folder();
    std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
    app.opener().open_path(folder.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())?;
    Ok(folder.display().to_string())
}
