//! Kleine dingen rond een antwoord: startvragen die bij het moment passen, de knop die een fout oplost, een antwoord
//! opschonen en herkennen dat een antwoord geen antwoord is.

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};

use super::matches;
use crate::settings::{detect_language, BrainRuntime, BrainSelection};

/// Wat er nu speelt, voor de startvragen. Wat een platform niet weet, blijft leeg.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Moment {
    /// 0…23
    pub hour: u32,
    /// 1 = maandag … 7 = zondag
    pub weekday: u32,
    /// Het venster dat voor staat: app en titel.
    pub front_app: Option<(String, String)>,
    pub waiting_agent: Option<String>,
    pub failed_agent: Option<String>,
    /// Volgende afspraak binnen vier uur: titel.
    pub next_event: Option<String>,
    pub events_today: usize,
    pub events_tomorrow: usize,
    pub loops: Vec<String>,
    pub active_sources: Vec<String>,
    pub needs_attention: Vec<String>,
}

fn short(text: &str, limit: usize) -> String {
    let clean = text.trim();
    if clean.chars().count() <= limit {
        return clean.into();
    }
    let cut: String = clean.chars().take(limit).collect();
    let end = cut.rfind(' ').unwrap_or(cut.len());
    format!("{}…", &cut[..end])
}

fn ideas_for_app(app: &str, title: &str) -> Vec<String> {
    let name = app.to_lowercase();
    let any = |needles: &[&str]| needles.iter().any(|n| name.contains(n));
    let list: &[&str] = if any(&["thunderbird", "outlook", "mail", "evolution", "geary", "mailspring"]) {
        &["Vat deze mail samen", "Schrijf een antwoord op deze mail"]
    } else if any(&["firefox", "chrome", "chromium", "edge", "brave", "opera", "vivaldi", "safari"]) {
        &["Vat deze pagina samen", "Wat moet ik hiervan onthouden?"]
    } else if any(&["code", "cursor", "zed", "idea", "jetbrains", "sublime", "kate", "vim", "windsurf"]) {
        &["Leg uit wat deze code doet", "Zie je hier een fout?"]
    } else if any(&["terminal", "konsole", "powershell", "cmd", "alacritty", "kitty", "wezterm", "ghostty", "tilix"]) {
        &["Wat betekent deze foutmelding?"]
    } else if any(&["slack", "whatsapp", "telegram", "discord", "teams", "signal"]) {
        &["Help me antwoorden op dit gesprek", "Staat hier iets in om te plannen?"]
    } else if any(&["excel", "calc", "sheets", "airtable"]) {
        &["Maak een grafiek van deze cijfers", "Wat valt op in deze cijfers?"]
    } else if any(&["word", "writer", "notion", "obsidian", "docs", "notepad", "gedit", "onenote"]) {
        &["Maak deze tekst beter", "Vat dit samen in drie punten"]
    } else if any(&["calendar", "agenda"]) {
        &["Waar heb ik deze week nog tijd?", "Hoe druk is mijn week? Maak er een grafiek van"]
    } else if any(&["pdf", "acrobat", "okular", "evince"]) {
        &["Vat dit document samen"]
    } else if any(&["figma", "inkscape", "gimp"]) {
        &["Wat kan beter aan dit ontwerp?"]
    } else if any(&["zoom", "meet", "webex"]) {
        &["Maak notities van dit gesprek"]
    } else {
        &[]
    };
    if list.is_empty() && !title.is_empty() {
        return vec![format!("Help me met {}", short(title, 30))];
    }
    list.iter().map(|s| s.to_string()).collect()
}

