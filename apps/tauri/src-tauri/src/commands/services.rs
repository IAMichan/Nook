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

/// Settings › Privacy › Screen text: forgets every window's text Nook read, so nothing it saw goes along with a
/// question until it reads the screen again (`forgetScreenText` on the Mac).
#[tauri::command]
pub fn screen_forget(services: State<'_, Services>) {
    *services.live.lock().unwrap_or_else(|e| e.into_inner()) = nook_core::services::screen::LiveScreen::default();
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

/// The sound to play as a data URL, or nothing (then the interface plays its built-in tone). `choice` is the moment's
/// stored choice: "" or "file" is your own file in the Sounds folder, anything else a system sound by name.
#[tauri::command]
pub fn sound_file(name: String, choice: Option<String>) -> Option<String> {
    let sound = NookSound::parse(&name)?;
    let path = match choice.as_deref().unwrap_or("") {
        "" | "file" => sound.custom_file()?,
        "none" => return None,
        system => sounds::system_file_in(&sounds::system_folder()?, system)?,
    };
    let bytes = std::fs::read(&path).ok().filter(|b| b.len() < 3_000_000)?;
    Some(format!("data:{};base64,{}", sounds::mime(&path), base64::engine::general_purpose::STANDARD.encode(bytes)))
}

/// The system's sounds a moment can play (Windows' Media folder), and which moments have a file of your own.
#[tauri::command]
pub fn system_sounds() -> SoundChoicesView {
    SoundChoicesView {
        system: sounds::system_sounds(),
        custom: ["attention", "permission", "done", "error"].into_iter().filter(|n| NookSound::parse(n).and_then(|s| s.custom_file()).is_some()).map(String::from).collect(),
    }
}

#[derive(serde::Serialize)]
pub struct SoundChoicesView {
    system: Vec<String>,
    custom: Vec<String>,
}

#[tauri::command]
pub fn open_sounds_folder(app: AppHandle) -> Res<String> {
    use tauri_plugin_opener::OpenerExt;
    let folder = sounds::folder();
    std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
    app.opener().open_path(folder.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())?;
    Ok(folder.display().to_string())
}

// OpenTelemetry export (`TelemetrySettingsSection` on the Mac)

/// Gives Nook's own export (`nook_telemetry`) the configuration in effect: Settings with `OTEL_EXPORTER_OTLP_*` from
/// Nook's environment on top. The keychain is read only when there is an endpoint to send its headers to.
pub fn reload_telemetry(app: &AppHandle) {
    use nook_core::services::telemetry::{OtlpConfig, HEADERS_SECRET_ACCOUNT};
    let state = app.state::<crate::state::AppState>();
    let settings = state.settings().telemetry;
    let mut config = OtlpConfig::resolve_process(&settings, "");
    if !config.is_empty() {
        let headers = state.secrets.read(HEADERS_SECRET_ACCOUNT).unwrap_or_default();
        config = OtlpConfig::resolve_process(&settings, &headers);
    }
    let runtime = tauri::async_runtime::handle().inner().clone();
    nook_core::services::nook_telemetry::shared().reload(config, Some(runtime), &app.package_info().version.to_string());
}

/// At launch: read the export settings, then record the launch (a span from the process's start until now).
pub fn telemetry_launched(app: &AppHandle) {
    use nook_core::services::nook_telemetry;
    reload_telemetry(app);
    if let Some(started) = nook_telemetry::process_start() {
        nook_telemetry::shared().app_launched(started, chrono::Utc::now());
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetrySignalStatus {
    signal: nook_core::services::telemetry::OtlpSignal,
    endpoint: Option<String>,
    env_variable: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryStatusView {
    signals: Vec<TelemetrySignalStatus>,
    protocol: nook_core::services::telemetry::OtlpProtocol,
    protocol_env: Option<String>,
    headers_env: Option<String>,
    headers_count: usize,
    has_saved_headers: bool,
    sdk_disabled: bool,
}

/// Effective OTLP configuration (Settings merged with `OTEL_EXPORTER_OTLP_*` environment variables) and whether
/// headers are saved in the system keychain, without ever returning the raw header secrets to the UI.
#[tauri::command]
pub fn telemetry_status(app: AppHandle) -> TelemetryStatusView {
    use nook_core::services::telemetry::{OtlpConfig, OtlpSignal, OtlpSource, HEADERS_SECRET_ACCOUNT};
    // Settings › Maintenance asks for this after every change it saves: Nook's own export follows at once.
    reload_telemetry(&app);
    let state = app.state::<crate::state::AppState>();
    let settings = state.settings().telemetry;
    let saved_headers = state.secrets.read(HEADERS_SECRET_ACCOUNT).unwrap_or_default();
    let has_saved_headers = !saved_headers.trim().is_empty();
    let cfg = OtlpConfig::resolve_process(&settings, &saved_headers);
    let env_name = |src: Option<&OtlpSource>| match src {
        Some(OtlpSource::Environment(var)) => Some(var.clone()),
        _ => None,
    };
    let signals = OtlpSignal::ALL
        .into_iter()
        .map(|signal| TelemetrySignalStatus {
            signal,
            endpoint: cfg.endpoint(signal).map(String::from),
            env_variable: env_name(cfg.endpoint_sources.get(&signal)),
        })
        .collect();
    TelemetryStatusView {
        signals,
        protocol: cfg.protocol,
        protocol_env: env_name(Some(&cfg.protocol_source)),
        headers_env: env_name(Some(&cfg.headers_source)),
        headers_count: cfg.headers.len(),
        has_saved_headers,
        sdk_disabled: cfg.sdk_disabled,
    }
}

/// Saves OTLP headers (`key=value,key2=value2`) in the system keychain; empty string removes them.
#[tauri::command]
pub fn telemetry_save_headers(app: AppHandle, headers: String) -> Res<bool> {
    use nook_core::services::telemetry::{OtlpHeader, HEADERS_SECRET_ACCOUNT};
    let state = app.state::<crate::state::AppState>();
    let trimmed = headers.trim();
    if trimmed.is_empty() {
        state.secrets.remove(HEADERS_SECRET_ACCOUNT)?;
        reload_telemetry(&app);
        return Ok(false);
    }
    if OtlpHeader::parse(trimmed).is_empty() {
        return Err(nook_core::i18n::tr(
            "Schrijf de headers als sleutel=waarde, gescheiden door komma's.",
            "Write the headers as key=value, separated by commas.",
        )
        .into());
    }
    state.secrets.write(HEADERS_SECRET_ACCOUNT, trimmed)?;
    reload_telemetry(&app);
    Ok(true)
}

/// Sends an empty OTLP/HTTP JSON export to test connectivity for one signal (`traces`, `metrics`, or `logs`).
/// Saved keychain headers are only attached when `url` matches the effective configured endpoint (matching macOS).
#[tauri::command]
pub async fn telemetry_test(
    app: AppHandle,
    signal: nook_core::services::telemetry::OtlpSignal,
    url: Option<String>,
) -> Res<nook_core::services::telemetry::OtlpTestResult> {
    use nook_core::services::telemetry::{validate_http_url, OtlpConfig, OtlpExporter, OtlpSource, HEADERS_SECRET_ACCOUNT};
    let state = app.state::<crate::state::AppState>();
    let settings = state.settings().telemetry;
    let saved_headers = state.secrets.read(HEADERS_SECRET_ACCOUNT).unwrap_or_default();
    let cfg = OtlpConfig::resolve_process(&settings, &saved_headers);

    let env_endpoint = matches!(cfg.endpoint_sources.get(&signal), Some(OtlpSource::Environment(_)))
        .then(|| cfg.endpoint(signal).map(String::from))
        .flatten();
    let target = match env_endpoint {
        Some(u) => u,
        None => {
            let candidate = url.unwrap_or_else(|| settings.endpoint_for(signal).to_string());
            validate_http_url(&candidate).ok_or_else(|| {
                nook_core::i18n::tr("Vul een http- of https-adres in.", "Enter an http or https address.").to_string()
            })?
        }
    };
    let configured_match = cfg.endpoint(signal).is_some_and(|e| e == target)
        || validate_http_url(settings.endpoint_for(signal)).is_some_and(|e| e == target);
    let headers = if configured_match { cfg.headers } else { Vec::new() };
    Ok(OtlpExporter::new().test_connection(signal, &target, &headers).await)
}

// 1Password `op://` secret provider (`SecretProvidersSection` on the Mac, CH-97)

/// Returns 1Password CLI (`op`) installation status, version, sign-in mode, and optionally updates enabled/token config.
#[tauri::command]
pub async fn secrets_onepassword_status(
    app: AppHandle,
    enabled: Option<bool>,
    service_account_token: Option<String>,
    connect_host: Option<String>,
    connect_token: Option<String>,
) -> Res<nook_core::secrets::OnePasswordStatus> {
    use nook_core::secrets::{
        OnePasswordProvider, OP_CONNECT_HOST_KEY, OP_CONNECT_TOKEN_KEY, OP_ENABLED_KEY,
        OP_SERVICE_ACCOUNT_KEY,
    };
    blocking(move || {
        let state = app.state::<crate::state::AppState>();
        if let Some(en) = enabled {
            let _ = state.secrets.write(OP_ENABLED_KEY, if en { "true" } else { "false" });
        }
        if let Some(tok) = service_account_token {
            let _ = state.secrets.write(OP_SERVICE_ACCOUNT_KEY, &tok);
        }
        if let Some(host) = connect_host {
            let _ = state.secrets.write(OP_CONNECT_HOST_KEY, &host);
        }
        if let Some(tok) = connect_token {
            let _ = state.secrets.write(OP_CONNECT_TOKEN_KEY, &tok);
        }
        let cfg = OnePasswordProvider::config_from_store(&*state.secrets);
        let provider = OnePasswordProvider::new();
        provider.status(&cfg)
    })
    .await
}

/// Resolves an `op://vault/item/field` reference via `op read --no-newline`, or tests sign-in (`op whoami`) when
/// `reference` is empty (`SecretProviderSheet.test` on the Mac, CH-97).
#[tauri::command]
pub async fn secrets_onepassword_resolve(
    app: AppHandle,
    reference: String,
    mask_value: Option<bool>,
) -> Res<String> {
    use nook_core::secrets::{OnePasswordProvider, SecretReference};
    let mask_out = mask_value.unwrap_or(false);
    blocking(move || {
        let state = app.state::<crate::state::AppState>();
        let cfg = OnePasswordProvider::config_from_store(&*state.secrets);
        let provider = OnePasswordProvider::new();
        let trimmed = reference.trim();
        if trimmed.is_empty() {
            return provider.check(&cfg, None).map_err(|e| e.message());
        }
        let parsed = SecretReference::parse(trimmed)
            .ok_or_else(|| nook_core::secrets::OnePasswordFailure::NotReference.message())?;
        let secret = provider.read(&parsed, &cfg).map_err(|e| e.message())?;
        if mask_out {
            Ok(nook_core::secrets::mask(&secret))
        } else {
            Ok(secret)
        }
    })
    .await?
}

// `nook://` deep links (`AppModel+IncomingLinks` on the Mac, CH-100)

/// Parses and routes a `nook://` deep link URL, emitting a `nook-deep-link` event to the frontend window.
#[tauri::command]
pub fn handle_deep_link(
    app: AppHandle,
    url: String,
) -> Res<nook_core::services::deep_link::DeepLinkRoute> {
    use tauri::Emitter;
    let route = nook_core::services::deep_link::DeepLinkRoute::parse(&url)
        .ok_or_else(|| "Invalid or unsupported nook:// link.".to_string())?;
    let _ = app.emit("nook-deep-link", &route);
    Ok(route)
}


