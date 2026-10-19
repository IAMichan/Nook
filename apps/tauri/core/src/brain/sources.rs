//! Welke bronnen Nook voor een vraag gebruikt. Drie dingen komen hier samen:
//! - de catalogus: welke bronnen er zijn, wat voor koppeling het is en welke tools erbij horen;
//! - de keuze ([`SourceScope`]): wat de gebruiker toestaat, met de bronkiezer in de chat of in de vraag zelf
//!   ("alleen mijn agenda en mail", "zonder mijn scherm");
//! - de route ([`router`]): welke toegestane bronnen voor deze vraag volledig meegaan.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::matches;

/// Wat voor koppeling een bron gebruikt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    /// Op dit apparaat: agenda, bestanden, klembord, scherm.
    BuiltIn,
    /// Inloggen bij de dienst zelf (GitHub).
    Oauth,
    /// Een geplakte API-sleutel.
    ApiKey,
    /// Een eigen bron met een web-API of webhook.
    Custom,
    /// Het open web.
    Web,
    /// Nooks eigen gegevens.
    Nook,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDescriptor {
    pub id: String,
    pub title: String,
    pub kind: SourceKind,
}

pub const SCREEN: &str = "screen";
pub const WEB: &str = "web";
pub const LOOPS: &str = "loops";
pub const MEMORY: &str = "memory";

const BUILT_IN: [(&str, &str, SourceKind); 28] = [
    ("calendar", "Agenda", SourceKind::BuiltIn),
    ("icalfeeds", "Andere agenda's", SourceKind::ApiKey),
    ("calcom", "Cal.com", SourceKind::ApiKey),
    ("reminders", "Herinneringen", SourceKind::BuiltIn),
    ("notes", "Notities", SourceKind::BuiltIn),
    ("messages", "Berichten", SourceKind::BuiltIn),
    ("whatsapp", "WhatsApp", SourceKind::BuiltIn),
    ("bear", "Bear", SourceKind::BuiltIn),
    ("callnotes", "Gesprekken", SourceKind::Nook),
    ("system", "Dit apparaat", SourceKind::BuiltIn),
    ("things", "Things", SourceKind::BuiltIn),
    (LOOPS, "Open punten", SourceKind::Nook),
    (MEMORY, "Geheugen", SourceKind::Nook),
    ("mail", "Mail", SourceKind::BuiltIn),
    ("browser", "Browser", SourceKind::BuiltIn),
    ("terminal", "Terminal", SourceKind::BuiltIn),
    ("files", "Bestanden", SourceKind::BuiltIn),
    ("contacts", "Contacten", SourceKind::BuiltIn),
    ("clipboard", "Klembord", SourceKind::BuiltIn),
    (SCREEN, "Scherm", SourceKind::BuiltIn),
    ("github", "GitHub", SourceKind::Oauth),
    ("vercel", "Vercel", SourceKind::ApiKey),
    ("stripe", "Stripe", SourceKind::ApiKey),
    ("notion", "Notion", SourceKind::ApiKey),
    ("n8n", "n8n", SourceKind::ApiKey),
    ("resend", "Resend", SourceKind::ApiKey),
    ("customsources", "Eigen bronnen", SourceKind::Custom),
    (WEB, "Web", SourceKind::Web),
];

/// Bronnen met persoonlijke gegevens op dit apparaat: de voorinstelling voor "alleen op dit apparaat".
pub const PERSONAL: [&str; 17] = [
    "calendar",
    "icalfeeds",
    "reminders",
    "notes",
    "messages",
    "whatsapp",
    "bear",
    "things",
    LOOPS,
    "mail",
    "callnotes",
    "browser",
    "files",
    "contacts",
    "clipboard",
    SCREEN,
    MEMORY,
];

/// Tools van een bron. Tools zonder bron (grafieken, app openen, muziek…) mogen altijd.
const EXACT_TOOLS: [(&str, &str); 61] = [
    ("list_events", "calendar"),
    ("create_event", "calendar"),
    ("update_event", "calendar"),
    ("delete_event", "calendar"),
    ("check_availability", "calendar"),
    ("create_reminder", "reminders"),
    ("complete_reminder", "reminders"),
    ("delete_reminder", "reminders"),
    ("list_reminders", "reminders"),
    ("search_reminders", "reminders"),
    ("list_notes", "notes"),
    ("search_notes", "notes"),
    ("read_note", "notes"),
    ("create_note", "notes"),
    ("search_messages", "messages"),
    ("read_messages", "messages"),
    ("messages_open_chats", "messages"),
    ("search_whatsapp", "whatsapp"),
    ("read_whatsapp", "whatsapp"),
    ("whatsapp_open_chats", "whatsapp"),
    ("whatsapp_live", "whatsapp"),
    ("whatsapp_send", "whatsapp"),
    ("search_call_notes", "callnotes"),
    ("read_call_note", "callnotes"),
    ("mac_status", "system"),
    ("search_bear", "bear"),
    ("read_bear", "bear"),
    ("search_things", "things"),
    ("search_mail", "mail"),
    ("read_mail", "mail"),
    ("mail_unread", "mail"),
    ("inbox_mail", "mail"),
    ("search_files", "files"),
    ("read_file", "files"),
    ("read_browser_tab", "browser"),
    ("read_nook_browser", "browser"),
    ("open_in_nook_browser", "browser"),
    ("run_command", "terminal"),
    ("read_screen", SCREEN),
    ("read_app", SCREEN),
    ("list_running_apps", SCREEN),
    ("get_active_app", SCREEN),
    ("search_contacts", "contacts"),
    ("read_clipboard", "clipboard"),
    ("list_open_loops", LOOPS),
    ("add_open_loop", LOOPS),
    ("complete_open_loop", LOOPS),
    ("remember", MEMORY),
    ("forget", MEMORY),
    ("recall_memory", MEMORY),
    ("search_web", WEB),
    ("read_webpage", WEB),
    ("web_search", WEB),
    ("get_weather", WEB),
    ("read_source", "customsources"),
    ("send_to_source", "customsources"),
    ("vercel_deployments", "vercel"),
    ("stripe_payments", "stripe"),
    ("notion_search", "notion"),
    ("notion_read_page", "notion"),
    ("calcom_bookings", "calcom"),
];

