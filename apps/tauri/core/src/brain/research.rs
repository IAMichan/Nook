//! Nooks eigen onderzoek voor het model antwoordt. Een klein lokaal model zoekt zelden goed: het roept één tool aan met
//! de hele vraag als zoekterm, leest alleen de eerste regels van een treffer, of antwoordt uit de titels. Nook doet dat
//! werk daarom zelf, voor elk model en elke bron hetzelfde:
//!
//! 1. **Termen**: de woorden die de vraag dragen, zonder vulwoorden, bronnamen of datums; een vervolgvraag houdt de termen
//!    van de vraag ervoor.
//! 2. **Zoeken**: elke relevante bron wordt met die termen doorzocht. Een vraag die geen bron noemt, overal waar het kan.
//! 3. **Lezen**: de treffers van alle bronnen worden gerangschikt en de beste worden volledig geopend met de leestool
//!    van de bron (read_note, read_mail, read_file, notion_read_page, github_issue_details, read_webpage).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::OnceLock;

use serde_json::{json, Map, Value};

use super::intent::ChatIntent;
use super::matches;
use super::sources::{self, prefetch};
use super::text::fold;
use super::ChatTurn;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Terms {
    /// Woorden die de vraag dragen, meest specifiek (langst) eerst.
    pub words: Vec<String>,
    /// Zinnen die de gebruiker tussen aanhalingstekens zette, heel gehouden.
    pub phrases: Vec<String>,
    /// Woorden met een hoofdletter, waarschijnlijk namen ("Lisa", "Apollo").
    pub names: Vec<String>,
    /// Een deel kwam uit de vraag ervoor (een vervolgvraag).
    pub inherited: bool,
}

impl Terms {
    pub fn words(words: &[&str]) -> Self {
        Self { words: words.iter().map(|s| s.to_string()).collect(), ..Default::default() }
    }

    pub fn is_empty(&self) -> bool {
        self.words.is_empty() && self.phrases.is_empty()
    }

    /// Alles om op te matchen, zinnen eerst.
    pub fn all(&self) -> Vec<String> {
        let mut all = self.phrases.clone();
        all.extend(self.words.iter().filter(|w| !self.phrases.iter().any(|p| p.contains(w.as_str()))).cloned());
        all
    }

    /// Tekst voor een zoektool: zinnen eerst, dan de meest specifieke woorden.
    pub fn query(&self, limit: usize) -> String {
        self.all().into_iter().take(limit).collect::<Vec<_>>().join(" ")
    }
}

const STOPWORDS: &str = "de het een en of maar want dus dan als om te in op aan bij voor van met naar uit over onder tussen door tot sinds zonder tegen \
ik je jij u hij zij ze we wij jullie mij me mijn mijne jouw jou uw zijn haar hun hen ons onze die dat dit deze er hier daar \
wat wie waar wanneer waarom hoe welke welk hoeveel hoelang waarover waarin waarvan wat's \
is ben bent zijn was waren wordt worden werd geweest heb hebt heeft hebben had hadden kan kun kunt kunnen kon \
zal zul zult zullen zou zouden wil wilt willen wou moet moeten mag mogen doe doet doen deed gedaan ga gaat gaan ging \
staat staan stond stonden stuk zeg zegt zeggen zei vertel vertellen geef geven laat laten zien toon tonen weet weten \
zoek zoeken zocht vind vinden vond lees lezen las gelezen kijk kijken keek check checken schreef schrijf geschreven \
samenvatting samenvatten vat samen uitleg leg uit noem noemde noemen afgesproken besproken gezegd gevraagd \
niet geen nog al ook wel even eens graag alsjeblieft aub please iets niets alles allemaal veel weinig meer minder \
heel erg zo nu dan toen ooit altijd nooit soms vaak eigenlijk precies ongeveer gewoon echt alleen ander andere \
nook hoi hallo hey ok oke goed dank bedankt \
notitie notities note notes aantekening aantekeningen memo memos mail mails email emails e-mail mailtje inbox bericht berichten \
bestand bestanden document documenten file files pdf map mappen agenda kalender afspraak afspraken herinnering herinneringen \
taak taken todo github notion issue issues pr prs repo internet web online google browser tab tabs tabblad pagina site website \
scherm venster app apps klembord contact contacten bron bronnen \
chat chats chatje chatjes gesprek gesprekken appje appjes geappt appte imessage imessages sms sms'je sms'jes \
whatsapp whats-app slack teams discord telegram signal \
ongelezen gelezen beantwoord beantwoorden antwoord antwoorden reageren reactie \
open openstaan openstaand openstaande onbeantwoord onbeantwoorde wacht wachten wachtend wachtende status \
vandaag morgen gisteren overmorgen eergisteren straks vanavond vanochtend vanmiddag vannacht week weken maand maanden jaar \
maandag dinsdag woensdag donderdag vrijdag zaterdag zondag weekend ochtend middag avond nacht uur tijd keer \
laatste laatst nieuwste nieuw nieuwe recent recente vorige volgende eerste eerder later \
the a an and or but so then if to in on at by for of with from about into over under between through until since \
without against i you he she it we they me my mine your yours his her its our their them us this that these those there here \
what who where when why how which whose whom \
am is are was were be been being have has had do does did done can could will would shall should may might must \
get got go goes going went tell show give let see find found search look looking read check know say said says wrote write \
summary summarize summarise explain mention mentioned \
not no yet also just please something anything nothing everything all some any more less very really only other \
notes note memo mail mails email emails message messages file files document documents folder calendar event events reminder reminders \
task tasks todo issue issues repo internet web online browser tab tabs page site website screen window clipboard contact contacts source sources \
chat chats conversation conversations thread threads text texts texted whatsapp imessage sms slack teams discord telegram signal \
unread read replied reply answer open pending unanswered waiting awaiting outstanding \
today tomorrow yesterday tonight morning afternoon evening night week weeks month months year \
monday tuesday wednesday thursday friday saturday sunday weekend hour time last latest newest new recent previous next first earlier \
der die das ein eine einen einem einer und oder aber denn also dann wenn zu im am um bei für von mit nach aus über unter zwischen durch bis seit ohne gegen \
ich du er sie es wir ihr mich mir mein meine meinen dein deine sein seine ihre unser unsere dies diese dieser hier dort \
was wer wo wann warum wie welche welcher welches \
ist bin bist sind war waren wird werden wurde habe hast hat haben hatte kann kannst können konnte soll sollte will willst möchte muss müssen \
steht stehen stand sag sagt zeig zeige gib such suche suchen finde finden lies lesen schau schauen weiß wissen schrieb schreib \
zusammenfassung zusammenfassen erkläre erklär \
nicht kein keine noch schon auch bitte etwas nichts alles viel mehr weniger sehr nur andere \
notiz notizen dokument dokumente datei dateien ordner kalender termin termine erinnerung erinnerungen aufgabe aufgaben \
nachricht nachrichten bildschirm quelle quellen ungelesen gelesen beantwortet antwort offen offene unbeantwortet unbeantwortete \
heute morgen gestern woche monat jahr montag dienstag mittwoch donnerstag freitag samstag sonntag letzte neueste neu vorige nächste";

