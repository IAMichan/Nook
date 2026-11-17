//! Double Tap suggestions (`DoubleTapSuggest` on the Mac): what Nook could do with what is in front of the user right
//! now, as one-click chips under the quick field, and the line above the field that says where Nook will work. Text
//! selected where Nook can type gets "Improve this", a translation, "Shorten this" and "Explain"; an empty reply box gets
//! "Write a reply"; a form with empty fields gets "Fill in the form"; a window that names a day gets "Put this in my
//! calendar"; and the last things the user asked come back as chips too. Every chip is an ordinary request in the
//! user's language, so it takes the same path as one typed by hand.
//!
//! The quick field itself is SV-45; this is the logic it shows.

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc};
use serde::Serialize;

use crate::i18n::{tr, trf};

/// What has the keyboard in the window in front.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Focus {
    /// No text that takes typing (a page, a list, the desktop).
    #[default]
    None,
    /// A one-line field (a search box, a subject).
    Field,
    /// A text area or a document (a mail body, a page in Word, a note).
    Text,
}

/// What is in front of the user at the moment of the double tap, as far as suggestions need it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Scene {
    /// The app's name as the platform gives it ("WhatsApp", "Microsoft Outlook").
    pub app: String,
    pub focus: Focus,
    /// The selected text in the focused field.
    pub selection: String,
    /// The focused field holds no text yet.
    pub focus_empty: bool,
    /// The field's placeholder ("Write a message…"), which tells a reply box from a document.
    pub placeholder: String,
    /// Empty fields Nook may fill in the window in front.
    pub empty_fields: usize,
    /// The text of the window in front, as the active brain may see it.
    pub window_text: String,
    /// Read by Nook's browser extension in the tab in front.
    pub via_extension: bool,
    /// An app Nook never reads or types in (a password manager, a terminal).
    pub blocked: bool,
}

/// One chip: the request it sends and its icon (a Lucide name).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Suggestion {
    pub text: String,
    pub icon: &'static str,
}

/// The line above the field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Hint {
    pub text: String,
    pub icon: &'static str,
    /// "Via your browser", when the extension reads and fills the page.
    pub badge: Option<String>,
}

/// At most this many chips: the field stays a field, not a menu.
pub const MAX_SUGGESTIONS: usize = 4;
/// The requests remembered for the chips, newest first.
pub const MAX_RECENTS: usize = 8;

/// Apps whose text box is where you answer someone, by a word in their name.
const REPLY_APPS: &[&str] = &[
    "whatsapp",
    "telegram",
    "signal",
    "slack",
    "teams",
    "discord",
    "messenger",
    "instagram",
    "outlook",
    "thunderbird",
    "mail",
    "linkedin",
    "skype",
    "element",
    "zoom",
];

/// Placeholder words of a reply box, in every language Nook speaks.
const REPLY_PLACEHOLDER_WORDS: &[&str] = &[
    "message",
    "reply",
    "answer",
    "respond",
    "comment",
    "bericht",
    "antwoord",
    "reageer",
    "reactie",
    "nachricht",
    "antwort",
    "antworten",
    "kommentar",
    "réponse",
    "répondre",
    "repondre",
    "commentaire",
    "mensaje",
    "respuesta",
    "responder",
    "comentario",
];

/// An empty box in a chat or mail app, or one whose placeholder asks for a message: where you answer someone.
pub fn is_reply_box(scene: &Scene) -> bool {
    let app = scene.app.to_lowercase();
    if REPLY_APPS.iter().any(|a| app.contains(a)) {
        return true;
    }
    let placeholder = scene.placeholder.to_lowercase();
    !placeholder.is_empty() && REPLY_PLACEHOLDER_WORDS.iter().any(|w| placeholder.contains(w))
}

