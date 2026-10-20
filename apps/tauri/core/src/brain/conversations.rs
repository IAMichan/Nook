//! Eén adapter per dienst. Elk houdt zijn eigen berichtformaat bij; de gedeelde `ToolRunner` stuurt ze allemaal hetzelfde aan.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde_json::{json, Map, Value};

use super::http::{self, post_json, post_lines};
use super::text::visible;
use super::{alternating, ChatTurn, LoopTool, ModelConversation, ModelTurn, OnText, PromptImage, ToolCallRequest, ToolResult};
use crate::provider::AIProvider;
use crate::{NookError, Result};

const EMIT_EVERY: Duration = Duration::from_millis(45);

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn parse_args(raw: &Value) -> Value {
    match raw {
        Value::String(s) => serde_json::from_str(s).unwrap_or_else(|_| json!({})),
        Value::Object(_) => raw.clone(),
        _ => json!({}),
    }
}

fn function_tools(tools: &[LoopTool]) -> Value {
    Value::Array(
        tools
            .iter()
            .map(|t| json!({"type": "function", "function": {"name": t.name, "description": t.description, "parameters": t.schema}}))
            .collect(),
    )
}

// MARK: Anthropic

/// Claude via de Anthropic Messages API: streamen, prompt caching, zoeken op het web aan de serverkant.
pub struct AnthropicConversation {
    messages: Vec<Value>,
    system: Value,
    model: String,
    key: String,
    web_search: Option<Value>,
    max_tokens: u32,
    client: reqwest::Client,
    endpoint: String,
}

impl AnthropicConversation {
    pub fn new(
        model: &str,
        key: &str,
        system: &str,
        history: &[ChatTurn],
        prompt: &str,
        images: &[PromptImage],
        web_search: Option<Value>,
        max_tokens: u32,
    ) -> Self {
        let mut messages: Vec<Value> =
            alternating(history, prompt).into_iter().map(|(role, text)| json!({"role": role, "content": text})).collect();
        let mut convo = Self {
            messages: vec![],
            system: json!([{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}]),
            model: model.into(),
            key: key.into(),
            web_search,
            max_tokens,
            client: http::client(AIProvider::Claude),
            endpoint: "https://api.anthropic.com/v1/messages".into(),
        };
        std::mem::swap(&mut convo.messages, &mut messages);
        convo.attach(images);
        convo
    }

    /// Voor tests: een ander adres.
    pub fn with_endpoint(mut self, endpoint: &str) -> Self {
        self.endpoint = endpoint.into();
        self
    }

    /// Snelheid per model: Haiku zonder denken, Sonnet denkt alleen tussen tools.
    pub fn apply_speed(body: &mut Map<String, Value>, model: &str) {
        if model.starts_with("claude-haiku-5") {
            body.insert("thinking".into(), json!({"type": "disabled"}));
            body.insert("output_config".into(), json!({"effort": "medium"}));
        } else if model.starts_with("claude-sonnet-5-5") {
            body.insert("thinking".into(), json!({"type": "between_tools"}));
            body.insert("output_config".into(), json!({"effort": "medium"}));
        } else if model.starts_with("claude-opus-5") || model.starts_with("claude-fable-5") || model.starts_with("claude-sonnet-5") {
            body.insert("output_config".into(), json!({"effort": "medium"}));
        }
    }

    /// De zoek-tool op het web; de nieuwere versie (met filteren) alleen op modellen die hem kennen.
    pub fn web_search_tool(model: &str, country: Option<&str>, timezone: Option<&str>) -> Value {
        let modern = ["claude-opus-", "claude-sonnet-5", "claude-sonnet-4-6", "claude-fable-"].iter().any(|p| model.starts_with(p));
        let mut tool =
            json!({"type": if modern { "web_search_20260209" } else { "web_search_20250305" }, "name": "web_search", "max_uses": 3});
        if let (Some(country), Some(tz)) = (country, timezone) {
            tool["user_location"] = json!({"type": "approximate", "country": country, "timezone": tz});
        }
        tool
    }

