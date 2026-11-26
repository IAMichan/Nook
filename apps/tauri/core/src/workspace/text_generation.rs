//! Per-kind text generation routing and API testing (`TextGenerators.swift` on macOS, SV-65).
//!
//! Short texts Nook generates (session titles, commit/PR text, suggested next prompt) can be
//! written either by the coding agent's CLI (default, using your subscription) or directly via
//! a model API (Anthropic Messages API or OpenAI-compatible `/chat/completions`, including local
//! Ollama / LM Studio).

use std::fmt;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::i18n::{tr, trf};
use crate::provider::AIProvider;

/// A kind of short text Nook generates (`TextTask` on macOS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextTask {
    Titles,
    GitText,
    NextPrompt,
}

impl TextTask {
    pub const ALL: [Self; 3] = [Self::Titles, Self::GitText, Self::NextPrompt];

    pub fn id(self) -> &'static str {
        match self {
            Self::Titles => "titles",
            Self::GitText => "gitText",
            Self::NextPrompt => "nextPrompt",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|t| t.id() == id)
    }

    /// Maximum answer tokens for this task: a title or suggestion is a single line, a PR is a page.
    pub fn max_tokens(self) -> u32 {
        match self {
            Self::Titles => 300,
            Self::GitText => 2_000,
            Self::NextPrompt => 200,
        }
    }
}

/// Who writes a task's text (`TextGenerator` on macOS).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TextGenerator {
    /// The coding agent's CLI (Claude Code or Codex), on your subscription.
    Agent,
    /// A model API. An empty model uses the provider's default (or the loaded server model).
    Api { provider: AIProvider, model: String },
}

impl TextGenerator {
    /// Providers that can write text over their API (every non-subscription brain provider).
    pub fn api_providers() -> Vec<AIProvider> {
        AIProvider::ALL.into_iter().filter(|p| !p.is_subscription()).collect()
    }

    /// Wire format stored in settings: `"agent"` or `"api:<provider>:<model>"`.
    pub fn stored(&self) -> String {
        match self {
            Self::Agent => "agent".into(),
            Self::Api { provider, model } => format!("api:{}:{}", provider.id(), model.trim()),
        }
    }

    /// Parses a stored setting; anything unknown or subscription-based falls back to `Agent`.
    pub fn parse(stored: Option<&str>) -> Self {
        let Some(raw) = stored.map(str::trim) else { return Self::Agent };
        let Some(rest) = raw.strip_prefix("api:") else { return Self::Agent };
        let (provider_id, model) = match rest.split_once(':') {
            Some((p, m)) => (p, m.trim()),
            None => (rest, ""),
        };
        let Some(provider) = AIProvider::from_id(provider_id) else { return Self::Agent };
        if provider.is_subscription() {
            return Self::Agent;
        }
        Self::Api { provider, model: model.to_string() }
    }

    pub fn provider(&self) -> Option<AIProvider> {
        match self {
            Self::Agent => None,
            Self::Api { provider, .. } => Some(*provider),
        }
    }

    /// Resolved model name: chosen model if non-empty, otherwise the provider's default.
    pub fn resolved_model(&self) -> String {
        match self {
            Self::Agent => String::new(),
            Self::Api { provider, model } => {
                let clean = model.trim();
                if clean.is_empty() {
                    provider.default_model().to_string()
                } else {
                    clean.to_string()
                }
            }
        }
    }
}

/// Resolved destination for one text generation call (`TextGenerationRoute` on macOS).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextGenerationRoute {
    Agent,
    Api { provider: AIProvider, model: String, key: Option<String> },
}

impl TextGenerationRoute {
    /// Resolves `generator` against a secret-key lookup. An API that requires a key falls back to
    /// `Agent` until a key is saved.
    pub fn resolve<F>(generator: &TextGenerator, key_for: F) -> Self
    where
        F: FnOnce(AIProvider) -> Option<String>,
    {
        let TextGenerator::Api { provider, .. } = generator else {
            return Self::Agent;
        };
        let key = key_for(*provider).map(|k| k.trim().to_string()).filter(|k| !k.is_empty());
        if provider.needs_key() && key.is_none() {
            return Self::Agent;
        }
        Self::Api { provider: *provider, model: generator.resolved_model(), key }
    }
}