/// Woorden die nooit een goede zoekterm zijn: vulwoorden, vraagwoorden, bronnamen en datums (NL, EN, DE).
pub fn stopwords() -> &'static HashSet<&'static str> {
    static S: OnceLock<HashSet<&'static str>> = OnceLock::new();
    S.get_or_init(|| STOPWORDS.split_whitespace().collect())
}

pub fn terms(text: &str, history: &[ChatTurn]) -> Terms {
    let mut terms = extract(text);
    // Een korte vervolgvraag ("en het budget?") gaat over hetzelfde als de vraag ervoor.
    if let Some(previous) = history.iter().rev().find(|t| t.from_user) {
        if terms.words.len() < 2 && terms.phrases.is_empty() && is_follow_up(text) {
            let before = extract(&previous.text);
            if !before.is_empty() {
                for word in before.words {
                    if !terms.words.contains(&word) {
                        terms.words.push(word);
                    }
                }
                for phrase in before.phrases {
                    if !terms.phrases.contains(&phrase) {
                        terms.phrases.push(phrase);
                    }
                }
                for name in before.names {
                    if !terms.names.contains(&name) {
                        terms.names.push(name);
                    }
                }
                terms.inherited = true;
            }
        }
    }
    terms.words.truncate(8);
    terms
}

fn extract(text: &str) -> Terms {
    let mut terms = Terms::default();
    // "…", „…", “…" of ‘…': een zin om heel te houden (niet de apostrof van "m'n" of "Jan's").
    for caps in rx!(r#"["“„‘]([^"“”„‘’]{2,60})["”’]"#).captures_iter(text).flatten() {
        let phrase = caps[1].trim().to_lowercase();
        if !phrase.is_empty() && !terms.phrases.contains(&phrase) {
            terms.phrases.push(phrase);
        }
    }
    let tokens: Vec<&str> = text
        .split(|c: char| !(c.is_alphanumeric() || c == '-' || c == '.' || c == '@'))
        .map(|t| t.trim_matches(|c| c == '-' || c == '.'))
        .filter(|t| !t.is_empty())
        .collect();
    let mut seen = HashSet::new();
    let mut words: Vec<(String, usize)> = vec![];
    // De naam van een bron zegt waar je moet kijken, niet waarnaar.
    let source_names: HashSet<String> = sources::all().iter().map(|d| d.title.to_lowercase()).filter(|t| !t.contains(' ')).collect();
    for (index, token) in tokens.iter().enumerate() {
        let lower = token.to_lowercase();
        if !seen.insert(lower.clone()) || stopwords().contains(lower.as_str()) || source_names.contains(&lower) || is_date_or_time(&lower) {
            continue;
        }
        let has_digit = lower.chars().any(|c| c.is_numeric());
        let has_letter = lower.chars().any(|c| c.is_alphabetic());
        let length = lower.chars().count();
        // Een los getal telt pas vanaf vier cijfers (een jaar, een factuurnummer), niet de "14" van "14:30".
        let keep = if has_letter { length >= 3 || has_digit } else { has_digit && length >= 4 };
        if !keep {
            continue;
        }
        words.push((lower.clone(), index));
        // Een hoofdletter midden in een zin is waarschijnlijk een naam; het eerste woord kan de zin gewoon beginnen.
        let mut chars = token.chars();
        if chars.next().is_some_and(|c| c.is_uppercase()) && (index > 0 || (token.chars().count() > 1 && chars.any(|c| c.is_uppercase()))) {
            terms.names.push(token.to_string());
        }
    }
    let names: HashSet<String> = terms.names.iter().map(|n| n.to_lowercase()).collect();
    words.sort_by(|a, b| {
        let (na, nb) = (names.contains(&a.0), names.contains(&b.0));
        nb.cmp(&na).then(b.0.chars().count().cmp(&a.0.chars().count())).then(a.1.cmp(&b.1))
    });
    terms.words = words.into_iter().map(|w| w.0).collect();
    terms
}

fn is_date_or_time(word: &str) -> bool {
    matches(
        rx!(
            r"^(\d{1,2}[:.]\d{2}|\d{1,2}(u|h|uur|am|pm)|\d{4}-\d{2}-\d{2}|\d{1,2}[-/]\d{1,2}([-/]\d{2,4})?|\d{1,2}(e|ste|de|st|nd|rd|th))$"
        ),
        word,
    )
}

fn is_follow_up(text: &str) -> bool {
    let lower = text.trim().to_lowercase();
    lower.split_whitespace().count() <= 6
        || matches(
            rx!(
                r"^(en|and|und|ook|also|wat nog|what else|meer|more|verder|further)\b|\b(die|dat|daar\w*|erin|ervan|erover|hem|haar|it|that|those|them|there|darin|davon)\b"
            ),
            &lower,
        )
}

/// De vraag zoekt iets op (in plaats van een groet of een opdracht als "pauzeer de muziek").
pub fn is_lookup(text: &str) -> bool {
    let lower = text.trim().to_lowercase();
    lower.contains('?')
        || matches(
            rx!(
                r"^(nook,? )?(wat|wie|waar|wanneer|waarom|hoe|welke?|hoeveel|heb|hebben|is|zijn|was|staat|stond|weet|ken|kun|kan|zoek|vind|lees|toon|laat|geef|vertel|vat|check|kijk|what|who|where|when|why|how|which|do|does|did|is|are|was|have|has|find|search|look|read|show|tell|give|summari[sz]e|check|was|wer|wo|wann|warum|wie|welche|habe|hast|suche|finde|lies|zeig|gib|erzähl|fasse)\b"
            ),
            &lower,
        )
        || matches(
            rx!(
                r"\b(samenvatting|samenvatten|vat .{0,40}samen|summary|summari[sz]e|zusammenfass\w*|wat (staat|stond|weet|zei|schreef)|what (does|did|do) .{0,30}(say|said|write|wrote))\b"
            ),
            &lower,
        )
}

/// De vraag wil de inhoud van iets ("lees mijn laatste notitie", "vat de mail samen"), niet alleen een lijst.
pub fn wants_content(text: &str) -> bool {
    matches(
        rx!(
            r"(?i)\b(lees|lezen|voor ?lezen|samenvat\w*|vat .{0,40}samen|samenvatting|inhoud|wat staat er|wat stond er|read|summari[sz]e|summary|content|what does .{0,30}say|lies|lesen|zusammenfass\w*|inhalt)\b"
        ),
        text,
    )
}

