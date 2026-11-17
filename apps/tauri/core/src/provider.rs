use serde::{Deserialize, Serialize};

use crate::{NookError, Result};

/// Het brein waarmee Nook denkt. Claude spreekt de Anthropic-API; de rest spreekt het OpenAI-protocol
/// (chat/completions met function calling), dus één client dekt ze allemaal. Ollama en LM Studio draaien lokaal.
/// Zelfde lijst en namen als `AIProvider` in de macOS-app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AIProvider {
    Claude,
    #[serde(rename = "claudeCode")]
    ClaudeCode,
    #[serde(rename = "codexCLI")]
    CodexCli,
    #[serde(rename = "geminiCLI")]
    GeminiCli,
    #[serde(rename = "grokCLI")]
    GrokCli,
    #[serde(rename = "kimiCLI")]
    KimiCli,
    #[serde(rename = "vibeCLI")]
    VibeCli,
    Openai,
    Gemini,
    Grok,
    Mistral,
    Groq,
    Openrouter,
    Deepseek,
    Qwen,
    Moonshot,
    Ollama,
    Lmstudio,
}

impl AIProvider {
    pub const ALL: [AIProvider; 18] = [
        Self::Claude,
        Self::ClaudeCode,
        Self::CodexCli,
        Self::GeminiCli,
        Self::GrokCli,
        Self::KimiCli,
        Self::VibeCli,
        Self::Openai,
        Self::Gemini,
        Self::Grok,
        Self::Mistral,
        Self::Groq,
        Self::Openrouter,
        Self::Deepseek,
        Self::Qwen,
        Self::Moonshot,
        Self::Ollama,
        Self::Lmstudio,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::ClaudeCode => "claudeCode",
            Self::CodexCli => "codexCLI",
            Self::GeminiCli => "geminiCLI",
            Self::GrokCli => "grokCLI",
            Self::KimiCli => "kimiCLI",
            Self::VibeCli => "vibeCLI",
            Self::Openai => "openai",
            Self::Gemini => "gemini",
            Self::Grok => "grok",
            Self::Mistral => "mistral",
            Self::Groq => "groq",
            Self::Openrouter => "openrouter",
            Self::Deepseek => "deepseek",
            Self::Qwen => "qwen",
            Self::Moonshot => "moonshot",
            Self::Ollama => "ollama",
            Self::Lmstudio => "lmstudio",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.id() == id)
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Claude => "Claude",
            Self::ClaudeCode => "Claude Code (je abonnement)",
            Self::CodexCli => "ChatGPT (je abonnement, via Codex)",
            Self::GeminiCli => "Gemini (je Google-account, via Gemini CLI)",
            Self::GrokCli => "Grok (je xAI-account, via Grok)",
            Self::KimiCli => "Kimi (je Kimi-account, via Kimi Code)",
            Self::VibeCli => "Mistral (je Mistral-account, via Vibe)",
            Self::Openai => "OpenAI",
            Self::Gemini => "Google Gemini",
            Self::Grok => "Grok (xAI)",
            Self::Mistral => "Mistral",
            Self::Groq => "Groq",
            Self::Openrouter => "OpenRouter (alle modellen)",
            Self::Deepseek => "DeepSeek",
            Self::Qwen => "Qwen",
            Self::Moonshot => "Moonshot (Kimi)",
            Self::Ollama => "Ollama (op deze computer)",
            Self::Lmstudio => "LM Studio (op deze computer)",
        }
    }

    /// Draait lokaal; geen sleutel nodig.
    pub fn is_local_server(self) -> bool {
        matches!(self, Self::Ollama | Self::Lmstudio)
    }

    pub fn needs_key(self) -> bool {
        !self.is_local_server() && !self.is_subscription()
    }

    /// The command of the coding agent whose own login this provider thinks with (your subscription or account, no
    /// key); `None` for the APIs.
    pub fn cli_command(self) -> Option<&'static str> {
        match self {
            Self::ClaudeCode => Some("claude"),
            Self::CodexCli => Some("codex"),
            Self::GeminiCli => Some("gemini"),
            Self::GrokCli => Some("grok"),
            Self::KimiCli => Some("kimi"),
            Self::VibeCli => Some("vibe"),
            Self::Claude
            | Self::Openai
            | Self::Gemini
            | Self::Grok
            | Self::Mistral
            | Self::Groq
            | Self::Openrouter
            | Self::Deepseek
            | Self::Qwen
            | Self::Moonshot
            | Self::Ollama
            | Self::Lmstudio => None,
        }
    }

    /// What to run once in a terminal to sign in: Kimi Code and Vibe have their own command; the agents Nook runs sign
    /// in when they start.
    pub fn login_command(self) -> Option<&'static str> {
        match self {
            Self::KimiCli => Some("kimi login"),
            Self::VibeCli => Some("vibe --setup"),
            other => other.cli_command(),
        }
    }

    /// Thinks through a coding agent you are signed in to, instead of an API with a key.
    pub fn is_subscription(self) -> bool {
        self.cli_command().is_some()
    }

    /// Pictures go along with the prompt through the agent: Codex takes them, Claude Code through its stream input;
    /// Gemini CLI, Grok, Kimi and Vibe would only read them as files, which stays off.
    pub fn cli_takes_images(self) -> bool {
        matches!(self, Self::ClaudeCode | Self::CodexCli) || !self.is_subscription()
    }

    /// Whether the agent may search the web for Nook when the Web source is allowed. Kimi and Vibe never search: their
    /// search tools are not named in their documentation, so every tool stays off.
    pub fn cli_searches_web(self) -> bool {
        matches!(self, Self::ClaudeCode | Self::CodexCli | Self::GeminiCli | Self::GrokCli)
    }

    /// Naam waaronder de sleutel in de geheimenkluis staat (zelfde als de Keychain op de Mac).
    pub fn key_account(self) -> String {
        if self == Self::Claude {
            "anthropic-api-key".into()
        } else {
            format!("{}-api-key", self.id())
        }
    }

    pub fn key_placeholder(self) -> &'static str {
        match self {
            Self::Claude => "Anthropic API-sleutel (sk-ant-…)",
            Self::Openai => "OpenAI API-sleutel (sk-…)",
            Self::Gemini => "Google AI Studio-sleutel",
            Self::Grok => "xAI API-sleutel (xai-…)",
            Self::Mistral => "Mistral API-sleutel",
            Self::Groq => "Groq API-sleutel (gsk_…)",
            Self::Openrouter => "OpenRouter-sleutel (sk-or-…)",
            Self::Deepseek => "DeepSeek API-sleutel",
            Self::Qwen => "DashScope API-sleutel",
            Self::Moonshot => "Moonshot API-sleutel",
            Self::Ollama
            | Self::Lmstudio
            | Self::ClaudeCode
            | Self::CodexCli
            | Self::GeminiCli
            | Self::GrokCli
            | Self::KimiCli
            | Self::VibeCli => "",
        }
    }

    pub fn key_url(self) -> &'static str {
        match self {
            Self::Claude => "https://console.anthropic.com/settings/keys",
            Self::ClaudeCode => "https://claude.com/product/claude-code",
            Self::CodexCli => "https://github.com/openai/codex",
            Self::GeminiCli => "https://github.com/google-gemini/gemini-cli",
            Self::GrokCli => "https://github.com/xai-org/grok-build",
            Self::KimiCli => "https://github.com/MoonshotAI/kimi-code",
            Self::VibeCli => "https://github.com/mistralai/mistral-vibe",
            Self::Openai => "https://platform.openai.com/api-keys",
            Self::Gemini => "https://aistudio.google.com/apikey",
            Self::Grok => "https://console.x.ai",
            Self::Mistral => "https://console.mistral.ai/api-keys",
            Self::Groq => "https://console.groq.com/keys",
            Self::Openrouter => "https://openrouter.ai/settings/keys",
            Self::Deepseek => "https://platform.deepseek.com/api_keys",
            Self::Qwen => "https://dashscope.console.aliyun.com/apiKey",
            Self::Moonshot => "https://platform.moonshot.ai/console/api-keys",
            Self::Ollama => "https://ollama.com/download",
            Self::Lmstudio => "https://lmstudio.ai",
        }
    }

    /// Basisadres van de OpenAI-compatibele API (Claude gebruikt de Anthropic Messages API).
    pub fn base_url(self) -> &'static str {
        match self {
            Self::Claude | Self::ClaudeCode => "https://api.anthropic.com/v1",
            Self::Openai | Self::CodexCli => "https://api.openai.com/v1",
            Self::Gemini | Self::GeminiCli => "https://generativelanguage.googleapis.com/v1beta/openai",
            Self::Grok | Self::GrokCli => "https://api.x.ai/v1",
            Self::Mistral | Self::VibeCli => "https://api.mistral.ai/v1",
            Self::Groq => "https://api.groq.com/openai/v1",
            Self::Openrouter => "https://openrouter.ai/api/v1",
            Self::Deepseek => "https://api.deepseek.com/v1",
            Self::Qwen => "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            Self::Moonshot | Self::KimiCli => "https://api.moonshot.ai/v1",
            Self::Ollama => "http://localhost:11434/v1",
            Self::Lmstudio => "http://localhost:1234/v1",
        }
    }

    /// Een snel startmodel. Met "Modellen ophalen" kies je uit wat je sleutel kan gebruiken.
    pub fn default_model(self) -> &'static str {
        match self {
            Self::Claude => "claude-haiku-5-5",
            Self::ClaudeCode => "haiku",
            // Empty: the agent's own default for your account.
            Self::CodexCli | Self::GeminiCli | Self::GrokCli | Self::KimiCli | Self::VibeCli => "",
            Self::Openai => "gpt-4.1-mini",
            Self::Gemini => "gemini-2.5-flash",
            Self::Grok => "grok-3-mini",
            Self::Mistral => "mistral-small-latest",
            Self::Groq => "llama-3.3-70b-versatile",
            Self::Openrouter => "openrouter/auto",
            Self::Deepseek => "deepseek-chat",
            Self::Qwen => "qwen-plus",
            Self::Moonshot => "kimi-k2-turbo-preview",
            Self::Ollama => "llama3.2",
            Self::Lmstudio => "",
        }
    }

    pub fn suggested_models(self) -> &'static [&'static str] {
        match self {
            Self::Claude => &["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"],
            Self::ClaudeCode => &["haiku", "sonnet", "opus"],
            Self::CodexCli | Self::GrokCli | Self::KimiCli | Self::VibeCli => &[],
            Self::GeminiCli => &["gemini-2.5-flash", "gemini-2.5-pro"],
            Self::Openai => &["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini"],
            Self::Gemini => &["gemini-2.5-flash", "gemini-2.5-pro"],
            Self::Grok => &["grok-3-mini", "grok-3", "grok-4"],
            Self::Mistral => &["mistral-small-latest", "mistral-medium-latest", "mistral-large-latest"],
            Self::Groq => &["llama-3.3-70b-versatile", "llama-3.1-8b-instant"],
            Self::Openrouter => &["openrouter/auto", "anthropic/claude-sonnet-4", "google/gemini-2.5-flash", "x-ai/grok-3-mini"],
            Self::Deepseek => &["deepseek-chat", "deepseek-reasoner"],
            Self::Qwen => &["qwen-plus", "qwen-max", "qwen-turbo"],
            Self::Moonshot => &["kimi-k2-turbo-preview", "moonshot-v1-8k"],
            Self::Ollama | Self::Lmstudio => &[],
        }
    }

    /// Haalt de modellen op die deze dienst met deze sleutel aanbiedt.
    pub async fn list_models(self, key: Option<&str>) -> Result<Vec<String>> {
        if self.is_subscription() {
            return Ok(self.suggested_models().iter().map(|s| s.to_string()).collect());
        }
        let base = if self == Self::Ollama {
            format!("{}/v1", crate::brain::conversations::ollama_base_url())
        } else {
            self.base_url().to_string()
        };
        let url = format!("{base}/models{}", if self == Self::Claude { "?limit=100" } else { "" });
        let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(8)).build()?;
        let mut request = client.get(url);
        if self == Self::Claude {
            request = request.header("x-api-key", key.unwrap_or_default()).header("anthropic-version", "2023-06-01");
        } else if let Some(key) = key.filter(|k| !k.is_empty()) {
            request = request.bearer_auth(key);
        }
        let response = request.send().await.map_err(|e| {
            if self.is_local_server() {
                NookError(format!("{} reageert niet. Draait de server?", self.title()))
            } else {
                NookError(e.to_string())
            }
        })?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            return Err(if self.is_local_server() {
                NookError(format!("{} reageert niet. Draait de server?", self.title()))
            } else {
                NookError(format!("{} gaf status {status}. Klopt de API-sleutel?", self.title()))
            });
        }
        let object: serde_json::Value = response.json().await.unwrap_or_default();
        let list = object.get("data").or_else(|| object.get("models")).and_then(|v| v.as_array()).cloned().unwrap_or_default();
        let mut ids: Vec<String> = list
            .iter()
            .filter_map(|m| m.get("id").or_else(|| m.get("name")).and_then(|v| v.as_str()))
            .map(|s| s.replace("models/", ""))
            .filter(|s| Self::is_chat_model(s))
            .collect();
        ids.sort();
        Ok(ids)
    }

    /// Modellijsten bevatten ook embedding-, spraak-, beeld- en moderatiemodellen; als brein geven die alleen een fout.
    pub fn is_chat_model(id: &str) -> bool {
        let lower = id.to_lowercase();
        const EXCLUDED: [&str; 18] = [
            "embed",
            "bge-",
            "all-minilm",
            "rerank",
            "clip",
            "whisper",
            "tts",
            "transcribe",
            "dall-e",
            "imagen",
            "gpt-image",
            "sora",
            "veo",
            "moderat",
            "realtime",
            "babbage",
            "davinci",
            "aqa",
        ];
        !EXCLUDED.iter().any(|e| lower.contains(e))
    }

    /// Of dit model een plaatje kan lezen, afgaand op de naam.
    pub fn sees_images(self, model: &str) -> bool {
        let name = model.to_lowercase();
        let has = |parts: &[&str]| parts.iter().any(|p| name.contains(p));
        match self {
            Self::Claude | Self::ClaudeCode | Self::CodexCli | Self::Gemini | Self::Openrouter => true,
            Self::GeminiCli | Self::GrokCli | Self::KimiCli | Self::VibeCli => false,
            Self::Openai => !has(&["gpt-3", "o1-mini", "o3-mini", "instruct"]),
            Self::Grok => has(&["vision", "grok-4", "grok-2-image"]),
            Self::Mistral => has(&["pixtral", "small", "medium", "large"]),
            Self::Groq => has(&["vision", "scout", "maverick"]),
            Self::Deepseek => false,
            Self::Qwen => has(&["vl", "omni"]),
            Self::Moonshot => has(&["vision", "vl", "k2.5"]),
            Self::Ollama | Self::Lmstudio => has(&[
                "vl",
                "vision",
                "llava",
                "gemma3",
                "gemma-3",
                "gemma4",
                "gemma-4",
                "minicpm-v",
                "moondream",
                "pixtral",
                "qwen3.5",
                "qwen3.6",
                "llama4",
                "llama-4",
                "mistral-small3",
            ]),
        }
    }
}