const EXACT_MORE: [(&str, &str); 2] = [("n8n_status", "n8n"), ("resend_overview", "resend")];

/// Hoe de gebruiker naar een bron verwijst (Nederlands, Engels, Duits). Eén woord kan meerdere bronnen dekken.
const BUILT_IN_ALIASES: [(&str, &[&str]); 26] = [
    (r"agenda'?s?|kalender\w*|calendars?|ical", &["calendar", "icalfeeds", "calcom"]),
    (r"cal\.com", &["calcom"]),
    (r"herinnering\w*|reminders?|erinnerung\w*", &["reminders"]),
    (r"taken|takenlijst|tasks?|to-?do'?s?|aufgaben", &["reminders", LOOPS]),
    (r"notitie\w*|notes?|memo'?s?|aantekening\w*", &["notes", "bear"]),
    (r"imessages?|sms'?(je|jes|en)?|berichten-?app|messages app|appje\w*|ge-?appt|appte\w*", &["messages", "whatsapp"]),
    (r"whats-?app\w*", &["whatsapp"]),
    (r"bear", &["bear"]),
    (
        r"(opgenomen|mijn) (gesprekk?en|calls|meetings)|gespreksnotities|notulen|transcript\w*|recorded calls?|call notes|meeting notes",
        &["callnotes"],
    ),
    (r"things( ?3| app|-app)", &["things"]),
    (r"contact\w*|telefoon\w*|adresboek|address book", &["contacts"]),
    (r"open punten|open loops?", &[LOOPS]),
    (r"e-?mails?|mail|mailbox|inbox|postvak\w*|posteingang", &["mail"]),
    (r"browser\w*|tabs?|tabblad\w*|safari|chrome|firefox|edge", &["browser"]),
    (r"terminal\w*|shell|commando'?s?|command line|kommandozeile|powershell", &["terminal"]),
    (r"bestand\w*|files?|documenten|documents?|dokumente?n?|dateien|pdf'?s?|spotlight", &["files"]),
    (r"klembord|clipboard|zwischenablage", &["clipboard"]),
    (r"scherm\w*|screen\w*|bildschirm\w*|vensters?", &[SCREEN]),
    (r"internet|web|online|google", &[WEB]),
    (r"github|pull requests?|pr'?s|issues?", &["github"]),
    (r"vercel|deploy\w*", &["vercel"]),
    (r"stripe|betaling\w*|payments?", &["stripe"]),
    (r"notion", &["notion"]),
    (r"n8n|workflows?", &["n8n"]),
    (r"resend", &["resend"]),
    (r"slack|teams|discord|telegram|eigen bronn?e?n?|custom sources?", &["customsources"]),
];

#[derive(Default)]
struct Registry {
    descriptors: Vec<SourceDescriptor>,
    tools: HashMap<String, String>,
    aliases: Vec<(String, Vec<String>)>,
    intents: Vec<(String, Vec<String>)>,
}

fn registry() -> &'static RwLock<Registry> {
    static R: OnceLock<RwLock<Registry>> = OnceLock::new();
    R.get_or_init(Default::default)
}

/// Maakt een bron bekend bij de catalogus: zijn tools volgen dan de bronkiezer, en de route kan hem kiezen.
/// `aliases` en `intents` zijn reguliere expressies (hoofdletterongevoelig).
pub fn register(descriptor: SourceDescriptor, tools: &[String], aliases: &[&str], intents: &[&str]) {
    let mut r = registry().write().unwrap_or_else(|e| e.into_inner());
    r.descriptors.retain(|d| d.id != descriptor.id);
    let id = descriptor.id.clone();
    let escaped = fancy_regex::escape(&descriptor.title.to_lowercase()).to_string();
    r.descriptors.push(descriptor);
    r.tools.retain(|_, v| *v != id);
    for tool in tools {
        r.tools.insert(tool.clone(), id.clone());
    }
    r.aliases.retain(|(_, ids)| ids != std::slice::from_ref(&id));
    r.intents.retain(|(_, ids)| ids != std::slice::from_ref(&id));
    let all: Vec<String> = aliases.iter().map(|a| a.to_string()).chain(std::iter::once(escaped)).filter(|a| !a.is_empty()).collect();
    r.aliases.push((all.join("|"), vec![id.clone()]));
    if !intents.is_empty() {
        r.intents.push((intents.join("|"), vec![id]));
    }
}

/// Koppelt tools aan een bron zonder de rest van de beschrijving te veranderen (het register doet dit bij elke vraag).
pub fn register_tools(id: &str, tools: &[String]) {
    let mut r = registry().write().unwrap_or_else(|e| e.into_inner());
    for tool in tools {
        if !EXACT_TOOLS.iter().chain(EXACT_MORE.iter()).any(|(t, _)| t == tool) {
            r.tools.insert(tool.clone(), id.to_string());
        }
    }
}