/// Zoektools die Nook kent, met de tool die een treffer opent (niets: de treffer is al compleet).
pub fn reader_of(tool: &str) -> Option<Option<&'static str>> {
    Some(match tool {
        "search_notes" | "list_notes" => Some("read_note"),
        "search_mail" => Some("read_mail"),
        "inbox_mail" => None,
        "search_files" => Some("read_file"),
        "notion_search" => Some("notion_read_page"),
        "github_search" => Some("github_issue_details"),
        "search_web" => Some("read_webpage"),
        "search_messages" | "messages_open_chats" => Some("read_messages"),
        "search_whatsapp" | "whatsapp_open_chats" => Some("read_whatsapp"),
        "search_bear" => Some("read_bear"),
        "search_things" | "search_reminders" | "search_contacts" => None,
        _ => return None,
    })
}

/// Een lees-tool die een zoektekst neemt en verder niets nodig heeft.
pub fn is_search(tool: &prefetch::Available) -> bool {
    tool.query.as_ref().is_some_and(|field| tool.required.iter().all(|r| r == field))
}

/// De tool om een bron mee te doorzoeken, en de invoer voor deze termen.
pub fn search(source: &str, terms: &Terms, question: &str, available: &[prefetch::Available]) -> Option<prefetch::Call> {
    if terms.is_empty() {
        return None;
    }
    let candidates: Vec<&prefetch::Available> = available.iter().filter(|a| a.source == source).collect();
    let tool =
        candidates.iter().find(|a| reader_of(&a.name).is_some() && is_search(a)).or_else(|| candidates.iter().find(|a| is_search(a)))?;
    let field = tool.query.clone().unwrap_or_else(|| "query".into());
    let text = match tool.name.as_str() {
        // Een zoekmachine begrijpt de vraag zelf beter dan een zak woorden.
        "search_web" => question.trim().chars().take(160).collect(),
        "search_contacts" => terms.names.first()?.clone(),
        "search_reminders" | "notion_search" => terms.query(1),
        "search_notes" | "search_mail" | "search_messages" | "search_whatsapp" | "search_bear" | "search_things" => terms.query(6),
        _ => terms.query(3),
    };
    if text.is_empty() {
        return None;
    }
    let mut input = Map::new();
    input.insert(field, Value::String(text));
    Some(prefetch::Call { tool: tool.name.clone(), input: Value::Object(input) })
}

/// Bronnen voor een vraag die er geen noemt: alles wat Nook kan doorzoeken, behalve het web, contacten en het scherm.
pub fn searchable(available: &[prefetch::Available], active: &HashSet<String>) -> HashSet<String> {
    let skip = [sources::WEB, "contacts", sources::SCREEN, "clipboard", "browser", "terminal"];
    available
        .iter()
        .filter(|a| active.contains(&a.source) && !skip.contains(&a.source.as_str()) && is_search(a))
        .map(|a| a.source.clone())
        .collect()
}

/// De bronnen om in te kijken voor deze vraag. `named` zijn de bronnen die de vraag zelf noemt: dan zei de gebruiker
/// waar Nook moet kijken, en wordt er nooit overal anders gezocht.
pub fn sources_for(
    question: &str,
    intent: &ChatIntent,
    terms: &Terms,
    relevant: &HashSet<String>,
    previous: &HashSet<String>,
    named: &HashSet<String>,
    available: &[prefetch::Available],
    active: &HashSet<String>,
) -> HashSet<String> {
    let mut result = relevant.clone();
    if terms.inherited {
        result.extend(previous.iter().cloned());
    }
    let own: HashSet<String> = result.iter().filter(|s| !prefetch::in_context(s)).cloned().collect();
    if own.is_empty() && named.is_empty() && intent.kinds.is_empty() && !terms.is_empty() && is_lookup(question) {
        result.extend(searchable(available, active));
    }
    let asks_name = (is_lookup(question) && named.is_empty()) || own.contains("contacts") || named.contains("contacts");
    if !terms.names.is_empty() && active.contains("contacts") && asks_name {
        result.insert("contacts".into());
    }
    result
}

/// De opzoekingen voor deze bronnen: zoeken met de termen waar dat kan, anders (of als de vraag om het nieuwste vraagt)
/// het overzicht van de bron.
pub fn lookups(
    question: &str,
    terms: &Terms,
    sources: &HashSet<String>,
    available: &[prefetch::Available],
    limit: usize,
) -> Vec<prefetch::Call> {
    let order = sources::order();
    let mut list: Vec<&String> = sources.iter().filter(|s| !prefetch::in_context(s)).collect();
    list.sort_by_key(|s| (sources::rank(s, &order), s.to_string()));
    let mut searches = vec![];
    let mut overviews = vec![];
    for source in list {
        let found = search(source, terms, question, available);
        let none = found.is_none();
        if let Some(call) = found {
            searches.push(call);
        }
        if none || prefetch::prefers_listing(source, question) {
            overviews.extend(prefetch::calls(question, &HashSet::from([source.clone()]), available, 1));
        }
    }
    searches.extend(overviews);
    searches.truncate(limit);
    searches
}

/// Leestools die bij deze tools horen, zodat een model dat kan zoeken ook kan openen wat het vindt.
pub fn companions(tools: &[&str]) -> Vec<String> {
    let mut result: Vec<String> = vec![];
    for tool in tools {
        if let Some(Some(reader)) = reader_of(tool) {
            if !tools.contains(&reader) && !result.iter().any(|r| r == reader) {
                result.push(reader.to_string());
            }
        }
    }
    result
}

/// Iets wat een zoekopdracht vond, en hoe je het volledig opent.
#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub tool: String,
    pub title: String,
    pub text: String,
    pub read: Option<String>,
    pub input: Value,
    /// De zoekopdracht liet het al helemaal zien.
    pub complete: bool,
    pub position: usize,
}

impl Hit {
    fn new(tool: &str, title: String, text: String, read: Option<&str>, input: Value) -> Self {
        Self { tool: tool.into(), title, text, read: read.map(str::to_string), input, complete: false, position: 0 }
    }
}

fn headed(output: &str) -> Vec<(String, String)> {
    let mut sections: Vec<(String, String)> = vec![];
    for line in output.split('\n') {
        if let Some(heading) = line.strip_prefix("### ") {
            sections.push((heading.into(), String::new()));
        } else if let Some(last) = sections.last_mut() {
            // Het grootboek zet de genummerde bronnen eronder; die horen niet bij de laatste treffer.
            if line.starts_with("Sources in this result") {
                break;
            }
            if !last.1.is_empty() {
                last.1.push('\n');
            }
            last.1.push_str(line);
        }
    }
    sections.into_iter().map(|(h, b)| (h, b.trim().to_string())).collect()
}

