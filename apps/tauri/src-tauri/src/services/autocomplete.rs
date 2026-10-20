//! Autocomplete Anywhere in the app: the controller between the platform's keyboard hook and field reader
//! (`TextInput`), the model (`nook_core::services::autocomplete::engine`) and the ghost-text window. The Mac's
//! `AutocompleteController`, smaller: one suggestion at a time, no writing ahead, no emoji or typo cards.
//!
//! Flow: a key → (debounce) read the focused field → the suggestion on screen still fits (typed through) or the model is
//! asked → the answer becomes a suggestion → ghost text at the caret, accept keys armed. An accept key types the word
//! with `SendInput` and reads the field again to move the ghost along.
//!
//! Privacy: typed text and field contents live only in memory for the current suggestion and are never logged or
//! written to disk; only counts go to `autocomplete/stats.json`. Typed text goes to the local server unless the user
//! chose the external brain in Settings › Autocomplete.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nook_core::brain::memory::MemoryItem;
use nook_core::platform::{FieldSkip, FocusedField, InputEvent, ScreenRect, TextInput};
use nook_core::services::autocomplete::emoji::{self, EmojiUsage, Picker, PickerLayout};
use nook_core::services::autocomplete::engine::{self, Engine, EngineOutput, EngineTarget, Plan};
use nook_core::services::autocomplete::prefs::{EscapeAction, KeyChord};
use nook_core::services::autocomplete::prompt::{field_key, CompletionContext, CompletionPrompt, PromptBuilder};
use nook_core::services::autocomplete::session::{ReadOutcome, Session};
use nook_core::services::autocomplete::stats::{self, CompletionStats, SeenApp, StatsSummary};
use nook_core::services::autocomplete::suggestion::{CompletionOptions, CompletionPolicy, CompletionSuggestion};
use nook_core::services::autocomplete::{privacy, AutocompleteSettings};
use nook_core::settings::Settings;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};

use crate::state::AppState;

/// The ghost-text window.
pub const GHOST: &str = "ghost";
/// The context around a field is gathered again after this long, so new messages on screen are seen.
const CONTEXT_SECONDS: u64 = 180;
/// The clipboard only goes into the prompt this long after it changed.
const CLIPBOARD_SECONDS: u64 = 300;
/// After Nook typed, the app may show the text a moment later: read again this often before giving up.
const SETTLE_ATTEMPTS: u32 = 6;
const SETTLE_INTERVAL: Duration = Duration::from_millis(30);

/// What Settings shows as the live status.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// "unsupported", "off", "checking", "ready", "paused", "noModel".
    pub state: String,
    pub detail: String,
    /// "Ollama · qwen3:4b".
    pub engine: String,
    /// Typed text stays on this computer.
    pub local: bool,
}

/// Everything Settings › Autocomplete shows.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub status: Status,
    pub stats: StatsSummary,
    pub seen_apps: Vec<SeenApp>,
    pub off_by_default: Vec<String>,
    pub accept_keys: Vec<String>,
    pub paused: bool,
}

/// What the Playground shows.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaygroundResult {
    pub raw: String,
    pub shown: Option<String>,
    pub milliseconds: u64,
    pub prompt: String,
    pub engine: String,
    pub confidence: bool,
}

struct EngineCache {
    key: String,
    result: Result<Arc<Engine>, String>,
    at: Instant,
}

/// Shared with the commands. The controller itself runs as one task (see [`setup`]).
pub struct Autocomplete {
    tx: UnboundedSender<Msg>,
    status: Mutex<Status>,
    stats: Mutex<CompletionStats>,
    stats_dirty: std::sync::atomic::AtomicBool,
    seen: Mutex<Vec<SeenApp>>,
    engine: Mutex<Option<EngineCache>>,
    paused_until: Mutex<Option<Instant>>,
    playground: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    /// The emoji taken from the picker (emoji and counts only).
    emoji: Mutex<EmojiUsage>,
}

/// One choice in the picker, for the window and the Playground.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EmojiChoice {
    pub emoji: String,
    pub name: String,
}

/// The picker for the Playground: the name typed after the colon and what fits.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EmojiChoices {
    pub query: String,
    pub choices: Vec<EmojiChoice>,
}

/// The emoji picker on screen in another app.
struct OpenPicker {
    picker: Picker,
    caret: ScreenRect,
    app: String,
    layout: PickerLayout,
    scale: f64,
}

enum Msg {
    Input(InputEvent),
    Settings,
    Read { generation: u64, field: Box<Result<FocusedField, FieldSkip>>, continuing: bool, attempt: u32 },
    Answer(Box<Answer>),
}