/// Haalt een bron weg die er niet meer is (een verwijderde MCP-server).
pub fn unregister(id: &str) {
    let mut r = registry().write().unwrap_or_else(|e| e.into_inner());
    r.descriptors.retain(|d| d.id != id);
    r.tools.retain(|_, v| v != id);
    r.aliases.retain(|(_, ids)| ids.iter().all(|i| i != id));
    r.intents.retain(|(_, ids)| ids.iter().all(|i| i != id));
}

pub fn all() -> Vec<SourceDescriptor> {
    let mut list: Vec<SourceDescriptor> =
        BUILT_IN.iter().map(|(id, title, kind)| SourceDescriptor { id: id.to_string(), title: title.to_string(), kind: *kind }).collect();
    let r = registry().read().unwrap_or_else(|e| e.into_inner());
    for added in &r.descriptors {
        if !list.iter().any(|d| d.id == added.id) {
            list.push(added.clone());
        }
    }
    list
}

pub fn order() -> Vec<String> {
    all().into_iter().map(|d| d.id).collect()
}

/// Plaats in de catalogus, voor een vaste volgorde.
pub fn rank(id: &str, order: &[String]) -> usize {
    order.iter().position(|o| o == id).unwrap_or(99)
}

pub fn descriptor(id: &str) -> Option<SourceDescriptor> {
    let r = registry().read().unwrap_or_else(|e| e.into_inner());
    r.descriptors.iter().find(|d| d.id == id).cloned().or_else(|| {
        BUILT_IN.iter().find(|(i, _, _)| *i == id).map(|(i, t, k)| SourceDescriptor { id: i.to_string(), title: t.to_string(), kind: *k })
    })
}

pub fn title(id: &str) -> String {
    descriptor(id).map(|d| d.title).unwrap_or_else(|| id.to_string())
}

pub fn source_for_tool(name: &str) -> Option<String> {
    if let Some((_, source)) = EXACT_TOOLS.iter().chain(EXACT_MORE.iter()).find(|(t, _)| *t == name) {
        return Some(source.to_string());
    }
    if let Some(found) = registry().read().unwrap_or_else(|e| e.into_inner()).tools.get(name) {
        return Some(found.clone());
    }
    name.starts_with("github_").then(|| "github".to_string())
}

fn aliases() -> Vec<(String, Vec<String>)> {
    let mut list: Vec<(String, Vec<String>)> =
        BUILT_IN_ALIASES.iter().map(|(p, ids)| (p.to_string(), ids.iter().map(|s| s.to_string()).collect())).collect();
    list.extend(registry().read().unwrap_or_else(|e| e.into_inner()).aliases.iter().cloned());
    list
}

fn registered_intents() -> Vec<(String, Vec<String>)> {
    registry().read().unwrap_or_else(|e| e.into_inner()).intents.clone()
}

fn bounded(pattern: &str) -> Option<fancy_regex::Regex> {
    fancy_regex::Regex::new(&format!(r"(?i)(?<![\p{{L}}\d])(?:{pattern})(?![\p{{L}}\d])")).ok()
}

/// Alle bronnen die in de tekst genoemd worden, met hun plek (in bytes).
pub fn mentions(text: &str) -> Vec<(std::ops::Range<usize>, Vec<String>)> {
    let mut found = vec![];
    for (pattern, ids) in aliases() {
        let Some(re) = bounded(&pattern) else { continue };
        for m in re.find_iter(text).flatten() {
            found.push((m.range(), ids.clone()));
        }
    }
    found.sort_by_key(|f| f.0.start);
    found
}

/// Welke bronnen Nook mag gebruiken. Automatisch = alles wat aan staat; Nook kiest wat ertoe doet.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SourceScope {
    pub mode: ScopeMode,
    /// In `Only`: alleen deze bronnen.
    pub included: BTreeSet<String>,
    /// Deze bronnen nooit, ook niet automatisch.
    pub excluded: BTreeSet<String>,
    /// Genoemd in de vraag zonder beperking ("zoek in Slack en GitHub"): daar eerst zoeken.
    pub focus: BTreeSet<String>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScopeMode {
    #[default]
    Automatic,
    Only,
}

impl SourceScope {
    pub fn is_restricted(&self) -> bool {
        self.mode == ScopeMode::Only || !self.excluded.is_empty()
    }

    pub fn allows(&self, id: &str) -> bool {
        if self.excluded.contains(id) {
            return false;
        }
        self.mode != ScopeMode::Only || self.included.contains(id)
    }

    /// Of deze tool mag. Tools zonder bron (grafieken, app openen) mogen altijd.
    pub fn allows_tool(&self, name: &str) -> bool {
        source_for_tool(name).is_none_or(|s| self.allows(&s))
    }

    /// De keuze in de chat samen met wat de vraag zegt. De vraag gaat voor, maar een bron die de gebruiker in de kiezer
    /// uitzette, komt niet terug doordat hij in de vraag genoemd wordt.
    pub fn merged(&self, request: Option<&SourceScope>) -> SourceScope {
        let Some(request) = request else { return self.clone() };
        let mut result = self.clone();
        if request.mode == ScopeMode::Only {
            result.mode = ScopeMode::Only;
            result.included = if self.mode == ScopeMode::Only {
                request.included.intersection(&self.included).cloned().collect()
            } else {
                request.included.clone()
            };
            if result.included.is_empty() {
                result.included = request.included.difference(&self.excluded).cloned().collect();
            }
        }
        result.excluded.extend(request.excluded.iter().cloned());
        result.focus = request.focus.difference(&result.excluded).cloned().collect();
        result
    }

