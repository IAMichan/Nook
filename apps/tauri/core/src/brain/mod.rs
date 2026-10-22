//! Het brein: één tool-loop voor elk model (Anthropic, OpenAI-compatibel, Ollama, Claude Code), net als op de Mac.

/// Een reguliere expressie die één keer gebouwd wordt (met lookaround, zoals de patronen op de Mac).
macro_rules! rx {
    ($pattern:expr) => {{
        static R: std::sync::OnceLock<fancy_regex::Regex> = std::sync::OnceLock::new();
        R.get_or_init(|| fancy_regex::Regex::new($pattern).expect("geldig patroon"))
    }};
}

/// Of het patroon ergens in de tekst voorkomt.
pub(crate) fn matches(re: &fancy_regex::Regex, text: &str) -> bool {
    re.is_match(text).unwrap_or(false)
}

/// A regex whose pattern is only known at runtime (intents, aliases, memory subjects). The same patterns are checked
/// against every message, so each one is compiled once and kept; `None` remembers a pattern that does not compile.
/// The cache starts over when it grows past its cap, so subjects that come and go cannot make it grow without bound.
pub(crate) fn cached(pattern: &str) -> Option<std::sync::Arc<fancy_regex::Regex>> {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};
    type Cache = Mutex<HashMap<String, Option<Arc<fancy_regex::Regex>>>>;
    static CACHE: OnceLock<Cache> = OnceLock::new();
    const CAP: usize = 1024;
    let cache = CACHE.get_or_init(Default::default);
    if let Some(found) = cache.lock().unwrap_or_else(|e| e.into_inner()).get(pattern) {
        return found.clone();
    }
    let built = fancy_regex::Regex::new(pattern).ok().map(Arc::new);
    let mut cache = cache.lock().unwrap_or_else(|e| e.into_inner());
    if cache.len() >= CAP {
        cache.clear();
    }
    cache.insert(pattern.to_string(), built.clone());
    built
}

/// Whether the runtime pattern occurs in the text; a pattern that does not compile never matches.
pub(crate) fn matches_pattern(pattern: &str, text: &str) -> bool {
    cached(pattern).is_some_and(|re| matches(&re, text))
}

pub mod action_gate;
pub mod chart;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub mod claude_code;
pub mod command_risk;
pub mod conversations;
pub mod dates;
pub mod follow_ups;
pub mod fuzzy;
pub mod http;
pub mod intent;
pub mod local_intent;
pub mod memory;
pub mod model_download;
pub mod network_guard;
pub mod prepare;
pub mod profile;
pub mod quality;
pub mod query_plan;
pub mod research;
pub mod retrieval;
pub mod service;
pub mod sources;
pub mod suggestions;
pub mod text;
pub mod tool_loop;
pub mod undo;
pub mod weather;
pub mod web;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use tool_loop::{Limits, ToolRunner};

pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// Een actie die het brein voorstelt. Er gebeurt niets tot de gebruiker hem goedkeurt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlannedAction {
    pub id: String,
    pub tool: String,
    /// Kan nog veranderen: de gebruiker mag een voorstel aanpassen voor hij het uitvoert.
    pub input: Value,
}

impl PlannedAction {
    pub fn new(tool: impl Into<String>, input: Value) -> Self {
        Self { id: uuid::Uuid::new_v4().to_string(), tool: tool.into(), input }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrainPlan {
    pub text: String,
    pub actions: Vec<PlannedAction>,
}

/// Een eerdere beurt in het gesprek, zodat vervolgvragen begrepen worden.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatTurn {
    pub from_user: bool,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolKind {
    Read,
    Action,
}

pub type ToolFn = Arc<dyn Fn(Value) -> BoxFuture<crate::Result<String>> + Send + Sync>;

/// Een tool zoals de loop hem ziet: wat het model mag aanroepen en hoe hij draait.
#[derive(Clone)]
pub struct LoopTool {
    pub name: String,
    pub description: String,
    pub schema: Value,
    pub kind: ToolKind,
    pub run: ToolFn,
    /// De bron waar deze tool bij hoort (`calendar`, `web`, …); het register vult dit in.
    pub source: Option<String>,
}

impl LoopTool {
    pub fn read<F, Fut>(name: &str, description: &str, schema: Value, run: F) -> Self
    where
        F: Fn(Value) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = crate::Result<String>> + Send + 'static,
    {
        Self {
            name: name.into(),
            description: description.into(),
            schema,
            kind: ToolKind::Read,
            run: Arc::new(move |v| Box::pin(run(v))),
            source: None,
        }
    }

    /// Een actie draait nooit in de loop; hij wordt een voorstel.
    pub fn action(name: &str, description: &str, schema: Value) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            schema,
            kind: ToolKind::Action,
            run: Arc::new(|_| Box::pin(async { Ok(String::new()) })),
            source: None,
        }
    }