struct Answer {
    generation: u64,
    before: String,
    after: String,
    field: String,
    app: String,
    caret: ScreenRect,
    max_words: usize,
    output: Result<EngineOutput, String>,
}

impl Autocomplete {
    pub fn status(&self) -> Status {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn set_status(&self, app: &AppHandle, status: Status) {
        let mut current = self.status.lock().unwrap_or_else(|e| e.into_inner());
        if *current != status {
            *current = status.clone();
            let _ = app.emit("autocomplete-status", &status);
        }
    }

    pub fn is_paused(&self) -> bool {
        self.paused_until.lock().unwrap_or_else(|e| e.into_inner()).is_some_and(|until| until > Instant::now())
    }

    pub fn pause(&self, minutes: Option<u64>) {
        let until = Instant::now() + Duration::from_secs(minutes.unwrap_or(60 * 24 * 365) * 60);
        *self.paused_until.lock().unwrap_or_else(|e| e.into_inner()) = Some(until);
        let _ = self.tx.send(Msg::Settings);
    }

    pub fn resume(&self) {
        *self.paused_until.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let _ = self.tx.send(Msg::Settings);
    }

    pub fn view(&self) -> View {
        View {
            status: self.status(),
            stats: self.stats.lock().unwrap_or_else(|e| e.into_inner()).summary(chrono::Local::now().date_naive()),
            seen_apps: self.seen.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            off_by_default: nook_core::services::autocomplete::prefs::OFF_BY_DEFAULT.iter().map(|s| s.to_string()).collect(),
            accept_keys: nook_core::services::autocomplete::prefs::ACCEPT_KEYS.iter().map(|s| s.to_string()).collect(),
            paused: self.is_paused(),
        }
    }

    pub fn reset_stats(&self) {
        let mut stats = self.stats.lock().unwrap_or_else(|e| e.into_inner());
        *stats = CompletionStats::default();
        let _ = stats::save(&*stats, &stats::stats_file());
    }

    fn record(&self, f: impl FnOnce(&mut CompletionStats)) {
        f(&mut self.stats.lock().unwrap_or_else(|e| e.into_inner()));
        self.stats_dirty.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    fn save_stats(&self) {
        if self.stats_dirty.swap(false, std::sync::atomic::Ordering::SeqCst) {
            let stats = self.stats.lock().unwrap_or_else(|e| e.into_inner()).clone();
            if let Err(e) = stats::save(&stats, &stats::stats_file()) {
                log::warn!("Aanvullen: statistiek niet bewaard: {e}");
            }
        }
    }

    fn usage(&self) -> EmojiUsage {
        self.emoji.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn record_emoji(&self, character: &str) {
        let mut usage = self.emoji.lock().unwrap_or_else(|e| e.into_inner());
        usage.record(character);
        let _ = stats::save(&*usage, &stats::emoji_file());
    }

    fn remember_app(&self, id: &str, name: &str) {
        let mut seen = self.seen.lock().unwrap_or_else(|e| e.into_inner());
        if seen.first().is_some_and(|a| a.id == id) {
            return;
        }
        stats::remember_app(&mut seen, id, name, 40);
        let _ = stats::save(&*seen, &stats::apps_file());
    }
}

/// The engine for the current settings, made once and reused; a failure is remembered for a few seconds so a key does
/// not ask the server for its models every time.
pub async fn engine_for(app: &AppHandle) -> Result<Arc<Engine>, String> {
    let state = app.state::<AppState>();
    let settings = state.settings();
    let plan = engine::plan(&settings);
    let key = format!(
        "{plan:?}|{}|{:?}|{}",
        settings.autocomplete.model,
        settings.autocomplete.local_server,
        state.key_for(settings.provider).map(|k| k.len()).unwrap_or(0)
    );
    let shared = app.state::<Autocomplete>();
    if let Some(cache) = shared.engine.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        if cache.key == key && (cache.result.is_ok() || cache.at.elapsed() < Duration::from_secs(15)) {
            return cache.result.clone();
        }
    }
    let result = match plan {
        Plan::Local { server } => match engine::list_local_models(server).await {
            Ok(models) => match engine::choose_model(&settings, server, &models) {
                Some(model) => Ok(Arc::new(Engine::new(EngineTarget::local(server, &model)))),
                None => Err(format!("{} heeft nog geen model. Installeer er een bij Instellingen › Brein.", server.title())),
            },
            Err(_) => Err(format!("{} draait niet. Start het, of installeer een lokaal model bij Instellingen › Brein.", server.title())),
        },
        Plan::Remote { provider, model } => Ok(Arc::new(Engine::new(EngineTarget::remote(provider, &model, state.key_for(provider))))),
        Plan::Unsupported(reason) => Err(reason),
    };
    *shared.engine.lock().unwrap_or_else(|e| e.into_inner()) = Some(EngineCache { key, result: result.clone(), at: Instant::now() });
    result
}

/// The facts from memory for the prompt: the strongest, never habits, local-only ones only for a local model.
fn facts(app: &AppHandle, local: bool) -> Vec<String> {
    let state = app.state::<AppState>();
    let mut items: Vec<MemoryItem> =
        state.store.memories::<MemoryItem>().into_iter().filter(|m| !m.is_habit() && (local || !m.local_only)).collect();
    items.sort_by(|a, b| b.pinned.cmp(&a.pinned).then(b.strength.total_cmp(&a.strength)));
    items.into_iter().take(8).map(|m| privacy::sanitize(&m.text)).collect()
}

/// The ghost text at the caret, or hidden. The window is sized from the caret's height.
fn show_ghost(app: &AppHandle, input: &Arc<dyn TextInput>, caret: Option<ScreenRect>, text: &str) {
    let Some(window) = app.get_webview_window(GHOST) else { return };
    let handle = native_handle(&window);
    match caret {
        Some(caret) if !text.is_empty() => {
            let height = (caret.height * 1.3).max(16.0);
            let width = (text.chars().count() as f64 * caret.height * 0.62 + caret.height).clamp(40.0, 1600.0);
            let rect = ScreenRect { x: caret.x + caret.width, y: caret.y - (height - caret.height) / 2.0, width, height };
            let _ = window.emit("autocomplete-ghost", serde_json::json!({"kind": "text", "text": text, "caretHeight": caret.height}));
            input.place_overlay(handle, Some(rect));
        }
        _ => input.place_overlay(handle, None),
    }
}

#[cfg(target_os = "windows")]
fn native_handle(window: &tauri::WebviewWindow) -> isize {
    window.hwnd().map(|h| h.0 as isize).unwrap_or(0)
}

#[cfg(not(target_os = "windows"))]
fn native_handle(_window: &tauri::WebviewWindow) -> isize {
    0
}

#[cfg(desktop)]
fn create_ghost(app: &AppHandle, input: &Arc<dyn TextInput>) {
    use tauri::{WebviewUrl, WebviewWindowBuilder};
    if app.get_webview_window(GHOST).is_some() {
        return;
    }
    match WebviewWindowBuilder::new(app, GHOST, WebviewUrl::App("index.html#ghost".into()))
        .title("Nook")
        .inner_size(300.0, 24.0)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()
    {
        Ok(window) => {
            let _ = window.set_ignore_cursor_events(true);
            input.prepare_overlay(native_handle(&window));
        }
        Err(e) => log::warn!("Venster voor aanvullen: {e}"),
    }
}

fn choice_list(picker: &Picker, tone: u8) -> Vec<EmojiChoice> {
    picker
        .choices
        .iter()
        .map(|e| EmojiChoice { emoji: emoji::render(e, tone), name: e.shortcodes.first().cloned().unwrap_or_default() })
        .collect()
}

/// The picker card under the caret. Returns where it is (physical pixels), for the hook's click test.
fn show_card(app: &AppHandle, input: &Arc<dyn TextInput>, open: &OpenPicker, tone: u8) -> Option<ScreenRect> {
    let window = app.get_webview_window(GHOST)?;
    let rect = ScreenRect {
        x: open.caret.x,
        y: open.caret.y + open.caret.height + 4.0,
        width: open.layout.width() * open.scale,
        height: open.layout.height() * open.scale,
    };
    let _ = window.emit(
        "autocomplete-ghost",
        serde_json::json!({
            "kind": "picker",
            "choices": choice_list(&open.picker, tone),
            "selected": open.picker.selected,
            "query": open.picker.query,
            "layout": open.layout,
        }),
    );
    input.place_overlay(native_handle(&window), Some(rect));
    Some(rect)
}

fn chord_for(settings: &AutocompleteSettings, name: &str, app: &str) -> Option<KeyChord> {
    let chord = KeyChord::parse(name)?;
    // "Leave Tab to the app": plain Tab is not taken there.
    if settings.app(app).leave_tab && chord.key == nook_core::services::autocomplete::prefs::ChordKey::Tab {
        return None;
    }
    Some(chord)
}

/// The controller's own state, owned by its task.
struct Controller {
    app: AppHandle,
    input: Arc<dyn TextInput>,
    tx: UnboundedSender<Msg>,
    settings: Settings,
    running: bool,
    session: Session,
    generation: u64,
    work: Option<tauri::async_runtime::JoinHandle<()>>,
    caret: Option<ScreenRect>,
    /// After Nook typed: the text the field should show soon.
    expected: Option<String>,
    /// After an emoji replaced `:name`: the text as it was, which the app may still show for a moment.
    replaced: Option<String>,
    context: Option<(String, Instant, CompletionContext)>,
    off_until_switch: Option<String>,
    app_paused: BTreeMap<String, Instant>,
    clipboard: Option<(u64, Instant)>,
    builder: PromptBuilder,
    picker: Option<OpenPicker>,
}

impl Controller {
    fn shared(&self) -> tauri::State<'_, Autocomplete> {
        self.app.state::<Autocomplete>()
    }

    fn handle(&mut self, msg: Msg) {
        match msg {
            Msg::Settings => self.apply_settings(),
            Msg::Input(event) => self.on_input(event),
            Msg::Read { generation, field, continuing, attempt } if generation == self.generation => {
                self.on_read(*field, continuing, attempt)
            }
            Msg::Answer(answer) if answer.generation == self.generation => self.on_answer(*answer),
            _ => {}
        }
    }

    fn apply_settings(&mut self) {
        self.settings = self.app.state::<AppState>().settings();
        self.context = None;
        let wanted = self.settings.autocomplete.enabled && self.input.available();
        if wanted && !self.running {
            let tx = self.tx.clone();
            match self.input.start(Arc::new(move |event| {
                let _ = tx.send(Msg::Input(event));
            })) {
                Ok(()) => self.running = true,
                Err(e) => log::warn!("Aanvullen start niet: {e}"),
            }
        } else if !wanted && self.running {
            self.input.stop();
            self.running = false;
            self.dismiss();
        }
        self.refresh_status();
    }

    fn refresh_status(&self) {
        let shared = self.shared();
        if !self.input.available() {
            shared.set_status(&self.app, Status { state: "unsupported".into(), detail: self.input.status(), ..Default::default() });
            return;
        }
        if !self.settings.autocomplete.enabled {
            shared.set_status(&self.app, Status { state: "off".into(), ..Default::default() });
            return;
        }
        if shared.is_paused() {
            shared.set_status(&self.app, Status { state: "paused".into(), ..Default::default() });
            return;
        }
        shared.set_status(&self.app, Status { state: "checking".into(), ..Default::default() });
        let app = self.app.clone();
        tauri::async_runtime::spawn(async move {
            let status = match engine_for(&app).await {
                Ok(engine) => Status {
                    state: "ready".into(),
                    detail: String::new(),
                    engine: engine.target().label(),
                    local: engine.target().is_local(),
                },
                Err(reason) => Status { state: "noModel".into(), detail: reason, ..Default::default() },
            };
            app.state::<Autocomplete>().set_status(&app, status);
        });
    }

    fn cancel_work(&mut self) {
        self.generation += 1;
        if let Some(work) = self.work.take() {
            work.abort();
        }
    }

    fn dismiss(&mut self) {
        self.picker = None;
        self.input.set_picker(None, false);
        self.input.arm(false);
        self.session.dismiss();
        self.caret = None;
        show_ghost(&self.app, &self.input, None, "");
    }

    fn on_input(&mut self, event: InputEvent) {
        if !self.running {
            return;
        }
        if self.picker.is_some() && self.on_picker_input(event) {
            return;
        }
        match event {
            InputEvent::AcceptWord | InputEvent::AcceptAll => self.accept(event == InputEvent::AcceptAll),
            InputEvent::Escape => {
                self.cancel_work();
                let app = self.session.proposal().map(|p| p.app.clone());
                self.dismiss();
                if let Some(app) = app {
                    match self.settings.autocomplete.escape {
                        EscapeAction::Dismiss => {}
                        EscapeAction::PauseBriefly => {
                            self.app_paused.insert(app, Instant::now() + Duration::from_secs(10));
                        }
                        EscapeAction::OffUntilAppSwitch => self.off_until_switch = Some(app),
                    }
                }
            }
            InputEvent::Click => {
                self.cancel_work();
                self.expected = None;
                self.dismiss();
            }
            // Picker keys after the picker closed are ordinary keys.
            InputEvent::Key
            | InputEvent::PickerLetter(_)
            | InputEvent::PickerBackspace
            | InputEvent::PickerMove { .. }
            | InputEvent::PickerNumber(_)
            | InputEvent::PickerReturn
            | InputEvent::PickerClick { .. } => {
                self.cancel_work();
                self.expected = None;
                self.replaced = None;
                let delay = Duration::from_millis(self.settings.autocomplete.delay_milliseconds.clamp(20, 1000));
                self.schedule_read(delay, false, 0);
            }
        }
    }

    /// A key or click while the emoji picker is open. `false`: the picker closed and the event is handled as usual.
    fn on_picker_input(&mut self, event: InputEvent) -> bool {
        let usage = self.shared().usage();
        let Some(open) = self.picker.as_mut() else { return false };
        let chosen = match event {
            InputEvent::AcceptWord | InputEvent::AcceptAll | InputEvent::PickerReturn => Some(open.picker.selected),
            InputEvent::PickerNumber(n) => match open.picker.numbered(n as usize) {
                Some(index) => Some(index),
                None => return true,
            },
            InputEvent::PickerClick { x, y } => match open.layout.hit(x / open.scale, y / open.scale, open.picker.choices.len()) {
                Some(index) => Some(index),
                None => return true,
            },
            InputEvent::PickerMove { dx, dy } => {
                open.picker.step(dx as i32, dy as i32);
                None
            }
            InputEvent::PickerLetter(c) => {
                let query = format!("{}{c}", open.picker.query);
                if !open.picker.retype(query, &usage) {
                    self.close_picker();
                    return true;
                }
                open.layout = PickerLayout::new(open.picker.choices.len());
                None
            }
            InputEvent::PickerBackspace => {
                let mut query = open.picker.query.clone();
                // Delete right after the colon takes the colon away.
                if query.pop().is_none() || !open.picker.retype(query, &usage) {
                    self.close_picker();
                    return false;
                }
                open.layout = PickerLayout::new(open.picker.choices.len());
                None
            }
            InputEvent::Escape => {
                self.close_picker();
                return true;
            }
            InputEvent::Click | InputEvent::Key => {
                self.close_picker();
                return false;
            }
        };
        match chosen {
            Some(index) => self.take_emoji(index),
            None => self.redraw_picker(),
        }
        true
    }

    fn close_picker(&mut self) {
        self.cancel_work();
        self.dismiss();
    }

    fn redraw_picker(&mut self) {
        let tone = self.settings.autocomplete.skin_tone;
        let Some(open) = self.picker.as_ref() else { return };
        let card = show_card(&self.app, &self.input, open, tone);
        self.input.set_picker(card, open.picker.return_takes());
        let app = open.app.clone();
        self.arm_for(&app);
    }

    /// Replaces `:name` with the emoji, typed as key events.
    fn take_emoji(&mut self, index: usize) {
        let Some(open) = self.picker.take() else { return };
        let Some(chosen) = open.picker.choices.get(index).copied() else { return self.close_picker() };
        let rendered = emoji::render(chosen, self.settings.autocomplete.skin_tone);
        self.close_picker();
        if let Err(e) = self.input.replace_text(open.picker.query.chars().count() + 1, &rendered) {
            log::warn!("Aanvullen: {e}");
            return;
        }
        self.replaced = Some(format!("{}:{}", open.picker.context, open.picker.query));
        let today = chrono::Local::now().date_naive();
        self.shared().record(|s| s.record_accepted(&rendered, true, Some(&open.app), today));
        self.shared().record_emoji(&chosen.character);
        let delay = Duration::from_millis(self.settings.autocomplete.delay_milliseconds.clamp(20, 1000));
        self.schedule_read(delay, false, 0);
    }

    /// Opens the picker when `:` starts a word before the cursor. True when it did.
    fn open_picker(&mut self, field: &FocusedField) -> bool {
        if !self.settings.autocomplete.emoji || field.has_selection {
            return false;
        }
        let (Some(query), Some(caret)) = (emoji::query(&field.before), field.caret) else { return false };
        let keep = field.before.chars().count().saturating_sub(query.chars().count() + 1);
        let context: String = field.before.chars().take(keep).collect();
        let Some(picker) = Picker::open(&query, &context, &self.shared().usage()) else { return false };
        let scale = self.app.get_webview_window(GHOST).and_then(|w| w.scale_factor().ok()).unwrap_or(1.0);
        let layout = PickerLayout::new(picker.choices.len());
        self.picker = Some(OpenPicker { picker, caret, app: field.app_id.clone(), layout, scale });
        self.redraw_picker();
        true
    }

    fn accept(&mut self, all: bool) {
        self.cancel_work();
        let options = self.settings.autocomplete.accept_options();
        let Some(accepted) = self.session.accept(all, options) else {
            self.dismiss();
            return;
        };
        if let Err(e) = self.input.type_text(&accepted.text) {
            log::warn!("Aanvullen: {e}");
            self.dismiss();
            return;
        }
        let today = chrono::Local::now().date_naive();
        self.shared().record(|s| s.record_accepted(&accepted.text, accepted.first, Some(&accepted.app), today));
        // The ghost goes until the app shows the word; the read puts the rest where the caret is then.
        show_ghost(&self.app, &self.input, None, "");
        self.expected = Some(accepted.anchor.clone());
        if accepted.finished {
            self.input.arm(false);
        }
        self.schedule_read(SETTLE_INTERVAL, accepted.finished, 0);
    }

    fn schedule_read(&mut self, delay: Duration, continuing: bool, attempt: u32) {
        let generation = self.generation;
        let input = self.input.clone();
        let tx = self.tx.clone();
        self.work = Some(tauri::async_runtime::spawn(async move {
            tokio::time::sleep(delay).await;
            let field = tauri::async_runtime::spawn_blocking(move || input.focused_field()).await.unwrap_or(Err(FieldSkip::NoField));
            let _ = tx.send(Msg::Read { generation, field: Box::new(field), continuing, attempt });
        }));
    }

    fn eligible(&mut self, field: &FocusedField) -> bool {
        let settings = &self.settings.autocomplete;
        if !settings.enabled || self.shared().is_paused() {
            return false;
        }
        // The energy plan pauses optional work (a hot or overloaded computer); suggestions wait too.
        if super::energy::plan(&self.app).pace == nook_core::services::energy::EnergyPace::Paused {
            return false;
        }
        if self.off_until_switch.as_deref().is_some_and(|app| app != field.app_id) {
            self.off_until_switch = None;
        }
        if self.off_until_switch.as_deref() == Some(field.app_id.as_str()) {
            return false;
        }
        if self.app_paused.get(&field.app_id).is_some_and(|until| *until > Instant::now()) {
            return false;
        }
        settings.is_enabled_in_app(&field.app_id)
    }

    fn on_read(&mut self, field: Result<FocusedField, FieldSkip>, mut continuing: bool, attempt: u32) {
        let Ok(field) = field else {
            self.dismiss();
            return;
        };
        self.shared().remember_app(&field.app_id, &field.app_name);
        if !self.eligible(&field) {
            self.dismiss();
            return;
        }
        // Nook just typed: the app may not show it yet.
        if let Some(replaced) = self.replaced.take() {
            if field.before == replaced && attempt < SETTLE_ATTEMPTS {
                self.replaced = Some(replaced);
                self.schedule_read(SETTLE_INTERVAL, continuing, attempt + 1);
                return;
            }
        }
        if let Some(expected) = self.expected.clone() {
            if field.before != expected && expected.starts_with(&field.before) && attempt < SETTLE_ATTEMPTS {
                self.schedule_read(SETTLE_INTERVAL, continuing, attempt + 1);
                return;
            }
            self.expected = None;
        }
        if self.open_picker(&field) {
            self.session.dismiss();
            return;
        }
        let key = field_key(Some(&field.app_id), None, None, Some(&field.window_title));
        match self.session.on_read(&key, &field.before) {
            ReadOutcome::Kept => {
                self.caret = field.caret;
                let remaining = self.session.proposal().map(|p| p.suggestion.remaining().to_string()).unwrap_or_default();
                if field.caret.is_none() {
                    self.dismiss();
                    return;
                }
                show_ghost(&self.app, &self.input, field.caret, &remaining);
                self.arm_for(&field.app_id);
                return;
            }
            ReadOutcome::Finished => continuing = true,
            ReadOutcome::Dropped | ReadOutcome::None => {}
        }
        self.dismiss();
        self.ask(field, key, continuing);
    }

    fn arm_for(&self, app: &str) {
        let settings = &self.settings.autocomplete;
        self.input.set_keys(chord_for(settings, &settings.accept_word, app), chord_for(settings, &settings.accept_all, app));
        self.input.arm(true);
    }

    /// The context around the text, gathered once per field (see `CONTEXT_SECONDS`).
    fn context(&mut self, field: &FocusedField, key: &str, local: bool) -> CompletionContext {
        if let Some((saved, at, context)) = &self.context {
            if saved == key && at.elapsed() < Duration::from_secs(CONTEXT_SECONDS) {
                return context.clone();
            }
        }
        let settings = &self.settings.autocomplete;
        let mut context = CompletionContext { instructions: settings.instructions_for(Some(&field.app_id), None), ..Default::default() };
        if settings.memory_context && self.settings.use_memory {
            context.facts = facts(&self.app, local);
        }
        if settings.window_context {
            context.app_name = Some(field.app_name.clone());
            context.window_title = Some(privacy::sanitize(&field.window_title));
        }
        if settings.clipboard_context {
            let services = self.app.state::<crate::services::Services>();
            if let Ok(Some(text)) = services.platform.system.clipboard_text() {
                use std::hash::{Hash, Hasher};
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                text.hash(&mut hasher);
                let hash = hasher.finish();
                if self.clipboard.is_none_or(|(h, _)| h != hash) {
                    self.clipboard = Some((hash, Instant::now()));
                }
                if self.clipboard.is_some_and(|(_, at)| at.elapsed() < Duration::from_secs(CLIPBOARD_SECONDS)) {
                    context.clipboard = Some(privacy::sanitize(&text));
                }
            }
        }
        self.context = Some((key.to_string(), Instant::now(), context.clone()));
        context
    }

    fn ask(&mut self, field: FocusedField, key: String, continuing: bool) {
        let settings = self.settings.autocomplete.clone();
        let policy = CompletionPolicy { mid_line: settings.mid_line_in_app(&field.app_id), ..Default::default() };
        let Some(caret) = field.caret else { return };
        if !policy.should_complete(&field.before, &field.after, field.has_selection) {
            return;
        }
        let mut options = CompletionOptions::new(settings.max_words.clamp(1, 30), settings.eagerness);
        if continuing {
            options = options.continuing();
        }
        let generation = self.generation;
        let app = self.app.clone();
        let tx = self.tx.clone();
        // Whether the engine is local decides about local-only memories; the cached engine says so without waiting.
        let local = self
            .shared()
            .engine
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .and_then(|c| c.result.as_ref().ok().map(|e| e.target().is_local()))
            .unwrap_or(false);
        let mut context = self.context(&field, &key, local);
        context.before = field.before.clone();
        let builder = self.builder;
        self.work = Some(tauri::async_runtime::spawn(async move {
            let output = match engine_for(&app).await {
                Ok(engine) => {
                    // An external model never sees what looks like a secret, also not in the typed text.
                    if !engine.target().is_local() {
                        context.before = privacy::sanitize(&context.before);
                    }
                    let prompt: CompletionPrompt = builder.build(&context);
                    engine.complete(&prompt, &options).await.map_err(|e| e.to_string())
                }
                Err(e) => Err(e),
            };
            let answer = Answer {
                generation,
                before: field.before,
                after: field.after,
                field: key,
                app: field.app_id,
                caret,
                max_words: options.max_words,
                output,
            };
            let _ = tx.send(Msg::Answer(Box::new(answer)));
        }));
    }

    fn on_answer(&mut self, answer: Answer) {
        let output = match answer.output {
            Ok(output) => output,
            Err(reason) => {
                // The server stopped or the model went: the status says so; nothing typed is logged.
                self.shared().engine.lock().unwrap_or_else(|e| e.into_inner()).take();
                self.shared().set_status(&self.app, Status { state: "noModel".into(), detail: reason, ..Default::default() });
                return;
            }
        };
        let Some(result) = output.result else { return };
        let Some(suggestion) =
            CompletionSuggestion::make(&result.text, &answer.before, &answer.after, answer.max_words, result.truncated, result.unfinished)
        else {
            return;
        };
        let text = suggestion.remaining().to_string();
        self.session.show(suggestion, &answer.before, &answer.field, &answer.app);
        self.caret = Some(answer.caret);
        show_ghost(&self.app, &self.input, Some(answer.caret), &text);
        self.arm_for(&answer.app);
        let today = chrono::Local::now().date_naive();
        self.shared().record(|s| s.record_shown(today));
    }
}

/// Starts autocomplete: shared state, the controller task, the ghost window. From `services::setup`.
pub fn setup(app: &AppHandle, input: Arc<dyn TextInput>) {
    let (tx, mut rx) = unbounded_channel::<Msg>();
    app.manage(Autocomplete {
        tx: tx.clone(),
        status: Mutex::new(Status::default()),
        stats: Mutex::new(stats::load(&stats::stats_file())),
        stats_dirty: Default::default(),
        seen: Mutex::new(stats::load(&stats::apps_file())),
        engine: Mutex::new(None),
        paused_until: Mutex::new(None),
        playground: Mutex::new(None),
        emoji: Mutex::new(stats::load(&stats::emoji_file())),
    });
    #[cfg(desktop)]
    if input.available() {
        create_ghost(app, &input);
    }
    let mut controller = Controller {
        app: app.clone(),
        input,
        tx: tx.clone(),
        settings: Settings::default(),
        running: false,
        session: Session::default(),
        generation: 0,
        work: None,
        caret: None,
        expected: None,
        replaced: None,
        context: None,
        off_until_switch: None,
        app_paused: BTreeMap::new(),
        clipboard: None,
        builder: PromptBuilder::default(),
        picker: None,
    };
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        controller.apply_settings();
        let mut tick = tokio::time::interval(Duration::from_secs(5));
        loop {
            tokio::select! {
                msg = rx.recv() => match msg {
                    Some(msg) => controller.handle(msg),
                    None => break,
                },
                _ = tick.tick() => handle.state::<Autocomplete>().save_stats(),
            }
        }
    });
    let settings_tx = tx;
    tauri::Listener::listen_any(app, "settings-changed", move |_| {
        let _ = settings_tx.send(Msg::Settings);
    });
}