/// Startvragen die passen bij wat de gebruiker nu doet: het voorste venster, een afspraak, een wachtende agent,
/// open punten en het moment van de dag. Hoogstens vier, zonder dubbele.
pub fn start(moment: &Moment) -> Vec<String> {
    let mut ideas: Vec<(u32, String)> = vec![];
    if let Some((app, title)) = &moment.front_app {
        ideas.extend(ideas_for_app(app, title).into_iter().map(|i| (100, i)));
    }
    if let Some(agent) = &moment.waiting_agent {
        ideas.push((95, format!("Wat heeft {agent} van me nodig?")));
    } else if let Some(agent) = &moment.failed_agent {
        ideas.push((90, format!("Waarom liep {agent} vast?")));
    }
    if let Some(event) = &moment.next_event {
        ideas.push((85, format!("Bereid me voor op {}", short(event, 26))));
    }
    if moment.hour < 11 {
        ideas.push((70, if moment.events_today > 0 { "Vat mijn dag samen".into() } else { "Wat is vandaag het belangrijkst?".into() }));
    } else if moment.hour >= 16 {
        ideas.push((
            65,
            if moment.events_tomorrow > 0 {
                "Wat staat er morgen op de planning?".into()
            } else {
                "Wat moet ik vandaag nog afronden?".into()
            },
        ));
    }
    if moment.weekday == 5 && moment.hour >= 14 {
        ideas.push((60, "Hoe ging mijn week?".into()));
    }
    if moment.weekday == 1 && moment.hour < 12 {
        ideas.push((60, "Hoe druk is mijn week? Maak er een grafiek van".into()));
    }
    match moment.loops.len() {
        0 => {}
        1 => ideas.push((55, format!("Help me met {}", short(&moment.loops[0], 28)))),
        n => ideas.push((55, format!("Help me mijn {n} open punten afronden"))),
    }
    let active: HashSet<&str> = moment.active_sources.iter().map(String::as_str).collect();
    if active.contains("mail") {
        ideas.push((50, "Welke mail moet ik beantwoorden?".into()));
    }
    if active.contains("notes") {
        ideas.push((52, "Wat staat er in mijn Notities?".into()));
    }
    if active.contains("reminders") {
        ideas.push((51, "Welke taken heb ik openstaan?".into()));
    }
    if let Some(source) = moment.needs_attention.first() {
        ideas.push((52, format!("Wat moet ik doen met {source}?")));
    }
    if active.contains("github") {
        ideas.push((45, "Wat wacht er op mij op GitHub?".into()));
    }
    if active.contains("stripe") {
        ideas.push((40, "Hoe gaat de omzet deze maand? Met grafiek".into()));
    }
    // Een open vraag die altijd werkt, en een paar dingen die Nook zonder koppelingen kan.
    ideas.push((10, if moment.hour < 12 { "Vat mijn dag samen".into() } else { "Waar kun je me nu mee helpen?".into() }));
    ideas.push((9, "Schrijf een mail".into()));
    ideas.push((8, "Wat is het weer morgen?".into()));
    ideas.sort_by_key(|i| std::cmp::Reverse(i.0));
    let mut seen = HashSet::new();
    ideas.into_iter().map(|i| i.1).filter(|t| seen.insert(t.to_lowercase())).take(4).collect()
}

/// Wat de knop naast een chatfout moet doen. Een kale knop "Instellingen" verbergt wat er mis is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Recovery {
    /// Het gekozen model ontbreekt: kies of installeer er een bij Instellingen › Brein.
    ChooseModel,
    /// Ollama of LM Studio antwoordt niet: start hem (en probeer opnieuw).
    OpenLocalServer {
        name: String,
    },
    /// De externe AI weigert de sleutel of heeft er geen.
    ReconnectBrain,
    /// Een gekoppelde dienst weigert zijn inloggegevens.
    ReconnectConnection,
    OpenSettings,
}

impl Recovery {
    pub fn for_error(text: &str, selection: &BrainSelection) -> Self {
        let lower = text.to_lowercase();
        let mentions = |words: &[&str]| words.iter().any(|w| lower.contains(w));
        let credentials = mentions(&[
            "credentials were rejected",
            "inloggegevens",
            "api key",
            "api-sleutel",
            "sleutel",
            "no key",
            "rejected (401",
            "rejected (403",
            "unauthorized",
            "weigerde",
        ]);
        match selection.runtime {
            BrainRuntime::Ollama | BrainRuntime::Lmstudio => {
                if mentions(&["no model", "geen model", "model not found", "not found", "bestaat niet", "kies eerst een model"]) {
                    Self::ChooseModel
                } else {
                    Self::OpenLocalServer {
                        name: if selection.runtime == BrainRuntime::Ollama { "Ollama".into() } else { "LM Studio".into() },
                    }
                }
            }
            BrainRuntime::External => {
                if mentions(&["credentials were rejected", "inloggegevens"]) && !mentions(&["api key", "api-sleutel"]) {
                    Self::ReconnectConnection
                } else if credentials {
                    Self::ReconnectBrain
                } else if mentions(&["kies eerst een model", "bestaat niet bij"]) {
                    Self::ChooseModel
                } else {
                    Self::OpenSettings
                }
            }
        }
    }

    pub fn title(&self) -> String {
        match self {
            Self::ChooseModel => "Kies een model".into(),
            Self::OpenLocalServer { name } => format!("Hoe start ik {name}?"),
            Self::ReconnectBrain | Self::ReconnectConnection => "Opnieuw koppelen".into(),
            Self::OpenSettings => "Instellingen".into(),
        }
    }
}