    /// Dezelfde tool, als onderdeel van een bron.
    pub fn in_source(mut self, source: &str) -> Self {
        self.source = Some(source.to_string());
        self
    }

    /// De velden die de tool verplicht nodig heeft.
    pub fn required(&self) -> Vec<String> {
        self.schema["required"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_string)).collect()
    }
}

impl std::fmt::Debug for LoopTool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LoopTool").field("name", &self.name).field("kind", &self.kind).finish()
    }
}

/// Eén tool-aanroep van een model.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolCallRequest {
    pub id: String,
    pub name: String,
    pub input: Value,
}

/// Wat een model in één ronde teruggaf.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ModelTurn {
    pub text: String,
    pub calls: Vec<ToolCallRequest>,
    /// De dienst zegt dat hij klaar is (geen nieuwe ronde, ook als de tekst JSON bevat).
    pub finished: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolResult {
    pub call: ToolCallRequest,
    pub output: String,
    pub is_error: bool,
}

/// Een plaatje zoals een model het krijgt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptImage {
    pub media_type: String,
    pub base64: String,
}

/// Ontvangt de zichtbare tekst tot nu toe, terwijl het antwoord geschreven wordt.
pub type OnText<'a> = Option<&'a (dyn Fn(String) + Send + Sync)>;

/// Het gesprek met één dienst; elk houdt zijn eigen berichtformaat bij. De loop vraagt om een ronde,
/// geeft de resultaten terug en herhaalt.
#[async_trait::async_trait]
pub trait ModelConversation: Send {
    async fn next(&mut self, tools: &[LoopTool], on_text: OnText<'_>) -> crate::Result<ModelTurn>;
    fn add_results(&mut self, results: &[ToolResult]);
    /// Vraagt het model af te ronden met een gewoon antwoord, zonder tools.
    fn add_instruction(&mut self, text: &str);
    fn attach(&mut self, _images: &[PromptImage]) {}
}

/// Beurten afwisselend user/assistant, beginnend bij de gebruiker; twee op rij worden samengevoegd.
pub fn alternating(history: &[ChatTurn], prompt: &str) -> Vec<(&'static str, String)> {
    let mut result: Vec<(&'static str, String)> = Vec::new();
    let all = history.iter().cloned().chain(std::iter::once(ChatTurn { from_user: true, text: prompt.into() }));
    for turn in all {
        let role = if turn.from_user { "user" } else { "assistant" };
        if result.is_empty() && role == "assistant" {
            continue;
        }
        match result.last_mut() {
            Some(last) if last.0 == role => last.1 = format!("{}\n\n{}", last.1, turn.text),
            _ => result.push((role, turn.text)),
        }
    }
    result
}

/// Voor breinen zonder gestructureerde geschiedenis: het gesprek tot nu toe als tekst voor de vraag.
pub fn history_prefix(history: &[ChatTurn], limit: usize, length: usize) -> String {
    if history.is_empty() {
        return String::new();
    }
    let start = history.len().saturating_sub(limit);
    let lines: Vec<String> = history[start..]
        .iter()
        .map(|t| format!("{}: {}", if t.from_user { "User" } else { "Nook" }, t.text.chars().take(length).collect::<String>()))
        .collect();
    format!("Conversation so far (for follow-up context):\n{}\n\n", lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alternating_merges_and_skips_leading_assistant() {
        let history = vec![
            ChatTurn { from_user: false, text: "hallo".into() },
            ChatTurn { from_user: true, text: "a".into() },
            ChatTurn { from_user: true, text: "b".into() },
            ChatTurn { from_user: false, text: "c".into() },
        ];
        let out = alternating(&history, "d");
        assert_eq!(out, vec![("user", "a\n\nb".into()), ("assistant", "c".into()), ("user", "d".into())]);
    }
}