/// A suggestion for text typed in Settings › Autocomplete › Playground: the same engine, options and personal context as
/// in other apps, without a field, window or clipboard. Nothing is stored or counted. `None` when a newer request came.
pub async fn playground(app: &AppHandle, before: String, continuing: bool) -> Result<Option<PlaygroundResult>, String> {
    let shared = app.state::<Autocomplete>();
    if let Some(previous) = shared.playground.lock().unwrap_or_else(|e| e.into_inner()).take() {
        previous.abort();
    }
    let handle = app.clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let task = tauri::async_runtime::spawn(async move {
        let _ = tx.send(playground_run(&handle, before, continuing).await);
    });
    *shared.playground.lock().unwrap_or_else(|e| e.into_inner()) = Some(task);
    match rx.await {
        Ok(result) => result.map(Some),
        // Cancelled by a newer request.
        Err(_) => Ok(None),
    }
}

pub fn cancel_playground(app: &AppHandle) {
    if let Some(task) = app.state::<Autocomplete>().playground.lock().unwrap_or_else(|e| e.into_inner()).take() {
        task.abort();
    }
}

async fn playground_run(app: &AppHandle, before: String, continuing: bool) -> Result<PlaygroundResult, String> {
    let settings = app.state::<AppState>().settings();
    let engine = engine_for(app).await?;
    let local = engine.target().is_local();
    let ac = &settings.autocomplete;
    let mut context = CompletionContext {
        before: if local { before.clone() } else { privacy::sanitize(&before) },
        instructions: ac.instructions_for(None, None),
        ..Default::default()
    };
    if ac.memory_context && settings.use_memory {
        context.facts = facts(app, local);
    }
    let prompt = PromptBuilder::default().build(&context);
    let mut options = CompletionOptions::new(ac.max_words.clamp(1, 30), ac.eagerness);
    if continuing {
        options = options.continuing();
    }
    let output = engine.complete(&prompt, &options).await.map_err(|e| e.to_string())?;
    let shown = output.result.as_ref().and_then(|r| {
        CompletionSuggestion::make(&r.text, &before, "", options.max_words, r.truncated, r.unfinished).map(|s| s.remaining().to_string())
    });
    Ok(PlaygroundResult {
        raw: output.raw,
        shown,
        milliseconds: output.milliseconds,
        prompt: output.prompt,
        engine: engine.target().label(),
        confidence: output.confidence,
    })
}

