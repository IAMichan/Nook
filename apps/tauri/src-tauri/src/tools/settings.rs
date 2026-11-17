//! Nook's own settings from the chat (the Mac's `AppModel+SettingsTools`): "turn web search off", "answer in English",
//! "open the settings of my connections". The brain reads them with `get_settings` and proposes a change with
//! `change_setting`; a change always waits for the user's click, is written to the audit log by the plan runner, and
//! can be undone ("undo that"). Which settings qualify is `nook_core::settings_catalog`.

use nook_core::brain::LoopTool;
use nook_core::i18n::{tr, trf};
use nook_core::settings_catalog::{self as catalog, Entry};
use serde_json::{json, Value};
use tauri::Manager as _;

use super::{text, ToolCtx, ToolSource};
use crate::state::AppState;

pub struct SettingsTools;

const GET: &str = "get_settings";
const CHANGE: &str = "change_setting";
const OPEN: &str = "open_settings";

/// The setting's name in the user's language, for the plan.
fn name(id: &str) -> &'static str {
    match id {
        "app_language" => tr("Taal van Nook", "Nook's language"),
        "answer_language" => tr("Taal van de antwoorden", "Answer language"),
        "bar_placement" => tr("Plek van de balk", "Where the bar sits"),
        "hide_when_idle" => tr("Verbergen als er niets is", "Hide when idle"),
        "theme" => tr("Weergave", "Look"),
        "energy_mode" => tr("Energie", "Energy"),
        "web_search" => tr("Zoeken op het web", "Web search"),
        "think_along" => tr("Meedenken", "Think Along"),
        "track_screens" => tr("Schermen lezen", "Read the screens"),
        "screens_with_every_question" => tr("Schermen bij elke vraag", "Screens with every question"),
        "speak_answers" => tr("Antwoorden voorlezen", "Read answers aloud"),
        "wake_word" => tr("Hey Nook", "Hey Nook"),
        "agent_sounds" => tr("Geluiden van agents", "Agent sounds"),
        "notices_agents" => tr("Meldingen van agents", "Agent notices"),
        "use_memory" => tr("Geheugen gebruiken", "Use memory"),
        "learn_from_chats" => tr("Leren van gesprekken", "Learn from conversations"),
        _ => tr("Instelling", "Setting"),
    }
}

/// A value in words: "on", "off", "English", "Floating on screen".
fn value_label(value: &str) -> String {
    match value {
        "on" => tr("aan", "on").into(),
        "off" => tr("uit", "off").into(),
        "auto" => tr("de taal van de vraag", "the question's language").into(),
        "top" => tr("bovenaan het scherm", "at the top of the screen").into(),
        "floating" => tr("zwevend op het scherm", "floating on screen").into(),
        "system" => tr("zoals het systeem", "like the system").into(),
        "light" => tr("licht", "light").into(),
        "dark" => tr("donker", "dark").into(),
        "automatic" => tr("automatisch", "automatic").into(),
        "saver" => tr("zuinig", "saver").into(),
        "full" => tr("volle kracht", "full power").into(),
        "detailed" => tr("een kaart", "a card").into(),
        "compact" => tr("één regel", "one line").into(),
        "en" => "English".into(),
        "nl" => "Nederlands".into(),
        "de" => "Deutsch".into(),
        "fr" => "Français".into(),
        "es" => "Español".into(),
        other => other.into(),
    }
}

fn raw_value(input: &Value) -> String {
    match &input["value"] {
        Value::Bool(b) => if *b { "on" } else { "off" }.into(),
        _ => text(input, "value"),
    }
}

fn change_schema() -> Value {
    json!({"type": "object", "properties": {
        "setting": {"type": "string", "enum": catalog::ids(), "description": "Which setting."},
        "value": {"type": "string", "description": "on or off for a switch; for a choice one of its options (see get_settings)."}
    }, "required": ["setting", "value"]})
}