    /// Blokken terug in de volgende beurt: denkblokken blijven, bronvermeldingen gaan eruit.
    fn pass_back(blocks: &[Value]) -> Value {
        Value::Array(
            blocks
                .iter()
                .map(|b| {
                    let mut copy = b.clone();
                    if copy["type"] == "text" {
                        if let Some(map) = copy.as_object_mut() {
                            map.remove("citations");
                        }
                    }
                    copy
                })
                .collect(),
        )
    }

    async fn stream(&self, body: &Value, on_text: &(dyn Fn(String) + Send + Sync)) -> Result<Value> {
        let request = self.client.post(&self.endpoint).header("x-api-key", &self.key).header("anthropic-version", "2023-06-01");
        let mut lines = Box::pin(post_lines(request, body, AIProvider::Claude, &self.model).await?);
        let mut message = Map::new();
        let mut blocks: BTreeMap<usize, Value> = BTreeMap::new();
        let mut partial_json: BTreeMap<usize, String> = BTreeMap::new();
        let mut last_emit = Instant::now() - EMIT_EVERY;
        let current_text = |blocks: &BTreeMap<usize, Value>| -> String {
            blocks.values().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect()
        };
        while let Some(line) = lines.next().await {
            let line = line?;
            let Some(payload) = line.strip_prefix("data:") else { continue };
            let Ok(event) = serde_json::from_str::<Value>(payload.trim()) else { continue };
            let index = event["index"].as_u64().unwrap_or(0) as usize;
            match event["type"].as_str().unwrap_or("") {
                "message_start" => {
                    if let Some(m) = event["message"].as_object() {
                        message = m.clone();
                    }
                }
                "content_block_start" => {
                    let mut block = event["content_block"].clone();
                    let kind = block["type"].as_str().unwrap_or("");
                    if kind == "tool_use" || kind == "server_tool_use" {
                        partial_json.insert(index, String::new());
                        block["input"] = json!({});
                    }
                    blocks.insert(index, block);
                }
                "content_block_delta" => {
                    let delta = &event["delta"];
                    let Some(block) = blocks.get_mut(&index) else { continue };
                    let append = |block: &mut Value, field: &str, piece: &Value| {
                        let joined = format!("{}{}", block[field].as_str().unwrap_or(""), piece.as_str().unwrap_or(""));
                        block[field] = Value::String(joined);
                    };
                    match delta["type"].as_str().unwrap_or("") {
                        "text_delta" => {
                            append(block, "text", &delta["text"]);
                            if last_emit.elapsed() > EMIT_EVERY {
                                last_emit = Instant::now();
                                on_text(current_text(&blocks));
                            }
                        }
                        "input_json_delta" => partial_json.entry(index).or_default().push_str(delta["partial_json"].as_str().unwrap_or("")),
                        "thinking_delta" => append(block, "thinking", &delta["thinking"]),
                        "signature_delta" => append(block, "signature", &delta["signature"]),
                        "citations_delta" => {
                            let mut list = block["citations"].as_array().cloned().unwrap_or_default();
                            list.push(delta["citation"].clone());
                            block["citations"] = Value::Array(list);
                        }
                        _ => {}
                    }
                }
                "content_block_stop" => {
                    if let (Some(raw), Some(block)) = (partial_json.remove(&index), blocks.get_mut(&index)) {
                        block["input"] = if raw.is_empty() { json!({}) } else { serde_json::from_str(&raw).unwrap_or_else(|_| json!({})) };
                    }
                }
                "message_delta" => {
                    if let Some(reason) = event["delta"]["stop_reason"].as_str() {
                        message.insert("stop_reason".into(), json!(reason));
                    }
                }
                "error" => {
                    let error = event["error"].clone();
                    let status = if error["type"] == "overloaded_error" { 529 } else { 500 };
                    return Err(http::status_error(status, &json!({"error": error}), AIProvider::Claude, &self.model));
                }
                _ => {}
            }
        }
        on_text(current_text(&blocks));
        message.insert("content".into(), Value::Array(blocks.into_values().collect()));
        Ok(Value::Object(message))
    }
}

