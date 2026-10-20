//! The model that writes suggestions. On the Mac that is llama.cpp or MLX in Nook's own process; here it is the local
//! server the brain already uses (Ollama's `/api/generate` with `raw: true`, or LM Studio's `/v1/completions`), with a
//! small token budget, greedy sampling and a stop at the end of the line. Each request is a future: dropping it (a new
//! key) closes the connection, and the server stops writing.
//!
//! An external brain (OpenAI-compatible or Anthropic) is only used when the user chose it in Settings › Autocomplete
//! (`EngineChoice::Brain`): typed text then leaves the computer, so it never happens by default.
//!
//! When the server returns token probabilities (`logprobs`), the same certainty thresholds as on the Mac apply
//! ([`ConfidenceGate`]); otherwise only the token limit and the stops end a suggestion.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::prefs::{EngineChoice, LocalServer};
use super::prompt::{chat_request, is_chat_model, ChatTemplate, CompletionPrompt};
use super::suggestion::{CompletionOptions, CompletionResult};
use crate::brain::conversations::ollama_base_url;
use crate::brain::http::lines;
use crate::brain::profile::{profile_for_server_model, system_memory_gb};
use crate::provider::AIProvider;
use crate::settings::Settings;
use crate::{nook_err, NookError, Result};

/// Where the model for autocomplete comes from, decided from the settings alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Plan {
    /// A local server; the model is chosen from what it has.
    Local { server: AIProvider },
    /// The external brain, chosen explicitly by the user.
    Remote { provider: AIProvider, model: String },
    /// This choice cannot autocomplete; the reason for the user.
    Unsupported(String),
}

/// The local server autocomplete uses.
pub fn local_server(settings: &Settings) -> AIProvider {
    match settings.autocomplete.local_server {
        LocalServer::Ollama => AIProvider::Ollama,
        LocalServer::Lmstudio => AIProvider::Lmstudio,
        LocalServer::Auto if settings.provider == AIProvider::Lmstudio => AIProvider::Lmstudio,
        LocalServer::Auto => AIProvider::Ollama,
    }
}

pub fn plan(settings: &Settings) -> Plan {
    match settings.autocomplete.engine {
        EngineChoice::Local => Plan::Local { server: local_server(settings) },
        EngineChoice::Brain if settings.provider.is_local_server() => Plan::Local { server: settings.provider },
        EngineChoice::Brain if settings.provider == AIProvider::ClaudeCode => {
            Plan::Unsupported("Claude Code als brein kan niet aanvullen. Kies een model op deze computer.".into())
        }
        EngineChoice::Brain => Plan::Remote { provider: settings.provider, model: settings.active_model() },
    }
}

/// A model a local server has.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModel {
    pub name: String,
    /// Bytes on disk, 0 when the server does not say.
    pub size: u64,
}

fn base_url(server: AIProvider) -> String {
    if server == AIProvider::Ollama {
        ollama_base_url()
    } else {
        server.base_url().trim_end_matches("/v1").to_string()
    }
}

fn client(timeout: Duration) -> reqwest::Client {
    reqwest::Client::builder().connect_timeout(Duration::from_secs(3)).timeout(timeout).build().unwrap_or_default()
}

/// The models on a local server; an error when it does not answer.
pub async fn list_local_models(server: AIProvider) -> Result<Vec<LocalModel>> {
    list_local_models_at(server, &base_url(server)).await
}

