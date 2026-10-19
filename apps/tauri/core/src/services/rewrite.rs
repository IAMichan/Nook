//! Eén vraag aan het gekozen brein met een eigen systeemprompt en zonder tools: voor het opschonen van een dictaat
//! (Flow) en de samenvatting van een gesprek (Notetaker). Het brein is dat van de gebruiker: standaard lokaal.

use crate::brain::conversations::{AnthropicConversation, OllamaConversation, OpenAIConversation};
use crate::brain::service::profile_for;
use crate::brain::ModelConversation;
use crate::provider::AIProvider;
use crate::settings::Settings;
use crate::{nook_err, Result};

/// Het antwoord van het brein op `prompt`, met `system` als instructie. `key` is de sleutel van de actieve dienst.
pub async fn complete(settings: &Settings, key: Option<String>, system: &str, prompt: &str, max_tokens: u32) -> Result<String> {
    let provider = settings.provider;
    let model = settings.active_model();
    let memory = crate::brain::profile::system_memory_gb().unwrap_or(16);
    let mut conversation: Box<dyn ModelConversation> = match provider {
        AIProvider::Claude => {
            let key = key.filter(|k| !k.is_empty()).ok_or_else(|| nook_err!("Er is nog geen Anthropic API-sleutel."))?;
            Box::new(AnthropicConversation::new(&model, &key, system, &[], prompt, &[], None, max_tokens))
        }
        AIProvider::Ollama => Box::new(OllamaConversation::new(&model, system, &[], prompt, &[], profile_for(settings, memory), memory)),
        AIProvider::ClaudeCode => return Err(nook_err!("Claude Code als brein kan hier (nog) niet herschrijven.")),
        other => {
            if other.needs_key() && key.as_deref().unwrap_or("").is_empty() {
                return Err(nook_err!("Er is nog geen sleutel voor {}.", other.title()));
            }
            Box::new(OpenAIConversation::new(other, &model, key, system, &[], prompt, &[], Some(max_tokens)))
        }
    };
    let turn = conversation.next(&[], None).await?;
    Ok(turn.text.trim().to_string())
}