#[async_trait::async_trait]
impl ModelConversation for AnthropicConversation {
    async fn next(&mut self, tools: &[LoopTool], on_text: OnText<'_>) -> Result<ModelTurn> {
        let mut definitions: Vec<Value> =
            tools.iter().map(|t| json!({"name": t.name, "description": t.description, "input_schema": t.schema})).collect();
        if let Some(web) = &self.web_search {
            definitions.push(web.clone());
        }
        // Prompt caching: tools en systeemprompt hoeven bij een vervolgvraag niet opnieuw verwerkt te worden.
        if let Some(last) = definitions.last_mut() {
            last["cache_control"] = json!({"type": "ephemeral"});
        }
        let mut text = String::new();
        loop {
            let mut body = Map::new();
            body.insert("model".into(), json!(self.model));
            body.insert("max_tokens".into(), json!(self.max_tokens));
            body.insert("system".into(), self.system.clone());
            body.insert("messages".into(), Value::Array(self.messages.clone()));
            body.insert("stream".into(), json!(true));
            Self::apply_speed(&mut body, &self.model);
            if !definitions.is_empty() {
                body.insert("tools".into(), Value::Array(definitions.clone()));
            }
            let before = if text.is_empty() { String::new() } else { format!("{text}\n\n") };
            let emit = |partial: String| {
                if let Some(cb) = on_text {
                    cb(format!("{before}{partial}"));
                }
            };
            let response = self.stream(&Value::Object(body), &emit).await?;
            let blocks = response["content"].as_array().cloned().ok_or_else(|| NookError::new("Onverwacht antwoord van het model."))?;
            let round_text: String = blocks.iter().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect();
            if !round_text.is_empty() {
                text = format!("{before}{round_text}");
            }
            let stop = response["stop_reason"].as_str().unwrap_or("");
            // Lange zoekopdrachten op het web pauzeert de API soms: ga door met dezelfde berichten.
            if stop == "pause_turn" {
                self.messages.push(json!({"role": "assistant", "content": Self::pass_back(&blocks)}));
                continue;
            }
            if stop == "refusal" && text.is_empty() {
                text = "Daar kan ik je niet mee helpen.".into();
            }
            let uses: Vec<&Value> = blocks.iter().filter(|b| b["type"] == "tool_use").collect();
            if stop != "tool_use" || uses.is_empty() {
                return Ok(ModelTurn { text, calls: vec![], finished: true });
            }
            self.messages.push(json!({"role": "assistant", "content": Self::pass_back(&blocks)}));
            let calls = uses
                .iter()
                .map(|u| ToolCallRequest {
                    id: u["id"].as_str().map(str::to_string).unwrap_or_else(new_id),
                    name: u["name"].as_str().unwrap_or("").into(),
                    input: if u["input"].is_object() { u["input"].clone() } else { json!({}) },
                })
                .collect();
            return Ok(ModelTurn { text, calls, finished: false });
        }
    }

    fn add_results(&mut self, results: &[ToolResult]) {
        let content: Vec<Value> = results
            .iter()
            .map(|r| {
                let mut block = json!({"type": "tool_result", "tool_use_id": r.call.id, "content": r.output});
                if r.is_error {
                    block["is_error"] = json!(true);
                }
                block
            })
            .collect();
        self.messages.push(json!({"role": "user", "content": content}));
    }

    fn add_instruction(&mut self, text: &str) {
        if let Some(last) = self.messages.last_mut() {
            if last["role"] == "user" {
                if let Some(content) = last["content"].as_array_mut() {
                    content.push(json!({"type": "text", "text": text}));
                    return;
                }
            }
        }
        self.messages.push(json!({"role": "user", "content": text}));
    }

    fn attach(&mut self, images: &[PromptImage]) {
        let Some(last) = self.messages.last_mut() else { return };
        if images.is_empty() || last["role"] != "user" {
            return;
        }
        let mut blocks: Vec<Value> = images
            .iter()
            .map(|i| json!({"type": "image", "source": {"type": "base64", "media_type": i.media_type, "data": i.base64}}))
            .collect();
        match &last["content"] {
            Value::String(text) => blocks.push(json!({"type": "text", "text": text})),
            Value::Array(existing) => blocks.extend(existing.iter().cloned()),
            _ => {}
        }
        last["content"] = Value::Array(blocks);
    }
}

