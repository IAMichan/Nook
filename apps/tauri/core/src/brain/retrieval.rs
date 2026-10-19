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
}

impl SourceReference {
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
            step.outcome = Outcome::Failed(reason.into());
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
                        self.lock().steps[index].outcome = Outcome::Failed(e.0.clone());
                        self.changed();
                        return Err(e);
                    }
                }
            }
        };

        let (text, found) = parse_references(&raw);
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
}