/// "Hey Nook" listens through Windows' own speech recognition; elsewhere it cannot be switched on.
fn wake_word_supported() -> bool {
    cfg!(windows)
}

#[async_trait::async_trait]
impl ToolSource for SettingsTools {
    fn id(&self) -> &'static str {
        "settings"
    }

    fn is_source(&self) -> bool {
        false
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let app = ctx.app.clone();
        vec![
            LoopTool::read(
                GET,
                "Reads Nook's own settings (instellingen, Einstellungen, réglages, ajustes) with their current values and the options each one takes. Use it before change_setting when the current value matters, or when the user asks how Nook is set up.",
                json!({"type": "object", "properties": {}, "required": []}),
                move |_input: Value| {
                    let app = app.clone();
                    async move { Ok(catalog::overview(&app.state::<AppState>().settings())) }
                },
            ),
            LoopTool::action(
                CHANGE,
                "Changes one of Nook's own settings for the user: switch web search, thinking along, reading the screens, reading answers aloud, the \"Hey Nook\" wake word, agent sounds or memory on or off, or change the app language, the answer language, the look, the energy mode, where the bar sits or how agent notices show. Only when the user asks for it; the user approves every change with a click. One call per setting.",
                change_schema(),
            ),
            LoopTool::action(
                OPEN,
                "Opens Nook's Settings at a section, so the user can look or change something there themselves: brain, connections, agents, privacy, shortcuts, and more.",
                json!({"type": "object", "properties": {
                    "section": {"type": "string", "enum": catalog::SECTIONS, "description": "Which section to show."}
                }, "required": ["section"]}),
            ),
        ]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            GET => Some(tr("Instellingen bekijken", "Read settings").into()),
            CHANGE => Some(match catalog::entry(&text(input, "setting")) {
                Some(entry) => {
                    let raw = raw_value(input);
                    let value = catalog::value(&raw, entry).map(|v| value_label(&v)).unwrap_or(raw);
                    format!("{} → {value}", name(entry.id))
                }
                None => tr("Onbekende instelling", "Unknown setting").into(),
            }),
            OPEN => Some(trf("Instellingen openen: {section}", "Open Settings: {section}", &[("section", &text(input, "section"))])),
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        match tool {
            CHANGE => Some(change(&ctx.app, input)),
            OPEN => Some(open(&ctx.app, input)),
            _ => None,
        }
    }
}

fn change(app: &tauri::AppHandle, input: &Value) -> Result<String, String> {
    let entry: &Entry = catalog::entry(&text(input, "setting"))
        .ok_or_else(|| tr("Die instelling kan Nook niet aanpassen.", "Nook cannot change that setting.").to_string())?;
    let raw = raw_value(input);
    let value = catalog::value(&raw, entry)
        .ok_or_else(|| trf("‘{value}’ past niet bij deze instelling.", "“{value}” does not fit this setting.", &[("value", &raw)]))?;
    if entry.id == "wake_word" && value == "on" && !wake_word_supported() {
        return Err(tr("‘Hey Nook’ werkt nog alleen op Windows.", "“Hey Nook” only works on Windows for now.").into());
    }
    let state = app.state::<AppState>();
    let mut settings = state.settings();
    let old = catalog::current(&settings, entry.id);
    catalog::apply(&mut settings, entry.id, &value);
    // The same path as saving in Settings, so the tray, the bar and every window follow.
    crate::commands::save_settings(app.clone(), app.state::<AppState>(), settings);
    Ok(catalog::result(entry.id, &value, &old))
}

fn open(app: &tauri::AppHandle, input: &Value) -> Result<String, String> {
    let section = text(input, "section");
    let section = if catalog::SECTIONS.contains(&section.as_str()) { section } else { "start".into() };
    #[cfg(desktop)]
    crate::platform::desktop::show_main(app, &format!("settings:{section}"));
    #[cfg(not(desktop))]
    let _ = app;
    Ok(format!("Opened Settings at {section}."))
}