// MARK: OpenAI-compatibel

/// Elke dienst met een OpenAI-compatibel `/chat/completions` (OpenAI, Gemini, Grok, Mistral, LM Studio…).
pub struct OpenAIConversation {
    messages: Vec<Value>,
    provider: AIProvider,
    model: String,
    key: Option<String>,
    max_tokens: Option<u32>,
    base_url: String,
    client: reqwest::Client,
}

impl OpenAIConversation {
    pub fn new(
        provider: AIProvider,
        model: &str,
        key: Option<String>,
        system: &str,
        history: &[ChatTurn],
        prompt: &str,
        images: &[PromptImage],
        max_tokens: Option<u32>,
    ) -> Self {
        let mut messages = vec![json!({"role": "system", "content": system})];
        messages.extend(alternating(history, prompt).into_iter().map(|(role, text)| json!({"role": role, "content": text})));
        let mut convo = Self {
            messages,
            provider,
            model: model.into(),
            key,
            max_tokens,
            base_url: provider.base_url().into(),
            client: http::client(provider),
        };
        convo.attach(images);
        convo
    }

    pub fn with_base_url(mut self, base: &str) -> Self {
        self.base_url = base.trim_end_matches('/').into();
        self
    }

    fn request(&self) -> reqwest::RequestBuilder {
        let mut request = self.client.post(format!("{}/chat/completions", self.base_url));
        if let Some(key) = self.key.as_deref().filter(|k| !k.is_empty()) {
            request = request.bearer_auth(key);
        }
        if self.provider == AIProvider::Openrouter {
            request = request.header("HTTP-Referer", "https://github.com/IAMichan/nook").header("X-Title", "Nook");
        }
        request
    }

    async fn stream_next(&mut self, body: &Value, on_text: &(dyn Fn(String) + Send + Sync)) -> Result<ModelTurn> {
        let mut lines = Box::pin(post_lines(self.request(), body, self.provider, &self.model).await?);
        #[derive(Default)]
        struct Partial {
            id: String,
            name: String,
            arguments: String,
        }
        let mut text = String::new();
        let mut acc: BTreeMap<u64, Partial> = BTreeMap::new();
        let mut received = false;
        let mut last_emit = Instant::now() - EMIT_EVERY;
        while let Some(line) = lines.next().await {
            let line = line?;
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with(':') {
                continue;
            }
            let payload = if let Some(p) = trimmed.strip_prefix("data:") {
                p.trim()
            } else if trimmed.starts_with('{') {
                trimmed
            } else {
                continue;
            };
            if payload == "[DONE]" {
                break;
            }
            let Ok(object) = serde_json::from_str::<Value>(payload) else { continue };
            if let Some(err) = object.pointer("/error/message").and_then(|v| v.as_str()) {
                return Err(NookError(format!("{}: {err}", self.provider.title())));
            }
            let Some(choice) = object["choices"].get(0) else { continue };
            received = true;
            if let Some(delta) = choice.get("delta") {
                if let Some(piece) = delta["content"].as_str() {
                    text.push_str(piece);
                    if last_emit.elapsed() > EMIT_EVERY {
                        last_emit = Instant::now();
                        let v = visible(&text);
                        if !v.is_empty() {
                            on_text(v);
                        }
                    }
                }
                for dc in delta["tool_calls"].as_array().into_iter().flatten() {
                    let entry = acc.entry(dc["index"].as_u64().unwrap_or(0)).or_default();
                    if let Some(id) = dc["id"].as_str().filter(|s| !s.is_empty()) {
                        entry.id = id.into();
                    }
                    if let Some(name) = dc["function"]["name"].as_str() {
                        entry.name.push_str(name);
                    }
                    if let Some(args) = dc["function"]["arguments"].as_str() {
                        entry.arguments.push_str(args);
                    }
                }
            } else if let Some(message) = choice.get("message") {
                text.push_str(message["content"].as_str().unwrap_or(""));
                for (i, rc) in message["tool_calls"].as_array().into_iter().flatten().enumerate() {
                    acc.insert(
                        i as u64,
                        Partial {
                            id: rc["id"].as_str().map(str::to_string).unwrap_or_else(new_id),
                            name: rc["function"]["name"].as_str().unwrap_or("").into(),
                            arguments: rc["function"]["arguments"].as_str().unwrap_or("{}").into(),
                        },
                    );
                }
            }
        }
        if !received {
            return Err(NookError::new("Lege stream"));
        }
        let v = visible(&text);
        if !v.is_empty() {
            on_text(v);
        }
        let mut raw_calls = vec![];
        let mut calls = vec![];
        for item in acc.into_values().filter(|p| !p.name.is_empty()) {
            let id = if item.id.is_empty() { new_id() } else { item.id };
            let args = if item.arguments.is_empty() { "{}".to_string() } else { item.arguments };
            raw_calls.push(json!({"id": id, "type": "function", "function": {"name": item.name, "arguments": args}}));
            calls.push(ToolCallRequest { id, name: item.name, input: serde_json::from_str(&args).unwrap_or_else(|_| json!({})) });
        }
        if !calls.is_empty() {
            let mut msg = json!({"role": "assistant", "tool_calls": raw_calls});
            if !text.is_empty() {
                msg["content"] = json!(text);
            }
            self.messages.push(msg);
        }
        Ok(ModelTurn { text, calls, finished: false })
    }
}

