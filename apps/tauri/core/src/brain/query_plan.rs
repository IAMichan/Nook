//! De lezing van een vraag door het model zelf, voor Nook iets opzoekt. Woordenlijsten raden slecht wat een vraag
//! bedoelt: "heb ik chats openstaan in WhatsApp?" is geen zoektocht naar de woorden "chats" en "whatsapp" in bestanden,
//! maar vraagt om de ongelezen WhatsApp-chats. Het brein beantwoordt daarom eerst drie korte vragen over de vraag (wat wil
//! de gebruiker, waar staat dat, waarop zoeken), en Nook zoekt met dat plan. Lukt plannen niet op tijd, dan valt Nook terug
//! op zijn eigen woordonderzoek.

use std::collections::HashSet;

use serde_json::Value;

use super::research::{self, Terms};
use super::sources::{self, prefetch};
use super::ChatTurn;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Iets specifieks in de gegevens van de gebruiker.
    Lookup,
    /// De nieuwste, ongelezen of openstaande dingen van een bron.
    Listing,
    /// Iets doen; de gewone actiestroom regelt dat.
    Action,
    /// Algemene kennis of het web.
    General,
    /// Een groet of bedankje.
    Chat,
}

impl Kind {
    fn parse(raw: &str) -> Self {
        match raw.trim().to_lowercase().as_str() {
            "listing" => Self::Listing,
            "action" => Self::Action,
            "general" => Self::General,
            "chat" => Self::Chat,
            _ => Self::Lookup,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Lookup => "lookup",
            Self::Listing => "listing",
            Self::Action => "action",
            Self::General => "general",
            Self::Chat => "chat",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueryPlan {
    /// Eén zin: wat de gebruiker echt wil weten of gedaan hebben.
    pub goal: String,
    pub kind: Kind,
    /// Bron-id's waar het antwoord staat, waarschijnlijkste eerst.
    pub sources: Vec<String>,
    /// Korte zoekopdrachten (één tot drie woorden), beste eerst.
    pub queries: Vec<String>,
}

impl QueryPlan {
    /// De woorden om mee te zoeken, zoals Nooks onderzoek ze gebruikt.
    pub fn terms(&self) -> Terms {
        let mut terms = Terms::default();
        for query in &self.queries {
            let lower = query.trim().to_lowercase();
            if lower.is_empty() {
                continue;
            }
            if lower.contains(' ') {
                terms.phrases.push(lower.clone());
            }
            for word in research::words_of(&lower) {
                if !terms.words.contains(&word) && word.chars().count() >= 2 {
                    terms.words.push(word);
                }
            }
        }
        terms.phrases.truncate(3);
        terms.words.truncate(8);
        terms.names = self
            .queries
            .iter()
            .flat_map(|q| q.split(' ').map(str::to_string).collect::<Vec<_>>())
            .filter(|w| w.chars().next().is_some_and(|c| c.is_uppercase()))
            .collect();
        terms
    }
}

/// Wat de planner over een bron weet.
#[derive(Debug, Clone, PartialEq)]
pub struct PlannerSource {
    pub id: String,
    pub title: String,
    pub can_search: bool,
    pub can_list: bool,
}

pub const SYSTEM: &str = r#"You plan how to answer a question asked to Nook, the assistant on the user's computer. You do not answer it.
Work out what the user really wants and where on their computer or in their services that lives, then reply with ONLY one JSON object:
{"goal": "...", "kind": "lookup|listing|action|general|chat", "sources": ["id", ...], "queries": ["...", ...]}
- goal: one short sentence in English: what exactly the user wants to know or have done.
- kind: lookup = find something specific in their data; listing = the newest, unread, open or unanswered items of a source (no keywords needed); action = create, send, change or open something; general = general knowledge, news or the web; chat = greeting or thanks.
- sources: ids from the list below where the answer most likely is, best first, at most 4. A source the user names comes first. Do not add sources that merely could mention the topic: a question about chats is answered by the chat apps, not by files or code.
- queries: 1 to 3 short keyword searches (1 to 3 words, the words that would literally appear in the item: names, subjects, synonyms; in the language the data is likely in). Never the name of a source, never words like open/unread/latest. Empty for a listing."#;

pub fn prompt(question: &str, history: &[ChatTurn], sources: &[PlannerSource], today: &str) -> String {
    let mut lines: Vec<String> = vec![];
    let recent = &history[history.len().saturating_sub(4)..];
    if !recent.is_empty() {
        lines.push("Conversation so far:".into());
        for turn in recent {
            let text: String = turn.text.chars().take(300).collect::<String>().replace('\n', " ");
            lines.push(format!("{}{text}", if turn.from_user { "User: " } else { "Nook: " }));
        }
        lines.push(String::new());
    }
    lines.push("Sources (id — name: what Nook can do):".into());
    for source in sources {
        let mut abilities = vec![];
        if source.can_search {
            abilities.push("search");
        }
        if source.can_list {
            abilities.push("newest/unread/open items");
        }
        lines.push(format!(
            "- {} — {}: {}",
            source.id,
            source.title,
            if abilities.is_empty() { "context".into() } else { abilities.join(", ") }
        ));
    }
    lines.push(String::new());
    lines.push(format!("Today: {today}."));
    lines.push(format!("Question: {question}"));
    lines.push("JSON:".into());
    lines.join("\n")
}

/// Het plan in het antwoord van het model: het eerste JSON-object erin, zonder onbekende bronnen.
pub fn parse(reply: &str, known: &HashSet<String>) -> Option<QueryPlan> {
    let (start, end) = (reply.find('{')?, reply.rfind('}')?);
    if start >= end {
        return None;
    }
    let object: Value = serde_json::from_str(&reply[start..=end]).ok()?;
    let object = object.as_object()?;
    let kind = object.get("kind").and_then(|k| k.as_str()).map(Kind::parse).unwrap_or(Kind::Lookup);
    let mut found: Vec<String> = vec![];
    for raw in object.get("sources").and_then(|s| s.as_array()).into_iter().flatten() {
        let Some(id) = raw.as_str().map(|s| s.trim().to_lowercase()) else { continue };
        // Modellen antwoorden soms met de naam in plaats van het id.
        let matched = if known.contains(&id) { Some(id) } else { known.iter().find(|k| sources::title(k).to_lowercase() == id).cloned() };
        if let Some(m) = matched {
            if !found.contains(&m) {
                found.push(m);
            }
        }
    }
    let queries: Vec<String> = object
        .get("queries")
        .and_then(|q| q.as_array())
        .into_iter()
        .flatten()
        .filter_map(|q| q.as_str().map(|s| s.trim().to_string()))
        .filter(|q| !q.is_empty() && q.chars().count() <= 60)
        .take(3)
        .collect();
    found.truncate(4);
    Some(QueryPlan {
        goal: object.get("goal").and_then(|g| g.as_str()).unwrap_or("").chars().take(240).collect(),
        kind,
        sources: found,
        queries,
    })
}

/// De opzoekingen voor een plan: elke zoekopdracht in elke geplande bron die kan zoeken, en het overzicht van de bron
/// voor een lijst (of een bron die niet kan zoeken).
pub fn lookups(plan: &QueryPlan, question: &str, available: &[prefetch::Available], limit: usize) -> Vec<prefetch::Call> {
    let mut searches: Vec<prefetch::Call> = vec![];
    let mut overviews: Vec<prefetch::Call> = vec![];
    for source in plan.sources.iter().filter(|s| !prefetch::in_context(s)) {
        let mut searched = false;
        if plan.kind != Kind::Listing || !plan.queries.is_empty() {
            for query in plan.queries.iter().take(2) {
                let terms = Terms {
                    words: research::words_of(&query.to_lowercase()),
                    names: query.split(' ').filter(|w| w.chars().next().is_some_and(|c| c.is_uppercase())).map(str::to_string).collect(),
                    ..Default::default()
                };
                if let Some(call) = research::search(source, &terms, question, available) {
                    if !searches.iter().any(|c| c.tool == call.tool && c.input == call.input) {
                        searches.push(call);
                        searched = true;
                    }
                }
            }
        }
        if plan.kind == Kind::Listing || !searched {
            overviews.extend(prefetch::calls(question, &HashSet::from([source.clone()]), available, 1));
        }
    }
    let mut ordered = if plan.kind == Kind::Listing {
        overviews.into_iter().chain(searches).collect::<Vec<_>>()
    } else {
        searches.into_iter().chain(overviews).collect()
    };
    ordered.truncate(limit);
    ordered
}

#[cfg(test)]
mod tests {
    use super::prefetch::Available;
    use super::*;

    fn available() -> Vec<Available> {
        vec![
            Available::new("search_whatsapp", "whatsapp", &["query"], Some("query")),
            Available::new("whatsapp_open_chats", "whatsapp", &[], None),
            Available::new("read_whatsapp", "whatsapp", &["chat"], None),
            Available::new("search_mail", "mail", &["query"], Some("query")),
            Available::new("inbox_mail", "mail", &[], None),
            Available::new("search_files", "files", &["query"], Some("query")),
            Available::new("read_file", "files", &["path"], None),
        ]
    }

    fn known() -> HashSet<String> {
        ["whatsapp", "mail", "files", "notes"].map(String::from).into()
    }

    #[test]
    fn a_plan_is_read_from_the_reply() {
        let reply = "```json\n{\"goal\": \"Which WhatsApp chats are unread or wait for a reply\", \"kind\": \"listing\", \"sources\": [\"whatsapp\", \"slack\"], \"queries\": []}\n```";
        let plan = parse(reply, &known()).unwrap();
        assert_eq!(plan.kind, Kind::Listing);
        assert_eq!(plan.sources, vec!["whatsapp"]);
        assert_eq!(plan.goal, "Which WhatsApp chats are unread or wait for a reply");
        let named = parse(r#"{"goal": "x", "kind": "lookup", "sources": ["WhatsApp", "Mail"], "queries": ["offerte"]}"#, &known()).unwrap();
        assert_eq!(named.sources, vec!["whatsapp", "mail"]);
        assert!(parse("Ja, je hebt chats openstaan.", &known()).is_none());
        assert_eq!(parse(r#"{"goal": "x", "kind": "weird"}"#, &known()).unwrap().kind, Kind::Lookup);
    }

    #[test]
    fn listings_and_searches() {
        let listing = QueryPlan { goal: "open chats".into(), kind: Kind::Listing, sources: vec!["whatsapp".into()], queries: vec![] };
        let calls = lookups(&listing, "Heb ik chats openstaan in whatsapp", &available(), 8);
        assert_eq!(calls.iter().map(|c| c.tool.as_str()).collect::<Vec<_>>(), vec!["whatsapp_open_chats"]);
        let lookup = QueryPlan {
            goal: "what Lisa said about the quote".into(),
            kind: Kind::Lookup,
            sources: vec!["whatsapp".into(), "mail".into()],
            queries: vec!["Lisa offerte".into(), "prijsopgave".into()],
        };
        let calls = lookups(&lookup, "wat zei Lisa over de offerte?", &available(), 8);
        assert_eq!(
            calls.iter().map(|c| c.tool.as_str()).collect::<Vec<_>>(),
            vec!["search_whatsapp", "search_whatsapp", "search_mail", "search_mail"]
        );
        assert_eq!(calls.last().unwrap().input["query"], "prijsopgave");
        let terms =
            QueryPlan { goal: String::new(), kind: Kind::Lookup, sources: vec![], queries: vec!["Lisa offerte".into(), "keuken".into()] }
                .terms();
        assert!(terms.words.contains(&"offerte".to_string()) && terms.words.contains(&"keuken".to_string()));
        assert_eq!(terms.names, vec!["Lisa"]);
    }

    #[test]
    fn the_prompt_lists_what_each_source_can_do() {
        let prompt = prompt(
            "Heb ik chats openstaan?",
            &[],
            &[PlannerSource { id: "whatsapp".into(), title: "WhatsApp".into(), can_search: true, can_list: true }],
            "maandag 19 oktober 2026 10:00",
        );
        assert!(prompt.contains("- whatsapp — WhatsApp: search, newest/unread/open items"));
        assert!(prompt.ends_with("Question: Heb ik chats openstaan?\nJSON:"));
    }
}