/// The emoji picker for text typed in the Playground: `None` when no `:name` is being typed. Nothing is recorded.
pub fn playground_emoji(app: &AppHandle, text: &str) -> Option<EmojiChoices> {
    let settings = app.state::<AppState>().settings();
    if !settings.autocomplete.emoji {
        return None;
    }
    let query = emoji::query(text)?;
    let keep = text.chars().count().saturating_sub(query.chars().count() + 1);
    let context: String = text.chars().take(keep).collect();
    let picker = Picker::open(&query, &context, &app.state::<Autocomplete>().usage())?;
    Some(EmojiChoices { query, choices: choice_list(&picker, settings.autocomplete.skin_tone) })
}

/// The models on the local server autocomplete uses, for the model picker.
pub async fn local_models(app: &AppHandle) -> Result<Vec<String>, String> {
    let settings = app.state::<AppState>().settings();
    let server = engine::local_server(&settings);
    engine::list_local_models(server).await.map(|list| list.into_iter().map(|m| m.name).collect()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leave_tab_drops_only_tab() {
        let mut s = AutocompleteSettings::default();
        s.set_app("slack", nook_core::services::autocomplete::prefs::AppRule { leave_tab: true, ..Default::default() });
        assert!(chord_for(&s, "Tab", "Slack.exe").is_none());
        assert!(chord_for(&s, "Tab", "notepad").is_some());
        assert!(chord_for(&s, "Alt+Right", "slack").is_some());
        assert!(chord_for(&s, "", "notepad").is_none());
    }
}
