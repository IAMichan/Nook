//! How much Nook may do by itself from the chat, chosen in its composer (Shift+Tab moves to the next level) the way an
//! agent's access is chosen in its own composer. Port of the Mac's `NookAccess` and `AppModel.request(_:asksFor:)`.
//!
//! Whatever the level, an action only runs without a click when the user's own words ask for it ([`asks_for`]): text
//! from the screen, a mail or a web page is never enough. Mail and messages, links, commands, shortcuts, webhooks,
//! settings and deleting always wait for a click, and every action that runs is in the audit log.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::memory::{request as memory_request, text as memory_text};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NookAccess {
    /// Every action waits for a click.
    #[default]
    Ask,
    /// Small, easily reversed things right away: music, volume, an app, a reminder, a to-do.
    Small,
    /// Also what stays with you and nobody else receives: a calendar event without guests, ticking off a reminder, a
    /// note. A change to an existing event still asks here: the Tauri app cannot tell whether others are invited.
    More,
}

/// What `small` runs without a click.
pub const SMALL_TOOLS: [&str; 7] =
    ["media_control", "set_volume", "open_app", "add_open_loop", "create_reminder", "complete_open_loop", "open_settings"];
/// What `more` runs without a click besides the small things. The Mac's `update_event` and `take_over` are left out:
/// whether an event has guests is unknown here, and taking over a task is not in the Tauri app yet (BR-29).
pub const MORE_TOOLS: [&str; 3] = ["create_event", "complete_reminder", "create_note"];

impl NookAccess {
    pub const ALL: [NookAccess; 3] = [Self::Ask, Self::Small, Self::More];

    pub fn id(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Small => "small",
            Self::More => "more",
        }
    }

    /// Whether this level runs `tool` without asking (before the user's words and the input are checked).
    pub fn allows(self, tool: &str) -> bool {
        match self {
            Self::Ask => false,
            Self::Small => SMALL_TOOLS.contains(&tool),
            Self::More => SMALL_TOOLS.contains(&tool) || MORE_TOOLS.contains(&tool),
        }
    }

    /// Shift+Tab in the composer: ask → small → more → ask.
    pub fn next(self) -> Self {
        let all = Self::ALL;
        all[(all.iter().position(|a| *a == self).unwrap_or(0) + 1) % all.len()]
    }

    /// The level from before it could be chosen in the composer: the "small things right away" switch.
    pub fn migrated(stored: Option<NookAccess>, auto_run_safe: bool) -> Self {
        stored.unwrap_or(if auto_run_safe { Self::Small } else { Self::Ask })
    }

    /// Whether this call may run without a click at this level. An event others are invited to always asks: they
    /// would receive it.
    pub fn allows_call(self, tool: &str, input: &Value) -> bool {
        if !self.allows(tool) {
            return false;
        }
        if tool == "create_event" {
            return !has_guests(input);
        }
        true
    }
}

/// Guests in an event's input, under any of the names the calendar tools use.
fn has_guests(input: &Value) -> bool {
    ["attendees", "invitees", "guests", "participants"].iter().any(|key| match &input[key] {
        Value::Array(list) => !list.is_empty(),
        Value::String(text) => !text.trim().is_empty(),
        Value::Null => false,
        _ => true,
    })
}