    /// Dezelfde keuze zonder de bronnen die alleen een brein op dit apparaat mag lezen.
    pub fn keeping_local(&self, private: &BTreeSet<String>) -> SourceScope {
        if private.is_empty() {
            return self.clone();
        }
        let mut result = self.clone();
        result.excluded.extend(private.iter().cloned());
        result.included.retain(|i| !private.contains(i));
        result.focus.retain(|i| !private.contains(i));
        result
    }

    /// Korte omschrijving: "Alleen Agenda en Mail" of "Zonder Scherm".
    pub fn label(&self) -> String {
        let mut parts = vec![];
        if self.mode == ScopeMode::Only {
            parts.push(format!("Alleen {}", list(&unique_titles(&self.included))));
        }
        if !self.excluded.is_empty() {
            parts.push(format!("Zonder {}", list(&unique_titles(&self.excluded))));
        }
        if parts.is_empty() {
            "Automatisch".into()
        } else {
            parts.join(" · ")
        }
    }

    /// Haalt een beperking uit de vraag: "alleen mijn agenda en mail", "zoek in Slack en GitHub, maar niet mijn scherm".
    pub fn parse(text: &str) -> Option<SourceScope> {
        let mut scope = SourceScope::default();
        let mut said = matches(rx!(r"(?i)\b(alle|all)\b[^.;!?]{0,25}\b(bronnen|sources|quellen)\b"), text);
        let only_cue = rx!(r"(?i)\b(alleen|uitsluitend|enkel|only|exclusively|nur|ausschlie(ß|ss)lich)\b");
        let except_cue = rx!(r"(?i)\b(zonder|behalve|exclusief|without|except|excluding|ohne|au(ß|ss)er)\b");
        let negation_cue = rx!(r"(?i)\b(niet|geen|nooit|not|don'?t|never|nicht|kein\w*|nie)\b");
        let use_verb = rx!(
            r"(?i)\b(gebruik\w*|zoek\w*|doorzoek\w*|kijk\w*|lees\w*|use|using|search\w*|look\w*|read\w*|check\w*|benutz\w*|verwend\w*|durchsuch\w*|such\w*|schau\w*)\b"
        );
        let ranges =
            |re: &fancy_regex::Regex, s: &str| -> Vec<std::ops::Range<usize>> { re.find_iter(s).flatten().map(|m| m.range()).collect() };
        let chars = |s: &str, a: usize, b: usize| s[a..b].chars().count();

        for clause in clauses(text) {
            let found = mentions(&clause);
            if found.is_empty() {
                continue;
            }
            let only = only_cue.find(&clause).ok().flatten().map(|m| m.range());
            let except = except_cue.find(&clause).ok().flatten().map(|m| m.range());
            let negations = ranges(negation_cue, &clause);
            let verbs = ranges(use_verb, &clause);
            // "gebruik … niet", "niet gebruiken": de ontkenning gaat over het gebruik zelf.
            let negated_verb = negations.iter().any(|n| {
                verbs.iter().any(|v| {
                    let gap = if v.start > n.end {
                        chars(&clause, n.end, v.start)
                    } else if n.start > v.end {
                        chars(&clause, v.end, n.start)
                    } else {
                        99
                    };
                    gap <= 14
                })
            });
            for (range, ids) in found {
                let negated_mention = negations.iter().any(|n| {
                    if n.end <= range.start {
                        return chars(&clause, n.end, range.start) <= 16;
                    }
                    if n.start >= range.end && !verbs.is_empty() {
                        return chars(&clause, range.end, n.start) <= 12;
                    }
                    false
                });
                if except.as_ref().is_some_and(|e| e.start < range.start) || negated_verb || negated_mention {
                    scope.excluded.extend(ids);
                } else if only.as_ref().is_some_and(|o| o.start < range.start) {
                    scope.mode = ScopeMode::Only;
                    scope.included.extend(ids);
                } else {
                    scope.focus.extend(ids);
                    continue;
                }
                said = true;
            }
        }
        let excluded = scope.excluded.clone();
        scope.included.retain(|i| !excluded.contains(i));
        scope.focus.retain(|i| !excluded.contains(i));
        if scope.mode == ScopeMode::Only && scope.included.is_empty() {
            scope.mode = ScopeMode::Automatic;
        }
        (said || !scope.focus.is_empty()).then_some(scope)
    }
}

fn unique_titles(ids: &BTreeSet<String>) -> Vec<String> {
    let order = order();
    let mut sorted: Vec<&String> = ids.iter().collect();
    sorted.sort_by_key(|id| rank(id, &order));
    let mut seen = HashSet::new();
    sorted.into_iter().map(|id| title(id)).filter(|t| seen.insert(t.clone())).collect()
}

fn list(names: &[String]) -> String {
    match names.len() {
        0 => String::new(),
        1 => names[0].clone(),
        n => format!("{} en {}", names[..n - 1].join(", "), names[n - 1]),
    }
}

/// Zinsdelen: een beperking geldt binnen een zin of bijzin ("…, maar niet mijn scherm").
fn clauses(text: &str) -> Vec<String> {
    rx!(r"(?i)[.;!?\n]|,|\b(maar|but|aber|en daarna|and then|dann)\b")
        .replace_all(text, "\u{1F}")
        .split('\u{1F}')
        .filter(|c| !c.trim().is_empty())
        .map(str::to_string)
        .collect()
}

/// Welke bronnen voor deze vraag volledig meegaan; de rest gaat als één regel.
pub mod router {
    use super::*;