pub async fn list_local_models_at(server: AIProvider, base: &str) -> Result<Vec<LocalModel>> {
    let client = client(Duration::from_secs(5));
    let url = if server == AIProvider::Ollama { format!("{base}/api/tags") } else { format!("{base}/v1/models") };
    let response = client.get(url).send().await.map_err(|_| nook_err!("{} draait niet.", server.title()))?;
    if !response.status().is_success() {
        return Err(nook_err!("{} gaf status {}.", server.title(), response.status().as_u16()));
    }
    let object: Value = response.json().await.unwrap_or_default();
    let list = object.get("models").or_else(|| object.get("data")).and_then(Value::as_array).cloned().unwrap_or_default();
    Ok(list
        .iter()
        .filter_map(|m| {
            let name = m.get("name").or_else(|| m.get("id")).and_then(Value::as_str)?;
            Some(LocalModel { name: name.to_string(), size: m.get("size").and_then(Value::as_u64).unwrap_or(0) })
        })
        .filter(|m| AIProvider::is_chat_model(&m.name))
        .collect())
}

/// How suitable a model is for autocomplete, lower first: chat (instruct) models, then base models, code and math
/// models last (as on the Mac); smaller first within a group, since a suggestion has to come within a keystroke.
fn rank(model: &LocalModel) -> (u8, u64) {
    let lower = model.name.to_lowercase();
    let group = if ["code", "coder", "math", "vision", "-vl", "ocr"].iter().any(|w| lower.contains(w)) {
        2
    } else if lower.contains("base") || lower.contains("-text") || lower.contains("-pt") {
        1
    } else {
        0
    };
    (group, if model.size == 0 { u64::MAX } else { model.size })
}

/// The model to use on `server`: the one chosen in Settings › Autocomplete, the brain's own when it runs there, or the
/// most suitable one it has.
pub fn choose_model(settings: &Settings, server: AIProvider, models: &[LocalModel]) -> Option<String> {
    let chosen = settings.autocomplete.model.trim();
    if !chosen.is_empty() {
        return Some(chosen.to_string());
    }
    if settings.provider == server {
        let brain = settings.active_model();
        if models.iter().any(|m| m.name == brain || m.name == format!("{brain}:latest")) {
            return Some(brain);
        }
    }
    models.iter().min_by_key(|m| rank(m)).map(|m| m.name.clone())
}

/// How a request is made.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Backend {
    Ollama,
    LmStudio,
    OpenAi,
    Anthropic,
}

/// The model a request goes to.
#[derive(Debug, Clone, PartialEq)]
pub struct EngineTarget {
    pub backend: Backend,
    pub provider: AIProvider,
    pub base_url: String,
    pub model: String,
    pub key: Option<String>,
    /// Ollama: the same context as the brain uses for this model, so switching between chat and autocomplete never
    /// makes Ollama load the model again.
    pub num_ctx: u32,
}

impl EngineTarget {
    pub fn local(server: AIProvider, model: &str) -> Self {
        let memory = system_memory_gb().unwrap_or(16);
        Self {
            backend: if server == AIProvider::Lmstudio { Backend::LmStudio } else { Backend::Ollama },
            provider: server,
            base_url: base_url(server),
            model: model.to_string(),
            key: None,
            num_ctx: profile_for_server_model(model).roomier(memory).context_tokens,
        }
    }

    pub fn remote(provider: AIProvider, model: &str, key: Option<String>) -> Self {
        Self {
            backend: if provider == AIProvider::Claude { Backend::Anthropic } else { Backend::OpenAi },
            provider,
            base_url: provider.base_url().to_string(),
            model: model.to_string(),
            key,
            num_ctx: 0,
        }
    }

    pub fn with_base_url(mut self, base: &str) -> Self {
        self.base_url = base.trim_end_matches('/').to_string();
        self
    }

    /// Typed text stays on this computer.
    pub fn is_local(&self) -> bool {
        matches!(self.backend, Backend::Ollama | Backend::LmStudio)
    }

    /// "Ollama · qwen3:4b".
    pub fn label(&self) -> String {
        let title = self.provider.title().split(" (").next().unwrap_or(self.provider.title()).to_string();
        format!("{title} · {}", self.model)
    }
}

/// Decides token by token whether the model is still sure enough (the Mac's certainty thresholds).
#[derive(Debug, Clone)]
pub struct ConfidenceGate {
    options: CompletionOptions,
    sequence: f32,
    tokens: usize,
}