/// Wire protocol spoken by a text-generation API provider (`TextWire` on macOS).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextWire {
    AnthropicMessages,
    ChatCompletions,
}

pub fn text_wire(provider: AIProvider) -> TextWire {
    if provider == AIProvider::Claude {
        TextWire::AnthropicMessages
    } else {
        TextWire::ChatCompletions
    }
}

/// Failure modes for a text-generation API call (`TextGeneratorError` on macOS).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextGeneratorError {
    BadEndpoint,
    MissingKey(String),
    Status(u16, String),
    Empty,
    Network(String),
}

impl fmt::Display for TextGeneratorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadEndpoint => f.write_str(tr("Deze dienst heeft geen geldig adres.", "This service has no valid address.")),
            Self::MissingKey(name) => f.write_str(&trf(
                "{name} heeft een API-sleutel nodig. Tot die er is, schrijft de coding agent deze tekst.",
                "{name} needs an API key. Until it has one, the coding agent writes this text.",
                &[("name", name)],
            )),
            Self::Status(401 | 403, msg) => {
                f.write_str(&trf("De sleutel werd geweigerd: {msg}", "The key was refused: {msg}", &[("msg", msg)]))
            }
            Self::Status(404, msg) => {
                f.write_str(&trf("Het model is niet gevonden: {msg}", "The model was not found: {msg}", &[("msg", msg)]))
            }
            Self::Status(429, _) => {
                f.write_str(tr("Te veel aanvragen. Probeer het zo opnieuw.", "Too many requests. Try again in a moment."))
            }
            Self::Status(code, msg) => f.write_str(&trf(
                "De dienst gaf fout {code}: {msg}",
                "The service answered with error {code}: {msg}",
                &[("code", code), ("msg", msg)],
            )),
            Self::Empty => f.write_str(tr("Het model antwoordde zonder tekst.", "The model answered without any text.")),
            Self::Network(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for TextGeneratorError {}

pub const ANTHROPIC_VERSION: &str = "2023-06-01";
pub const SYSTEM_PROMPT: &str = "You write short texts for a developer tool. Follow the requested format exactly and add nothing else.";

/// Prepared HTTP request parts for unit testing and execution.
#[derive(Debug, Clone, PartialEq)]
pub struct PreparedRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Value,
}

/// Builds the endpoint, headers, and JSON body for one text-generation request.
pub fn build_request(
    provider: AIProvider,
    model: &str,
    key: Option<&str>,
    prompt: &str,
    max_tokens: u32,
) -> Result<PreparedRequest, TextGeneratorError> {
    let base = provider.base_url().trim_end_matches('/');
    if base.is_empty() || (!base.starts_with("http://") && !base.starts_with("https://")) {
        return Err(TextGeneratorError::BadEndpoint);
    }
    let wire = text_wire(provider);
    let url = match wire {
        TextWire::AnthropicMessages => format!("{base}/messages"),
        TextWire::ChatCompletions => format!("{base}/chat/completions"),
    };
    let mut headers = vec![("Content-Type".to_string(), "application/json".to_string())];
    let body = match wire {
        TextWire::AnthropicMessages => {
            headers.push(("x-api-key".into(), key.unwrap_or("").to_string()));
            headers.push(("anthropic-version".into(), ANTHROPIC_VERSION.into()));
            json!({
                "model": model,
                "max_tokens": max_tokens,
                "system": SYSTEM_PROMPT,
                "messages": [{ "role": "user", "content": prompt }],
            })
        }
        TextWire::ChatCompletions => {
            if let Some(k) = key.map(str::trim).filter(|k| !k.is_empty()) {
                headers.push(("Authorization".into(), format!("Bearer {k}")));
            }
            let mut map = serde_json::Map::new();
            map.insert(
                "messages".into(),
                json!([
                    { "role": "system", "content": SYSTEM_PROMPT },
                    { "role": "user", "content": prompt }
                ]),
            );
            map.insert("temperature".into(), json!(0.2));
            if !model.trim().is_empty() {
                map.insert("model".into(), json!(model.trim()));
            }
            let token_key = if provider == AIProvider::Openai { "max_completion_tokens" } else { "max_tokens" };
            map.insert(token_key.into(), json!(max_tokens));
            Value::Object(map)
        }
    };
    Ok(PreparedRequest { url, headers, body })
}