#[async_trait::async_trait]
impl ModelConversation for OpenAIConversation {
    async fn next(&mut self, tools: &[LoopTool], on_text: OnText<'_>) -> Result<ModelTurn> {
        let mut body = json!({
            "model": self.model,
            "messages": self.messages,
            "temperature": if self.provider.is_local_server() { 0.2 } else { 0.3 },
        });
        if let Some(max) = self.max_tokens {
            body["max_tokens"] = json!(max);
        }
        if !tools.is_empty() {
            body["tools"] = function_tools(tools);
        }
        // Streamen via SSE; een server die dat niet kan, krijgt een gewone POST.
        if let Some(cb) = on_text {
            let mut stream_body = body.clone();
            stream_body["stream"] = json!(true);
            match self.stream_next(&stream_body, cb).await {
                Ok(turn) => return Ok(turn),
                Err(e) if e.0 != "Lege stream" && !e.0.contains("stream") => return Err(e),
                Err(_) => {}
            }
        }
        let object = post_json(self.request(), &body, self.provider, &self.model).await?;
        let message = object
            .pointer("/choices/0/message")
            .cloned()
            .ok_or_else(|| NookError(format!("Onverwacht antwoord van {}.", self.provider.title())))?;
        let text = message["content"].as_str().unwrap_or("").to_string();
        if let (Some(cb), false) = (on_text, text.is_empty()) {
            cb(visible(&text));
        }
        let raw_calls = message["tool_calls"].as_array().cloned().unwrap_or_default();
        if raw_calls.is_empty() {
            return Ok(ModelTurn { text, calls: vec![], finished: false });
        }
        self.messages.push(message);
        let calls = raw_calls
            .iter()
            .map(|c| ToolCallRequest {
                id: c["id"].as_str().map(str::to_string).unwrap_or_else(new_id),
                name: c["function"]["name"].as_str().unwrap_or("").into(),
                input: parse_args(&c["function"]["arguments"]),
            })
            .collect();
        Ok(ModelTurn { text, calls, finished: false })
    }

    fn add_results(&mut self, results: &[ToolResult]) {
        for r in results {
            self.messages.push(json!({"role": "tool", "tool_call_id": r.call.id, "content": r.output}));
        }
    }

    fn add_instruction(&mut self, text: &str) {
        self.messages.push(json!({"role": "user", "content": text}));
    }