impl ConfidenceGate {
    pub fn new(options: CompletionOptions) -> Self {
        Self { options, sequence: 1.0, tokens: 0 }
    }

    /// Whether a token with this log probability may still be part of the suggestion.
    pub fn admit(&mut self, logprob: f32) -> bool {
        let probability = logprob.exp();
        let bar = if self.tokens == 0 { self.options.min_first_probability } else { self.options.min_probability };
        if probability < bar || self.sequence * probability < self.options.min_sequence_probability {
            return false;
        }
        self.sequence *= probability;
        self.tokens += 1;
        true
    }

    pub fn tokens(&self) -> usize {
        self.tokens
    }
}

/// Whether `token` goes on with the word before it (a letter, digit or apostrophe first).
pub fn continues_word(token: &str) -> bool {
    token.chars().next().is_some_and(|c| c.is_alphanumeric() || "'’".contains(c))
}

/// Text written so far and how it ended, while a stream is read.
#[derive(Debug, Default)]
struct Collector {
    text: String,
    truncated: bool,
    unfinished: bool,
    /// The gate said no: stop reading.
    stopped: bool,
    logprobs: bool,
}

impl Collector {
    /// Adds a piece of text with the log probabilities of its tokens, when the server gave them.
    fn push(&mut self, text: &str, tokens: &[(String, f32)], gate: &mut ConfidenceGate) {
        if self.stopped {
            return;
        }
        if tokens.is_empty() {
            self.text.push_str(text);
            return;
        }
        self.logprobs = true;
        for (token, logprob) in tokens {
            if !gate.admit(*logprob) {
                self.unfinished = continues_word(token) && self.text.chars().last().is_some_and(|c| c.is_alphanumeric());
                self.stopped = true;
                return;
            }
            self.text.push_str(token);
        }
    }

    fn result(self, gate: &ConfidenceGate) -> Option<CompletionResult> {
        // Not sure of the first token: no suggestion at all.
        if self.logprobs && gate.tokens() == 0 {
            return None;
        }
        Some(CompletionResult { text: self.text, truncated: self.truncated, unfinished: self.unfinished })
    }
}

/// What the model answered, for the controller and the Playground.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineOutput {
    pub result: Option<CompletionResult>,
    /// Everything the model wrote before the gate cut it.
    pub raw: String,
    /// The server gave token probabilities, so the certainty thresholds applied.
    pub confidence: bool,
    pub milliseconds: u64,
    /// The prompt exactly as the model read it (for the Playground; never logged or stored).
    pub prompt: String,
}

fn parse_ollama_logprobs(object: &Value) -> Vec<(String, f32)> {
    object
        .get("logprobs")
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(|t| Some((t.get("token")?.as_str()?.to_string(), t.get("logprob")?.as_f64()? as f32))).collect())
        .unwrap_or_default()
}

fn parse_openai_logprobs(choice: &Value) -> Vec<(String, f32)> {
    let Some(logprobs) = choice.get("logprobs").filter(|v| !v.is_null()) else { return vec![] };
    let tokens = logprobs.get("tokens").and_then(Value::as_array);
    let values = logprobs.get("token_logprobs").and_then(Value::as_array);
    match (tokens, values) {
        (Some(tokens), Some(values)) => {
            tokens.iter().zip(values).filter_map(|(t, v)| Some((t.as_str()?.to_string(), v.as_f64()? as f32))).collect()
        }
        _ => vec![],
    }
}

/// A model on a server, ready for requests. Remembers each model's chat format.
pub struct Engine {
    target: EngineTarget,
    client: reqwest::Client,
    templates: Mutex<HashMap<String, ChatTemplate>>,
}

impl Engine {
    pub fn new(target: EngineTarget) -> Self {
        // Loading a model the first time can take a while; a suggestion after that comes within a second.
        Self { target, client: client(Duration::from_secs(60)), templates: Mutex::new(HashMap::new()) }
    }

