//! Kleine dingen rond een antwoord: startvragen die bij het moment passen, de knop die een fout oplost, een antwoord
//! opschonen en herkennen dat een antwoord geen antwoord is.

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};

use super::matches;
use crate::i18n::{tr, trf};
use crate::settings::{detect_language, BrainRuntime, BrainSelection};

/// What is going on now, for the starters (`startSuggestions` on the Mac). What a platform does not know stays empty.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Moment {
    /// 0…23
    pub hour: u32,
    /// 1 = Monday … 7 = Sunday
    pub weekday: u32,
    /// The window in front: app and title.
    pub front_app: Option<(String, String)>,
    pub waiting_agent: Option<String>,
    pub failed_agent: Option<String>,
    /// The next event within six hours: its title.
    pub next_event: Option<String>,
    pub events_today: usize,
    pub events_tomorrow: usize,
    pub loops: Vec<String>,
    pub active_sources: Vec<String>,
    /// A pull request whose review is asked of the user: its title.
    pub github_review: Option<String>,
    /// A pull request of the user's whose checks fail: its title.
    pub github_failing: Option<String>,
    /// Who wrote the newest unread mail.
    pub mail_from: Option<String>,
    /// Some reminders are overdue; `open_tasks`: some are open.
    pub overdue_tasks: bool,
    pub open_tasks: bool,
    /// Nook already has an automation of its own (then the secretary line is not offered).
    pub has_nook_task: bool,
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
    let list: Vec<&str> = if any(&["thunderbird", "outlook", "mail", "evolution", "geary", "mailspring"]) {
        vec![tr("Schrijf een antwoord op deze mail", "Write a reply to this email"), tr("Vat deze mail samen", "Summarize this email")]
    } else if any(&["firefox", "chrome", "chromium", "edge", "brave", "opera", "vivaldi", "safari"]) {
        vec![tr("Vat deze pagina samen", "Summarize this page"), tr("Wat moet ik hiervan onthouden?", "What should I remember from this?")]
    } else if any(&["code", "cursor", "zed", "idea", "jetbrains", "sublime", "kate", "vim", "windsurf"]) {
        vec![tr("Zie je hier een fout?", "Do you see a bug here?"), tr("Leg uit wat deze code doet", "Explain what this code does")]
    } else if any(&["terminal", "konsole", "powershell", "cmd", "alacritty", "kitty", "wezterm", "ghostty", "tilix"]) {
        vec![tr("Wat betekent deze foutmelding?", "What does this error mean?")]
    } else if any(&["slack", "whatsapp", "telegram", "discord", "teams", "signal"]) {
        vec![
            tr("Help me antwoorden op dit gesprek", "Help me reply to this conversation"),
            tr("Staat hier iets in om te plannen?", "Is there anything here to schedule?"),
        ]
    } else if any(&["excel", "calc", "sheets", "airtable"]) {
        vec![
            tr("Wat valt op in deze cijfers?", "What stands out in these numbers?"),
            tr("Maak een grafiek van deze cijfers", "Make a chart of these numbers"),
        ]
    } else if any(&["word", "writer", "notion", "obsidian", "docs", "notepad", "gedit", "onenote"]) {
        vec![tr("Maak deze tekst beter", "Improve this text"), tr("Vat dit samen in drie punten", "Summarize this in three points")]
    } else if any(&["calendar", "agenda"]) {
        vec![
            tr("Waar heb ik deze week nog tijd?", "Where do I still have time this week?"),
            tr("Hoe druk is mijn week? Maak er een grafiek van", "How busy is my week? Make it a chart"),
        ]
    } else if any(&["pdf", "acrobat", "okular", "evince"]) {
        vec![tr("Vat dit document samen", "Summarize this document")]
    } else if any(&["figma", "inkscape", "gimp"]) {
        vec![tr("Wat kan beter aan dit ontwerp?", "What could be better in this design?")]
    } else if any(&["zoom", "meet", "webex"]) {
        vec![tr("Maak notities van dit gesprek", "Take notes of this call")]
    } else {
        vec![]
    };
    if list.is_empty() && !title.is_empty() {
        return vec![trf("Help me met {what}", "Help me with {what}", &[("what", &short(title, 30))])];
    }
    list.into_iter().map(str::to_string).collect()
}