/// Strips `<think>...</think>` reasoning blocks emitted by local models such as Qwen 3 and DeepSeek R1.
pub fn without_thinking(text: &str) -> String {
    let mut rest = text.to_string();
    while let Some(open) = rest.find("<think>") {
        let after_open = open + "<think>".len();
        if let Some(rel_close) = rest[after_open..].find("</think>") {
            let end = after_open + rel_close + "</think>".len();
            rest.replace_range(open..end, "");
        } else {
            rest.truncate(open);
            break;
        }
    }
    rest
}

/// Extracts the assistant text from a response body or maps HTTP/empty failures to `TextGeneratorError`.
pub fn answer_text(provider: AIProvider, status: u16, body: &[u8]) -> Result<String, TextGeneratorError> {
    let parsed = serde_json::from_slice::<Value>(body).ok();
    if !(200..300).contains(&status) {
        let message = parsed
            .as_ref()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message").and_then(Value::as_str).or_else(|| e.as_str()))
                    .or_else(|| v.get("message").and_then(Value::as_str))
            })
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToString::to_string)
            .unwrap_or_else(|| {
                let raw = String::from_utf8_lossy(&body[..body.len().min(200)]);
                raw.trim().to_string()
            });
        return Err(TextGeneratorError::Status(status, message));
    }

    let Some(obj) = parsed else {
        return Err(TextGeneratorError::Empty);
    };
    let text = match text_wire(provider) {
        TextWire::AnthropicMessages => obj
            .get("content")
            .and_then(Value::as_array)
            .map(|blocks| {
                blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                    .filter_map(|b| b.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("")
            })
            .unwrap_or_default(),
        TextWire::ChatCompletions => obj
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|c| c.first())
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .map(|content| {
                if let Some(s) = content.as_str() {
                    s.to_string()
                } else if let Some(parts) = content.as_array() {
                    parts.iter().filter_map(|p| p.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("")
                } else {
                    String::new()
                }
            })
            .unwrap_or_default(),
    };

    let clean = without_thinking(&text).trim().to_string();
    if clean.is_empty() {
        Err(TextGeneratorError::Empty)
    } else {
        Ok(clean)
    }
}