/// The language a selection should be translated into: the app's language when the selection is in another one, else
/// English (or nothing when the app's language is English too). `None` when the language was not recognized.
pub fn translation_target(selection_language: Option<&str>, app_language: &str) -> Option<String> {
    let source: String = selection_language?.chars().take(2).collect::<String>().to_lowercase();
    if source.is_empty() {
        return None;
    }
    if source != app_language {
        return Some(app_language.to_string());
    }
    (app_language != "en").then(|| "en".to_string())
}

fn language_name(code: &str) -> &'static str {
    match code {
        "nl" => tr("Nederlands", "Dutch"),
        "de" => tr("Duits", "German"),
        "fr" => tr("Frans", "French"),
        "es" => tr("Spaans", "Spanish"),
        _ => tr("Engels", "English"),
    }
}

const MONTHS: &[&str] = &[
    "jan",
    "januari",
    "january",
    "januar",
    "janvier",
    "enero",
    "feb",
    "februari",
    "february",
    "februar",
    "février",
    "fevrier",
    "febrero",
    "maart",
    "march",
    "märz",
    "marz",
    "mars",
    "marzo",
    "apr",
    "april",
    "avril",
    "abril",
    "mei",
    "may",
    "mai",
    "mayo",
    "jun",
    "juni",
    "june",
    "juin",
    "junio",
    "jul",
    "juli",
    "july",
    "juillet",
    "julio",
    "aug",
    "augustus",
    "august",
    "août",
    "aout",
    "agosto",
    "sep",
    "sept",
    "september",
    "septembre",
    "septiembre",
    "okt",
    "oct",
    "oktober",
    "october",
    "octobre",
    "octubre",
    "nov",
    "november",
    "novembre",
    "noviembre",
    "dec",
    "dez",
    "december",
    "dezember",
    "décembre",
    "decembre",
    "diciembre",
    "dic",
];

const DAY_WORDS: &[&str] = &[
    "today",
    "tomorrow",
    "vandaag",
    "morgen",
    "overmorgen",
    "heute",
    "übermorgen",
    "demain",
    "aujourd'hui",
    "hoy",
    "mañana",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "maandag",
    "dinsdag",
    "woensdag",
    "donderdag",
    "vrijdag",
    "zaterdag",
    "zondag",
    "montag",
    "dienstag",
    "mittwoch",
    "donnerstag",
    "freitag",
    "samstag",
    "sonntag",
    "lundi",
    "mardi",
    "mercredi",
    "jeudi",
    "vendredi",
    "samedi",
    "dimanche",
    "lunes",
    "martes",
    "miércoles",
    "jueves",
    "viernes",
    "sábado",
    "domingo",
];

/// Whether the window names a day: a date from yesterday to a year from now, a month with a day number, or a day word.
/// A clock time alone ("14:30"), which nearly every window shows, does not count. Simpler than the Mac's
/// `NSDataDetector`: a date without a year is taken as meant.
pub fn has_dates(text: &str, now: DateTime<Utc>) -> bool {
    let sample: String = text.chars().take(4_000).collect::<String>().to_lowercase();
    if sample.trim().is_empty() {
        return false;
    }
    let words: Vec<&str> = sample.split(|c: char| !(c.is_alphanumeric() || c == '\'')).filter(|w| !w.is_empty()).collect();
    if words.iter().any(|w| DAY_WORDS.contains(w)) {
        return true;
    }
    // "12 november", "november 12", "14 nov."
    let is_day = |w: &str| w.parse::<u32>().is_ok_and(|n| (1..=31).contains(&n));
    for pair in words.windows(2) {
        if (is_day(pair[0]) && MONTHS.contains(&pair[1])) || (MONTHS.contains(&pair[0]) && is_day(pair[1])) {
            return true;
        }
    }
    // ISO dates within range; "11-12", "11/12/2026" as a day and a month.
    let (from, until) = ((now - Duration::days(1)).date_naive(), (now + Duration::days(366)).date_naive());
    for token in sample.split(|c: char| c.is_whitespace() || ",;()[]".contains(c)) {
        let token = token.trim_matches(|c: char| !c.is_ascii_digit());
        let parts: Vec<&str> = token.split(['-', '/', '.']).collect();
        let numbers: Vec<u32> = parts.iter().filter_map(|p| p.parse().ok()).collect();
        if numbers.len() != parts.len() || !(2..=3).contains(&numbers.len()) {
            continue;
        }
        if parts[0].len() == 4 {
            if let Some(date) = numbers.get(1..3).and_then(|md| NaiveDate::from_ymd_opt(numbers[0] as i32, md[0], md[1])) {
                if date >= from && date <= until {
                    return true;
                }
            }
            continue;
        }
        let year = numbers.get(2).map_or(now.year(), |y| if *y < 100 { 2000 + *y as i32 } else { *y as i32 });
        let valid = |d: u32, m: u32| NaiveDate::from_ymd_opt(year, m, d).is_some_and(|date| date >= from && date <= until);
        // A clock ("14.30") has no third part and a second part above 12 is a minute, not a month.
        if token.contains('.') && numbers.len() == 2 {
            continue;
        }
        if valid(numbers[0], numbers[1]) || valid(numbers[1], numbers[0]) {
            return true;
        }
    }
    false
}