    /// Altijd volledig: compact en bijna altijd nuttig om de dag te begrijpen.
    pub const CORE: [&str; 3] = ["calendar", "reminders", LOOPS];

    const INTENTS: [(&str, &[&str]); 19] = [
        (
            r"\w*mail\w*|inbox|postvak\w*|ongelezen|unread|ungelesen|niet\W+(\w+\W+){0,2}gelezen|not\W+(\w+\W+){0,2}read|afzender\w*|senders?|bericht\w*|messages?|antwoord\w*|reply|replies|schreef|schrijf|wrote|follow.?up|opvolg\w*|toegezegd|beloofd|commitments?|afgesproken|agreed|discuss\w*|besproken|gesprek",
            &["mail", "customsources"],
        ),
        (
            r"bericht\w*|messages?|chat\w*|gesprek\w*|appje\w*|ge-?appt|appte\w*|sms\w*|imessage|whats-?app|zei|zegt|stuurde|said|texted|toegezegd|beloofd|afgesproken",
            &["messages", "whatsapp"],
        ),
        (r"tabs?|tabblad\w*|pagina|page|website|site|artikel|article|browser|gelezen|las ik", &["browser"]),
        (r"terminal|shell|commando|command\b|npm |yarn |pip |brew |git |draai |run |voer .{0,20}uit|installeer|install\b", &["terminal"]),
        (r"notitie\w*|notes?|memo'?s?|aantekening\w*", &["notes", "bear"]),
        (
            r"traag|langzaam|trage (mac|pc|computer)|hangt|vastloopt|batterij\w*|accu\w*|geheugen|werkgeheugen|\bram\b|processor|\bcpu\b|ventilator|schijfruimte|harde schijf|schijf vol\w*|opslag\w*|vrije ruimte|slow|battery|memory|disk space|storage|fan\b|langsam|akku|speicher|festplatte",
            &["system"],
        ),
        (
            r"call\w*|meeting\w*|vergader\w*|overleg\w*|gesprek\w*|besproken|afgesproken|zei .{0,20}in de|notulen|to-?do'?s? uit|besprechung\w*",
            &["callnotes"],
        ),
        (r"taken|takenlijst|to-?do'?s?|tasks?|projecten|projects?", &["things"]),
        (r"contact\w*|telefoon\w*|telefoonnummer|e-?mailadres|adresboek|address book", &["contacts"]),
        (
            r"bestand\w*|files?|document\w*|pdf|rapport|report|requirements?|eisen|specificatie\w*|spec\b|offerte|contract",
            &["files", "notion"],
        ),
        (r"code|repo\w*|pull|pr\b|prs\b|issues?|ci\b|build|merge|review|commit\w*|bug\w*|release|requirements?", &["github"]),
        (r"deploy\w*|vercel|productie|production|site live", &["vercel"]),
        (r"omzet|revenue|betaling\w*|payments?|stripe|klant\w*|customers?|facturen|invoices?|abonnement\w*|subscriptions?", &["stripe"]),
        (r"notion|wiki|kennisbank|knowledge|docs?\b", &["notion"]),
        (r"boeking\w*|bookings?|cal\.com", &["calcom"]),
        (r"workflows?|automatiser\w*|automation|n8n", &["n8n"]),
        (r"resend|verzonden mail|deliverability|bounce\w*", &["resend"]),
        (r"klembord|clipboard|gekopieerd|copied|plakken", &["clipboard"]),
        (r"slack|teams|discord|telegram|kanaal|channel", &["customsources"]),
    ];

    /// Brede vragen ("vat mijn week samen") mogen alle beschikbare bronnen gebruiken.
    fn broad(text: &str) -> bool {
        matches(
            rx!(
                r"(?i)samenvat\w*|vat\b.*samen|overzicht|summar\w*|zusammenfass\w*|alles|everything|all (my|of)|wat is er gebeurd|what happened|deze week|this week|diese woche|bereid\w* .*voor|prepare|voorbereid\w*"
            ),
            text,
        )
    }

    pub fn relevant(text: &str, scope: &SourceScope, active: &HashSet<String>) -> HashSet<String> {
        let allowed: HashSet<String> = active.iter().filter(|a| scope.allows(a)).cloned().collect();
        if broad(text) {
            return allowed;
        }
        let mut wanted: HashSet<String> = CORE.iter().map(|s| s.to_string()).collect();
        wanted.extend(scope.focus.iter().cloned());
        if scope.mode == ScopeMode::Only {
            wanted.extend(scope.included.iter().cloned());
        }
        let intents = INTENTS.iter().map(|(p, ids)| (p.to_string(), ids.iter().map(|s| s.to_string()).collect::<Vec<_>>()));
        for (pattern, ids) in intents.chain(registered_intents()) {
            let Ok(re) = fancy_regex::Regex::new(&format!(r"(?i)(?<![\p{{L}}\d])(?:{pattern})")) else { continue };
            if matches(&re, text) {
                wanted.extend(ids);
            }
        }
        for (_, ids) in mentions(text) {
            wanted.extend(ids);
        }
        allowed.intersection(&wanted).cloned().collect()
    }
}

/// Wat een koppeling kan, in gewone taal, voor de instellingen.
pub mod capabilities {
    use super::*;