fn bracket(key: &str, line: &str) -> Option<String> {
    let start = line.find(&format!("[{key}: "))? + key.len() + 3;
    let rest = &line[start..];
    let value = rest[..rest.find(']')?].trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn plain_title(heading: &str) -> String {
    let mut title = heading.strip_prefix("- ").unwrap_or(heading).to_string();
    for marker in [" [map: ", " [id: ", " | ", " (", " — "] {
        if let Some(i) = title.find(marker) {
            title.truncate(i);
        }
    }
    title.trim().to_string()
}

fn readable(path: &str) -> bool {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    [
        "txt", "md", "markdown", "pdf", "doc", "docx", "rtf", "rtfd", "odt", "pages", "html", "htm", "csv", "json", "xml", "yaml", "yml",
        "tex", "org", "log",
    ]
    .contains(&ext.as_str())
}

/// De treffers in één zoekresultaat, in de volgorde van de bron.
pub fn hits(output: &str, tool: &str) -> Vec<Hit> {
    let mut hits: Vec<Hit> = match tool {
        "search_notes" => headed(output)
            .into_iter()
            .map(|(heading, body)| {
                let id = bracket("id", &heading).unwrap_or_else(|| plain_title(&heading));
                let complete = body.chars().count() < 750;
                let mut hit = Hit::new(tool, plain_title(&heading), body, Some("read_note"), json!({"identifier": id}));
                hit.complete = complete;
                hit
            })
            .collect(),
        "search_bear" => headed(output)
            .into_iter()
            .filter_map(|(heading, body)| {
                let id = bracket("id", &heading)?;
                let complete = body.chars().count() < 750;
                let mut hit = Hit::new(tool, plain_title(&heading), body, Some("read_bear"), json!({"id": id}));
                hit.complete = complete;
                Some(hit)
            })
            .collect(),
        "search_messages" | "search_whatsapp" | "messages_open_chats" | "whatsapp_open_chats" => headed(output)
            .into_iter()
            .filter_map(|(heading, body)| {
                let chat = bracket("chat", &heading)?;
                let read = if tool.contains("whatsapp") { "read_whatsapp" } else { "read_messages" };
                Some(Hit::new(tool, plain_title(&heading), body, Some(read), json!({"chat": chat})))
            })
            .collect(),
        "list_notes" => output
            .split('\n')
            .filter(|l| l.starts_with("- "))
            .filter_map(|line| {
                let id = bracket("id", line)?;
                let title = plain_title(line.split(" — ").next().unwrap_or(line));
                Some(Hit::new(tool, title, String::new(), Some("read_note"), json!({"identifier": id})))
            })
            .collect(),
        "search_mail" => headed(output)
            .into_iter()
            .map(|(heading, body)| {
                let id = bracket("id", &heading);
                let complete = body.chars().count() < 650;
                let input = id.as_ref().map(|i| json!({"id": i})).unwrap_or_else(|| json!({}));
                let mut hit = Hit::new(tool, plain_title(&heading), format!("{heading}\n{body}"), id.as_ref().map(|_| "read_mail"), input);
                hit.complete = complete;
                hit
            })
            .collect(),
        "search_files" => output
            .split('\n')
            .filter(|l| l.starts_with("~/") || l.starts_with('/') || l.get(1..3) == Some(":\\"))
            .map(|path| {
                let name = path.rsplit(['/', '\\']).next().unwrap_or(path).to_string();
                Hit::new(tool, name, path.into(), readable(path).then_some("read_file"), json!({"path": path}))
            })
            .collect(),
        "notion_search" => output
            .split('\n')
            .filter(|l| l.starts_with("- "))
            .filter_map(|line| {
                let m = rx!(r"\(id [0-9a-fA-F-]{32,36}\)").find(line).ok()??;
                let id = &line[m.start() + 4..m.end() - 1];
                let title = line[2..m.start()].trim().to_string();
                Some(Hit::new(tool, title, line.into(), Some("notion_read_page"), json!({"page": id})))
            })
            .collect(),
        "github_search" => output
            .split('\n')
            .filter(|l| l.starts_with("- "))
            .filter_map(|line| {
                let m = rx!(r"^- [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#\d+").find(line).ok()??;
                let reference = &line[2..m.end()];
                let (repo, number) = reference.split_once('#')?;
                let number: u64 = number.parse().ok()?;
                let title = rx!(r"'.*'")
                    .find(line)
                    .ok()
                    .flatten()
                    .map(|t| line[t.start() + 1..t.end() - 1].to_string())
                    .unwrap_or(reference.into());
                Some(Hit::new(tool, title, line.into(), Some("github_issue_details"), json!({"repo": repo, "number": number})))
            })
            .collect(),
        "search_web" => headed(output)
            .into_iter()
            .filter_map(|(heading, body)| {
                let mut parts = body.splitn(2, '\n');
                let url = parts.next()?.trim().to_string();
                if !url.starts_with("https://") {
                    return None;
                }
                Some(Hit::new(tool, plain_title(&heading), parts.next().unwrap_or("").into(), Some("read_webpage"), json!({"url": url})))
            })
            .collect(),
        _ => vec![],
    };
    for (index, hit) in hits.iter_mut().enumerate() {
        hit.position = index;
    }
    hits
}

/// Hoe goed een treffer past: een woord in de titel telt drie keer, in de tekst één keer; een zin twee keer zoveel.
pub fn score(title: &str, text: &str, terms: &Terms) -> usize {
    let (title, text) = (fold(title), fold(text));
    let mut score = 0;
    for phrase in &terms.phrases {
        let folded = fold(phrase);
        if title.contains(&folded) {
            score += 6;
        } else if text.contains(&folded) {
            score += 2;
        }
    }
    for word in &terms.words {
        let folded = fold(word);
        if title.contains(&folded) {
            score += 3;
        } else if text.contains(&folded) {
            score += 1;
        }
    }
    score
}

/// Hoe je een treffer opent van een zoekopdracht die Nook niet kent: de leestool van de bron en het ene veld.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opener {
    pub tool: String,
    pub field: String,
}