/// The chips for what is in front, then the most recent requests that are not among them, at most `MAX_SUGGESTIONS`.
pub fn suggestions(
    scene: Option<&Scene>,
    recents: &[String],
    app_language: &str,
    selection_language: Option<&str>,
    now: DateTime<Utc>,
) -> Vec<Suggestion> {
    let mut chips: Vec<Suggestion> = vec![];
    let chip = |text: String, icon: &'static str| Suggestion { text, icon };
    if let Some(scene) = scene {
        let selected = scene.selection.trim();
        if scene.focus != Focus::None && !selected.is_empty() {
            chips.push(chip(tr("Verbeter dit", "Improve this").into(), "sparkles"));
            if let Some(target) = translation_target(selection_language, app_language) {
                chips.push(chip(
                    trf("Vertaal dit naar het {language}", "Translate this into {language}", &[("language", &language_name(&target))]),
                    "globe",
                ));
            }
            if selected.chars().count() > 120 {
                chips.push(chip(tr("Verkort dit", "Shorten this").into(), "fold-vertical"));
            }
            chips.push(chip(tr("Leg de geselecteerde tekst uit", "Explain the selected text").into(), "message-circle-question"));
        } else {
            let reply = is_reply_box(scene);
            if scene.empty_fields >= 2 || (scene.empty_fields >= 1 && scene.focus == Focus::Field && scene.focus_empty && !reply) {
                chips.push(chip(tr("Vul het formulier in", "Fill in the form").into(), "list"));
            }
            if scene.focus != Focus::None && reply && scene.focus_empty {
                chips.push(chip(tr("Schrijf een antwoord", "Write a reply").into(), "reply"));
            } else if scene.focus == Focus::Text && !scene.focus_empty {
                chips.push(chip(tr("Schrijf verder", "Write more").into(), "pen-line"));
            }
            if has_dates(&scene.window_text, now) {
                chips.push(chip(tr("Zet dit in mijn agenda", "Put this in my calendar").into(), "calendar-plus"));
            }
            if scene.window_text.chars().count() >= 600 {
                chips.push(chip(tr("Vat dit venster samen", "Summarize this window").into(), "align-left"));
            }
        }
    }
    chips.truncate(MAX_SUGGESTIONS);
    // What the user asked lately, so a request they repeat is one click.
    for recent in recents {
        if chips.len() >= MAX_SUGGESTIONS {
            break;
        }
        if !chips.iter().any(|c| c.text.to_lowercase() == recent.to_lowercase()) {
            chips.push(chip(recent.clone(), "history"));
        }
    }
    chips
}

