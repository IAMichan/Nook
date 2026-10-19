//! "Maak ongedaan": wat een actie terugdraait die Nook net uitvoerde. Nook draait terug wat hij in je agenda, herinneringen
//! en open punten deed, als een plan dat je goedkeurt zoals elk ander.

use chrono::{DateTime, Utc};
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq)]
pub struct UndoStep {
    pub tool: String,
    pub input: Value,
}

/// De stap die één uitgevoerde actie terugdraait. Niets als dat niet kan (een verstuurde mail of een bericht).
pub fn step(tool: &str, input: &Value, result: &str) -> Option<UndoStep> {
    let titled = |mut value: Value| {
        if let Some(title) = input["title"].as_str().filter(|t| !t.is_empty()) {
            value["title"] = json!(title);
        }
        value
    };
    match tool {
        "create_event" => created_id(result).map(|id| UndoStep { tool: "delete_event".into(), input: titled(json!({"id": id})) }),
        "create_reminder" => created_id(result).map(|id| UndoStep { tool: "delete_reminder".into(), input: titled(json!({"id": id})) }),
        "add_open_loop" => bracket_id(result).map(|id| UndoStep { tool: "complete_open_loop".into(), input: json!({"id": id}) }),
        "remember" => memory_id(result).map(|id| UndoStep { tool: "forget".into(), input: json!({"what": id}) }),
        _ => None,
    }
}

/// "(id ABC-123)" in een resultaat.
pub fn created_id(result: &str) -> Option<String> {
    let caps = rx!(r"\(id ([^)\s]+)\)").captures(result).ok()??;
    Some(caps[1].to_string())
}

/// "[id 1a2b3c4d]" in een resultaat.
pub fn bracket_id(result: &str) -> Option<String> {
    let caps = rx!(r"\[id ([^\]\s]+)\]").captures(result).ok()??;
    Some(caps[1].to_string())
}

/// "(m:abc123)" achter een onthouden herinnering.
fn memory_id(result: &str) -> Option<String> {
    if !result.starts_with("Onthouden:") {
        return None;
    }
    let caps = rx!(r"\((m:[0-9a-f]{6})\)\s*$").captures(result).ok()??;
    Some(caps[1].to_string())
}

/// De gebruiker vraagt om terug te draaien wat er net gedaan is (Nederlands, Engels, Duits).
pub fn is_request(raw: &str) -> bool {
    let text = raw.trim().trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace()).to_lowercase();
    if text.split_whitespace().count() > 8 {
        return false;
    }
    super::matches(
        rx!(
            r"^((nook|hé nook|hey nook)[ ,]+)?((maak|zet) (dat|dit|het|alles|die|deze)? ?(maar )?(weer )?ongedaan|ongedaan maken|draai (dat|dit|het) (maar )?(weer )?terug|terugdraaien|undo( (that|it|this))?|revert( (that|it))?|cancel (that|it)|mach (das|es) rückgängig|rückgängig( machen)?|doe (dat|het) maar niet|toch niet|annule( (ça|ca|cela))?|annuler( (ça|ca|cela))?|deshaz( eso)?|deshacer( eso)?)( alsjeblieft| please| bitte| stp| por favor)?$"
        ),
        &text,
    )
}

/// De acties om terug te draaien: die van de laatste reeks (binnen twee minuten van de laatste), hoogstens een half uur
/// geleden, nieuwste eerst.
pub fn batch<T: Clone>(actions: &[(T, DateTime<Utc>)], now: DateTime<Utc>) -> Vec<T> {
    let Some(last) = actions.iter().map(|a| a.1).max() else { return vec![] };
    if (now - last).num_seconds() > 1_800 {
        return vec![];
    }
    let mut recent: Vec<&(T, DateTime<Utc>)> = actions.iter().filter(|a| (last - a.1).num_seconds() <= 120).collect();
    recent.sort_by_key(|a| std::cmp::Reverse(a.1));
    recent.into_iter().map(|a| a.0.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    #[test]
    fn what_can_be_undone() {
        assert_eq!(
            step("create_event", &json!({"title": "Lunch"}), "Event created: Lunch at vr 12:00 (id ABC:123-x)"),
            Some(UndoStep { tool: "delete_event".into(), input: json!({"id": "ABC:123-x", "title": "Lunch"}) })
        );
        assert_eq!(step("create_reminder", &json!({}), "Reminder created: Bellen (id R1)").map(|s| s.tool), Some("delete_reminder".into()));
        assert_eq!(
            step("add_open_loop", &json!({}), "Todo added: Offerte [id 1a2b3c4d]"),
            Some(UndoStep { tool: "complete_open_loop".into(), input: json!({"id": "1a2b3c4d"}) })
        );
        assert_eq!(
            step("remember", &json!({}), "Onthouden: Lisa is mijn vrouw (m:ab12cd)").map(|s| s.input),
            Some(json!({"what": "m:ab12cd"}))
        );
        assert_eq!(step("whatsapp_send", &json!({}), "WhatsApp message sent to Lisa."), None);
        assert_eq!(step("create_event", &json!({}), "Event created: Lunch"), None);
    }

    #[test]
    fn recognizes_the_request() {
        for text in [
            "Maak dat ongedaan",
            "maak het maar weer ongedaan",
            "Ongedaan maken",
            "draai dat terug",
            "undo",
            "Undo that please",
            "mach das rückgängig",
            "Nook, maak dat ongedaan!",
            "toch niet",
        ] {
            assert!(is_request(text), "{text}");
        }
        for text in ["hoe maak ik iets ongedaan in Word?", "maak een afspraak", "undo the last commit in my repo and push it"] {
            assert!(!is_request(text), "{text}");
        }
    }

    #[test]
    fn only_the_last_batch() {
        let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let actions = vec![("old", now - Duration::seconds(900)), ("a", now - Duration::seconds(100)), ("b", now - Duration::seconds(60))];
        assert_eq!(batch(&actions, now), vec!["b", "a"]);
        assert!(batch(&actions, now + Duration::seconds(3_600)).is_empty());
    }
}