    pub fn target(&self) -> &EngineTarget {
        &self.target
    }

    /// The chat format of the model (asked once): Ollama reports its template, LM Studio is guessed from the name.
    async fn template(&self) -> ChatTemplate {
        if let Some(found) = self.templates.lock().unwrap_or_else(|e| e.into_inner()).get(&self.target.model) {
            return *found;
        }
        let template = match self.target.backend {
            Backend::Ollama => {
                let url = format!("{}/api/show", self.target.base_url);
                let shown: Value = match self.client.post(url).json(&json!({"model": self.target.model})).send().await {
                    Ok(response) if response.status().is_success() => response.json().await.unwrap_or_default(),
                    _ => Value::Null,
                };
                let text = shown.get("template").and_then(Value::as_str).unwrap_or("");
                let detected = ChatTemplate::detect(text);
                if is_chat_model(&self.target.model, detected != ChatTemplate::Document) {
                    detected
                } else {
                    ChatTemplate::Document
                }
            }
            Backend::LmStudio => {
                let guessed = ChatTemplate::guess(&self.target.model);
                if is_chat_model(&self.target.model, guessed != ChatTemplate::Document) {
                    guessed
                } else {
                    ChatTemplate::Document
                }
            }
            Backend::OpenAi | Backend::Anthropic => ChatTemplate::Document,
        };
        self.templates.lock().unwrap_or_else(|e| e.into_inner()).insert(self.target.model.clone(), template);
        template
    }

    /// Continues the text of `prompt`. `Ok` with `result: None` when the model was not sure enough.
    pub async fn complete(&self, prompt: &CompletionPrompt, options: &CompletionOptions) -> Result<EngineOutput> {
        let start = Instant::now();
        let mut output = match self.target.backend {
            Backend::Ollama | Backend::LmStudio => self.complete_local(prompt, options).await?,
            Backend::OpenAi | Backend::Anthropic => self.complete_remote(prompt, options).await?,
        };
        output.milliseconds = start.elapsed().as_millis() as u64;
        Ok(output)
    }

