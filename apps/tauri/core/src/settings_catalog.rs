//! The settings Nook's chat may read and change (`SettingsCatalog` on the Mac), how a value said in words ("aan",
//! "off", "zwevend", "Engels") becomes one the setting takes, and reading and writing them on [`Settings`]. The app's
//! `tools::settings` offers `get_settings`, `change_setting` and `open_settings`; a change always waits for the user's
//! click and can be undone.
//!
//! Left out on purpose, as on the Mac: anything that lets Nook act without asking or that sends more out of the
//! computer (the brain, its provider, the sources kept on this computer). Those stay a click in Settings.
//!
//! Left out because the Tauri app has no such setting yet: the notch's own switches (`show_notch`,
//! `notch_on_all_screens`, `open_on_hover`, `open_window_at_launch`, UI-16), Nook's face style (UI-56), dictation
//! (kept in the Flow store), per-kind notices for chats, Nook and suggestions (UI-17) and online lyrics.

use crate::services::energy::EnergyMode;
use crate::settings::Settings;

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

const LANGUAGES: &[&str] = &["en", "nl", "de", "fr", "es"];
const ANSWER_LANGUAGES: &[&str] = &["en", "nl", "de", "fr", "es", "auto"];

pub const ENTRIES: &[Entry] = &[
    Entry { id: "app_language", kind: Kind::Choice(LANGUAGES), section: "general", about: "Language of Nook's own screens and buttons." },
    Entry {
        id: "answer_language",
        kind: Kind::Choice(ANSWER_LANGUAGES),
        section: "general",
        about: "Language Nook answers in; auto is the language of the question.",
    },
    Entry {
        id: "bar_placement",
        kind: Kind::Choice(&["top", "floating"]),
        section: "notch",
        about: "Nook's bar at the top of the screen, or floating anywhere on screen.",
    },
    Entry { id: "hide_when_idle", kind: Kind::Toggle, section: "notch", about: "Hide Nook's bar when there is nothing to show." },
    Entry {
        id: "theme",
        kind: Kind::Choice(&["system", "light", "dark"]),
        section: "appearance",
        about: "The windows' look: follow the system, light or dark.",
    },
    Entry {
        id: "energy_mode",
        kind: Kind::Choice(&["automatic", "saver", "full"]),
        section: "general",
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
    Entry { id: "agent_sounds", kind: Kind::Toggle, section: "sound", about: "A sound when an agent waits or is done." },
    Entry {
        id: "notices_agents",
        kind: Kind::Choice(&["detailed", "compact", "system"]),
        section: "notifications",
        about: "How a coding agent that is done, failed or waits shows: a card with what changed, one slim line in the bar, or a system notification. Permission requests always reach the user.",
    },
    Entry { id: "use_memory", kind: Kind::Toggle, section: "memory", about: "Use what Nook remembers with every question." },
    Entry { id: "learn_from_chats", kind: Kind::Toggle, section: "memory", about: "Let Nook learn from conversations by itself." },
];

pub fn ids() -> Vec<&'static str> {
    ENTRIES.iter().map(|e| e.id).collect()
}

pub fn entry(id: &str) -> Option<&'static Entry> {
    let key = id.trim().to_lowercase();
    ENTRIES.iter().find(|e| e.id == key)
}

const ON_WORDS: &[&str] = &["on", "true", "yes", "1", "enable", "enabled", "aan", "ja", "an", "ein", "oui", "activé", "sí", "si"];
const OFF_WORDS: &[&str] = &["off", "false", "no", "0", "disable", "disabled", "uit", "nee", "aus", "nein", "non", "désactivé", "apagado"];

/// Language names in the five languages, the placements, the looks and the energy modes.
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
    ("bar", "top"),
    ("at the top", "top"),
    ("bovenaan", "top"),
    ("oben", "top"),
    ("en haut", "top"),
    ("arriba", "top"),
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
    ("card", "detailed"),
    ("kaart", "detailed"),
    ("line", "compact"),
    ("strip", "compact"),
    ("regel", "compact"),
    ("notification", "system"),
    ("melding", "system"),
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

/// The current value of a setting, as `value` writes it.
pub fn current(settings: &Settings, id: &str) -> String {
    match id {
        "app_language" => settings.app_language.clone(),
        "answer_language" => settings.language.clone(),
        "bar_placement" => if settings.placement == "floating" { "floating" } else { "top" }.into(),
        "hide_when_idle" => flag(settings.hide_when_idle),
        "theme" => settings.theme.clone(),
        "energy_mode" => energy_id(settings.energy_mode).into(),
        "web_search" => flag(settings.web_search),
        "think_along" => flag(settings.auto_watch),
        "track_screens" => flag(settings.live_screen),
        "screens_with_every_question" => flag(settings.screen_with_every_question),
        "speak_answers" => flag(settings.speak_answers),
        "wake_word" => flag(settings.wake_word),
        "agent_sounds" => flag(settings.sounds),
        "notices_agents" => settings.agent_notice.clone(),
        "use_memory" => flag(settings.use_memory),
        "learn_from_chats" => flag(settings.learn_from_chats),
        _ => String::new(),
    }
}

/// Writes a value `value` accepted for this setting.
pub fn apply(settings: &mut Settings, id: &str, value: &str) {
    let on = value == "on";
    match id {
        "app_language" => settings.app_language = value.into(),
        "answer_language" => settings.language = value.into(),
        "bar_placement" => settings.placement = value.into(),
        "hide_when_idle" => settings.hide_when_idle = on,
        "theme" => settings.theme = value.into(),
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
        "agent_sounds" => settings.sounds = on,
        "notices_agents" => settings.agent_notice = value.into(),
        "use_memory" => settings.use_memory = on,
        "learn_from_chats" => settings.learn_from_chats = on,
        _ => {}
    }
}

/// Every setting the chat may change, one per line: id, current value, options and what it does.
pub fn overview(settings: &Settings) -> String {
    ENTRIES
        .iter()
        .map(|e| {
            let options = match e.kind {
                Kind::Toggle => "on/off".to_string(),
                Kind::Choice(values) => values.join("/"),
            };
            format!("{} = {} [{options}] — {} (Settings › {})", e.id, current(settings, e.id), e.about, e.section)
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
    "sound",
    "shortcuts",
    "games",
    "brain",
    "assistant",
    "memory",
    "instructions",
    "autocomplete",
    "dictation",
    "agents",
    "usage",
    "sessions",
    "archive",
    "automation",
    "chats",
    "connections",
    "iphone",
    "privacy",
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
        assert_eq!(value("donker", entry("theme").unwrap()).as_deref(), Some("dark"));
        assert_eq!(value("klingon", entry("app_language").unwrap()), None);
        assert!(entry("provider").is_none(), "the brain is never changed from the chat");
    }

    #[test]
    fn reading_and_writing_go_through_the_same_ids() {
        let mut settings = Settings::default();
        for e in ENTRIES {
            let options: Vec<String> = match e.kind {
                Kind::Toggle => vec!["on".into(), "off".into()],
                Kind::Choice(values) => values.iter().map(|v| v.to_string()).collect(),
            };
            for option in options {
                apply(&mut settings, e.id, &option);
                assert_eq!(current(&settings, e.id), option, "{} = {option}", e.id);
            }
        }
        assert!(overview(&settings).lines().count() == ENTRIES.len());
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
        for section in SECTIONS.iter().chain(ENTRIES.iter().map(|e| &e.section)) {
            assert!(pages.contains(&format!("\"{section}\"")), "{section} is not a Settings subject");
        }
    }
}