    fn phrase(tool: &str) -> Option<&'static str> {
        Some(match tool {
            "list_events" => "afspraken lezen",
            "check_availability" => "beschikbaarheid in alle agenda's",
            "create_event" => "afspraak maken",
            "update_event" => "afspraak aanpassen",
            "delete_event" => "afspraak verwijderen",
            "create_reminder" => "herinnering maken",
            "complete_reminder" => "herinnering afvinken",
            "list_reminders" => "herinneringen bekijken",
            "search_notes" => "notities zoeken",
            "read_note" => "notitie lezen",
            "create_note" => "notitie maken",
            "search_mail" => "mail zoeken (inbox en verzonden)",
            "read_mail" => "hele mail lezen",
            "mail_unread" => "ongelezen mail tellen",
            "inbox_mail" => "recente mail lezen",
            "compose_mail" => "mailconcept (jij verstuurt)",
            "search_files" => "bestanden zoeken",
            "read_file" => "document lezen",
            "read_browser_tab" => "geopende webpagina lezen",
            "read_screen" => "scherm lezen",
            "read_app" => "een geopende app lezen",
            "search_contacts" => "contacten zoeken",
            "read_clipboard" => "klembord lezen",
            "list_open_loops" => "open punten lezen",
            "add_open_loop" => "open punt toevoegen",
            "complete_open_loop" => "open punt afronden",
            "remember" => "iets onthouden",
            "forget" => "iets vergeten",
            "recall_memory" => "geheugen doorzoeken",
            "search_web" | "web_search" => "web doorzoeken",
            "read_webpage" => "webpagina lezen",
            "get_weather" => "weer opvragen",
            "github_overview" => "je PR's en reviews",
            "github_pr_details" => "PR met diff lezen",
            "github_search" => "issues en PR's zoeken",
            "github_issue_details" => "issue lezen",
            "github_create_issue" => "issue maken",
            "stripe_payments" => "betalingen lezen",
            "notion_search" => "pagina's zoeken",
            "notion_read_page" => "pagina lezen",
            _ => return None,
        })
    }

    pub fn kind_label(kind: SourceKind) -> &'static str {
        match kind {
            SourceKind::BuiltIn => "Op dit apparaat",
            SourceKind::Oauth => "Inloggen (OAuth)",
            SourceKind::ApiKey => "API-sleutel",
            SourceKind::Custom => "Eigen API of webhook",
            SourceKind::Web => "Internet",
            SourceKind::Nook => "Nook",
        }
    }

    /// Lezen en schrijven van een bron, uit de tools (naam, of het een actie is).
    pub fn describe(source: &str, tools: &[(&str, bool)]) -> (Vec<String>, Vec<String>) {
        let (mut reads, mut writes) = (vec![], vec![]);
        for (name, action) in tools {
            if source_for_tool(name).as_deref() != Some(source) {
                continue;
            }
            let text = phrase(name).map(str::to_string).unwrap_or_else(|| name.to_string());
            let list = if *action { &mut writes } else { &mut reads };
            if !list.contains(&text) {
                list.push(text);
            }
        }
        (reads, writes)
    }

    /// "API-sleutel · lezen: betalingen lezen · schrijven: niets".
    pub fn line(source: &str, tools: &[(&str, bool)]) -> String {
        let (reads, writes) = describe(source, tools);
        let mut parts: Vec<String> = descriptor(source).map(|d| kind_label(d.kind).to_string()).into_iter().collect();
        if !reads.is_empty() {
            parts.push(format!("lezen: {}", reads.join(", ")));
        }
        parts.push(if writes.is_empty() { "schrijven: niets".into() } else { format!("schrijven (na jouw OK): {}", writes.join(", ")) });
        parts.join(" · ")
    }
}

/// Opzoekingen die Nook zelf doet voor het model antwoordt, voor elke bron waar de vraag over gaat.
pub mod prefetch {
    use super::*;

    #[derive(Debug, Clone, PartialEq)]
    pub struct Call {
        pub tool: String,
        pub input: Value,
    }

    /// Een lees-tool die Nook zou kunnen draaien: naam, bron en verplichte velden.
    #[derive(Debug, Clone, PartialEq)]
    pub struct Available {
        pub name: String,
        pub source: String,
        pub required: Vec<String>,
        /// Het tekstveld voor een zoekopdracht ("query", "q"…), als de tool er een heeft.
        pub query: Option<String>,
    }

    impl Available {
        pub fn new(name: &str, source: &str, required: &[&str], query: Option<&str>) -> Self {
            Self {
                name: name.into(),
                source: source.into(),
                required: required.iter().map(|s| s.to_string()).collect(),
                query: query.map(str::to_string),
            }
        }

        /// Het veld van een schema dat een zoektekst neemt.
        pub fn query_field(schema: &Value) -> Option<String> {
            let properties = schema["properties"].as_object()?;
            ["query", "q", "search", "term", "keyword", "keywords", "text"]
                .iter()
                .find(|name| properties.get(**name).is_some_and(|f| f["type"] == "string"))
                .map(|s| s.to_string())
        }
    }

    /// Bronnen waarvan de gegevens altijd al volledig in de context staan.
    pub fn in_context(source: &str) -> bool {
        router::CORE.contains(&source)
    }

    const UNREAD: &str = r"ongelezen|unread|ungelesen|niet\W+(\w+\W+){0,2}gelezen|not\W+(\w+\W+){0,2}read";
    const REPLY: &str =
        r"beantwoord\w*|antwoord\w*|reageer|reageren|terugmail\w*|terugschrijv\w*|reply|respond|answer|follow.?up|opvolg\w*";
    /// Chats die nog op iets wachten.
    pub const PENDING: &str = r"open ?staa?n\w*|openstaand\w*|open (chats?|gesprekk?e?n?|berichten|appjes?|conversations?|threads?|messages?)|onbeantwoord\w*|unanswered|pending|outstanding|waiting|wacht\w* (op|nog)|nog (niet )?(gereageerd|geantwoord|beantwoord|teruggeappt|teruggestuurd)|unbeantwortet\w*|offene?n? (chats?|nachrichten)";