    fn attach(&mut self, images: &[PromptImage]) {
        let Some(last) = self.messages.last_mut() else { return };
        let Some(text) = last["content"].as_str().map(str::to_string) else { return };
        if images.is_empty() || last["role"] != "user" {
            return;
        }
        let mut parts = vec![json!({"type": "text", "text": text})];
        parts.extend(
            images.iter().map(|i| json!({"type": "image_url", "image_url": {"url": format!("data:{};base64,{}", i.media_type, i.base64)}})),
        );
        last["content"] = Value::Array(parts);
    }
}

// MARK: Ollama

pub use super::profile::ModelProfile;

/// Ollama via zijn eigen `/api/chat`, zodat de context ingesteld kan worden (`num_ctx`).
pub struct OllamaConversation {
    messages: Vec<Value>,
    model: String,
    profile: ModelProfile,
    base_url: String,
    thinking: bool,
    keep_alive: String,
    client: reqwest::Client,
}

/// Het adres van Ollama: `OLLAMA_HOST` als die gezet is (zoals Ollama zelf), anders deze computer.
pub fn ollama_base_url() -> String {
    match std::env::var("OLLAMA_HOST").ok().map(|h| h.trim().trim_end_matches('/').to_string()).filter(|h| !h.is_empty()) {
        Some(host) if host.starts_with("http://") || host.starts_with("https://") => host,
        Some(host) => format!("http://{host}"),
        None => OllamaConversation::BASE_URL.into(),
    }
}

/// How long Ollama keeps the model in memory after a request. The weights take gigabytes of (GPU) memory and loading
/// them again from the disk cache takes only a second or two, so the model is given back after 90 seconds on every
/// computer, whatever its memory (`_memory_gb` is kept for callers that still pass it).
pub fn ollama_keep_alive(_memory_gb: u64) -> &'static str {
    "90s"
}

/// Whether Ollama has this model in memory right now (`GET /api/ps`). `None` when Ollama cannot be asked.
pub async fn ollama_is_loaded(base_url: &str, model: &str) -> Option<bool> {
    let client = http::client(AIProvider::Ollama);
    let response = client.get(format!("{base_url}/api/ps")).timeout(std::time::Duration::from_secs(5)).send().await.ok()?;
    let body: Value = response.json().await.ok()?;
    Some(ollama_lists_model(&body, model))
}

/// Whether a `/api/ps` answer lists the model ("llama3.2" matches "llama3.2:latest").
pub fn ollama_lists_model(body: &Value, model: &str) -> bool {
    let bare = |name: &str| name.trim().strip_suffix(":latest").unwrap_or(name.trim()).to_string();
    let wanted = bare(model);
    body["models"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|m| [m["name"].as_str(), m["model"].as_str()].into_iter().flatten().any(|name| bare(name) == wanted))
}

/// Asks Ollama to give the model's memory back right away (`keep_alive: 0`). For background work (thinking along)
/// that loaded the model only for itself. Failures are ignored: Ollama then unloads it after its own timeout.
pub async fn ollama_unload(base_url: &str, model: &str) {
    let client = http::client(AIProvider::Ollama);
    let _ = client
        .post(format!("{base_url}/api/generate"))
        .timeout(std::time::Duration::from_secs(10))
        .json(&json!({"model": model, "keep_alive": 0}))
        .send()
        .await;
}

impl OllamaConversation {
    pub const BASE_URL: &'static str = "http://localhost:11434";

    pub fn new(
        model: &str,
        system: &str,
        history: &[ChatTurn],
        prompt: &str,
        images: &[PromptImage],
        profile: ModelProfile,
        memory_gb: u64,
    ) -> Self {
        let mut messages = vec![json!({"role": "system", "content": system})];
        messages.extend(alternating(history, prompt).into_iter().map(|(role, text)| json!({"role": role, "content": text})));
        let mut convo = Self {
            messages,
            model: model.into(),
            profile,
            base_url: ollama_base_url(),
            thinking: false,
            keep_alive: ollama_keep_alive(memory_gb).into(),
            client: http::client(AIProvider::Ollama),
        };
        convo.attach(images);
        convo
    }

    pub fn with_base_url(mut self, base: &str) -> Self {
        self.base_url = base.trim_end_matches('/').into();
        self
    }