/// The line above the field: the app, then what Nook can do there, so the field says what it is for before you type.
/// `scene` is `None` while Nook is still reading what is in front.
pub fn hint(app: &str, scene: Option<&Scene>) -> Hint {
    let badge = scene.filter(|s| s.via_extension).map(|_| tr("Via je browser", "Via your browser").to_string());
    let line = |text: String, icon: &'static str| Hint { text, icon, badge: badge.clone() };
    if app.is_empty() {
        return Hint {
            text: tr(
                "Nook schrijft, past aan of vult in waar je cursor staat, of doet wat je vraagt",
                "Nook writes, changes or fills in where your cursor is, or does what you ask",
            )
            .into(),
            icon: "sparkles",
            badge: None,
        };
    }
    let Some(scene) = scene else {
        return Hint {
            text: trf("{app} · Kijkt wat er voor je staat…", "{app} · Looking at what is in front…", &[("app", &app)]),
            icon: "eye",
            badge: None,
        };
    };
    if scene.blocked {
        return Hint { text: trf("Nook typt niet in {app}", "Nook doesn't type in {app}", &[("app", &app)]), icon: "hand", badge: None };
    }
    let selected = scene.selection.trim();
    if scene.focus != Focus::None && !selected.is_empty() {
        let n = selected.split_whitespace().count().to_string();
        let text = if n == "1" {
            trf(
                "{app} · {n} woord geselecteerd: verbeteren, vertalen of uitleggen",
                "{app} · {n} word selected: improve, translate or explain it",
                &[("app", &app), ("n", &n)],
            )
        } else {
            trf(
                "{app} · {n} woorden geselecteerd: verbeteren, vertalen of uitleggen",
                "{app} · {n} words selected: improve, translate or explain them",
                &[("app", &app), ("n", &n)],
            )
        };
        return line(text, "text-quote");
    }
    if scene.empty_fields >= 2 || (scene.empty_fields == 1 && scene.focus == Focus::Field && !is_reply_box(scene)) {
        let n = scene.empty_fields.to_string();
        let text = if scene.empty_fields == 1 {
            trf("{app} · {n} leeg veld: Nook kan het invullen", "{app} · {n} empty field: Nook can fill it in", &[("app", &app), ("n", &n)])
        } else {
            trf(
                "{app} · {n} lege velden: Nook kan ze invullen",
                "{app} · {n} empty fields: Nook can fill them in",
                &[("app", &app), ("n", &n)],
            )
        };
        return line(text, "list");
    }
    if scene.focus != Focus::None && is_reply_box(scene) {
        return line(
            trf("{app} · Antwoordveld: Nook kan het antwoord schrijven", "{app} · Reply box: Nook can write the reply", &[("app", &app)]),
            "reply",
        );
    }
    if scene.focus != Focus::None {
        return line(
            trf(
                "{app} · Nook schrijft of past tekst aan bij je cursor",
                "{app} · Nook writes or changes text at your cursor",
                &[("app", &app)],
            ),
            "text-cursor",
        );
    }
    line(
        trf("{app} · Nook kan dit venster lezen en ermee aan de slag", "{app} · Nook can read this window and act on it", &[("app", &app)]),
        "app-window",
    )
}