    pub fn has(pattern: &str, text: &str) -> bool {
        fancy_regex::Regex::new(&format!(r"(?i)(?<![\p{{L}}\d])(?:{pattern})")).ok().is_some_and(|re| matches(&re, text))
    }

    /// De vraag wil de nieuwste of ongelezen dingen van deze bron, dus zijn overzicht helpt ook naast een zoekopdracht.
    pub fn prefers_listing(source: &str, text: &str) -> bool {
        match source {
            "mail" | "messages" | "whatsapp" => has(UNREAD, text) || has(REPLY, text) || has(PENDING, text),
            "notes" => has(r"recent\w*|laatst\w*|nieuwst\w*|latest|newest|neueste?n?|letzte?n?", text),
            _ => false,
        }
    }

    fn hint(tool: &str, text: &str) -> (u8, Value) {
        match tool {
            "mail_unread" => (if has(UNREAD, text) { 0 } else { 9 }, json!({})),
            "inbox_mail" => {
                if has(REPLY, text) || has(PENDING, text) {
                    (1, json!({"days": 14, "unanswered_only": true}))
                } else {
                    (2, json!({"days": 7}))
                }
            }
            "whatsapp_open_chats" | "messages_open_chats" => {
                (if has(UNREAD, text) || has(REPLY, text) || has(PENDING, text) { 0 } else { 2 }, json!({}))
            }
            "whatsapp_live" => (if has(UNREAD, text) || has(REPLY, text) || has(PENDING, text) { 0 } else { 1 }, json!({})),
            "list_notes" => (1, json!({"limit": 8})),
            "list_reminders" | "read_browser_tab" => (1, json!({})),
            _ => (5, json!({})),
        }
    }

    /// Eén aanroep per relevante bron (hoogstens `limit`), met een lees-tool zonder verplichte invoer.
    pub fn calls(text: &str, relevant: &HashSet<String>, available: &[Available], limit: usize) -> Vec<Call> {
        let order = order();
        let mut sources: Vec<&String> = relevant.iter().filter(|s| !in_context(s)).collect();
        sources.sort_by_key(|s| (rank(s, &order), s.to_string()));
        let mut calls = vec![];
        for source in sources {
            let best = available
                .iter()
                .enumerate()
                .filter(|(_, a)| &a.source == source && a.required.is_empty())
                .min_by_key(|(index, a)| (hint(&a.name, text).0, *index));
            if let Some((_, pick)) = best {
                calls.push(Call { tool: pick.name.clone(), input: hint(&pick.name, text).1 });
            }
        }
        calls.truncate(limit);
        calls
    }
}

#[cfg(test)]
mod tests {
    use super::prefetch::{calls, Available};
    use super::*;