    /// Een model dat kan redeneren, doet dat alleen bij moeilijke vragen.
    pub fn with_thinking(mut self, thinking: bool) -> Self {
        self.thinking = thinking;
        self
    }

    /// Context, uitvoer en de sampling die de makers van het model aanraden.
    fn options(&self) -> Value {
        let sampling = super::profile::ModelFamily::of(&self.model).sampling(self.thinking);
        let mut options = json!({
            "num_ctx": self.profile.context_tokens,
            "num_predict": if self.thinking { self.profile.thinking_output_tokens() } else { self.profile.max_output_tokens },
            "temperature": sampling.temperature,
            "top_p": sampling.top_p,
        });
        if sampling.top_k > 0 {
            options["top_k"] = json!(sampling.top_k);
        }
        options
    }
}

#[async_trait::async_trait]
impl ModelConversation for OllamaConversation {
    async fn next(&mut self, tools: &[LoopTool], on_text: OnText<'_>) -> Result<ModelTurn> {
        let mut body = json!({
            "model": self.model,
            "messages": self.messages,
            "stream": true,
            "options": self.options(),
            "keep_alive": self.keep_alive,
        });
        if !tools.is_empty() {
            body["tools"] = function_tools(tools);
        }
        let request = self.client.post(format!("{}/api/chat", self.base_url));
        let mut lines = Box::pin(post_lines(request, &body, AIProvider::Ollama, &self.model).await?);
        let mut text = String::new();
        let mut raw_calls: Vec<Value> = vec![];
        let mut received = false;
        let mut last_emit = Instant::now() - EMIT_EVERY;
        while let Some(line) = lines.next().await {
            let Ok(object) = serde_json::from_str::<Value>(&line?) else { continue };
            if let Some(error) = object["error"].as_str() {
                return Err(NookError(format!("Ollama: {error}")));
            }
            let Some(message) = object.get("message") else { continue };
            received = true;
            text.push_str(message["content"].as_str().unwrap_or(""));
            raw_calls.extend(message["tool_calls"].as_array().cloned().unwrap_or_default());
            if let Some(cb) = on_text {
                if last_emit.elapsed() > EMIT_EVERY {
                    last_emit = Instant::now();
                    let v = visible(&text);
                    if !v.is_empty() {
                        cb(v);
                    }
                }
            }
        }
        if !received {
            return Err(NookError::new("Onverwacht antwoord van Ollama."));
        }
        if let Some(cb) = on_text {
            let v = visible(&text);
            if !v.is_empty() {
                cb(v);
            }
        }
        if raw_calls.is_empty() {
            return Ok(ModelTurn { text, calls: vec![], finished: false });
        }
        self.messages.push(json!({"role": "assistant", "content": text, "tool_calls": raw_calls}));
        let calls = raw_calls
            .iter()
            .map(|c| ToolCallRequest {
                id: new_id(),
                name: c["function"]["name"].as_str().unwrap_or("").into(),
                input: parse_args(&c["function"]["arguments"]),
            })
            .collect();
        Ok(ModelTurn { text, calls, finished: false })
    }

    fn add_results(&mut self, results: &[ToolResult]) {
        for r in results {
            self.messages.push(json!({"role": "tool", "tool_name": r.call.name, "content": r.output}));
        }
    }

    fn add_instruction(&mut self, text: &str) {
        self.messages.push(json!({"role": "user", "content": text}));
    }

