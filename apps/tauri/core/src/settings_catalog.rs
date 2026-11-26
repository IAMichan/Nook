//! The settings Nook's chat may read and change (`SettingsCatalog` on the Mac), how a value said in words ("aan",
//! "off", "zwevend", "Engels") becomes one the setting takes, and reading and writing them on [`Settings`] (plus
//! [`Extras`] for the two settings that live in `Services`: dictation and online lyrics). The app's `tools::settings`
//! offers `get_settings`, `change_setting` and `open_settings`; a change always waits for the user's click and can be
//! undone.
//!
//! Left out on purpose, as on the Mac: anything that lets Nook act without asking or that sends more out of the
//! computer (the brain, its provider, the sources kept on this computer). Those stay a click in Settings.

use crate::services::energy::EnergyMode;
use crate::services::notice_rules::{NoticeSource, NoticeStyle};
use crate::settings::{NookLook, Settings};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Toggle,
    Choice(&'static [&'static str]),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: &'static str,
    pub kind: Kind,
    /// The Settings subject it lives in (`settingsSections` in `src/lib/settings-pages.ts`).
    pub section: &'static str,
    /// What it does, for the model.
    pub about: &'static str,
}

/// The two catalog settings that live outside [`Settings`] (in `Services.flow` and `Services.prefs`), passed alongside
/// `Settings` so `settings_catalog` stays pure and testable without Tauri state.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Extras {
    pub dictation: bool,
    pub online_lyrics: bool,
}

const LANGUAGES: &[&str] = &["en", "nl", "de", "fr", "es"];
const ANSWER_LANGUAGES: &[&str] = &["en", "nl", "de", "fr", "es", "auto"];
const NOTICE_STYLES: &[&str] = &["card", "strip", "system", "off"];

