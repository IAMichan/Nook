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
use crate::services::Services;
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
        "nook_style" => tr("Stijl van Nook", "Nook's style"),
        "theme" => tr("Weergave", "Look"),
        "bar_placement" => tr("Plek van de balk", "Where the bar sits"),
        "show_bar" => tr("Nook in de balk", "Nook in the bar"),
        "bar_on_all_screens" => tr("Balk op elk scherm", "Bar on every screen"),
        "hide_when_idle" => tr("Verbergen als er niets is", "Hide when idle"),
        "open_on_hover" => tr("Openen bij aanwijzen", "Open on hover"),
        "open_window_at_launch" => tr("Hoofdvenster openen bij opstarten", "Open main window at launch"),
        "energy_mode" => tr("Energie", "Energy"),
        "web_search" => tr("Zoeken op het web", "Web search"),
        "think_along" => tr("Meedenken", "Think Along"),
        "track_screens" => tr("Schermen lezen", "Read the screens"),
        "screens_with_every_question" => tr("Schermen bij elke vraag", "Screens with every question"),
        "speak_answers" => tr("Antwoorden voorlezen", "Read answers aloud"),
        "wake_word" => tr("Hey Nook", "Hey Nook"),
        "dictation" => tr("Dicteren", "Dictation"),
        "agent_sounds" => tr("Geluiden van agents", "Agent sounds"),
        "notices_agents" => tr("Meldingen van agents", "Agent notices"),
        "notices_chats" => tr("Meldingen van chats", "Chat notices"),
        "notices_nook" => tr("Meldingen van Nook", "Nook notices"),
        "notices_suggestions" => tr("Meldingen van Meedenken", "Think Along notices"),
        "use_memory" => tr("Geheugen gebruiken", "Use memory"),
        "learn_from_chats" => tr("Leren van gesprekken", "Learn from conversations"),
        "online_lyrics" => tr("Songteksten online", "Online lyrics"),
        _ => tr("Instelling", "Setting"),
    }
}

/// A value in words: "on", "off", "English", "floating on screen", "a system notification".
fn value_label(value: &str, entry: &Entry) -> String {
    let is_notice = entry.id.starts_with("notices_");
    match value {
        "on" => tr("aan", "on").into(),
        "off" if is_notice => tr("alleen in de lijst", "only in the list").into(),
        "off" => tr("uit", "off").into(),
        "auto" => tr("de taal van de vraag", "the question's language").into(),
        "top" => tr("bovenaan het scherm", "at the top of the screen").into(),
        "floating" => tr("zwevend op het scherm", "floating on screen").into(),
        "minimal" => tr("minimaal", "minimal").into(),
        "classic" => tr("klassiek", "classic").into(),
        "playful" => tr("speels", "playful").into(),
        "custom" => tr("eigen mix", "custom").into(),
        "system" if is_notice => tr("een systeemmelding", "a system notification").into(),
        "system" => tr("zoals het systeem", "like the system").into(),
        "light" => tr("licht", "light").into(),
        "dark" => tr("donker", "dark").into(),
        "automatic" => tr("automatisch", "automatic").into(),
        "saver" => tr("zuinig", "saver").into(),
        "full" => tr("volle kracht", "full power").into(),
        "card" | "detailed" => tr("een kaart", "a card").into(),
        "strip" | "compact" => tr("één regel", "one line").into(),
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

fn extras(app: &tauri::AppHandle) -> catalog::Extras {
    let services = app.state::<Services>();
    let dictation = services.flow.lock().unwrap_or_else(|e| e.into_inner()).settings.enabled;
    let online_lyrics = services.prefs().online_lyrics;
    catalog::Extras { dictation, online_lyrics }
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
                    async move {
                        let settings = app.state::<AppState>().settings();
                        Ok(catalog::overview_with(&settings, extras(&app)))
                    }
                },
            ),
            LoopTool::action(
                CHANGE,
                "Changes one of Nook's own settings for the user: switch web search, thinking along, reading the screens, reading answers aloud, the \"Hey Nook\" wake word, dictation, agent sounds, memory or online lyrics on or off, or change the app language, the answer language, Nook's style, the look, the energy mode, where the bar sits or how notices show. Only when the user asks for it; the user approves every change with a click. One call per setting.",
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
                    let value = catalog::value(&raw, entry).map(|v| value_label(&v, entry)).unwrap_or(raw);
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
    let current_extras = extras(app);
    let state = app.state::<AppState>();
    let mut settings = state.settings();
    let old = catalog::current_with(&settings, current_extras, entry.id);
    match entry.id {
        "dictation" => {
            let services = app.state::<Services>();
            let mut flow_settings = services.flow.lock().unwrap_or_else(|e| e.into_inner()).settings.clone();
            flow_settings.enabled = value == "on";
            crate::commands::services::save_flow_settings(app.clone(), services, flow_settings);
        }
        "online_lyrics" => {
            let services = app.state::<Services>();
            let mut prefs = services.prefs();
            prefs.online_lyrics = value == "on";
            crate::commands::services::save_services_prefs(app.clone(), services, prefs);
        }
        _ => {
            catalog::apply(&mut settings, entry.id, &value);
            // The same path as saving in Settings, so the tray, the bar and every window follow.
            crate::commands::save_settings(app.clone(), app.state::<AppState>(), settings);
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_catalog_entry_has_a_specific_name_and_labels_for_its_values() {
        let fallback = name("unknown_setting_id");
        for entry in catalog::ENTRIES {
            assert_ne!(name(entry.id), fallback, "missing name() for {}", entry.id);
            match entry.kind {
                catalog::Kind::Toggle => {
                    assert!(!value_label("on", entry).is_empty());
                    assert!(!value_label("off", entry).is_empty());
                }
                catalog::Kind::Choice(values) => {
                    for v in values {
                        assert!(!value_label(v, entry).is_empty(), "empty label for {} = {v}", entry.id);
                    }
                }
            }
        }
        let theme = catalog::entry("theme").unwrap();
        let notices = catalog::entry("notices_agents").unwrap();
        assert_ne!(value_label("system", theme), value_label("system", notices));
        let web = catalog::entry("web_search").unwrap();
        assert_ne!(value_label("off", web), value_label("off", notices));
    }
}