/// De treffers die het openen waard zijn, beste eerst, over alle bronnen heen.
pub fn to_open(
    results: &[(String, String)],
    terms: &Terms,
    wants_content: bool,
    available: &HashSet<String>,
    limit: usize,
    per_source: usize,
    openers: &HashMap<String, Opener>,
) -> Vec<Hit> {
    if limit == 0 {
        return vec![];
    }
    let mut candidates: Vec<(Hit, usize, usize)> = vec![];
    for (order, (tool, output)) in results.iter().enumerate() {
        let mut found = hits(output, tool);
        if found.is_empty() {
            if let Some(opener) = openers.get(tool) {
                found = generic_hits(output, tool, opener);
            }
        }
        for mut hit in found {
            if matches!(hit.read.as_deref(), Some("read_messages") | Some("read_whatsapp")) && !terms.is_empty() {
                hit.input["query"] = Value::String(terms.query(6));
            }
            let Some(read) = &hit.read else { continue };
            if !available.contains(read) || hit.complete {
                continue;
            }
            if terms.is_empty() {
                if wants_content && hit.position == 0 {
                    candidates.push((hit, 1, order));
                }
                continue;
            }
            let value = score(&hit.title, &hit.text, terms);
            if value > 0 {
                candidates.push((hit, value, order));
            }
        }
    }
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.position.cmp(&b.0.position)).then(a.2.cmp(&b.2)));
    let mut picked = vec![];
    let mut per_tool: HashMap<String, usize> = HashMap::new();
    for (hit, _, _) in candidates {
        if picked.len() >= limit {
            break;
        }
        let key = hit.read.clone().unwrap_or_else(|| hit.tool.clone());
        let count = per_tool.entry(key).or_default();
        if *count >= per_source {
            continue;
        }
        *count += 1;
        picked.push(hit);
    }
    picked
}

/// Houdt de beste `keep` van de ruwe resultaten van een tool, gerangschikt op de termen (stabiel).
pub fn best<T: Clone>(chunks: &[T], terms: &Terms, keep: usize, title: impl Fn(&T) -> String, text: impl Fn(&T) -> String) -> Vec<T> {
    if terms.is_empty() {
        return chunks.iter().take(keep).cloned().collect();
    }
    let scored: Vec<(usize, &T, usize)> = chunks.iter().enumerate().map(|(i, c)| (i, c, score(&title(c), &text(c), terms))).collect();
    let matching: Vec<&(usize, &T, usize)> = scored.iter().filter(|s| s.2 > 0).collect();
    let mut pool: Vec<&(usize, &T, usize)> = if matching.is_empty() { scored.iter().collect() } else { matching };
    pool.sort_by(|a, b| b.2.cmp(&a.2).then(a.0.cmp(&b.0)));
    pool.into_iter().take(keep).map(|s| s.1.clone()).collect()
}

/// Een zoekopdracht opgedeeld in de woorden waarop hij matcht.
pub fn words_of(query: &str) -> Vec<String> {
    let quoted = extract(query);
    let words: Vec<String> = if quoted.is_empty() {
        query.to_lowercase().split(' ').filter(|w| w.chars().count() >= 2).map(str::to_string).collect()
    } else {
        quoted.all()
    };
    words.into_iter().take(6).collect()
}

/// Voor elke zoekopdracht van een bron die Nook niet kent: de tool van dezelfde bron die één ding opent.
pub fn openers(available: &[prefetch::Available]) -> HashMap<String, Opener> {
    let mut result = HashMap::new();
    for search in available.iter().filter(|a| reader_of(&a.name).is_none() && is_search(a)) {
        let reader = available.iter().find(|tool| {
            tool.name != search.name
                && tool.source == search.source
                && tool.required.len() == 1
                && tool.query.is_none()
                && matches(rx!(r"(?i)(get|read|fetch|retrieve|show|open|view|detail|lookup|page|document|item)"), &tool.name)
        });
        if let Some(reader) = reader {
            result.insert(search.name.clone(), Opener { tool: reader.name.clone(), field: reader.required[0].clone() });
        }
    }
    result
}