/// Starters built from what is actually going on (`startSuggestions` on the Mac): the window in front, the agent that
/// needs the user, a review or failing build on GitHub, the next meeting, overdue tasks, unread mail, the time of day
/// and the week. Each names something real when it can, one per topic, at most four.
pub fn start(moment: &Moment) -> Vec<String> {
    let mut ideas: Vec<(u32, &str, String)> = vec![];
    let active: HashSet<&str> = moment.active_sources.iter().map(String::as_str).collect();
    if let Some((app, title)) = &moment.front_app {
        if let Some(idea) = ideas_for_app(app, title).into_iter().next() {
            ideas.push((100, "front", idea));
        }
    }
    if let Some(agent) = &moment.waiting_agent {
        ideas.push((95, "agent", trf("Wat heeft {agent} van me nodig?", "What does {agent} need from me?", &[("agent", agent)])));
    } else if let Some(agent) = &moment.failed_agent {
        ideas.push((90, "agent", trf("Waarom liep {agent} vast?", "Why did {agent} get stuck?", &[("agent", agent)])));
    }
    if let Some(title) = &moment.github_review {
        ideas.push((88, "github", trf("Review “{title}” voor me", "Review “{title}” for me", &[("title", &short(title, 34))])));
    } else if let Some(title) = &moment.github_failing {
        ideas.push((
            86,
            "github",
            trf("Waarom faalt de CI van “{title}”?", "Why is CI failing on “{title}”?", &[("title", &short(title, 30))]),
        ));
    }
    if let Some(event) = &moment.next_event {
        ideas.push((80, "calendar", trf("Bereid me voor op {event}", "Prepare me for {event}", &[("event", &short(event, 26))])));
    }
    if moment.overdue_tasks {
        ideas.push((78, "tasks", tr("Plan mijn verlopen taken opnieuw in", "Reschedule my overdue tasks").into()));
    } else if moment.open_tasks && moment.hour < 17 {
        ideas.push((56, "tasks", tr("Plan mijn open taken rond mijn agenda", "Fit my open tasks around my calendar").into()));
    }
    if active.contains("mail") {
        match &moment.mail_from {
            Some(from) => ideas.push((
                60,
                "mail",
                trf("Vat de mail van {name} samen", "Summarize the mail from {name}", &[("name", &short(from, 22))]),
            )),
            None => ideas.push((50, "mail", tr("Welke mail moet ik beantwoorden?", "Which email should I reply to?").into())),
        }
    }
    let priority = || tr("Wat is vandaag het belangrijkst?", "What matters most today?").to_string();
    if moment.hour < 11 {
        let line = if moment.events_today == 0 {
            priority()
        } else {
            tr("Plan mijn dag rond mijn afspraken", "Plan my day around my meetings").into()
        };
        ideas.push((70, "day", line));
    } else if moment.hour < 16 {
        let line = if active.contains("calendar") || moment.events_today > 0 {
            tr("Waar heb ik vandaag nog tijd?", "Where do I still have time today?").into()
        } else {
            priority()
        };
        ideas.push((54, "day", line));
    } else if moment.events_tomorrow > 0 {
        ideas.push((65, "day", tr("Wat staat er morgen op de planning?", "What's planned for tomorrow?").into()));
    } else {
        ideas.push((65, "day", tr("Wat moet ik vandaag nog afronden?", "What do I still need to finish today?").into()));
    }
    if moment.weekday == 5 && moment.hour >= 14 {
        ideas.push((62, "week", tr("Hoe ging mijn week?", "How did my week go?").into()));
    }
    if moment.weekday == 1 && moment.hour < 12 {
        ideas.push((62, "week", tr("Hoe druk is mijn week? Maak er een grafiek van", "How busy is my week? Make it a chart").into()));
    }
    if moment.loops.len() > 3 {
        let n = moment.loops.len().to_string();
        ideas.push((52, "loops", trf("Help me mijn {n} open punten afronden", "Help me finish my {n} open items", &[("n", &n)])));
    }
    if active.contains("stripe") {
        ideas.push((40, "stripe", tr("Hoe gaat de omzet deze maand? Met grafiek", "How is revenue this month? With a chart").into()));
    }
    if !moment.has_nook_task {
        ideas.push((
            45,
            "secretary",
            tr("Geef me elke ochtend om 9:00 een update over mijn berichten", "Give me an update on my messages every morning at 9:00")
                .into(),
        ));
    }
    // Open-ended prompts that always work.
    ideas.push((10, "fallback", tr("Vat mijn dag samen", "Summarize my day").into()));
    ideas.push((9, "anything", tr("Waar kun je me nu mee helpen?", "What can you help me with right now?").into()));
    ideas.sort_by_key(|i| std::cmp::Reverse(i.0));
    let (mut topics, mut texts) = (HashSet::new(), HashSet::new());
    ideas.into_iter().filter(|(_, topic, text)| topics.insert(*topic) && texts.insert(text.to_lowercase())).map(|i| i.2).take(4).collect()
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
        let morning = start(&Moment { hour: 8, weekday: 1, events_today: 2, has_nook_task: true, ..Default::default() });
        assert_eq!(morning[0], "Plan my day around my meetings");
        assert_eq!(morning[1], "How busy is my week? Make it a chart");
        let busy = start(&Moment {
            hour: 14,
            weekday: 3,
            front_app: Some(("Firefox".into(), "News".into())),
            next_event: Some("Meeting with the client about next year's offer".into()),
            github_failing: Some("Fix the login flow".into()),
            ..Default::default()
        });
        assert_eq!(busy[0], "Summarize this page");
        assert_eq!(busy[1], "Why is CI failing on “Fix the login flow”?");
        assert!(busy[2].starts_with("Prepare me for Meeting with the client"));
        assert_eq!(busy.len(), 4);
        let reviews = start(&Moment {
            hour: 13,
            weekday: 3,
            github_review: Some("Add dark mode".into()),
            github_failing: Some("Other".into()),
            active_sources: vec!["mail".into()],
            mail_from: Some("Lisa de Vries".into()),
            overdue_tasks: true,
            ..Default::default()
        });
        assert_eq!(reviews[..3], ["Review “Add dark mode” for me", "Reschedule my overdue tasks", "Summarize the mail from Lisa de Vries"]);
        let quiet = start(&Moment { hour: 13, weekday: 3, has_nook_task: true, ..Default::default() });
        assert_eq!(quiet, ["What matters most today?", "Summarize my day", "What can you help me with right now?"]);
        let fresh = start(&Moment { hour: 13, weekday: 3, ..Default::default() });
        assert!(
            fresh.contains(&"Give me an update on my messages every morning at 9:00".to_string()),
            "the secretary while Nook has no task"
        );
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