pub const ENTRIES: &[Entry] = &[
    Entry { id: "app_language", kind: Kind::Choice(LANGUAGES), section: "general", about: "Language of Nook's own screens and buttons." },
    Entry {
        id: "answer_language",
        kind: Kind::Choice(ANSWER_LANGUAGES),
        section: "general",
        about: "Language Nook answers in; auto is the language of the question.",
    },
    Entry {
        id: "nook_style",
        kind: Kind::Choice(&["minimal", "classic", "playful"]),
        section: "appearance",
        about: "How Nook's face looks: minimal (dots, no mouth), classic (the usual look) or playful (round eyes, a talking mouth).",
    },
    Entry {
        id: "theme",
        kind: Kind::Choice(&["system", "light", "dark"]),
        section: "appearance",
        about: "The windows' look: follow the system, light or dark.",
    },
    Entry {
        id: "bar_placement",
        kind: Kind::Choice(&["top", "floating"]),
        section: "notch",
        about: "Nook's bar at the top of the screen, or floating anywhere on screen.",
    },
    Entry {
        id: "show_bar",
        kind: Kind::Toggle,
        section: "notch",
        about: "Show Nook in the bar; off keeps him out of sight until opened with a shortcut or from the tray.",
    },
    Entry { id: "bar_on_all_screens", kind: Kind::Toggle, section: "notch", about: "Show the bar on every connected screen." },
    Entry { id: "hide_when_idle", kind: Kind::Toggle, section: "notch", about: "Hide Nook's bar when there is nothing to show." },
    Entry { id: "open_on_hover", kind: Kind::Toggle, section: "notch", about: "Open the panel when the pointer rests on the bar." },
    Entry {
        id: "open_window_at_launch",
        kind: Kind::Toggle,
        section: "notch",
        about: "Open the main window every time Nook starts.",
    },
    Entry {
        id: "energy_mode",
        kind: Kind::Choice(&["automatic", "saver", "full"]),
        section: "maintenance",
        about: "How much Nook does by himself on battery or a busy computer: automatic (steps back when needed), saver (always light) or full (never slows down).",
    },
    Entry { id: "web_search", kind: Kind::Toggle, section: "assistant", about: "Search the web when a question needs it." },
    Entry { id: "think_along", kind: Kind::Toggle, section: "assistant", about: "Proactive suggestions while the user works." },
    Entry {
        id: "track_screens",
        kind: Kind::Toggle,
        section: "assistant",
        about: "Read the text of the windows on screen, on this computer, so answers are ready at once.",
    },
    Entry {
        id: "screens_with_every_question",
        kind: Kind::Toggle,
        section: "assistant",
        about: "Use the screens with every question, not only when the user points at something.",
    },
    Entry { id: "speak_answers", kind: Kind::Toggle, section: "sound", about: "Read answers aloud after a spoken question." },
    Entry { id: "wake_word", kind: Kind::Toggle, section: "sound", about: "Listen for \"Hey Nook\"." },
    Entry { id: "dictation", kind: Kind::Toggle, section: "dictation", about: "Dictate anywhere by holding a key." },
    Entry { id: "agent_sounds", kind: Kind::Toggle, section: "sound", about: "A sound when an agent waits or is done." },
    Entry {
        id: "notices_agents",
        kind: Kind::Choice(NOTICE_STYLES),
        section: "notifications",
        about: "How a coding agent that is done, failed or waits shows: a card, one line, a system notification, or only in the list. Permission requests always reach the user.",
    },
    Entry {
        id: "notices_chats",
        kind: Kind::Choice(NOTICE_STYLES),
        section: "notifications",
        about: "How a new chat message shows: a card with an answer field, one line, a system notification, or only in the list.",
    },
    Entry {
        id: "notices_nook",
        kind: Kind::Choice(NOTICE_STYLES),
        section: "notifications",
        about: "How Nook's own notices show (an answer that finished in the background, call notes that are ready).",
    },
    Entry {
        id: "notices_suggestions",
        kind: Kind::Choice(NOTICE_STYLES),
        section: "notifications",
        about: "How a Think Along suggestion shows: its card, one line that opens it, a system notification, or only in the list.",
    },
    Entry { id: "use_memory", kind: Kind::Toggle, section: "memory", about: "Use what Nook remembers with every question." },
    Entry { id: "learn_from_chats", kind: Kind::Toggle, section: "memory", about: "Let Nook learn from conversations by itself." },
    Entry { id: "online_lyrics", kind: Kind::Toggle, section: "connections", about: "Look up song lyrics online." },
];

pub fn ids() -> Vec<&'static str> {
    ENTRIES.iter().map(|e| e.id).collect()
}

pub fn entry(id: &str) -> Option<&'static Entry> {
    let key = id.trim().to_lowercase();
    let canonical = match key.as_str() {
        "notch_placement" => "bar_placement",
        "show_notch" => "show_bar",
        "notch_on_all_screens" => "bar_on_all_screens",
        other => other,
    };
    ENTRIES.iter().find(|e| e.id == canonical)
}

const ON_WORDS: &[&str] = &["on", "true", "yes", "1", "enable", "enabled", "aan", "ja", "an", "ein", "oui", "activé", "sí", "si"];
const OFF_WORDS: &[&str] = &["off", "false", "no", "0", "disable", "disabled", "uit", "nee", "aus", "nein", "non", "désactivé", "apagado"];