fn value_text(raw: &Value) -> Option<String> {
    match raw {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn json_objects(output: &str) -> Option<Vec<Map<String, Value>>> {
    let start = output.find(['[', '{'])?;
    let closing = if output[start..].starts_with('[') { ']' } else { '}' };
    let end = output.rfind(closing)?;
    if end <= start {
        return None;
    }
    let json: Value = serde_json::from_str(&output[start..=end]).ok()?;
    if let Value::Array(list) = &json {
        let objects: Vec<Map<String, Value>> = list.iter().filter_map(|v| v.as_object().cloned()).collect();
        if objects.len() == list.len() {
            return Some(objects);
        }
    }
    let object = json.as_object()?;
    let mut keys: Vec<&String> = object.keys().collect();
    keys.sort();
    let as_objects = |v: &Value| -> Option<Vec<Map<String, Value>>> {
        let list = v.as_array()?;
        let objects: Vec<Map<String, Value>> = list.iter().filter_map(|v| v.as_object().cloned()).collect();
        (!objects.is_empty() && objects.len() == list.len()).then_some(objects)
    };
    for key in &keys {
        if let Some(list) = as_objects(&object[*key]) {
            return Some(list);
        }
        if let Some(inner) = object[*key].as_object() {
            let mut inner_keys: Vec<&String> = inner.keys().collect();
            inner_keys.sort();
            for inner_key in inner_keys {
                if let Some(list) = as_objects(&inner[inner_key]) {
                    return Some(list);
                }
            }
        }
    }
    Some(vec![object.clone()])
}

/// Treffers in de uitvoer van een onbekende zoekopdracht: de objecten van een JSON-antwoord, of elke regel met een id.
pub fn generic_hits(output: &str, tool: &str, opener: &Opener) -> Vec<Hit> {
    let id_keys = [opener.field.as_str(), "id", "key", "identifier", "uuid", "slug", "number", "url", "uri", "path"];
    let title_keys = ["title", "name", "subject", "summary", "displayName", "label", "text"];
    let mut hits = vec![];
    if let Some(objects) = json_objects(output) {
        for object in objects {
            let Some(id) = id_keys.iter().find_map(|k| object.get(*k).and_then(value_text)) else { continue };
            let title = title_keys.iter().find_map(|k| object.get(*k).and_then(value_text)).unwrap_or_else(|| id.clone());
            let mut lines: Vec<String> = object.iter().filter_map(|(k, v)| value_text(v).map(|t| format!("{k}: {t}"))).collect();
            lines.sort();
            let mut input = Map::new();
            input.insert(opener.field.clone(), Value::String(id));
            let mut hit = Hit::new(tool, title, lines.join("\n"), Some(&opener.tool), Value::Object(input));
            hit.position = hits.len();
            hits.push(hit);
        }
        return hits;
    }
    for line in output.split('\n') {
        if line.starts_with("Sources in this result") || line.starts_with('[') {
            continue;
        }
        let Some(caps) = rx!(r#"(?i)\b(?:id|key)\s*[:=]?\s*["'`]?([A-Za-z0-9][A-Za-z0-9_\-:./]{1,80})"#).captures(line).ok().flatten()
        else {
            continue;
        };
        let id = caps[1].trim_matches(|c| "\"'`.,;)".contains(c)).to_string();
        let mut input = Map::new();
        input.insert(opener.field.clone(), Value::String(id));
        let title = line.trim_matches(|c| "-*• ".contains(c)).to_string();
        let mut hit = Hit::new(tool, title, line.into(), Some(&opener.tool), Value::Object(input));
        hit.position = hits.len();
        hits.push(hit);
    }
    hits
}

const ITEMIZED: [&str; 10] = [
    "search_notes",
    "search_mail",
    "search_bear",
    "search_messages",
    "search_whatsapp",
    "search_files",
    "github_search",
    "notion_search",
    "search_things",
    "search_reminders",
];

/// Een zoekresultaat zonder de items die niets met de vraag te maken hebben. Is niets erover, dan staat dat er.
pub fn relevant_only(output: &str, tool: &str, terms: &Terms) -> String {
    if terms.is_empty() || !ITEMIZED.contains(&tool) {
        return output.to_string();
    }
    let headed_tools = ["search_notes", "search_mail", "search_bear", "search_messages", "search_whatsapp"];
    let starts = |line: &str| {
        if headed_tools.contains(&tool) {
            line.starts_with("### ")
        } else {
            line.starts_with("- ") || line.starts_with("~/") || line.starts_with('/')
        }
    };
    let (mut head, mut items, mut tail): (Vec<&str>, Vec<Vec<&str>>, Vec<&str>) = (vec![], vec![], vec![]);
    for line in output.split('\n') {
        if !tail.is_empty() || line.starts_with("Sources in this result") {
            tail.push(line);
        } else if starts(line) {
            items.push(vec![line]);
        } else if let Some(last) = items.last_mut() {
            last.push(line);
        } else {
            head.push(line);
        }
    }
    if items.is_empty() {
        return output.to_string();
    }
    let total = items.len();
    let kept: Vec<Vec<&str>> = items.into_iter().filter(|item| score(item[0], &item[1..].join("\n"), terms) > 0).collect();
    let words = terms.query(6);
    if kept.is_empty() {
        return format!("({total} results, none of them about \"{words}\".)");
    }
    if kept.len() == total {
        return output.to_string();
    }
    let note = format!("({} results that are not about \"{words}\" left out.)", total - kept.len());
    let mut lines: Vec<&str> = head;
    for item in &kept {
        lines.extend(item.iter().copied());
    }
    lines.push(&note);
    lines.extend(tail);
    lines.join("\n")
}

/// De delen van een lange tekst (een venster, een pagina) die over de vraag gaan: elke regel die past, met twee regels
/// ervoor en erna. Zonder treffer het begin van de tekst.
pub fn focus(text: &str, terms: &Terms, limit: usize) -> String {
    if terms.is_empty() || text.chars().count() <= limit / 2 {
        return text.chars().take(limit).collect();
    }
    let (body, sources) = match text.find("\n\nSources in this result") {
        Some(i) => (&text[..i], &text[i..]),
        None => (text, ""),
    };
    let lines: Vec<&str> = body.split('\n').collect();
    let hits: Vec<usize> = (0..lines.len()).filter(|i| score("", lines[*i], terms) > 0).collect();
    let room = limit.saturating_sub(sources.chars().count());
    if hits.is_empty() {
        return body.chars().take(room).collect::<String>() + sources;
    }
    let mut keep: BTreeSet<usize> = BTreeSet::from([0]);
    for index in hits {
        keep.extend(index.saturating_sub(2)..=(index + 2).min(lines.len() - 1));
    }
    let mut parts: Vec<&str> = vec![];
    let mut previous: Option<usize> = None;
    let mut size = 0;
    for index in keep {
        if previous.is_some_and(|p| index > p + 1) {
            parts.push("…");
        }
        parts.push(lines[index]);
        size += lines[index].chars().count() + 1;
        previous = Some(index);
        if size > room {
            break;
        }
    }
    format!("(The parts about \"{}\":)\n{}{}", terms.query(6), parts.join("\n"), sources)
}

/// Bouwuitvoer en geïnstalleerde pakketten zijn nooit waar iemand naar vraagt.
pub fn is_build_output(path: &str) -> bool {
    let parts = [
        "/node_modules/",
        "/dist/",
        "/build/",
        "/.build/",
        "/DerivedData/",
        "/Pods/",
        "/.git/",
        "/vendor/",
        "/.next/",
        "/.nuxt/",
        "/target/",
        "/coverage/",
        "/.cache/",
        "/__pycache__/",
        "/.venv/",
        "/venv/",
    ];
    let unified = path.replace('\\', "/");
    parts.iter().any(|p| unified.contains(p)) || path.ends_with(".map") || path.ends_with(".min.js")
}

/// Broncode: past bij bijna elk woord maar is zelden het antwoord op een vraag over je eigen leven.
pub fn is_source_code(path: &str) -> bool {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    [
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "go", "rs", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "mm", "rb",
        "php", "cs", "css", "scss", "less", "vue", "svelte", "sh", "lock", "plist", "xcconfig", "pbxproj", "gradle",
    ]
    .contains(&ext.as_str())
}

/// Zoektreffers in de volgorde die het tonen waard is: documenten eerst, dan code; bouwuitvoer weg.
pub fn rank_files(paths: &[String], code_first: bool) -> Vec<String> {
    let kept: Vec<&String> = paths.iter().filter(|p| !is_build_output(p)).collect();
    let (code, documents): (Vec<&String>, Vec<&String>) = kept.into_iter().partition(|p| is_source_code(p));
    let ordered = if code_first { code.into_iter().chain(documents) } else { documents.into_iter().chain(code) };
    ordered.cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::prefetch::Available;
    use super::*;

    fn available() -> Vec<Available> {
        vec![
            Available::new("search_notes", "notes", &["query"], Some("query")),
            Available::new("list_notes", "notes", &[], None),
            Available::new("read_note", "notes", &["identifier"], None),
            Available::new("search_mail", "mail", &["query"], Some("query")),
            Available::new("inbox_mail", "mail", &[], None),
            Available::new("read_mail", "mail", &["id"], None),
            Available::new("search_files", "files", &["query"], Some("query")),
            Available::new("read_file", "files", &["path"], None),
            Available::new("search_web", "web", &["query"], Some("query")),
            Available::new("search_contacts", "contacts", &["query"], Some("query")),
            Available::new("list_events", "calendar", &["from", "to"], None),
        ]
    }

    fn set(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    fn active() -> HashSet<String> {
        set(&["calendar", "reminders", "loops", "notes", "mail", "files", "web", "contacts"])
    }

    #[test]
    fn terms_keep_only_the_words_that_carry_the_question() {
        assert_eq!(terms("Wat staat er in mijn notitie over de verbouwing?", &[]).words, vec!["verbouwing"]);
        let lisa = terms("Wat zei Lisa in haar mail over de offerte voor de keuken?", &[]);
        assert_eq!(lisa.words, vec!["lisa", "offerte", "keuken"]);
        assert_eq!(lisa.names, vec!["Lisa"]);
        assert_eq!(terms("What did Tom write about the launch plan?", &[]).words, vec!["tom", "launch", "plan"]);
        assert_eq!(terms("Wat moet ik morgen om 14:30 doen voor Apollo?", &[]).words, vec!["apollo"]);
        assert!(terms("Welke notities heb ik?", &[]).is_empty());
        assert_eq!(terms("Zoek factuur 20251043 in mijn mail", &[]).words, vec!["20251043", "factuur"]);
        let apostrophes = terms("Wat staat er in m'n notitie over Jan's verbouwing?", &[]);
        assert!(apostrophes.phrases.is_empty() && apostrophes.words.contains(&"verbouwing".to_string()));
        let quoted = terms("Zoek mijn notitie \"plan van aanpak\"", &[]);
        assert_eq!(quoted.phrases, vec!["plan van aanpak"]);
        assert!(quoted.query(4).starts_with("plan van aanpak"));
        assert!(terms("Heb ik chats openstaan in whatsapp", &[]).is_empty());
        assert!(terms("Do I have unanswered WhatsApp chats?", &[]).is_empty());
    }

    #[test]
    fn follow_up_keeps_what_the_conversation_was_about() {
        let history = vec![
            ChatTurn { from_user: true, text: "Wat staat er in mijn notitie over de verbouwing?".into() },
            ChatTurn { from_user: false, text: "In je notitie Verbouwing keuken staat de offerte van Jansen.".into() },
        ];
        let follow = terms("En het budget?", &history);
        assert_eq!(follow.words, vec!["budget", "verbouwing"]);
        assert!(follow.inherited);
        assert!(!terms("Wat zei Lisa over de offerte voor de keuken?", &history).inherited);
    }

    #[test]
    fn where_to_search() {
        let question = "Wat weet ik over project Apollo?";
        let found = sources_for(
            question,
            &ChatIntent::detect(question),
            &terms(question, &[]),
            &set(&["calendar"]),
            &HashSet::new(),
            &HashSet::new(),
            &available(),
            &active(),
        );
        assert_eq!(found, set(&["calendar", "notes", "mail", "files", "contacts"]));
        let command = "Zet de muziek wat zachter";
        let found = sources_for(
            command,
            &ChatIntent::detect(command),
            &terms(command, &[]),
            &set(&["calendar"]),
            &HashSet::new(),
            &HashSet::new(),
            &available(),
            &active(),
        );
        assert_eq!(found, set(&["calendar"]));
        let named = "Wat staat er in Bear over Apollo?";
        let found = sources_for(
            named,
            &ChatIntent::detect(named),
            &terms(named, &[]),
            &set(&["calendar"]),
            &HashSet::new(),
            &set(&["bear"]),
            &available(),
            &active(),
        );
        assert_eq!(found, set(&["calendar"]));
    }

    #[test]
    fn lookups_search_with_the_terms() {
        let question = "Wat zei Lisa over de offerte?";
        let calls = lookups(question, &terms(question, &[]), &set(&["calendar", "notes", "mail"]), &available(), 6);
        assert_eq!(calls.iter().map(|c| c.tool.as_str()).collect::<Vec<_>>(), vec!["search_notes", "search_mail"]);
        assert_eq!(calls[0].input["query"], "lisa offerte");
        let list = lookups("Welke notities heb ik?", &terms("Welke notities heb ik?", &[]), &set(&["notes"]), &available(), 6);
        assert_eq!(list[0].tool, "list_notes");
        let unread = "Heb ik nog ongelezen mail van Lisa?";
        let calls = lookups(unread, &terms(unread, &[]), &set(&["mail"]), &available(), 6);
        assert_eq!(calls[0].tool, "search_mail");
        assert_eq!(calls.len(), 2);
        assert!(search("contacts", &terms("wat is het nummer van de loodgieter?", &[]), "", &available()).is_none());
        let named = search("contacts", &terms("Wat is het nummer van Lisa?", &[]), "", &available()).unwrap();
        assert_eq!(named.input["query"], "Lisa");
    }

    #[test]
    fn only_tools_with_a_search_field_count_as_search() {
        assert!(is_search(&Available::new("mcp_search", "linear", &["query"], Some("query"))));
        assert!(!is_search(&Available::new("list_notes", "notes", &[], None)));
        assert!(!is_search(&Available::new("mcp_get", "linear", &["query", "team"], Some("query"))));
        assert_eq!(Available::query_field(&json!({"properties": {"q": {"type": "string"}}})).as_deref(), Some("q"));
        assert_eq!(Available::query_field(&json!({"properties": {"path": {"type": "string"}}})), None);
    }

    fn long_body() -> String {
        "De keuken wordt in november verbouwd. ".repeat(30)
    }

    #[test]
    fn hits_of_every_source_know_how_to_open() {
        let note = hits(
            &format!("### Verbouwing keuken [map: Huis] | 2026-10-01 [id: x-coredata://ABC/ICNote/p12]\n{}", long_body()),
            "search_notes",
        );
        assert_eq!(note[0].title, "Verbouwing keuken");
        assert_eq!(note[0].input["identifier"], "x-coredata://ABC/ICNote/p12");
        let mail = hits(
            &format!("### Offerte verbouwing | from Jansen <info@jansen.nl> | 2026-10-02 [id: abc@jansen.nl]\n{}", long_body()),
            "search_mail",
        );
        assert_eq!(mail[0].title, "Offerte verbouwing");
        assert_eq!(mail[0].input["id"], "abc@jansen.nl");
        let files = hits("~/Documents/Offerte keuken.pdf\n~/Pictures/keuken.jpg", "search_files");
        assert_eq!(files.iter().map(|h| h.read.clone()).collect::<Vec<_>>(), vec![Some("read_file".to_string()), None]);
        let github = hits("3 results:\n- IAMichan/nook#12 [issue, open] 'Launch checklist' · updated 1 okt", "github_search");
        assert_eq!(github[0].input["repo"], "IAMichan/nook");
        assert_eq!(github[0].input["number"], 12);
        assert_eq!(github[0].title, "Launch checklist");
        let notion = hits("- Roadmap Q4 (id 1234abcd-1234-1234-1234-1234567890ab) · edited 1 okt", "notion_search");
        assert_eq!(notion[0].title, "Roadmap Q4");
        let web = hits("### Weer Amsterdam\nhttps://weer.example/amsterdam\nZonnig, 18 graden", "search_web");
        assert_eq!(web[0].input["url"], "https://weer.example/amsterdam");
    }

    #[test]
    fn the_best_matches_across_sources_are_opened() {
        let notes = format!("### Boodschappen | 2026-10-15 [id: n1]\nmelk, eieren\n### Verbouwing keuken [map: Huis] | 2026-10-01 [id: n2]\n{} Het budget is 15.000 euro.", long_body());
        let mail = format!("### Offerte verbouwing | from Jansen | 2026-10-02 [id: m1]\n{}", long_body());
        let readers = set(&["read_note", "read_mail", "read_file"]);
        let results = vec![("search_notes".to_string(), notes), ("search_mail".to_string(), mail.clone())];
        let open = to_open(&results, &Terms::words(&["verbouwing", "budget"]), false, &readers, 3, 2, &HashMap::new());
        assert_eq!(open.iter().map(|h| h.title.as_str()).collect::<Vec<_>>(), vec!["Verbouwing keuken", "Offerte verbouwing"]);
        let short = vec![("search_notes".to_string(), "### Verbouwing | 2026-10-01 [id: n2]\nBudget 15.000 euro.".to_string())];
        assert!(to_open(&short, &Terms::words(&["verbouwing"]), false, &set(&["read_note"]), 3, 2, &HashMap::new()).is_empty());
        let no_reader = vec![("search_mail".to_string(), mail)];
        assert!(to_open(&no_reader, &Terms::words(&["verbouwing"]), false, &set(&["read_note"]), 3, 2, &HashMap::new()).is_empty());
        let list = vec![(
            "list_notes".to_string(),
            "Recente notities:\n- Boodschappen (Huis) — gewijzigd 2026-10-15 [id: n1]\n- Werk — gewijzigd 2026-10-14 [id: n2]".to_string(),
        )];
        let newest = to_open(&list, &Terms::default(), true, &set(&["read_note"]), 2, 2, &HashMap::new());
        assert_eq!(newest.len(), 1);
        assert_eq!(newest[0].input["identifier"], "n1");
        assert!(wants_content("Lees mijn laatste notitie voor"));
    }

    #[test]
    fn ranking_and_matching() {
        let chunks = vec!["Boodschappen melk", "Verbouwing keuken budget", "Keuken ideeën", "Verbouwing badkamer"];
        let ranked = best(&chunks, &Terms::words(&["verbouwing", "keuken"]), 3, |c| c.to_string(), |_| String::new());
        assert_eq!(ranked, vec!["Verbouwing keuken budget", "Keuken ideeën", "Verbouwing badkamer"]);
        assert!(score("Café De Kroon", "", &Terms::words(&["cafe"])) > 0);
        assert_eq!(companions(&["search_notes", "search_mail", "read_note"]), vec!["read_mail"]);
        assert!(companions(&["search_reminders"]).is_empty());
        assert!(is_lookup("Wat weet ik over Apollo?") && is_lookup("zoek de offerte van Jansen"));
        assert!(is_lookup("Vat mijn notities over de verbouwing samen") && !is_lookup("Zet de muziek wat zachter"));
    }

    #[test]
    fn unrelated_results_are_left_out() {
        let output = "### Verbouwing keuken | 2026-10-01 [id: n1]\nOfferte van Jansen.\n### Recept appeltaart | 2026-09-01 [id: n2]\n- appels\n- kaneel\nSources in this result (cite using the bracketed number, e.g. [1]):\n[1] Verbouwing keuken";
        let kept = relevant_only(output, "search_notes", &Terms::words(&["verbouwing"]));
        assert!(kept.contains("Verbouwing keuken") && !kept.contains("appeltaart") && !kept.contains("kaneel"));
        assert!(kept.contains("[1] Verbouwing keuken"));
        let none = relevant_only(output, "search_notes", &Terms::words(&["vakantie"]));
        assert!(none.starts_with("(2 results, none of them about"), "{none}");
        let window = (0..200).map(|i| format!("regel {i}")).collect::<Vec<_>>().join("\n")
            + "\nJan: de offerte is goedgekeurd\n"
            + &(0..200).map(|i| format!("rest {i}")).collect::<Vec<_>>().join("\n");
        let focused = focus(&window, &Terms::words(&["offerte"]), 600);
        assert!(focused.contains("Jan: de offerte is goedgekeurd") && focused.contains("regel 0") && !focused.contains("regel 100"));
    }

    #[test]
    fn mcp_hits_are_opened_with_the_servers_read_tool() {
        let available = vec![
            Available::new("mcp_linear_search_issues", "mcp.linear", &["query"], Some("query")),
            Available::new("mcp_linear_get_issue", "mcp.linear", &["id"], None),
        ];
        let openers = openers(&available);
        assert_eq!(openers["mcp_linear_search_issues"], Opener { tool: "mcp_linear_get_issue".into(), field: "id".into() });
        let json = r#"{"issues": [{"id": "ENG-12", "title": "Offerte module", "state": "open"}, {"id": "ENG-13", "title": "Login bug"}]}"#;
        let results = vec![("mcp_linear_search_issues".to_string(), json.to_string())];
        let open = to_open(&results, &Terms::words(&["offerte"]), false, &set(&["mcp_linear_get_issue"]), 3, 2, &openers);
        assert_eq!(open.iter().map(|h| h.input["id"].clone()).collect::<Vec<_>>(), vec![json!("ENG-12")]);
        let lines = "- Offerte module (id: ENG-12)\n- Login bug (id: ENG-13)";
        let opener = Opener { tool: "mcp_linear_get_issue".into(), field: "id".into() };
        let from_text = generic_hits(lines, "mcp_linear_search_issues", &opener);
        assert_eq!(from_text.iter().map(|h| h.input["id"].clone()).collect::<Vec<_>>(), vec![json!("ENG-12"), json!("ENG-13")]);
        let chats = vec![(
            "search_messages".to_string(),
            "### Jan | 2026-10-01 [chat: 7]\n- 2026-10-01 10:00 · Jan: de offerte komt morgen".to_string(),
        )];
        let open = to_open(&chats, &Terms::words(&["offerte"]), false, &set(&["read_messages"]), 2, 2, &HashMap::new());
        assert_eq!(open[0].input["chat"], "7");
        assert_eq!(open[0].input["query"], "offerte");
    }

    #[test]
    fn build_output_is_left_out_and_documents_come_first() {
        let paths: Vec<String> = [
            "/Users/m/Code/PulseGuard/apps/app/dist/assets/index-BRcVVYD8.js",
            "/Users/m/Code/Nook/Services/Connectors/AppConnectors.swift",
            "/Users/m/Documents/Offerte keuken.pdf",
            "/Users/m/Code/Nook/docs/ASSISTANT.md",
        ]
        .map(String::from)
        .to_vec();
        assert_eq!(
            rank_files(&paths, false),
            vec![
                "/Users/m/Documents/Offerte keuken.pdf",
                "/Users/m/Code/Nook/docs/ASSISTANT.md",
                "/Users/m/Code/Nook/Services/Connectors/AppConnectors.swift"
            ]
        );
        assert_eq!(rank_files(&paths, true)[0], "/Users/m/Code/Nook/Services/Connectors/AppConnectors.swift");
    }
}
