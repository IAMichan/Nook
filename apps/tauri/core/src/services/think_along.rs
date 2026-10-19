//! Meedenken: wanneer Nook ongevraagd meekijkt en wanneer hij hulp mag aanbieden. Het denken zelf doet het brein;
//! dit houdt de voorstellen rustig en leert van je antwoorden (`ThinkAlong` op de Mac).
//!
//! - Pas als je een tijdje bij hetzelfde venster blijft (niet bij elke wissel tussen apps).
//! - Hetzelfde venster pas na een paar minuten opnieuw, en alleen als er iets veranderde.
//! - Na een paar keer nee wacht Nook steeds langer; na een ja weer gewoon.
//! - "Niet in deze app" onthoudt hij (terug te zetten in Instellingen).

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

use super::screen::is_excluded;

/// Zo lang moet je bij hetzelfde venster blijven voor Nook kijkt.
pub const SETTLE: f64 = 25.0;
pub const MIN_LOOK_GAP: f64 = 120.0;
pub const SAME_WINDOW_GAP: f64 = 240.0;
pub const BASE_OFFER_GAP: f64 = 180.0;
/// Zo lang zonder muis of toetsenbord en Nook kijkt niet meer mee.
pub const IDLE_LIMIT: f64 = 120.0;

#[derive(Debug, Default)]
pub struct ThinkAlong {
    focus_key: String,
    focus_since: f64,
    last_look: Option<f64>,
    last_offer: Option<f64>,
    looked: HashMap<String, (f64, u64)>,
    offered: Vec<(f64, String)>,
    declines: u32,
}

impl ThinkAlong {
    /// Hoe lang Nook wacht na een aanbod: langer na elke nee, tot hooguit een half uur.
    pub fn offer_gap(&self) -> f64 {
        (BASE_OFFER_GAP * 2f64.powi(self.declines.min(4) as i32)).min(1800.0)
    }

    /// Moet Nook nu kijken? `app` en `window` beschrijven het voorste venster, `print` de vingerafdruk van de inhoud,
    /// `idle` de seconden sinds de laatste invoer, `muted` de apps waarin je meedenken uitzette.
    pub fn should_look(&mut self, app: &str, window: &str, print: u64, idle: f64, muted: &BTreeMap<String, String>, now: f64) -> bool {
        if app.is_empty() || is_excluded(app) || muted.contains_key(app) {
            return false;
        }
        if idle >= IDLE_LIMIT {
            return false;
        }
        let key = format!("{app}|{window}");
        if key != self.focus_key {
            self.focus_key = key;
            self.focus_since = now;
            return false;
        }
        let since = |t: Option<f64>| t.map(|t| now - t).unwrap_or(f64::INFINITY);
        if now - self.focus_since < SETTLE || since(self.last_look) < MIN_LOOK_GAP || since(self.last_offer) < self.offer_gap() {
            return false;
        }
        if let Some((date, previous)) = self.looked.get(&key) {
            if *previous == print || now - date < SAME_WINDOW_GAP {
                return false;
            }
        }
        true
    }

    pub fn did_look(&mut self, app: &str, window: &str, print: u64, now: f64) {
        self.last_look = Some(now);
        self.looked.insert(format!("{app}|{window}"), (now, print));
        if self.looked.len() > 60 {
            self.looked.retain(|_, (date, _)| now - *date < 3600.0);
        }
    }

    /// Bood Nook dit (of bijna hetzelfde) de laatste uren al aan?
    pub fn already_offered(&self, text: &str, now: f64) -> bool {
        let key = normalize(text);
        self.offered.iter().any(|(date, t)| now - date < 4.0 * 3600.0 && *t == key)
    }

    /// Recente aanbiedingen, zodat het brein zichzelf niet herhaalt.
    pub fn recent_offers(&self, now: f64) -> Vec<String> {
        let recent: Vec<String> = self.offered.iter().filter(|(date, _)| now - date < 4.0 * 3600.0).map(|(_, t)| t.clone()).collect();
        recent[recent.len().saturating_sub(6)..].to_vec()
    }

    pub fn did_offer(&mut self, text: &str, now: f64) {
        self.last_offer = Some(now);
        self.offered.push((now, normalize(text)));
        let excess = self.offered.len().saturating_sub(30);
        self.offered.drain(..excess);
    }

    pub fn accepted(&mut self) {
        self.declines = 0;
    }

    pub fn declined(&mut self) {
        self.declines += 1;
    }

    pub fn declines(&self) -> u32 {
        self.declines
    }
}

fn normalize(text: &str) -> String {
    text.to_lowercase().chars().filter(|c| c.is_alphanumeric() || *c == ' ').collect::<String>().trim().to_string()
}

/// De vraag aan het brein als Nook ongevraagd meekijkt (in het Nederlands, zoals op de Mac).
pub fn request(app: &str, window: &str, earlier: &[String]) -> String {
    let window = if window.is_empty() { String::new() } else { format!(" (venster: {})", window.chars().take(80).collect::<String>()) };
    let mut request = format!(
        "[Meedenken] De gebruiker is nu bezig in {app}{window}. Je kijkt ongevraagd mee. Is er één concreet ding dat jij nu voor hem kunt overnemen met een actie-tool (iets inplannen, een herinnering of open punt, een concept schrijven, een app of link openen), of weet je een duidelijk slimmere of snellere aanpak voor wat hij nu doet? Roep bij een actie meteen de tool aan. Begin je tekst met één korte vraag of tip van hooguit acht woorden, zoals \"Zal ik dit in je agenda zetten?\" of \"Tip: dit kan ook in één keer\", daarna hooguit twee zinnen uitleg. Alleen als het hem echt tijd scheelt of voorkomt dat hij iets vergeet; samenvattingen, complimenten of wat hij al doet tellen niet. Twijfel je, antwoord dan alleen NONE."
    );
    if !earlier.is_empty() {
        request.push_str(&format!(" You recently offered this; do not repeat it: {}.", earlier.join("; ")));
    }
    request
}