    async fn complete_local(&self, prompt: &CompletionPrompt, options: &CompletionOptions) -> Result<EngineOutput> {
        let template = self.template().await;
        let raw_prompt = template.render(prompt);
        let stops = template.stops();
        let mut gate = ConfidenceGate::new(*options);
        let mut collector = Collector::default();
        let server = self.target.provider;
        let (request, body) = match self.target.backend {
            Backend::Ollama => (
                self.client.post(format!("{}/api/generate", self.target.base_url)),
                json!({
                    "model": self.target.model,
                    "prompt": raw_prompt,
                    "raw": true,
                    "stream": true,
                    "keep_alive": "10m",
                    "logprobs": true,
                    "options": {
                        "num_predict": options.max_tokens,
                        "num_ctx": self.target.num_ctx,
                        "temperature": 0.0,
                        "top_k": 1,
                        "stop": stops,
                    },
                }),
            ),
            _ => (
                self.client.post(format!("{}/v1/completions", self.target.base_url)),
                json!({
                    "model": self.target.model,
                    "prompt": raw_prompt,
                    "stream": true,
                    "max_tokens": options.max_tokens,
                    "temperature": 0.0,
                    "logprobs": 1,
                    "stop": stops,
                }),
            ),
        };
        let response = request.json(&body).send().await.map_err(|_| nook_err!("{} draait niet.", server.title()))?;
        if !response.status().is_success() {
            let status = response.status().as_u16();
            let object: Value = response.json().await.unwrap_or_default();
            let message = object.pointer("/error/message").or_else(|| object.get("error")).and_then(Value::as_str).unwrap_or("");
            return Err(nook_err!("{} gaf status {status}. {message}", server.title()));
        }
        let mut stream = Box::pin(lines(response.bytes_stream().map(|r| r.map_err(|e| NookError(e.to_string())))));
        while let Some(line) = stream.next().await {
            let line = line?;
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let data = line.strip_prefix("data:").map(str::trim).unwrap_or(line);
            if data == "[DONE]" {
                break;
            }
            let Ok(object) = serde_json::from_str::<Value>(data) else { continue };
            if let Some(error) = object.get("error") {
                let message = error.get("message").and_then(Value::as_str).or(error.as_str()).unwrap_or("onbekende fout");
                return Err(nook_err!("{}: {message}", server.title()));
            }
            if self.target.backend == Backend::Ollama {
                let text = object.get("response").and_then(Value::as_str).unwrap_or("");
                collector.push(text, &parse_ollama_logprobs(&object), &mut gate);
                if object.get("done").and_then(Value::as_bool) == Some(true) {
                    collector.truncated = object.get("done_reason").and_then(Value::as_str) == Some("length");
                    break;
                }
            } else if let Some(choice) = object.pointer("/choices/0") {
                let text = choice.get("text").and_then(Value::as_str).unwrap_or("");
                collector.push(text, &parse_openai_logprobs(choice), &mut gate);
                if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
                    collector.truncated = reason == "length";
                    break;
                }
            }
            if collector.stopped {
                // Dropping the stream closes the connection: the server stops writing.
                break;
            }
        }
        let raw = collector.text.clone();
        let confidence = collector.logprobs;
        Ok(EngineOutput { result: collector.result(&gate), raw, confidence, milliseconds: 0, prompt: raw_prompt })
    }

    /// An external brain, which only gets a chat request: it answers with the words that come next.
    async fn complete_remote(&self, prompt: &CompletionPrompt, options: &CompletionOptions) -> Result<EngineOutput> {
        let key = self.target.key.clone().filter(|k| !k.is_empty());
        if self.target.provider.needs_key() && key.is_none() {
            return Err(nook_err!("Er is nog geen sleutel voor {}.", self.target.provider.title()));
        }
        let system = format!(
            "You are an autocomplete engine. Reply with only the words that come right after the user's text, at most {} words, \
on the same line. Start with a space when the next word is a new word. No quotes, no explanation, never repeat the text.",
            options.max_words
        );
        let user = format!("{}\n\nThe text so far, to be continued right where it stops:\n{}", chat_request(&prompt.context), prompt.text);
        let shown_prompt = format!("{system}\n\n{user}");
        let (text, truncated) = if self.target.backend == Backend::Anthropic {
            let body = json!({
                "model": self.target.model,
                "max_tokens": options.max_tokens,
                "system": system,
                "messages": [{"role": "user", "content": user}],
            });
            let object = self.post(&format!("{}/messages", self.target.base_url), &body, true, key.as_deref()).await?;
            let text = object.pointer("/content/0/text").and_then(Value::as_str).unwrap_or("").to_string();
            (text, object.get("stop_reason").and_then(Value::as_str) == Some("max_tokens"))
        } else {
            let body = json!({
                "model": self.target.model,
                "max_tokens": options.max_tokens,
                "temperature": 0.2,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            });
            let object = self.post(&format!("{}/chat/completions", self.target.base_url), &body, false, key.as_deref()).await?;
            let text = object.pointer("/choices/0/message/content").and_then(Value::as_str).unwrap_or("").to_string();
            (text, object.pointer("/choices/0/finish_reason").and_then(Value::as_str) == Some("length"))
        };
        let continuation = strip_echo(&text, &prompt.text);
        Ok(EngineOutput {
            result: Some(CompletionResult { text: continuation, truncated, unfinished: false }),
            raw: text,
            confidence: false,
            milliseconds: 0,
            prompt: shown_prompt,
        })
    }

    async fn post(&self, url: &str, body: &Value, anthropic: bool, key: Option<&str>) -> Result<Value> {
        let mut request = self.client.post(url).json(body);
        if anthropic {
            request = request.header("x-api-key", key.unwrap_or_default()).header("anthropic-version", "2023-06-01");
        } else if let Some(key) = key {
            request = request.bearer_auth(key);
        }
        let title = self.target.provider.title();
        let response = request.send().await.map_err(|_| nook_err!("Kan {title} niet bereiken."))?;
        let status = response.status().as_u16();
        let object: Value = response.json().await.unwrap_or_default();
        if !(200..300).contains(&status) {
            let message = object.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
            return Err(nook_err!("{title} gaf status {status}. {message}"));
        }
        Ok(object)
    }
}

