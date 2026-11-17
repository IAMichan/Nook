//! Wat Nook echt opzocht voor een antwoord. Elke lees-tool loopt hierdoorheen, voor elk brein. Zo ziet de chat welke
//! bronnen doorzocht zijn, welke iets opleverden en welke faalden, en komen er genummerde bronnen met links onder het antwoord.
//!
//! Een tool kan zelf een bron noemen met een regel van [`reference_line`]; anders wordt elke regel met een https-link een bron.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::{sources, LoopTool, ToolKind};
use crate::{NookError, Result};

/// Eén bron onder een antwoord: een mail, afspraak, document, issue, webpagina…
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceReference {
    pub number: u32,
    #[serde(default)]
    pub source_id: String,
    pub title: String,
    #[serde(default)]
    pub detail: String,
    /// Alleen https-, file- en message-adressen zijn te openen.
    #[serde(default)]
    pub url: Option<String>,
    /// What the source said: the part of the tool's result it came from, so a citation can show what the answer rests on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub excerpt: Option<String>,
}

impl SourceReference {
    /// Who sent a mail ("Vimexx" from its detail "Vimexx · 2026-11-14"); None for any other source.
    pub fn sender(&self) -> Option<String> {
        let mail = self.source_id.to_lowercase().contains("mail") || self.url.as_deref().is_some_and(|u| u.starts_with("message:"));
        if !mail {
            return None;
        }
        let name = self.detail.split(" · ").next()?.trim();
        if name.is_empty() || name.chars().next().is_some_and(|c| c.is_ascii_digit()) {
            return None;
        }
        Some(name.to_string())
    }

    pub fn is_openable(raw: Option<&str>) -> bool {
        let Some(raw) = raw else { return false };
        let Ok(url) = url::Url::parse(raw) else { return false };
        match url.scheme() {
            "https" => url.host_str().is_some_and(|h| !h.is_empty()),
            "file" | "message" => true,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum Outcome {
    Running,
    /// Iets gevonden; het getal is ongeveer hoeveel.
    Found(usize),
    Empty,
    Failed(String),
}

/// The reason shown for a search that was still running when the answer stopped.
pub const INTERRUPTED: &str = "Het zoeken werd onderbroken voordat het klaar was.";

/// The reason shown when an error said nothing a person can use.
pub const UNKNOWN_ERROR: &str = "Er ging iets mis bij het lezen.";

/// A failure as a person reads it: no raw cancellation errors or "The operation couldn't be completed". Older stored
/// answers also had these, so the interface reads them the same way.
pub fn readable_failure(reason: &str) -> String {
    let text = reason.trim();
    let lower = text.to_lowercase();
    if lower.contains("cancellationerror") || lower == "gestopt" || lower.contains("task was cancelled") || lower.contains("cancelled") {
        return INTERRUPTED.into();
    }
    if text.is_empty() || lower.contains("couldn’t be completed") || lower.contains("couldn't be completed") {
        return UNKNOWN_ERROR.into();
    }
    text.to_string()
}

/// Eén opzoeking in een bron.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RetrievalStep {
    pub id: String,
    pub tool: String,
    pub source_id: Option<String>,
    pub source_title: String,
    /// Waarop gezocht werd, kort ("offerte", "IAMichan/nook#12").
    pub query: String,
    pub outcome: Outcome,
    /// Uit de cache van een eerdere vraag (minder dan 90 seconden oud).
    pub cached: bool,
    pub references: Vec<u32>,
}

impl Default for RetrievalStep {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            tool: String::new(),
            source_id: None,
            source_title: String::new(),
            query: String::new(),
            outcome: Outcome::Running,
            cached: false,
            references: vec![],
        }
    }
}

impl RetrievalStep {
    pub fn new(tool: &str, source: Option<String>, query: String) -> Self {
        let title = source.as_deref().map(sources::title).unwrap_or_else(|| tool.to_string());
        Self { tool: tool.into(), source_id: source, source_title: title, query, ..Default::default() }
    }
}

/// Voor tools die altijd verse gegevens nodig hebben (het scherm, beschikbaarheid vlak voor het boeken).
pub const NEVER_CACHED: [&str; 3] = ["read_screen", "check_availability", "list_open_loops"];
pub const CACHE_LIFETIME: Duration = Duration::from_secs(90);