/// Wat de interface over een dienst moet weten.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    pub id: &'static str,
    pub title: &'static str,
    pub is_local: bool,
    pub needs_key: bool,
    /// Thinks through a coding agent's own sign-in (`cli_command`), with no key.
    pub is_subscription: bool,
    pub cli_command: Option<&'static str>,
    pub login_command: Option<&'static str>,
    pub key_placeholder: &'static str,
    pub key_url: &'static str,
    pub default_model: &'static str,
    pub suggested_models: Vec<&'static str>,
}

impl From<AIProvider> for ProviderInfo {
    fn from(p: AIProvider) -> Self {
        Self {
            id: p.id(),
            title: p.title(),
            is_local: p.is_local_server(),
            needs_key: p.needs_key(),
            is_subscription: p.is_subscription(),
            cli_command: p.cli_command(),
            login_command: p.login_command(),
            key_placeholder: p.key_placeholder(),
            key_url: p.key_url(),
            default_model: p.default_model(),
            suggested_models: p.suggested_models().to_vec(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_round_trip() {
        for p in AIProvider::ALL {
            assert_eq!(AIProvider::from_id(p.id()), Some(p));
            let json = serde_json::to_string(&p).unwrap();
            assert_eq!(json, format!("\"{}\"", p.id()));
        }
    }

    #[test]
    fn chat_models_skip_embeddings() {
        assert!(AIProvider::is_chat_model("gpt-4.1-mini"));
        assert!(!AIProvider::is_chat_model("text-embedding-3-small"));
        assert!(!AIProvider::is_chat_model("whisper-1"));
    }

    #[test]
    fn subscription_brains_need_no_key_and_match_mac_ids() {
        for (provider, id, command) in [
            (AIProvider::CodexCli, "codexCLI", "codex"),
            (AIProvider::GeminiCli, "geminiCLI", "gemini"),
            (AIProvider::GrokCli, "grokCLI", "grok"),
            (AIProvider::KimiCli, "kimiCLI", "kimi"),
            (AIProvider::VibeCli, "vibeCLI", "vibe"),
        ] {
            assert_eq!(provider.id(), id);
            assert_eq!(provider.cli_command(), Some(command));
            assert!(provider.is_subscription() && !provider.needs_key() && !provider.is_local_server());
        }
        assert_eq!(AIProvider::VibeCli.login_command(), Some("vibe --setup"));
        assert_eq!(AIProvider::CodexCli.login_command(), Some("codex"));
        assert_eq!(AIProvider::Openai.login_command(), None);
        assert!(AIProvider::CodexCli.cli_takes_images() && !AIProvider::GeminiCli.cli_takes_images());
        assert!(AIProvider::GrokCli.cli_searches_web() && !AIProvider::KimiCli.cli_searches_web());
        assert!(!AIProvider::Openai.is_subscription() && AIProvider::Openai.cli_takes_images());
    }

    #[test]
    fn key_accounts_match_mac() {
        assert_eq!(AIProvider::Claude.key_account(), "anthropic-api-key");
        assert_eq!(AIProvider::Openai.key_account(), "openai-api-key");
    }
}