/// A chat model sometimes repeats the text before going on, or wraps its answer in quotes: only the continuation stays.
pub fn strip_echo(answer: &str, text: &str) -> String {
    let mut answer = answer.lines().next().unwrap_or("").to_string();
    for quote in ['"', '“', '”'] {
        if answer.trim_start().starts_with(quote) && answer.trim_end().ends_with(quote) && answer.trim().chars().count() > 1 {
            answer = answer.trim().trim_matches(quote).to_string();
        }
    }
    let trimmed_text = text.trim_end();
    if !trimmed_text.is_empty() {
        if let Some(rest) = answer.strip_prefix(trimmed_text) {
            return rest.to_string();
        }
        // The answer repeats the last few words of the text.
        let words: Vec<&str> = trimmed_text.split_whitespace().collect();
        for count in (2..=4).rev() {
            let tail = words[words.len().saturating_sub(count)..].join(" ");
            if tail.chars().count() < 8 {
                continue;
            }
            if let Some(rest) = answer.trim_start().strip_prefix(&tail) {
                return rest.to_string();
            }
        }
    }
    answer
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::autocomplete::prefs::AutocompleteSettings;

    fn settings(provider: AIProvider, engine: EngineChoice) -> Settings {
        Settings { provider, autocomplete: AutocompleteSettings { engine, ..Default::default() }, ..Default::default() }
    }

    #[test]
    fn plans_local_first() {
        assert_eq!(plan(&settings(AIProvider::Claude, EngineChoice::Local)), Plan::Local { server: AIProvider::Ollama });
        assert_eq!(plan(&settings(AIProvider::Lmstudio, EngineChoice::Local)), Plan::Local { server: AIProvider::Lmstudio });
        assert_eq!(plan(&settings(AIProvider::Ollama, EngineChoice::Brain)), Plan::Local { server: AIProvider::Ollama });
        assert!(matches!(plan(&settings(AIProvider::Openai, EngineChoice::Brain)), Plan::Remote { provider: AIProvider::Openai, .. }));
        assert!(matches!(plan(&settings(AIProvider::ClaudeCode, EngineChoice::Brain)), Plan::Unsupported(_)));
        let mut s = settings(AIProvider::Ollama, EngineChoice::Local);
        s.autocomplete.local_server = LocalServer::Lmstudio;
        assert_eq!(local_server(&s), AIProvider::Lmstudio);
    }

    #[test]
    fn chooses_models() {
        let models = vec![
            LocalModel { name: "qwen2.5-coder:1.5b".into(), size: 1 },
            LocalModel { name: "gemma3:4b".into(), size: 3_000 },
            LocalModel { name: "qwen3:1.7b".into(), size: 1_400 },
            LocalModel { name: "llama3.2:3b-text".into(), size: 900 },
        ];
        let mut s = settings(AIProvider::Claude, EngineChoice::Local);
        assert_eq!(choose_model(&s, AIProvider::Ollama, &models).as_deref(), Some("qwen3:1.7b"));
        s.provider = AIProvider::Ollama;
        s.set_provider_model("gemma3:4b");
        assert_eq!(choose_model(&s, AIProvider::Ollama, &models).as_deref(), Some("gemma3:4b"));
        s.autocomplete.model = "llama3.2:3b-text".into();
        assert_eq!(choose_model(&s, AIProvider::Ollama, &models).as_deref(), Some("llama3.2:3b-text"));
        assert_eq!(choose_model(&settings(AIProvider::Claude, EngineChoice::Local), AIProvider::Ollama, &[]), None);
    }

    #[test]
    fn gate_follows_eagerness() {
        let options = CompletionOptions::new(8, 0.5);
        let mut gate = ConfidenceGate::new(options);
        assert!(gate.admit(-0.1));
        assert!(gate.admit(-0.5));
        // 1% sure: stop.
        assert!(!gate.admit((0.01f32).ln()));
        assert_eq!(gate.tokens(), 2);
        let mut first = ConfidenceGate::new(options);
        assert!(!first.admit((0.1f32).ln()));
    }

    #[test]
    fn collector_stops_mid_word() {
        let options = CompletionOptions::new(8, 0.5);
        let mut gate = ConfidenceGate::new(options);
        let mut c = Collector::default();
        c.push(" see you", &[(" see".into(), -0.1), (" you".into(), -0.2)], &mut gate);
        c.push(" tom", &[(" tom".into(), -0.3)], &mut gate);
        c.push("orrow", &[("orrow".into(), -4.0)], &mut gate);
        assert!(c.stopped);
        let result = c.result(&gate).unwrap();
        assert_eq!(result.text, " see you tom");
        assert!(result.unfinished);
        // Unsure of the first token: nothing.
        let mut gate = ConfidenceGate::new(options);
        let mut c = Collector::default();
        c.push(" maybe", &[(" maybe".into(), -5.0)], &mut gate);
        assert!(c.result(&gate).is_none());
        // Without probabilities everything is kept.
        let mut gate = ConfidenceGate::new(options);
        let mut c = Collector::default();
        c.push(" see you", &[], &mut gate);
        assert_eq!(c.result(&gate).unwrap().text, " see you");
    }

    #[test]
    fn strips_echoes() {
        assert_eq!(strip_echo("Dear Tom, thanks for", "Dear Tom,"), " thanks for");
        assert_eq!(strip_echo("\" for your mail\"", "Thanks"), " for your mail");
        assert_eq!(strip_echo("call you tomorrow\nmore", "I will"), "call you tomorrow");
        assert_eq!(strip_echo("meeting on Monday at noon", "We have a meeting on Monday"), " at noon");
    }

    #[test]
    fn targets() {
        let t = EngineTarget::local(AIProvider::Ollama, "qwen3:4b");
        assert!(t.is_local());
        assert_eq!(t.label(), "Ollama · qwen3:4b");
        assert!(t.num_ctx >= 4096);
        let r = EngineTarget::remote(AIProvider::Claude, "claude-haiku-5-5", None);
        assert_eq!(r.backend, Backend::Anthropic);
        assert!(!r.is_local());
    }

    /// A small server answering requests by path, to test the streams for real.
    async fn serve(routes: Vec<(&'static str, &'static str)>) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { break };
                let routes = routes.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 65536];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    let request = String::from_utf8_lossy(&buf[..n]).to_string();
                    let path = request.split_whitespace().nth(1).unwrap_or("").to_string();
                    let body = routes.iter().find(|(p, _)| *p == path).map(|(_, b)| *b).unwrap_or("{}");
                    let response = format!("HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn ollama_raw_generate_with_logprobs() {
        let generate = "{\"response\":\" see\",\"logprobs\":[{\"token\":\" see\",\"logprob\":-0.05}]}\n\
{\"response\":\" you\",\"logprobs\":[{\"token\":\" you\",\"logprob\":-0.1}]}\n\
{\"response\":\" later\",\"logprobs\":[{\"token\":\" later\",\"logprob\":-6.0}]}\n\
{\"response\":\"\",\"done\":true,\"done_reason\":\"stop\"}\n";
        let base = serve(vec![("/api/show", "{\"template\":\"<|im_start|>user\"}"), ("/api/generate", generate)]).await;
        let engine = Engine::new(EngineTarget::local(AIProvider::Ollama, "qwen2.5:3b-instruct").with_base_url(&base));
        let prompt = CompletionPrompt { context: String::new(), text: "I will".into() };
        let output = engine.complete(&prompt, &CompletionOptions::new(8, 0.5)).await.unwrap();
        assert!(output.confidence);
        assert_eq!(output.result.unwrap().text, " see you");
        assert!(output.prompt.ends_with("<|im_start|>assistant\nI will"));
    }

    #[tokio::test]
    async fn ollama_without_logprobs_and_base_model() {
        let generate = "{\"response\":\" see you\"}\n{\"response\":\" tomor\",\"done\":true,\"done_reason\":\"length\"}\n";
        let base = serve(vec![("/api/show", "{\"template\":\"{{ .Prompt }}\"}"), ("/api/generate", generate)]).await;
        let engine = Engine::new(EngineTarget::local(AIProvider::Ollama, "llama3.2:3b-text").with_base_url(&base));
        let prompt = CompletionPrompt { context: "About the author:\nAnna".into(), text: "I will".into() };
        let output = engine.complete(&prompt, &CompletionOptions::new(8, 0.5)).await.unwrap();
        assert!(!output.confidence);
        let result = output.result.unwrap();
        assert_eq!(result.text, " see you tomor");
        assert!(result.truncated);
        assert_eq!(output.prompt, "About the author:\nAnna\n\nI will");
    }

    #[tokio::test]
    async fn lm_studio_completions_stream() {
        let sse = "data: {\"choices\":[{\"text\":\" see\",\"logprobs\":{\"tokens\":[\" see\"],\"token_logprobs\":[-0.1]},\"finish_reason\":null}]}\n\n\
data: {\"choices\":[{\"text\":\" you\",\"logprobs\":null,\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
        let base = serve(vec![("/v1/completions", sse)]).await;
        let engine = Engine::new(EngineTarget::local(AIProvider::Lmstudio, "gemma-3-4b-pt").with_base_url(&base));
        let prompt = CompletionPrompt { context: String::new(), text: "I will".into() };
        let output = engine.complete(&prompt, &CompletionOptions::new(8, 0.5)).await.unwrap();
        assert_eq!(output.result.unwrap().text, " see you");
    }

    #[tokio::test]
    async fn remote_chat_answer() {
        let answer = "{\"choices\":[{\"message\":{\"content\":\"I will see you\"},\"finish_reason\":\"stop\"}]}";
        let base = serve(vec![("/chat/completions", answer)]).await;
        let engine = Engine::new(EngineTarget::remote(AIProvider::Openai, "gpt-4.1-mini", Some("k".into())).with_base_url(&base));
        let prompt = CompletionPrompt { context: String::new(), text: "I will".into() };
        let output = engine.complete(&prompt, &CompletionOptions::new(8, 0.5)).await.unwrap();
        assert_eq!(output.result.unwrap().text, " see you");
        // Without a key nothing is sent.
        let engine = Engine::new(EngineTarget::remote(AIProvider::Openai, "gpt-4.1-mini", None).with_base_url(&base));
        assert!(engine.complete(&prompt, &CompletionOptions::new(8, 0.5)).await.is_err());
    }

    #[tokio::test]
    async fn lists_models() {
        let tags = "{\"models\":[{\"name\":\"qwen3:4b\",\"size\":2500},{\"name\":\"nomic-embed-text\",\"size\":10}]}";
        let base = serve(vec![("/api/tags", tags)]).await;
        let models = list_local_models_at(AIProvider::Ollama, &base).await.unwrap();
        assert_eq!(models, vec![LocalModel { name: "qwen3:4b".into(), size: 2500 }]);
        assert!(list_local_models_at(AIProvider::Ollama, "http://127.0.0.1:9").await.is_err());
    }
}