fn recent() -> &'static Mutex<HashMap<String, (Instant, String)>> {
    static R: OnceLock<Mutex<HashMap<String, (Instant, String)>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

pub fn clear_cache() {
    recent().lock().unwrap_or_else(|e| e.into_inner()).clear();
}

#[derive(Default)]
struct State {
    steps: Vec<RetrievalStep>,
    references: Vec<SourceReference>,
    /// Dezelfde opzoeking binnen één antwoord gebeurt maar één keer.
    local: HashMap<String, String>,
}

pub type OnChange = Box<dyn Fn(Vec<RetrievalStep>) + Send + Sync>;

/// Houdt bij wat er voor één antwoord opgezocht werd.
#[derive(Default)]
pub struct RetrievalLedger {
    state: Mutex<State>,
    on_change: Option<OnChange>,
}

fn sorted(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for k in keys {
                out.insert(k.clone(), sorted(&map[k]));
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

pub fn key(tool: &str, input: &Value) -> String {
    format!("{tool}|{}", sorted(input))
}

/// Korte zoekterm of doel, zonder lange teksten of geheimen.
pub fn query_of(input: &Value) -> String {
    for field in ["query", "q", "path", "repo", "name", "from"] {
        if let Some(value) = input[field].as_str().filter(|v| !v.is_empty()) {
            let mut text = value.to_string();
            if field == "repo" {
                if let Some(number) = input.get("number").filter(|n| !n.is_null()) {
                    text += &format!("#{}", number.as_str().map(str::to_string).unwrap_or_else(|| number.to_string()));
                }
            }
            return text.chars().take(60).collect();
        }
    }
    String::new()
}

impl RetrievalLedger {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_on_change(on_change: OnChange) -> Self {
        Self { state: Mutex::default(), on_change: Some(on_change) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn changed(&self) {
        if let Some(cb) = &self.on_change {
            cb(self.steps());
        }
    }

    pub fn steps(&self) -> Vec<RetrievalStep> {
        self.lock().steps.clone()
    }

    pub fn references(&self) -> Vec<SourceReference> {
        self.lock().references.clone()
    }

    /// Alles wat de tools voor dit antwoord gaven: waar een antwoord terecht uit mag citeren.
    pub fn retrieved_text(&self) -> String {
        self.lock().local.values().cloned().collect::<Vec<_>>().join("\n")
    }

    pub fn failures(&self) -> Vec<RetrievalStep> {
        self.lock().steps.iter().filter(|s| matches!(s.outcome, Outcome::Failed(_))).cloned().collect()
    }

    /// Een bron waar de vraag om vraagt maar die Nook nu niet kan lezen: getoond als mislukte zoektocht.
    pub fn note_unavailable(&self, source: &str, tool: &str, reason: &str) {
        {
            let mut state = self.lock();
            if state.steps.iter().any(|s| s.source_id.as_deref() == Some(source)) {
                return;
            }
            let mut step = RetrievalStep::new(tool, Some(source.into()), String::new());
            step.outcome = Outcome::Failed(readable_failure(reason));
            state.steps.push(step);
        }
        self.changed();
    }

    /// Draait een lees-tool met een tijdslimiet en geeft tekst voor het brein terug, met genummerde bronnen.
    pub async fn run<Fut>(&self, tool: &str, source: Option<String>, input: &Value, timeout: Duration, operation: Fut) -> Result<String>
    where
        Fut: Future<Output = Result<String>>,
    {
        let key = key(tool, input);
        let index = {
            let mut state = self.lock();
            if let Some(output) = state.local.get(&key) {
                return Ok(format!("{output}\n(Already retrieved in this response turn.)"));
            }
            state.steps.push(RetrievalStep::new(tool, source.clone().or_else(|| sources::source_for_tool(tool)), query_of(input)));
            state.steps.len() - 1
        };
        self.changed();

        let cached = (!NEVER_CACHED.contains(&tool))
            .then(|| {
                let recent = recent().lock().unwrap_or_else(|e| e.into_inner());
                recent.get(&key).filter(|(when, _)| when.elapsed() < CACHE_LIFETIME).map(|(_, output)| output.clone())
            })
            .flatten();
        let raw = match cached {
            Some(output) => {
                self.lock().steps[index].cached = true;
                output
            }
            None => {
                let result = match tokio::time::timeout(timeout, operation).await {
                    Ok(result) => result,
                    Err(_) => Err(NookError(format!("Geen antwoord binnen {} seconden.", timeout.as_secs_f64().round()))),
                };
                match result {
                    Ok(output) => {
                        let mut recent = recent().lock().unwrap_or_else(|e| e.into_inner());
                        recent.insert(key.clone(), (Instant::now(), output.clone()));
                        recent.retain(|_, (when, _)| when.elapsed() < CACHE_LIFETIME * 4);
                        output
                    }
                    Err(e) => {
                        self.lock().steps[index].outcome = Outcome::Failed(readable_failure(&e.0));
                        self.changed();
                        return Err(e);
                    }
                }
            }
        };

        let (text, found) = parse_references(&raw);
        let alone = found.len() == 1;
        let output = {
            let mut state = self.lock();
            let source_id = state.steps[index].source_id.clone().unwrap_or_else(|| tool.to_string());
            let mut numbered: Vec<SourceReference> = vec![];
            for mut reference in found.into_iter().take(10) {
                if let Some(existing) =
                    state.references.iter().find(|r| r.url.is_some() && r.url == reference.url && r.title == reference.title)
                {
                    numbered.push(existing.clone());
                    continue;
                }
                reference.number = state.references.len() as u32 + 1;
                reference.source_id = source_id.clone();
                reference.excerpt = excerpt_for(&reference.title, &text, alone);
                state.references.push(reference.clone());
                numbered.push(reference);
            }
            let lines = text.lines().filter(|l| !l.trim().is_empty()).count();
            let step = &mut state.steps[index];
            step.references = numbered.iter().map(|r| r.number).collect();
            step.outcome = if is_empty_result(&text) { Outcome::Empty } else { Outcome::Found(numbered.len().max(lines)) };
            let mut output = text;
            if let Some(first) = numbered.first() {
                output += &format!("\n\nSources in this result (cite using the bracketed number, e.g. [{}]):\n", first.number);
                let list: Vec<String> = numbered
                    .iter()
                    .map(|r| {
                        format!(
                            "[{}] {}{}",
                            r.number,
                            r.title,
                            if r.detail.is_empty() { String::new() } else { format!(" — {}", r.detail) }
                        )
                    })
                    .collect();
                output += &list.join("\n");
            }
            state.local.insert(key, output.clone());
            output
        };
        self.changed();
        Ok(output)
    }
}

/// Verpakt een lees-tool zodat elke aanroep door het grootboek gaat. Acties blijven zoals ze zijn.
pub fn ledgered(tool: LoopTool, ledger: Arc<RetrievalLedger>, timeout: Duration) -> LoopTool {
    // Alleen leestools van een bron: een grafiek tekenen of een mail opstellen is geen opzoeking.
    if tool.kind != ToolKind::Read || tool.source.is_none() {
        return tool;
    }
    let run = tool.run.clone();
    let name = tool.name.clone();
    let source = tool.source.clone();
    LoopTool {
        run: Arc::new(move |input: Value| {
            let (run, name, source, ledger) = (run.clone(), name.clone(), source.clone(), ledger.clone());
            Box::pin(async move { ledger.run(&name, source, &input.clone(), timeout, run(input)).await })
        }),
        ..tool
    }
}

/// Bevat een willekeurig deel dat bij de start gekozen wordt, zodat een mail of pagina met een regel die met "@ref"
/// begint zich niet als bron (met een link naar keuze) kan voordoen. Alleen Nooks eigen tools schrijven deze markering.
pub fn marker() -> &'static str {
    static M: OnceLock<String> = OnceLock::new();
    M.get_or_init(|| format!("@ref-{} ", &uuid::Uuid::new_v4().simple().to_string()[..8]))
}

/// Een regel waarmee een tool zelf een bron noemt (link en detail mogen leeg zijn).
pub fn reference_line(title: &str, url: Option<&str>, detail: &str) -> String {
    let clean = |t: &str| t.replace('|', "/").replace('\n', " ");
    format!("{}{} | {} | {}", marker(), clean(title), url.unwrap_or(""), clean(detail))
}

/// The longest excerpt kept per reference: enough for a mail's opening or a few chat messages.
pub const EXCERPT_LIMIT: usize = 900;

/// The part of a tool's result that a reference with `title` came from: the block under the heading that names it
/// (a mail, a chat, a note), or the line that names it (a calendar event, an issue in a list). `alone`: the result has
/// only this reference, so all of it is the source when no line names it. Ids and other bookkeeping for the model are
/// left out. None when nothing in the text belongs to it.
pub fn excerpt_for(title: &str, text: &str, alone: bool) -> Option<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    if lines.is_empty() {
        return None;
    }
    let keys = excerpt_keys(title);
    let hit = lines.iter().position(|line| {
        let lower = line.to_lowercase();
        keys.iter().any(|k| lower.contains(k))
    });
    let picked: Vec<&str> = if let Some(hit) = hit {
        let line = lines[hit].trim();
        if line.starts_with('#') || alone {
            let level = line.bytes().take_while(|&b| b == b'#').count();
            let mut end = hit + 1;
            while end < lines.len() {
                let next = lines[end].trim();
                let next_level = next.bytes().take_while(|&b| b == b'#').count();
                if next_level > 0 && (level == 0 || next_level <= level) {
                    break;
                }
                end += 1;
            }
            lines[hit..end].to_vec()
        } else {
            vec![lines[hit]]
        }
    } else if alone {
        lines
    } else {
        return None;
    };
    let mut cleaned: Vec<String> = Vec::new();
    for raw in picked {
        let line = clean_excerpt_line(raw);
        if line.is_empty() && cleaned.last().is_none_or(|last| last.is_empty()) {
            continue;
        }
        cleaned.push(line);
    }
    let mut excerpt = cleaned.join("\n").trim().to_string();
    if excerpt.is_empty() {
        return None;
    }
    if excerpt.chars().count() > EXCERPT_LIMIT {
        let cut: String = excerpt.chars().take(EXCERPT_LIMIT).collect();
        let end = cut.rfind('\n').or_else(|| cut.rfind(' ')).unwrap_or(cut.len());
        excerpt = format!("{} …", cut[..end].trim_end());
    }
    Some(excerpt)
}

fn excerpt_keys(title: &str) -> Vec<String> {
    let name = match title.find(": ") {
        Some(idx) if title[..idx].chars().count() <= 20 => &title[idx + 2..],
        _ => title,
    };
    let mut keys = vec![name.to_lowercase()];
    if let Some(hash) = name.find('#') {
        if let Some(space_rel) = name[hash..].find(' ') {
            keys.push(name[..hash + space_rel].to_lowercase());
        }
    }
    keys.into_iter().filter(|k| k.chars().count() >= 2).collect()
}

fn clean_excerpt_line(line: &str) -> String {
    let trimmed = line.trim().trim_start_matches('#').trim();
    rx!(r"\s*\[(?:id|chat): [^\]]*\]|\s*\|\s*id \S+\s*$|\s*\|\s*calendar [^|]*").replace_all(trimmed, "").into_owned()
}

/// De tekst zonder bronregels, en de bronnen.
pub fn parse_references(raw: &str) -> (String, Vec<SourceReference>) {
    let mut kept: Vec<&str> = vec![];
    let mut explicit = vec![];
    for line in raw.split('\n') {
        let Some(rest) = line.strip_prefix(marker()) else {
            kept.push(line);
            continue;
        };
        let parts: Vec<&str> = rest.splitn(3, '|').map(str::trim).collect();
        let Some(title) = parts.first().filter(|t| !t.is_empty()) else { continue };
        let url = parts.get(1).filter(|u| SourceReference::is_openable(Some(u))).map(|u| u.to_string());
        explicit.push(SourceReference {
            number: 0,
            source_id: String::new(),
            title: title.chars().take(120).collect(),
            detail: parts.get(2).map(|d| d.chars().take(120).collect()).unwrap_or_default(),
            url,
            excerpt: None,
        });
    }
    let text = kept.join("\n").trim().to_string();
    if !explicit.is_empty() {
        return (text, explicit);
    }
    let links = links(&text);
    (text, links)
}

fn links(text: &str) -> Vec<SourceReference> {
    let mut result = vec![];
    let mut seen = std::collections::HashSet::new();
    for line in text.lines() {
        let Some(m) = rx!(r#"https://[^\s<>"'\)\]]+"#).find(line).ok().flatten() else { continue };
        let url = m.as_str().trim_end_matches(['.', ',', ';', ':']).to_string();
        if !SourceReference::is_openable(Some(&url)) || !seen.insert(url.clone()) {
            continue;
        }
        let mut title = format!("{}{}", &line[..m.start()], &line[m.end()..]);
        title = title.trim_matches(|c: char| " -*|·•\t".contains(c)).to_string();
        title = rx!(r"\s*[·|]\s*$").replace(&title, "").to_string();
        if title.is_empty() {
            title = url::Url::parse(&url).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_else(|| url.clone());
        }
        result.push(SourceReference {
            number: 0,
            source_id: String::new(),
            title: title.chars().take(120).collect(),
            detail: String::new(),
            url: Some(url),
            excerpt: None,
        });
    }
    result
}

pub fn is_empty_result(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.is_empty()
        || (trimmed.chars().count() < 140
            && super::matches(rx!(r"(?i)^(geen |niets gevonden|no |nothing found|keine |leeg antwoord)"), trimmed))
}

/// Bronverwijzingen in de tekst van het brein: [1], [2, 3]. Alleen nummers van een echt opgezochte bron blijven staan.
pub mod citations {
    use std::collections::BTreeSet;

    fn pattern() -> &'static fancy_regex::Regex {
        rx!(r"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?!\()")
    }

    pub fn used(text: &str) -> BTreeSet<u32> {
        let mut result = BTreeSet::new();
        for caps in pattern().captures_iter(text).flatten() {
            for part in caps[1].split(',') {
                if let Ok(n) = part.trim().parse() {
                    result.insert(n);
                }
            }
        }
        result
    }

    /// The answer without a list of its sources written out by the model ("Sources: [4] Vimexx · [8] WhatsApp …", or
    /// a "Sources" heading over cited lines): Nook shows every source beside the fact it backs, so such a list only
    /// repeats them, out of place and with bare numbers.
    pub fn without_source_list(text: &str) -> String {
        if !text.contains('[') || used(text).is_empty() {
            return text.to_string();
        }
        let line_rx =
            rx!(r"(?i)^\s*(?:[-*]\s+)?(?:[*_]{1,2})?(?:sources?|bronnen|bron|quellen?|fuentes?)(?:[*_]{1,2})?\s*:(?:[*_]{1,2})?(.*)$");
        let heading_rx = rx!(r"(?i)^\s*(?:#{1,6}\s*|[*_]{1,2})(?:sources?|bronnen|bron|quellen?|fuentes?)\s*:?\s*(?:[*_]{1,2})?\s*$");
        let mut lines: Vec<&str> = text.split('\n').collect();
        let mut index = 0;
        let mut changed = false;
        while index < lines.len() {
            let line = lines[index];
            let remainder = if line.chars().count() < 600 {
                line_rx.captures(line).ok().flatten().and_then(|c| c.get(1).map(|m| m.as_str()))
            } else {
                None
            }
            .or_else(|| (line.chars().count() < 60 && heading_rx.is_match(line).unwrap_or(false)).then_some(""));
            let Some(remainder) = remainder else {
                index += 1;
                continue;
            };
            let rest = remainder.trim();
            let mut end = index + 1;
            if rest.is_empty() {
                if end + 1 < lines.len() && lines[end].trim().is_empty() && !used(lines[end + 1]).is_empty() {
                    end += 1;
                }
                while end < lines.len() && !lines[end].trim().is_empty() && !used(lines[end]).is_empty() {
                    end += 1;
                }
                if !(end > index + 1 && !used(lines[end - 1]).is_empty()) {
                    index += 1;
                    continue;
                }
            } else if used(rest).is_empty() {
                index += 1;
                continue;
            }
            lines.drain(index..end);
            changed = true;
        }
        if !changed {
            return text.to_string();
        }
        let joined = lines.join("\n");
        rx!(r"\n{3,}").replace_all(&joined, "\n\n").trim().to_string()
    }

    /// Haalt verwijzingen weg die bij geen bron horen; de rest blijft, ook lijstjes als [1, 4].
    pub fn sanitize(text: &str, valid: &BTreeSet<u32>) -> String {
        let mut result = String::new();
        let mut cursor = 0;
        for caps in pattern().captures_iter(text).flatten() {
            let whole = caps.get(0).expect("hele match");
            result += &text[cursor..whole.start()];
            let keep: Vec<String> = caps[1]
                .split(',')
                .filter_map(|p| p.trim().parse::<u32>().ok())
                .filter(|n| valid.contains(n))
                .map(|n| n.to_string())
                .collect();
            if !keep.is_empty() {
                result += &format!("[{}]", keep.join(", "));
            } else if result.ends_with(' ') {
                result.pop();
            }
            cursor = whole.end();
        }
        result + &text[cursor..]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn records_source_and_explicit_references() {
        let ledger = RetrievalLedger::new();
        let line = reference_line("Offerte Q4", Some("message:%3Cabc@example.com%3E"), "Lisa · 1 okt");
        let raw = format!("### Offerte Q4 | van Lisa | 2026-10-01\nWe gaan akkoord met €12.000.\n{line}");
        let output =
            ledger.run("search_mail", None, &json!({"query": "offerte-ref"}), Duration::from_secs(5), async { Ok(raw) }).await.unwrap();
        let steps = ledger.steps();
        assert_eq!(steps[0].source_id.as_deref(), Some("mail"));
        assert_eq!(steps[0].query, "offerte-ref");
        assert_eq!(ledger.references()[0].url.as_deref(), Some("message:%3Cabc@example.com%3E"));
        assert!(output.contains("[1] Offerte Q4") && !output.contains("@ref"));
        assert!(matches!(steps[0].outcome, Outcome::Found(_)));
    }

    #[tokio::test]
    async fn links_become_references_and_failures_are_recorded() {
        let ledger = RetrievalLedger::new();
        let raw =
            "- IAMichan/nook#12 'Launch checklist' [open] · https://github.com/IAMichan/nook/issues/12\n- javascript:alert(1)".to_string();
        ledger.run("github_search", None, &json!({"query": "launch-links"}), Duration::from_secs(5), async { Ok(raw) }).await.unwrap();
        assert_eq!(
            ledger.references().iter().map(|r| r.url.clone().unwrap()).collect::<Vec<_>>(),
            vec!["https://github.com/IAMichan/nook/issues/12"]
        );
        assert_eq!(ledger.references()[0].source_id, "github");
        let failed = ledger
            .run("notion_search", None, &json!({"query": "x-fail"}), Duration::from_secs(5), async {
                Err(NookError::new("Notion weigerde de sleutel (401)."))
            })
            .await;
        assert!(failed.is_err());
        assert_eq!(ledger.failures().len(), 1);
        let slow = ledger
            .run("search_files", None, &json!({"query": "x-slow"}), Duration::from_millis(50), async {
                tokio::time::sleep(Duration::from_secs(2)).await;
                Ok("te laat".to_string())
            })
            .await;
        assert!(slow.is_err());
        let input = json!({"query": "zzz-empty"});
        let empty =
            ledger.run("search_mail", None, &input, Duration::from_secs(5), async { Ok("Geen mail gevonden voor \"zzz\".".to_string()) });
        empty.await.unwrap();
        assert_eq!(ledger.steps().last().unwrap().outcome, Outcome::Empty);
    }

    #[test]
    fn failures_read_as_plain_language() {
        assert_eq!(readable_failure("Swift.CancellationError error 1"), INTERRUPTED);
        assert_eq!(readable_failure("gestopt"), INTERRUPTED);
        assert_eq!(readable_failure("The operation couldn’t be completed. (x error 1.)"), UNKNOWN_ERROR);
        assert_eq!(readable_failure("  "), UNKNOWN_ERROR);
        assert_eq!(readable_failure("Notion weigerde de sleutel (401)."), "Notion weigerde de sleutel (401).");
    }

    #[tokio::test]
    async fn the_same_call_is_not_repeated() {
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let op = |c: Arc<std::sync::atomic::AtomicUsize>| async move {
            c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok("resultaat".to_string())
        };
        let first = RetrievalLedger::new();
        let input = json!({"query": "plan-cache"});
        first.run("search_files", None, &input, Duration::from_secs(5), op(calls.clone())).await.unwrap();
        first.run("search_files", None, &input, Duration::from_secs(5), op(calls.clone())).await.unwrap();
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(first.steps().len(), 1);
        let second = RetrievalLedger::new();
        second.run("search_files", None, &input, Duration::from_secs(5), op(calls.clone())).await.unwrap();
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(second.steps()[0].cached);
        RetrievalLedger::new().run("read_screen", None, &json!({}), Duration::from_secs(5), op(calls.clone())).await.unwrap();
        RetrievalLedger::new().run("read_screen", None, &json!({}), Duration::from_secs(5), op(calls.clone())).await.unwrap();
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn reference_numbers_continue_across_tools() {
        let ledger = RetrievalLedger::new();
        let line = reference_line("Mail A", None, "");
        ledger.run("search_mail", None, &json!({"query": "a-num"}), Duration::from_secs(5), async { Ok(line) }).await.unwrap();
        let second = ledger
            .run("notion_search", None, &json!({"query": "b-num"}), Duration::from_secs(5), async {
                Ok("Plan · https://www.notion.so/plan-1".to_string())
            })
            .await
            .unwrap();
        assert_eq!(ledger.references().iter().map(|r| r.number).collect::<Vec<_>>(), vec![1, 2]);
        assert!(second.contains("[2]"));
    }

    #[test]
    fn citations_keep_only_real_numbers() {
        let text = "We spraken 1 november af [1]. Volgens Slack was het later [7]. Zie ook [1, 9] en [link](https://x.nl) [2].";
        let cleaned = citations::sanitize(text, &[1, 2].into());
        assert_eq!(cleaned, "We spraken 1 november af [1]. Volgens Slack was het later. Zie ook [1] en [link](https://x.nl) [2].");
        assert_eq!(citations::used(&cleaned), [1, 2].into());
    }

    #[test]
    fn only_safe_schemes_are_openable() {
        assert!(SourceReference::is_openable(Some("https://github.com/a/b")));
        assert!(SourceReference::is_openable(Some("file:///home/x/plan.pdf")));
        assert!(SourceReference::is_openable(Some("message:%3Cid@x%3E")));
        assert!(!SourceReference::is_openable(Some("http://example.com")));
        assert!(!SourceReference::is_openable(Some("javascript:alert(1)")));
        assert!(!SourceReference::is_openable(None));
    }

    const MAILS: &str = "\
### Achterstallige rekening | from Vimexx <billing@vimexx.nl> | 2026-11-14 [id: abc@vimexx]
De registratie van infaris.com verloopt op 20 november.
Betaal de openstaande factuur om de domeinnaam te behouden.

### Roadmap 2026-2027 Mindlinq | from Laura van Ekris | 2026-11-15 [id: def@mindlinq]
Zullen we een sessie plannen om de roadmap door te nemen?";

    #[test]
    fn a_mails_excerpt_is_its_own_block_without_ids() {
        let excerpt = excerpt_for("Achterstallige rekening", MAILS, false);
        assert_eq!(
            excerpt.as_deref(),
            Some(
                "Achterstallige rekening | from Vimexx <billing@vimexx.nl> | 2026-11-14\n\
                 De registratie van infaris.com verloopt op 20 november.\n\
                 Betaal de openstaande factuur om de domeinnaam te behouden."
            )
        );
        let other = excerpt_for("Roadmap 2026-2027 Mindlinq", MAILS, false);
        assert_eq!(
            other.as_deref(),
            Some(
                "Roadmap 2026-2027 Mindlinq | from Laura van Ekris | 2026-11-15\n\
                 Zullen we een sessie plannen om de roadmap door te nemen?"
            )
        );
    }

    #[test]
    fn a_chat_is_found_by_its_name_without_the_app() {
        let chats = "\
### Mama Jis | 16 nov [chat: 31612345678@s.whatsapp.net]
- 09:12 · Mama Jis: Kom je zondag eten?
- 09:13 · You: Ja, om zes uur";
        let excerpt = excerpt_for("WhatsApp: Mama Jis", chats, false);
        assert_eq!(excerpt.as_deref(), Some("Mama Jis | 16 nov\n- 09:12 · Mama Jis: Kom je zondag eten?\n- 09:13 · You: Ja, om zes uur"));
    }

    #[test]
    fn an_event_in_a_list_is_its_own_line() {
        let events = "\
Daily Standup | 2026-11-16T09:00 – 2026-11-16T09:15 | calendar Werk | id E1
Retrospective Mindlinq-team | 2026-11-16T13:00 – 2026-11-16T14:00 | id E2";
        assert_eq!(
            excerpt_for("Retrospective Mindlinq-team", events, false).as_deref(),
            Some("Retrospective Mindlinq-team | 2026-11-16T13:00 – 2026-11-16T14:00")
        );
        assert_eq!(excerpt_for("Daily Standup", events, false).as_deref(), Some("Daily Standup | 2026-11-16T09:00 – 2026-11-16T09:15"));
    }

    #[test]
    fn an_issue_is_found_by_its_number() {
        let issues = "- InfarisHQ/monorepo#4358 [PR, open] 'feat(guard): hosting' · updated 15 nov";
        assert_eq!(excerpt_for("InfarisHQ/monorepo#4358 feat(guard): hosting", issues, false).as_deref(), Some(issues));
    }

    #[test]
    fn the_only_source_of_a_result_is_all_of_it() {
        assert_eq!(excerpt_for("Something else", "Line one\nLine two", true).as_deref(), Some("Line one\nLine two"));
        assert_eq!(excerpt_for("Something else", "Line one\nLine two", false), None);
    }

    #[test]
    fn a_long_excerpt_is_cut_at_a_line() {
        let long = (1..=200).map(|n| format!("Line number {n} of the note")).collect::<Vec<_>>().join("\n");
        let excerpt = excerpt_for("x", &long, true).unwrap();
        assert!(excerpt.chars().count() <= EXCERPT_LIMIT + 2);
        assert!(excerpt.ends_with(" …"));
    }

    #[tokio::test]
    async fn the_ledger_keeps_the_excerpt_per_reference() {
        let ledger = RetrievalLedger::new();
        let output = format!(
            "{MAILS}\n{}\n{}",
            reference_line("Achterstallige rekening", None, "Vimexx"),
            reference_line("Roadmap 2026-2027 Mindlinq", None, "Laura")
        );
        ledger.run("search_mail", None, &json!({"query": "excerpt-test"}), Duration::from_secs(5), async { Ok(output) }).await.unwrap();
        let refs = ledger.references();
        assert_eq!(refs.len(), 2);
        assert!(refs[0].excerpt.as_deref().is_some_and(|e| e.contains("infaris.com verloopt")));
        assert!(refs[1].excerpt.as_deref().is_some_and(|e| e.contains("roadmap door te nemen")));
    }

    #[test]
    fn a_reference_saved_before_excerpts_still_decodes() {
        let old = r#"{"number":2,"sourceId":"mail","title":"Hello","detail":"","url":null}"#;
        let reference: SourceReference = serde_json::from_str(old).unwrap();
        assert_eq!(reference.excerpt, None);
        assert_eq!(reference.number, 2);
    }

    #[test]
    fn a_mails_label_is_its_sender() {
        let mail = SourceReference {
            number: 1,
            source_id: "mail".into(),
            title: "Achterstallige rekening infaris.com".into(),
            detail: "Vimexx · 2026-11-14".into(),
            url: None,
            excerpt: None,
        };
        assert_eq!(mail.sender().as_deref(), Some("Vimexx"));
        let event = SourceReference {
            number: 2,
            source_id: "calendar".into(),
            title: "Retro".into(),
            detail: "16 nov · Werk".into(),
            url: None,
            excerpt: None,
        };
        assert_eq!(event.sender(), None);
    }

    #[test]
    fn a_sources_line_written_by_the_model_goes() {
        let text = "Sources: [4] infaris.com: Achterstallige Rekening, Vimexx · [8] WhatsApp +31 6 19304231\n\nHet concept-antwoord aan Laura staat klaar [30].";
        assert_eq!(citations::without_source_list(text), "Het concept-antwoord aan Laura staat klaar [30].");
    }

    #[test]
    fn a_sources_heading_with_its_list_goes() {
        let text = "Klaar [1].\n\n**Bronnen:**\n- [1] Vimexx\n- [2] Agenda";
        assert_eq!(citations::without_source_list(text), "Klaar [1].");
        assert_eq!(citations::without_source_list("Klaar [1].\n\n## Sources\n\n[1] Vimexx"), "Klaar [1].");
    }

    #[test]
    fn ordinary_text_about_sources_stays() {
        for text in [
            "Bronwater is gezond [2].",
            "Sources say the deadline moved [1].",
            "Bron: niets gevonden.",
            "## Sources\nNone of them answered.",
        ] {
            assert_eq!(citations::without_source_list(text), text);
        }
    }
}