/// Language names in the five languages, the placements, the looks, the face styles, the energy modes and notice styles.
const ALIASES: &[(&str, &str)] = &[
    ("english", "en"),
    ("engels", "en"),
    ("englisch", "en"),
    ("anglais", "en"),
    ("inglés", "en"),
    ("ingles", "en"),
    ("dutch", "nl"),
    ("nederlands", "nl"),
    ("niederländisch", "nl"),
    ("néerlandais", "nl"),
    ("neerlandés", "nl"),
    ("german", "de"),
    ("duits", "de"),
    ("deutsch", "de"),
    ("allemand", "de"),
    ("alemán", "de"),
    ("aleman", "de"),
    ("french", "fr"),
    ("frans", "fr"),
    ("französisch", "fr"),
    ("français", "fr"),
    ("francais", "fr"),
    ("francés", "fr"),
    ("spanish", "es"),
    ("spaans", "es"),
    ("spanisch", "es"),
    ("espagnol", "es"),
    ("español", "es"),
    ("espanol", "es"),
    ("floating", "floating"),
    ("zwevend", "floating"),
    ("schwebend", "floating"),
    ("flottant", "floating"),
    ("flotante", "floating"),
    ("notch", "top"),
    ("in the notch", "top"),
    ("in de notch", "top"),
    ("in der notch", "top"),
    ("bar", "top"),
    ("at the top", "top"),
    ("bovenaan", "top"),
    ("oben", "top"),
    ("en haut", "top"),
    ("arriba", "top"),
    ("minimaal", "minimal"),
    ("minimaliste", "minimal"),
    ("minimalista", "minimal"),
    ("minimalistisch", "minimal"),
    ("klassiek", "classic"),
    ("klassisch", "classic"),
    ("classique", "classic"),
    ("clásico", "classic"),
    ("clasico", "classic"),
    ("speels", "playful"),
    ("verspielt", "playful"),
    ("ludique", "playful"),
    ("divertido", "playful"),
    ("fun", "playful"),
    ("licht", "light"),
    ("hell", "light"),
    ("clair", "light"),
    ("claro", "light"),
    ("donker", "dark"),
    ("dunkel", "dark"),
    ("sombre", "dark"),
    ("oscuro", "dark"),
    ("systeem", "system"),
    ("auto", "automatic"),
    ("automatisch", "automatic"),
    ("automatique", "automatic"),
    ("automático", "automatic"),
    ("automatico", "automatic"),
    ("zuinig", "saver"),
    ("spaarstand", "saver"),
    ("battery saver", "saver"),
    ("sparsam", "saver"),
    ("économe", "saver"),
    ("econome", "saver"),
    ("ahorro", "saver"),
    ("eco", "saver"),
    ("full power", "full"),
    ("volle kracht", "full"),
    ("volle kraft", "full"),
    ("pleine puissance", "full"),
    ("máxima potencia", "full"),
    ("maxima potencia", "full"),
    ("performance", "full"),
    ("detailed", "card"),
    ("kaart", "card"),
    ("compact", "strip"),
    ("line", "strip"),
    ("one line", "strip"),
    ("regel", "strip"),
    ("één regel", "strip"),
    ("een regel", "strip"),
    ("notification", "system"),
    ("melding", "system"),
    ("systeemmelding", "system"),
    ("list", "off"),
    ("only in the list", "off"),
    ("alleen in de lijst", "off"),
    ("uit", "off"),
];

/// The value a setting takes for what was asked: "on"/"off" for a switch, one of the options for a choice. `None` when
/// it does not fit.
pub fn value(raw: &str, entry: &Entry) -> Option<String> {
    let text = raw.trim().to_lowercase();
    match entry.kind {
        Kind::Toggle if ON_WORDS.contains(&text.as_str()) => Some("on".into()),
        Kind::Toggle if OFF_WORDS.contains(&text.as_str()) => Some("off".into()),
        Kind::Toggle => None,
        Kind::Choice(options) => {
            if options.contains(&text.as_str()) {
                return Some(text);
            }
            // "auto" is the answer language's own option, and an energy mode elsewhere.
            ALIASES.iter().filter(|(word, _)| *word == text).map(|(_, to)| *to).find(|to| options.contains(to)).map(str::to_string)
        }
    }
}

fn flag(on: bool) -> String {
    if on { "on" } else { "off" }.into()
}

fn energy_id(mode: EnergyMode) -> &'static str {
    match mode {
        EnergyMode::Automatic => "automatic",
        EnergyMode::Saver => "saver",
        EnergyMode::Full => "full",
    }
}