/// Whether the user's own words ask for this action. The prompt also carries text from others (screen, mail, web,
/// invites), and such text must never be enough to make Nook act without a click.
pub fn asks_for(request: &str, tool: &str, input: &Value) -> bool {
    let text = request.to_lowercase();
    let mentions = |pattern: &str| fancy_regex::Regex::new(pattern).ok().is_some_and(|re| re.is_match(&text).unwrap_or(false));
    match tool {
        "open_app" => {
            let name = input["name"].as_str().unwrap_or("").trim().to_lowercase();
            !name.is_empty() && text.contains(&name) && mentions(r"\b(open|start|launch|öffne|starte)")
        }
        "media_control" => mentions(
            r"muziek|music|musik|nummer|liedje|song|track|speel|play|pauze|pause|stop|volgende|vorige|next|previous|skip|shuffle|herhaal|repeat",
        ),
        "set_volume" => mentions(r"volume|geluid|harder|zachter|louder|quieter|lauter|leiser|mute|dempen"),
        "create_reminder" => mentions(r"herinner|reminder|erinner|onthoud|remember"),
        // Only what the user said: a memory planted by text on screen or in a mail is never stored without a click.
        "remember" => memory_request::asks_to_remember(request) && memory_text::grounded(input["text"].as_str().unwrap_or(""), request),
        "forget" => memory_request::asks_to_forget(request) && memory_text::grounded(input["what"].as_str().unwrap_or(""), request),
        // Only opening the window: changing a setting always waits for a click.
        "open_settings" => mentions(r"instelling|setting|einstellung|réglage|reglage|paramètre|ajuste|configuración|preferen"),
        "create_event" => mentions(
            r"afspraak|agenda|kalender|calendar|event|meeting|vergadering|termin|kalendar|rendez-vous|réunion|reunion|cita|evento|reunión|inplannen|plan .+ in|schedule|book",
        ),
        "complete_reminder" => mentions(
            r"herinnering|reminder|erinnerung|rappel|recordatorio|afvinken|vink .+ af|afgerond|klaar|gedaan|done|complete|finished|erledigt|terminé|hecho|completad",
        ),
        "create_note" => mentions(r"notitie|notities|note|notes|notiz|nota|notas|schrijf .+ op|write .+ down"),
        "add_open_loop" | "complete_open_loop" => {
            mentions(r"onthoud|noteer|open punt|todo|to-do|taak|taken|remember|note|aufgabe|afgerond|klaar|done|erledigt")
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn each_level_runs_more_by_itself() {
        assert!(!NookAccess::Ask.allows("media_control"));
        assert!(NookAccess::Small.allows("media_control") && !NookAccess::Small.allows("create_event"));
        assert!(NookAccess::More.allows("create_event") && NookAccess::More.allows("create_reminder"));
        for never in ["send_mail", "whatsapp_send", "run_command", "open_url", "change_setting", "delete_event", "update_event"] {
            assert!(!NookAccess::More.allows(never), "{never} always asks");
        }
    }

    #[test]
    fn an_event_with_guests_always_asks() {
        assert!(NookAccess::More.allows_call("create_event", &json!({"title": "Tandarts"})));
        assert!(!NookAccess::More.allows_call("create_event", &json!({"title": "Overleg", "attendees": ["lisa@x.nl"]})));
        assert!(!NookAccess::More.allows_call("create_event", &json!({"title": "Overleg", "invitees": "lisa@x.nl"})));
        assert!(NookAccess::More.allows_call("create_event", &json!({"title": "Overleg", "attendees": []})));
    }

    #[test]
    fn shift_tab_cycles_and_the_old_switch_migrates() {
        assert_eq!(NookAccess::Ask.next(), NookAccess::Small);
        assert_eq!(NookAccess::More.next(), NookAccess::Ask);
        assert_eq!(NookAccess::migrated(None, true), NookAccess::Small);
        assert_eq!(NookAccess::migrated(None, false), NookAccess::Ask);
        assert_eq!(NookAccess::migrated(Some(NookAccess::More), false), NookAccess::More);
        assert_eq!(serde_json::to_string(&NookAccess::Small).unwrap(), "\"small\"", "the Mac's stored values");
    }

    #[test]
    fn only_the_users_words_ask_for_an_action() {
        assert!(asks_for("Zet morgen om 10 uur een afspraak met de tandarts in mijn agenda", "create_event", &json!({})));
        assert!(!asks_for("Wat staat er in deze mail?", "create_event", &json!({})));
        assert!(asks_for("Vink de herinnering over de vuilnis af", "complete_reminder", &json!({})));
        assert!(asks_for("Schrijf dit op in een notitie", "create_note", &json!({})));
        assert!(asks_for("Open Spotify", "open_app", &json!({"name": "Spotify"})));
        assert!(!asks_for("Wat speelt er?", "open_app", &json!({"name": "Spotify"})));
        assert!(!asks_for("Zet het in mijn agenda", "send_mail", &json!({})));
    }
}