/// Remembers a request typed in the quick field, newest first, without repeats.
pub fn remembering(request: &str, recents: &[String]) -> Vec<String> {
    let trimmed = request.trim();
    if trimmed.is_empty() || trimmed.chars().count() > 120 {
        return recents.to_vec();
    }
    std::iter::once(trimmed.to_string())
        .chain(recents.iter().filter(|r| r.to_lowercase() != trimmed.to_lowercase()).cloned())
        .take(MAX_RECENTS)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 17, 10, 0, 0).unwrap()
    }

    fn texts(chips: &[Suggestion]) -> Vec<&str> {
        chips.iter().map(|c| c.text.as_str()).collect()
    }

    #[test]
    fn a_selection_gets_rewrites_and_a_translation() {
        let scene = Scene { focus: Focus::Text, selection: "x ".repeat(80), ..Default::default() };
        let chips = suggestions(Some(&scene), &[], "en", Some("nl-NL"), now());
        assert_eq!(texts(&chips), ["Improve this", "Translate this into English", "Shorten this", "Explain the selected text"]);
        let short = Scene { focus: Focus::Field, selection: "hallo".into(), ..Default::default() };
        assert_eq!(texts(&suggestions(Some(&short), &[], "en", Some("en"), now())), ["Improve this", "Explain the selected text"]);
    }

    #[test]
    fn a_reply_box_a_form_and_a_window_with_a_day() {
        let reply = Scene { app: "WhatsApp".into(), focus: Focus::Text, focus_empty: true, ..Default::default() };
        assert_eq!(texts(&suggestions(Some(&reply), &[], "en", None, now()))[0], "Write a reply");
        let form =
            Scene { app: "Edge".into(), empty_fields: 3, window_text: "Meeting on 12 november at 14:30".into(), ..Default::default() };
        assert_eq!(texts(&suggestions(Some(&form), &[], "en", None, now())), ["Fill in the form", "Put this in my calendar"]);
        let doc = Scene { app: "Word".into(), focus: Focus::Text, focus_empty: false, window_text: "y".repeat(700), ..Default::default() };
        assert_eq!(texts(&suggestions(Some(&doc), &[], "en", None, now())), ["Write more", "Summarize this window"]);
    }

    #[test]
    fn recents_fill_the_room_without_repeats() {
        let recents = vec!["Write a reply".to_string(), "Book a table".into(), "Call Lisa".into(), "One".into(), "Two".into()];
        let reply = Scene { app: "Slack".into(), focus: Focus::Field, focus_empty: true, ..Default::default() };
        let chips = suggestions(Some(&reply), &recents, "en", None, now());
        assert_eq!(texts(&chips), ["Write a reply", "Book a table", "Call Lisa", "One"]);
        assert_eq!(chips[1].icon, "history");
        assert_eq!(texts(&suggestions(None, &recents[..1], "en", None, now())), ["Write a reply"]);
        let remembered = remembering(" Call Lisa ", &recents);
        assert_eq!(remembered[0], "Call Lisa");
        assert_eq!(remembered.iter().filter(|r| r.as_str() == "Call Lisa").count(), 1);
        assert_eq!(remembering(&"x".repeat(200), &recents), recents);
    }

    #[test]
    fn days_are_found_but_a_clock_alone_is_not() {
        assert!(has_dates("See you tomorrow", now()));
        assert!(has_dates("Afspraak op 3 dec.", now()));
        assert!(has_dates("Deadline 2026-12-01", now()));
        assert!(has_dates("Delivery 24/12", now()));
        assert!(!has_dates("Updated 14:30 and 14.30", now()));
        assert!(!has_dates("Released 2019-01-01", now()), "outside the year ahead");
        assert!(!has_dates("", now()));
    }

    #[test]
    fn the_hint_says_where_nook_works() {
        assert!(hint("", None).text.starts_with("Nook writes, changes or fills in"));
        assert_eq!(hint("Word", None).text, "Word · Looking at what is in front…");
        let blocked = Scene { blocked: true, ..Default::default() };
        assert_eq!(hint("1Password", Some(&blocked)).text, "Nook doesn't type in 1Password");
        let one = Scene { focus: Focus::Text, selection: "word".into(), via_extension: true, ..Default::default() };
        let h = hint("Edge", Some(&one));
        assert_eq!(h.text, "Edge · 1 word selected: improve, translate or explain it");
        assert_eq!(h.badge.as_deref(), Some("Via your browser"));
        let form = Scene { empty_fields: 1, focus: Focus::Field, ..Default::default() };
        assert_eq!(hint("Edge", Some(&form)).text, "Edge · 1 empty field: Nook can fill it in");
        assert_eq!(hint("Explorer", Some(&Scene::default())).icon, "app-window");
        assert_eq!(translation_target(Some("en"), "en"), None);
        assert_eq!(translation_target(Some("de"), "de").as_deref(), Some("en"));
        assert_eq!(translation_target(None, "nl"), None);
    }
}