fn agent_notice_value(style: NoticeStyle) -> &'static str {
    match style {
        NoticeStyle::Card => "detailed",
        NoticeStyle::Strip => "compact",
        NoticeStyle::System => "system",
        NoticeStyle::Off => "off",
    }
}

/// The current value of a setting, as `value` writes it.
pub fn current(settings: &Settings, id: &str) -> String {
    current_with(settings, Extras::default(), id)
}

/// The current value of a setting, including the two settings stored in `Services` (`dictation`, `online_lyrics`).
pub fn current_with(settings: &Settings, extras: Extras, id: &str) -> String {
    match id {
        "app_language" => settings.app_language.clone(),
        "answer_language" => settings.language.clone(),
        "nook_style" => settings.nook_look.preset_id().into(),
        "theme" => settings.theme.clone(),
        "bar_placement" => if settings.placement == "floating" { "floating" } else { "top" }.into(),
        "show_bar" => flag(settings.show_bar),
        "bar_on_all_screens" => flag(settings.bar_on_all_screens),
        "hide_when_idle" => flag(settings.hide_when_idle),
        "open_on_hover" => flag(settings.open_on_hover),
        "open_window_at_launch" => flag(settings.open_window_at_launch),
        "energy_mode" => energy_id(settings.energy_mode).into(),
        "web_search" => flag(settings.web_search),
        "think_along" => flag(settings.auto_watch),
        "track_screens" => flag(settings.live_screen),
        "screens_with_every_question" => flag(settings.screen_with_every_question),
        "speak_answers" => flag(settings.speak_answers),
        "wake_word" => flag(settings.wake_word),
        "dictation" => flag(extras.dictation),
        "agent_sounds" => flag(settings.sounds),
        "notices_agents" => NoticeStyle::from_id(&settings.agent_notice)
            .unwrap_or_else(|| settings.notice_rules.style(NoticeSource::Agents))
            .id()
            .into(),
        "notices_chats" => settings.notice_rules.style(NoticeSource::Chats).id().into(),
        "notices_nook" => settings.notice_rules.style(NoticeSource::Nook).id().into(),
        "notices_suggestions" => settings.notice_rules.style(NoticeSource::Suggestions).id().into(),
        "use_memory" => flag(settings.use_memory),
        "learn_from_chats" => flag(settings.learn_from_chats),
        "online_lyrics" => flag(extras.online_lyrics),
        _ => String::new(),
    }
}

/// Writes a value `value` accepted for a [`Settings`]-backed setting.
pub fn apply(settings: &mut Settings, id: &str, value: &str) {
    let mut extras = Extras::default();
    apply_with(settings, &mut extras, id, value);
}

/// Writes a value `value` accepted for any catalog setting, updating [`Settings`] or [`Extras`].
pub fn apply_with(settings: &mut Settings, extras: &mut Extras, id: &str, value: &str) {
    let on = value == "on";
    match id {
        "app_language" => settings.app_language = value.into(),
        "answer_language" => settings.language = value.into(),
        "nook_style" => {
            if let Some(look) = NookLook::preset(value) {
                settings.nook_look = look;
            }
        }
        "theme" => settings.theme = value.into(),
        "bar_placement" => settings.placement = value.into(),
        "show_bar" => settings.show_bar = on,
        "bar_on_all_screens" => settings.bar_on_all_screens = on,
        "hide_when_idle" => settings.hide_when_idle = on,
        "open_on_hover" => settings.open_on_hover = on,
        "open_window_at_launch" => settings.open_window_at_launch = on,
        "energy_mode" => {
            settings.energy_mode = match value {
                "saver" => EnergyMode::Saver,
                "full" => EnergyMode::Full,
                _ => EnergyMode::Automatic,
            }
        }
        "web_search" => settings.web_search = on,
        "think_along" => settings.auto_watch = on,
        "track_screens" => settings.live_screen = on,
        "screens_with_every_question" => settings.screen_with_every_question = on,
        "speak_answers" => settings.speak_answers = on,
        "wake_word" => settings.wake_word = on,
        "dictation" => extras.dictation = on,
        "agent_sounds" => settings.sounds = on,
        "notices_agents" => {
            if let Some(style) = NoticeStyle::from_id(value) {
                // Keep both fields in sync, just as `Voice.svelte` does when the user picks a style.
                settings.agent_notice = agent_notice_value(style).into();
                settings.notice_rules.set_style(NoticeSource::Agents, style);
            }
        }
        "notices_chats" => {
            if let Some(style) = NoticeStyle::from_id(value) {
                settings.notice_rules.set_style(NoticeSource::Chats, style);
            }
        }
        "notices_nook" => {
            if let Some(style) = NoticeStyle::from_id(value) {
                settings.notice_rules.set_style(NoticeSource::Nook, style);
            }
        }
        "notices_suggestions" => {
            if let Some(style) = NoticeStyle::from_id(value) {
                settings.notice_rules.set_style(NoticeSource::Suggestions, style);
            }
        }
        "use_memory" => settings.use_memory = on,
        "learn_from_chats" => settings.learn_from_chats = on,
        "online_lyrics" => extras.online_lyrics = on,
        _ => {}
    }
}