/// Sends the tiny test prompt ("Reply with the single word OK.") to verify key + model connectivity.
pub async fn test_api(provider: AIProvider, model: &str, key: Option<&str>) -> Result<String, TextGeneratorError> {
    let prepared = build_request(provider, model, key, "Reply with the single word OK.", 20)?;
    let client =
        reqwest::Client::builder().timeout(Duration::from_secs(30)).build().map_err(|e| TextGeneratorError::Network(e.to_string()))?;
    let mut req = client.post(&prepared.url);
    for (name, val) in &prepared.headers {
        req = req.header(name, val);
    }
    let response = req.json(&prepared.body).send().await.map_err(|e| TextGeneratorError::Network(e.to_string()))?;
    let status = response.status().as_u16();
    let bytes = response.bytes().await.map_err(|e| TextGeneratorError::Network(e.to_string()))?;
    answer_text(provider, status, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generator_round_trips_and_handles_colons_in_model_names() {
        let gen = TextGenerator::Api { provider: AIProvider::Ollama, model: "qwen2.5:7b-instruct".into() };
        assert_eq!(gen.stored(), "api:ollama:qwen2.5:7b-instruct");
        assert_eq!(TextGenerator::parse(Some(&gen.stored())), gen);
        assert_eq!(TextGenerator::parse(Some("agent")), TextGenerator::Agent);
        assert_eq!(TextGenerator::parse(None), TextGenerator::Agent);
        assert_eq!(TextGenerator::parse(Some("api:unknown:foo")), TextGenerator::Agent);
        // Subscription CLI providers are never valid API text generators.
        assert_eq!(TextGenerator::parse(Some("api:claudeCode:haiku")), TextGenerator::Agent);
    }

    #[test]
    fn route_resolution_falls_back_to_agent_when_key_missing() {
        let openai = TextGenerator::Api { provider: AIProvider::Openai, model: "".into() };
        assert_eq!(TextGenerationRoute::resolve(&openai, |_| None), TextGenerationRoute::Agent);
        assert_eq!(
            TextGenerationRoute::resolve(&openai, |_| Some("  sk-test  ".into())),
            TextGenerationRoute::Api {
                provider: AIProvider::Openai,
                model: AIProvider::Openai.default_model().into(),
                key: Some("sk-test".into()),
            }
        );
        // Local servers need no key.
        let lm = TextGenerator::Api { provider: AIProvider::Lmstudio, model: "".into() };
        assert_eq!(
            TextGenerationRoute::resolve(&lm, |_| None),
            TextGenerationRoute::Api { provider: AIProvider::Lmstudio, model: "".into(), key: None }
        );
    }

    #[test]
    fn builds_anthropic_and_openai_requests_correctly() {
        let anth = build_request(AIProvider::Claude, "claude-haiku-5-5", Some("sk-ant"), "Hi", 20).unwrap();
        assert!(anth.url.ends_with("/messages"));
        assert!(anth.headers.iter().any(|(k, v)| k == "x-api-key" && v == "sk-ant"));
        assert_eq!(anth.body["max_tokens"], json!(20));

        let oai = build_request(AIProvider::Openai, "gpt-4.1-mini", Some("sk-oai"), "Hi", 20).unwrap();
        assert!(oai.url.ends_with("/chat/completions"));
        assert!(oai.headers.iter().any(|(k, v)| k == "Authorization" && v == "Bearer sk-oai"));
        assert_eq!(oai.body["max_completion_tokens"], json!(20));

        let lm = build_request(AIProvider::Lmstudio, "", None, "Hi", 20).unwrap();
        assert!(lm.body.get("model").is_none());
        assert_eq!(lm.body["max_tokens"], json!(20));
    }

    #[test]
    fn parses_answers_strips_thinking_and_maps_errors() {
        let anth_body = br#"{"content":[{"type":"text","text":"  OK  "}]}"#;
        assert_eq!(answer_text(AIProvider::Claude, 200, anth_body).unwrap(), "OK");

        let oai_think = br#"{"choices":[{"message":{"content":"<think>reasoning</think>\nOK"}}]}"#;
        assert_eq!(answer_text(AIProvider::Ollama, 200, oai_think).unwrap(), "OK");

        let unclosed = br#"{"choices":[{"message":{"content":"OK<think>cut off"}}]}"#;
        assert_eq!(answer_text(AIProvider::Ollama, 200, unclosed).unwrap(), "OK");

        let empty = br#"{"choices":[{"message":{"content":"<think>only thought</think>"}}]}"#;
        assert_eq!(answer_text(AIProvider::Ollama, 200, empty), Err(TextGeneratorError::Empty));

        let err_body = br#"{"error":{"message":"invalid api key"}}"#;
        assert_eq!(answer_text(AIProvider::Openai, 401, err_body), Err(TextGeneratorError::Status(401, "invalid api key".into())));
    }

    #[test]
    fn api_providers_exclude_cli_subscriptions() {
        let providers = TextGenerator::api_providers();
        assert!(providers.contains(&AIProvider::Claude));
        assert!(providers.contains(&AIProvider::Openai));
        assert!(providers.contains(&AIProvider::Ollama));
        assert!(!providers.contains(&AIProvider::ClaudeCode));
        assert!(!providers.contains(&AIProvider::CodexCli));
    }
}