/// De vraag bij Meekijken (⌥⌘N op de Mac, Alt+Ctrl+N hier).
pub const LOOK_REQUEST: &str = "This is what the user currently has on screen. Do you see anything you can help with, such as an event, a commitment, or a task? Propose an appropriate action. If nothing relevant: NONE.";

/// Of het brein niets zag ("NONE").
pub fn is_none(body: &str) -> bool {
    let bare: String = body.trim().trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace()).to_uppercase();
    bare == "NONE" || bare.starts_with("NONE")
}

/// De korte zin naast de balk: de eerste zin van het aanbod, hooguit ~64 tekens.
pub fn nudge_line(body: &str, fallback: Option<&str>) -> String {
    let first = body.lines().next().unwrap_or("");
    let mut line = match first.find(['?', '.', '!']) {
        Some(end) => first[..=end].to_string(),
        None => first.to_string(),
    };
    line = line.replace("**", "").trim().to_string();
    if line.is_empty() {
        line = fallback.unwrap_or("").to_string();
    }
    if line.chars().count() > 64 {
        format!("{}…", line.chars().take(62).collect::<String>())
    } else {
        line
    }
}

/// Een aanbod dat nog op een antwoord wacht, ook voor Vandaag als je het miste.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Nudge {
    pub id: String,
    pub line: String,
    pub body: String,
    pub app: String,
    pub window: String,
    pub actions: Vec<crate::brain::PlannedAction>,
    /// Een leesbare regel per actie, voor het voorstel naast de balk.
    #[serde(default)]
    pub steps: Vec<String>,
    pub offers: Vec<String>,
    /// Unix-seconden.
    pub date: i64,
}

impl Nudge {
    /// Een gemist aanbod staat drie kwartier in Vandaag.
    pub fn still_fresh(&self, now: i64) -> bool {
        now - self.date < 45 * 60
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waits_until_you_settle_and_backs_off_after_no() {
        let mut think = ThinkAlong::default();
        let muted = BTreeMap::new();
        assert!(!think.should_look("Kladblok", "plan.txt", 1, 0.0, &muted, 0.0), "net gewisseld");
        assert!(!think.should_look("Kladblok", "plan.txt", 1, 0.0, &muted, 10.0), "nog niet lang genoeg");
        assert!(think.should_look("Kladblok", "plan.txt", 1, 0.0, &muted, 30.0));
        think.did_look("Kladblok", "plan.txt", 1, 30.0);
        assert!(!think.should_look("Kladblok", "plan.txt", 1, 0.0, &muted, 200.0), "zelfde inhoud");
        assert!(!think.should_look("Kladblok", "plan.txt", 2, 0.0, &muted, 200.0), "zelfde venster te snel");
        assert!(think.should_look("Kladblok", "plan.txt", 2, 0.0, &muted, 300.0));
        assert!(!think.should_look("Kladblok", "plan.txt", 3, 500.0, &muted, 400.0), "weg van de computer");

        think.did_offer("Zal ik dit in je agenda zetten?", 300.0);
        think.declined();
        think.declined();
        assert_eq!(think.offer_gap(), 720.0);
        assert!(think.already_offered("zal ik dit in je agenda zetten", 400.0));
        think.accepted();
        assert_eq!(think.offer_gap(), BASE_OFFER_GAP);
        for _ in 0..10 {
            think.declined();
        }
        assert_eq!(think.offer_gap(), 1800.0, "hooguit een half uur");
    }

    #[test]
    fn muted_apps_and_password_managers_are_skipped() {
        let mut think = ThinkAlong::default();
        let muted = BTreeMap::from([("Slack".to_string(), "Slack".to_string())]);
        think.should_look("Slack", "", 1, 0.0, &muted, 0.0);
        assert!(!think.should_look("Slack", "", 1, 0.0, &muted, 60.0));
        assert!(!think.should_look("KeePassXC", "", 1, 0.0, &muted, 60.0));
    }

    #[test]
    fn nudge_line_is_the_first_short_sentence() {
        assert_eq!(nudge_line("**Zal ik dit in je agenda zetten?** Het is vrijdag om 10 uur.", None), "Zal ik dit in je agenda zetten?");
        assert_eq!(nudge_line("", Some("Zal ik dit doen?")), "Zal ik dit doen?");
        let long = "a".repeat(80);
        assert_eq!(nudge_line(&long, None).chars().count(), 63);
        assert!(is_none("NONE."));
        assert!(is_none(" none"));
        assert!(!is_none("Zal ik dit doen?"));
    }

    #[test]
    fn request_mentions_earlier_offers() {
        let text = request("Thunderbird", "Re: offerte", &["zal ik dit inplannen".into()]);
        assert!(text.contains("bezig in Thunderbird (venster: Re: offerte)"));
        assert!(text.ends_with("do not repeat it: zal ik dit inplannen."));
    }
}