/// Every setting the chat may change, one per line: id, current value, options and what it does.
pub fn overview(settings: &Settings) -> String {
    overview_with(settings, Extras::default())
}

/// Every setting the chat may change, including the values from `Services`.
pub fn overview_with(settings: &Settings, extras: Extras) -> String {
    ENTRIES
        .iter()
        .map(|e| {
            let options = match e.kind {
                Kind::Toggle => "on/off".to_string(),
                Kind::Choice(values) => values.join("/"),
            };
            format!("{} = {} [{options}] — {} (Settings › {})", e.id, current_with(settings, extras, e.id), e.about, e.section)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The result of a change, with the old value so it can be undone: "web_search: on (was off)".
pub fn result(id: &str, value: &str, old: &str) -> String {
    format!("{id}: {value} (was {old})")
}

/// The old value in a result made by `result`.
pub fn previous(result: &str) -> Option<String> {
    let start = result.find("(was ")? + 5;
    let end = result[start..].find(')')? + start;
    let old = result[start..end].trim();
    (!old.is_empty() && !old.contains(char::is_whitespace)).then(|| old.to_string())
}

/// The Settings subjects `open_settings` can show (`settingsSections` in `src/lib/settings-pages.ts`).
pub const SECTIONS: &[&str] = &[
    "start",
    "general",
    "notch",
    "appearance",
    "notifications",
    "notificationApps",
    "sound",
    "shortcuts",
    "games",
    "brain",
    "assistant",
    "memory",
    "instructions",
    "autocomplete",
    "autocompleteApps",
    "autocompleteStyle",
    "autocompletePlayground",
    "autocompleteStats",
    "dictation",
    "agents",
    "skills",
    "usage",
    "sessions",
    "worktrees",
    "openIn",
    "archive",
    "automation",
    "projects",
    "pullRequests",
    "chats",
    "connections",
    "iphone",
    "privacy",
    "permissions",
    "activityLog",
    "maintenance",
    "about",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_said_in_words_become_the_settings_options() {
        let web = entry(" Web_Search ").unwrap();
        assert_eq!(value("uit", web).as_deref(), Some("off"));
        assert_eq!(value("Ja", web).as_deref(), Some("on"));
        assert_eq!(value("maybe", web), None);
        assert_eq!(value("Engels", entry("app_language").unwrap()).as_deref(), Some("en"));
        assert_eq!(value("auto", entry("answer_language").unwrap()).as_deref(), Some("auto"));
        assert_eq!(value("auto", entry("energy_mode").unwrap()).as_deref(), Some("automatic"));
        assert_eq!(value("zwevend", entry("bar_placement").unwrap()).as_deref(), Some("floating"));
        assert_eq!(value("speels", entry("nook_style").unwrap()).as_deref(), Some("playful"));
        assert_eq!(value("donker", entry("theme").unwrap()).as_deref(), Some("dark"));
        assert_eq!(value("detailed", entry("notices_agents").unwrap()).as_deref(), Some("card"));
        assert_eq!(value("compact", entry("notices_agents").unwrap()).as_deref(), Some("strip"));
        assert_eq!(value("alleen in de lijst", entry("notices_chats").unwrap()).as_deref(), Some("off"));
        assert_eq!(value("klingon", entry("app_language").unwrap()), None);
        assert!(entry("provider").is_none(), "the brain is never changed from the chat");
    }

    #[test]
    fn mac_notch_key_aliases_resolve_to_bar_entries() {
        assert_eq!(entry("notch_placement").map(|e| e.id), Some("bar_placement"));
        assert_eq!(entry("show_notch").map(|e| e.id), Some("show_bar"));
        assert_eq!(entry("notch_on_all_screens").map(|e| e.id), Some("bar_on_all_screens"));
    }

    #[test]
    fn reading_and_writing_go_through_the_same_ids() {
        let mut settings = Settings::default();
        let mut extras = Extras::default();
        for e in ENTRIES {
            let options: Vec<String> = match e.kind {
                Kind::Toggle => vec!["on".into(), "off".into()],
                Kind::Choice(values) => values.iter().map(|v| v.to_string()).collect(),
            };
            for option in options {
                apply_with(&mut settings, &mut extras, e.id, &option);
                assert_eq!(current_with(&settings, extras, e.id), option, "{} = {option}", e.id);
            }
        }
        assert_eq!(overview_with(&settings, extras).lines().count(), ENTRIES.len());
    }

    #[test]
    fn notices_agents_keeps_agent_notice_and_notice_rules_in_sync() {
        let mut settings = Settings::default();
        apply(&mut settings, "notices_agents", "strip");
        assert_eq!(settings.agent_notice, "compact");
        assert_eq!(settings.notice_rules.style(NoticeSource::Agents), NoticeStyle::Strip);
        apply(&mut settings, "notices_agents", "off");
        assert_eq!(settings.agent_notice, "off");
        assert_eq!(settings.notice_rules.style(NoticeSource::Agents), NoticeStyle::Off);
        apply(&mut settings, "notices_agents", "card");
        assert_eq!(settings.agent_notice, "detailed");
        assert_eq!(settings.notice_rules.style(NoticeSource::Agents), NoticeStyle::Card);
    }

    #[test]
    fn custom_nook_look_reports_custom() {
        let mut settings = Settings::default();
        settings.nook_look.gloss = false;
        assert_eq!(current(&settings, "nook_style"), "custom");
        apply(&mut settings, "nook_style", "minimal");
        assert_eq!(current(&settings, "nook_style"), "minimal");
    }

    #[test]
    fn a_result_holds_the_old_value_for_undo() {
        let line = result("web_search", "off", "on");
        assert_eq!(line, "web_search: off (was on)");
        assert_eq!(previous(&line).as_deref(), Some("on"));
        assert_eq!(previous("nothing here"), None);
    }

    #[test]
    fn every_section_and_entry_is_known_to_the_settings_window() {
        let pages = include_str!("../../src/lib/settings-pages.ts");
        let start = pages.find("export const settingsSections = [").expect("settingsSections array");
        let rest = &pages[start..];
        let end = rest.find("] as const;").expect("settingsSections end");
        let block = &rest[..end];
        let ui_sections: Vec<&str> = block.split('"').skip(1).step_by(2).collect();
        assert_eq!(SECTIONS, ui_sections.as_slice(), "SECTIONS must match settingsSections in settings-pages.ts");
        for e in ENTRIES {
            assert!(SECTIONS.contains(&e.section), "{} points to unknown Settings subject {}", e.id, e.section);
        }
    }
}