    fn set(ids: &[&str]) -> BTreeSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    fn hset(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn only_calendar_and_mail_in_dutch() {
        let scope = SourceScope::parse("Gebruik alleen mijn agenda en mail en bereid me voor op morgen").unwrap();
        assert_eq!(scope.mode, ScopeMode::Only);
        assert!(scope.allows("calendar") && scope.allows("mail") && scope.allows("icalfeeds"));
        assert!(!scope.allows("github") && !scope.allows(SCREEN));
    }

    #[test]
    fn only_in_english() {
        let scope = SourceScope::parse("Only use my calendar and email.").unwrap();
        assert_eq!(scope.mode, ScopeMode::Only);
        assert_eq!(scope.included, set(&["calendar", "icalfeeds", "calcom", "mail"]));
    }

    #[test]
    fn focus_with_exclusion() {
        let scope = SourceScope::parse("Search Slack and GitHub, but do not use my screen context.").unwrap();
        assert_eq!(scope.mode, ScopeMode::Automatic);
        assert!(scope.focus.contains("github") && scope.focus.contains("customsources"));
        assert_eq!(scope.excluded, set(&[SCREEN]));
        assert!(!scope.allows_tool("read_screen"));
        assert!(scope.allows_tool("github_search"));
    }

    #[test]
    fn negations_and_other_languages() {
        assert_eq!(SourceScope::parse("Vat mijn week samen, maar gebruik mijn scherm niet").unwrap().excluded, set(&[SCREEN]));
        assert!(SourceScope::parse("Fasse alles zusammen ohne Bildschirm").unwrap().excluded.contains(SCREEN));
        let all = SourceScope::parse("Use all relevant sources available to me.").unwrap();
        assert_eq!(all.mode, ScopeMode::Automatic);
        assert!(!all.is_restricted());
        assert_eq!(SourceScope::parse("Hoe laat is het?"), None);
        let scope = SourceScope::parse("Check of ik vrijdag niet dubbel geboekt sta in mijn agenda");
        assert!(!scope.is_some_and(|s| s.excluded.contains("calendar")));
    }

    #[test]
    fn tools_without_source_are_always_allowed() {
        let scope = SourceScope { mode: ScopeMode::Only, included: set(&["mail"]), ..Default::default() };
        assert!(scope.allows_tool("show_chart") && scope.allows_tool("compose_mail"));
        assert!(!scope.allows_tool("list_events") && !scope.allows_tool("search_web"));
    }

    #[test]
    fn merging() {
        let picker = SourceScope { excluded: set(&[SCREEN]), ..Default::default() };
        let request = SourceScope { mode: ScopeMode::Only, included: set(&["mail", SCREEN]), ..Default::default() };
        let merged = picker.merged(Some(&request));
        assert_eq!(merged.mode, ScopeMode::Only);
        assert!(merged.allows("mail") && !merged.allows(SCREEN));
        let picker = SourceScope { mode: ScopeMode::Only, included: set(&["mail", "calendar"]), ..Default::default() };
        let request = SourceScope { mode: ScopeMode::Only, included: set(&["mail"]), ..Default::default() };
        assert_eq!(picker.merged(Some(&request)).included, set(&["mail"]));
    }

    #[test]
    fn labels() {
        assert_eq!(SourceScope::default().label(), "Automatisch");
        assert_eq!(
            SourceScope { mode: ScopeMode::Only, included: set(&["calendar", "mail"]), ..Default::default() }.label(),
            "Alleen Agenda en Mail"
        );
        assert_eq!(SourceScope { excluded: set(&[SCREEN]), ..Default::default() }.label(), "Zonder Scherm");
    }

    #[test]
    fn tool_source_mapping() {
        assert_eq!(source_for_tool("github_pr_details").as_deref(), Some("github"));
        assert_eq!(source_for_tool("search_mail").as_deref(), Some("mail"));
        assert_eq!(source_for_tool("notion_read_page").as_deref(), Some("notion"));
        assert_eq!(source_for_tool("show_chart"), None);
        assert_eq!(source_for_tool("compose_mail"), None);
        assert_eq!(source_for_tool("read_app").as_deref(), Some(SCREEN));
        register(
            SourceDescriptor { id: "linear".into(), title: "Linear".into(), kind: SourceKind::Oauth },
            &["linear_issues".into()],
            &[],
            &[r"tickets?"],
        );
        assert_eq!(source_for_tool("linear_issues").as_deref(), Some("linear"));
        assert!(mentions("zoek in linear").iter().any(|(_, ids)| ids == &["linear"]));
        assert!(router::relevant("welke tickets staan open", &SourceScope::default(), &hset(&["linear"])).contains("linear"));
        unregister("linear");
        assert_eq!(source_for_tool("linear_issues"), None);
    }

    #[test]
    fn router_targets_relevant_sources() {
        let active = hset(&["calendar", "mail", "github", "stripe", "browser", "files"]);
        let relevant = router::relevant("Wat heeft Lisa gemaild over de offerte?", &SourceScope::default(), &active);
        assert!(relevant.contains("mail") && relevant.contains("calendar"));
        assert!(!relevant.contains("stripe") && !relevant.contains("github"));
        let active = hset(&["calendar", "mail", "github", "stripe"]);
        let broad = router::relevant(
            "Vat samen wat er deze week gebeurde",
            &SourceScope { excluded: set(&["stripe"]), ..Default::default() },
            &active,
        );
        assert_eq!(broad, hset(&["calendar", "mail", "github"]));
        for question in ["hoeveel heb ik nog niet gelezen?", "maak een grafiek van mijn ongelezen berichten", "how many unread do I have"] {
            let relevant = router::relevant(question, &SourceScope::default(), &hset(&["calendar", "mail", "github"]));
            assert!(relevant.contains("mail") && !relevant.contains("github"), "{question}");
        }
        let only = SourceScope { mode: ScopeMode::Only, included: set(&["github"]), ..Default::default() };
        assert_eq!(router::relevant("summarize everything", &only, &hset(&["calendar", "mail", "github"])), hset(&["github"]));
    }

    #[test]
    fn capabilities_separate_read_and_write() {
        let tools = [("github_search", false), ("github_create_issue", true), ("search_mail", false), ("show_chart", false)];
        let (reads, writes) = capabilities::describe("github", &tools);
        assert_eq!(reads, vec!["issues en PR's zoeken"]);
        assert_eq!(writes, vec!["issue maken"]);
        assert_eq!(capabilities::line("stripe", &[("stripe_payments", false)]), "API-sleutel · lezen: betalingen lezen · schrijven: niets");
    }

    fn available() -> Vec<Available> {
        vec![
            Available::new("mail_unread", "mail", &[], None),
            Available::new("inbox_mail", "mail", &[], None),
            Available::new("search_mail", "mail", &["query"], Some("query")),
            Available::new("github_overview", "github", &[], None),
            Available::new("github_search", "github", &["query"], Some("query")),
            Available::new("list_events", "calendar", &["from", "to"], None),
        ]
    }

    #[test]
    fn mail_questions_fetch_the_right_mail() {
        let mail = hset(&["calendar", "reminders", "mail"]);
        let reply = calls("Welke mail moet ik beantwoorden?", &mail, &available(), 4);
        assert_eq!(reply.iter().map(|c| c.tool.as_str()).collect::<Vec<_>>(), vec!["inbox_mail"]);
        assert_eq!(reply[0].input["unanswered_only"], true);
        let unread = calls("maak een grafiek van hoeveel mails ik nog niet heb gelezen", &mail, &available(), 4);
        assert_eq!(unread[0].tool, "mail_unread");
        assert_eq!(calls("wat is er binnengekomen in mijn mail", &mail, &available(), 4)[0].tool, "inbox_mail");
        let both = calls("hoe staat het met mijn code en mail", &hset(&["calendar", "mail", "github"]), &available(), 4);
        assert_eq!(both.iter().map(|c| c.tool.as_str()).collect::<Vec<_>>(), vec!["inbox_mail", "github_overview"]);
        assert!(calls("wat staat er morgen op de planning", &hset(&["calendar", "reminders"]), &available(), 4).is_empty());
    }
}