    fn attach(&mut self, images: &[PromptImage]) {
        if let Some(last) = self.messages.last_mut() {
            if !images.is_empty() && last["role"] == "user" {
                last["images"] = Value::Array(images.iter().map(|i| json!(i.base64)).collect());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn images_go_with_the_question() {
        let img = PromptImage { media_type: "image/png".into(), base64: "AAA".into() };
        let c = AnthropicConversation::new("claude-haiku-5-5", "k", "sys", &[], "wat is dit", std::slice::from_ref(&img), None, 1024);
        assert_eq!(c.messages[0]["content"][0]["type"], "image");
        assert_eq!(c.messages[0]["content"][1]["text"], "wat is dit");
        let o = OpenAIConversation::new(AIProvider::Openai, "gpt-4.1", None, "sys", &[], "wat is dit", std::slice::from_ref(&img), None);
        assert_eq!(o.messages[1]["content"][1]["type"], "image_url");
        let l = OllamaConversation::new("gemma3", "sys", &[], "wat", &[img], ModelProfile::LOCAL_SMALL, 16);
        assert_eq!(l.messages[1]["images"][0], "AAA");
    }

    /// Een mini-server die één antwoord geeft, om de streaming-parsers echt te testen.
    async fn serve_once(body: &'static str, content_type: &'static str) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 65536];
            let _ = socket.read(&mut buf).await;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(response.as_bytes()).await.unwrap();
        });
        format!("http://{addr}")
    }

    #[test]
    fn ollama_gives_memory_back_soon() {
        assert_eq!(ollama_keep_alive(8), "90s");
        assert_eq!(ollama_keep_alive(64), "90s");
        let ps = json!({"models": [{"name": "llama3.2:latest", "model": "llama3.2:latest"}, {"name": "qwen3:8b"}]});
        assert!(ollama_lists_model(&ps, "llama3.2"));
        assert!(ollama_lists_model(&ps, "qwen3:8b"));
        assert!(!ollama_lists_model(&ps, "qwen3:4b"));
        assert!(!ollama_lists_model(&json!({}), "llama3.2"));
    }

    #[tokio::test]
    async fn ollama_reports_a_loaded_model() {
        let base = serve_once(r#"{"models":[{"name":"gemma3:latest","model":"gemma3:latest"}]}"#, "application/json").await;
        assert_eq!(ollama_is_loaded(&base, "gemma3").await, Some(true));
    }

    #[tokio::test]
    async fn anthropic_stream_builds_tool_calls() {
        let sse = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\n\
data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\
data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Even kijken\"}}\n\
data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"weather\"}}\n\
data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}\n\
data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Utrecht\\\"}\"}}\n\
data: {\"type\":\"content_block_stop\",\"index\":1}\n\
data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n";
        let base = serve_once(sse, "text/event-stream").await;
        let mut c = AnthropicConversation::new("claude-haiku-5-5", "k", "sys", &[], "weer?", &[], None, 1024).with_endpoint(&base);
        let turn = c.next(&[], None).await.unwrap();
        assert_eq!(turn.text, "Even kijken");
        assert_eq!(turn.calls[0].name, "weather");
        assert_eq!(turn.calls[0].input, json!({"city": "Utrecht"}));
    }

    #[tokio::test]
    async fn openai_stream_accumulates_tool_arguments() {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Ik zoek\"}}]}\n\n\
data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"weather\",\"arguments\":\"{\\\"ci\"}}]}}]}\n\n\
data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"ty\\\":\\\"Gouda\\\"}\"}}]}}]}\n\n\
data: [DONE]\n\n";
        let base = serve_once(sse, "text/event-stream").await;
        let mut c =
            OpenAIConversation::new(AIProvider::Openai, "gpt-4.1", Some("k".into()), "sys", &[], "weer?", &[], None).with_base_url(&base);
        let seen = std::sync::Mutex::new(String::new());
        let cb = |t: String| *seen.lock().unwrap() = t;
        let turn = c.next(&[], Some(&cb)).await.unwrap();
        assert_eq!(turn.calls[0].input, json!({"city": "Gouda"}));
        assert_eq!(*seen.lock().unwrap(), "Ik zoek");
    }

    #[tokio::test]
    async fn ollama_stream_reads_lines() {
        let nd = "{\"message\":{\"content\":\"Hal\"}}\n{\"message\":{\"content\":\"lo\"}}\n{\"done\":true}\n";
        let base = serve_once(nd, "application/x-ndjson").await;
        let mut c = OllamaConversation::new("llama3.2", "sys", &[], "hoi", &[], ModelProfile::LOCAL_SMALL, 16).with_base_url(&base);
        let turn = c.next(&[], None).await.unwrap();
        assert_eq!(turn.text, "Hallo");
    }
}