/// Haalt denkblokken, tool-aanroepen als ruwe tekst en losse backslashes uit het antwoord.
pub fn clean_reply(text: &str) -> String {
    let mut cleaned = rx!(r"<think>[\s\S]*?</think>").replace_all(text, "").to_string();
    if cleaned.contains('{') {
        cleaned = rx!(r#"(?m)^\s*\{\s*"(name|tool)"\s*:.*\}\s*$"#).replace_all(&cleaned, "").to_string();
    }
    cleaned = rx!(r"(?m)\\\s*$").replace_all(&cleaned, "").to_string();
    cleaned.trim().to_string()
}

/// Een antwoord dat geen antwoord is: code of JSON bij een vraag die niet over code gaat, of in een andere taal dan gevraagd.
pub fn looks_broken(answer: &str, question: &str, expected: Option<&str>) -> bool {
    let trimmed = answer.trim();
    if trimmed.is_empty() {
        return false;
    }
    let about_code = matches(
        rx!(r"(?i)code|json|script|programm\w*|regex|sql|swift|python|javascript|rust|html|css|\bapi\b|terminal|commando"),
        question,
    );
    if !about_code && (trimmed.contains("```") || trimmed.starts_with('{') || trimmed.starts_with('[')) {
        return true;
    }
    let prose = rx!(r"```[\s\S]*?```|\[[0-9]+\]|\*\*").replace_all(trimmed, "").to_string();
    if let Some(expected) = expected {
        if prose.chars().count() >= 40 {
            if let Some(answered) = detect_language(&prose) {
                return answered != expected;
            }
        }
    }
    false
}

/// Een korte lijst uit wat er opgezocht is, voor als het model geen bruikbaar antwoord gaf.
pub fn digest(fetched: &[String]) -> String {
    let all = fetched.join("\n");
    let lines: Vec<&str> = all.lines().collect();
    let headings: Vec<String> = lines.iter().filter_map(|l| l.strip_prefix("### ")).take(10).map(|h| format!("- {h}")).collect();
    if !headings.is_empty() {
        return format!("Dit vond ik:\n\n{}", headings.join("\n"));
    }
    let items: Vec<&str> = lines.iter().filter(|l| l.starts_with("- ") || l.ends_with(':')).take(20).copied().collect();
    if !items.is_empty() {
        return format!("Dit vond ik:\n\n{}", items.join("\n"));
    }
    format!("Dit vond ik:\n\n{}", all.chars().take(800).collect::<String>())
}

/// Talen van de instellingen in de namen die [`detect_language`] geeft.
pub fn expected_language(setting: &str, question: &str) -> Option<&'static str> {
    let map: BTreeMap<&str, &str> = [("nl", "Dutch"), ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish")].into();
    if setting == "auto" {
        detect_language(question)
    } else {
        map.get(setting).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::AIProvider;

    #[test]
    fn suggestions_fit_the_moment() {
        let morning = start(&Moment { hour: 8, weekday: 1, events_today: 2, ..Default::default() });
        assert_eq!(morning[0], "Vat mijn dag samen");
        assert!(morning.contains(&"Hoe druk is mijn week? Maak er een grafiek van".to_string()));
        let busy = start(&Moment {
            hour: 14,
            weekday: 3,
            front_app: Some(("Firefox".into(), "Nieuws".into())),
            next_event: Some("Overleg met de klant over de offerte van volgend jaar".into()),
            loops: vec!["Lisa bellen".into()],
            ..Default::default()
        });
        assert_eq!(busy[0], "Vat deze pagina samen");
        assert!(busy.iter().any(|s| s.starts_with("Bereid me voor op Overleg met de klant")));
        assert_eq!(busy.len(), 4);
        assert_eq!(start(&Moment { hour: 13, weekday: 3, ..Default::default() })[0], "Waar kun je me nu mee helpen?");
    }

    #[test]
    fn the_button_fits_the_error() {
        let ollama = BrainSelection::resolve(AIProvider::Ollama, "llama3.2".into());
        assert_eq!(Recovery::for_error("Ollama draait niet. Start hem.", &ollama), Recovery::OpenLocalServer { name: "Ollama".into() });
        assert_eq!(Recovery::for_error("Model x bestaat niet bij Ollama.", &ollama), Recovery::ChooseModel);
        let claude = BrainSelection::resolve(AIProvider::Claude, "claude-haiku-5-5".into());
        assert_eq!(Recovery::for_error("Er is nog geen Anthropic API-sleutel.", &claude), Recovery::ReconnectBrain);
        assert_eq!(Recovery::for_error("Limiet bereikt bij Claude.", &claude), Recovery::OpenSettings);
    }

    #[test]
    fn cleaning_and_broken_answers() {
        assert_eq!(clean_reply("<think>hmm</think>Hallo\n{\"name\": \"x\", \"parameters\": {}}"), "Hallo");
        assert!(looks_broken("```json\n{}\n```", "wat staat er morgen", Some("Dutch")));
        assert!(!looks_broken("```rust\nfn main() {}\n```", "schrijf rust code", Some("Dutch")));
        assert!(looks_broken(
            "Tomorrow you have a meeting with the team and a call with Lisa about the quote.",
            "wat staat er morgen",
            Some("Dutch")
        ));
        assert!(!looks_broken(
            "Morgen heb je een overleg met het team en een call met Lisa over de offerte.",
            "wat staat er morgen",
            Some("Dutch")
        ));
        assert_eq!(digest(&["### Offerte\nx\n### Factuur".into()]), "Dit vond ik:\n\n- Offerte\n- Factuur");
    }
}
