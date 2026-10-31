//! Eén vraag aan het gekozen brein met een eigen systeemprompt en zonder tools: voor het opschonen van een dictaat
//! (Flow) en de samenvatting van een gesprek (Notetaker). Het brein is dat van de gebruiker: standaard lokaal.

use crate::brain::conversations::{AnthropicConversation, OllamaConversation, OpenAIConversation};
use crate::brain::service::profile_for;
use crate::brain::{ModelConversation, PromptImage};
use crate::provider::AIProvider;
use crate::settings::Settings;
use crate::{nook_err, Result};

/// Het antwoord van het brein op `prompt`, met `system` als instructie. `key` is de sleutel van de actieve dienst.
pub async fn complete(settings: &Settings, key: Option<String>, system: &str, prompt: &str, max_tokens: u32) -> Result<String> {
    if settings.provider == AIProvider::ClaudeCode {
        return Err(nook_err!("Claude Code als brein kan hier (nog) niet herschrijven."));
    }
    complete_seeing(settings, key, system, prompt, &[], max_tokens).await
}

/// [`complete`] with images (a screenshot for Gamer Mode). The brain needs to be able to see: a local model without
/// vision answers without them or fails, and that error is shown as is. Claude Code works here too (it reads images,
/// as in the chat), though each call starts a whole session and so takes a few seconds.
pub async fn complete_seeing(
    settings: &Settings,
    key: Option<String>,
    system: &str,
    prompt: &str,
    images: &[PromptImage],
    max_tokens: u32,
) -> Result<String> {
    let provider = settings.provider;
    let model = settings.active_model();
    let memory = crate::brain::profile::system_memory_gb().unwrap_or(16);
    let mut conversation: Box<dyn ModelConversation> = match provider {
        AIProvider::Claude => {
            let key = key.filter(|k| !k.is_empty()).ok_or_else(|| nook_err!("Er is nog geen Anthropic API-sleutel."))?;
            Box::new(AnthropicConversation::new(&model, &key, system, &[], prompt, images, None, max_tokens))
        }
        AIProvider::Ollama => Box::new(OllamaConversation::new(&model, system, &[], prompt, images, profile_for(settings, memory), memory)),
        AIProvider::ClaudeCode => claude_code(&model, system, prompt, images)?,
        other => {
            if other.needs_key() && key.as_deref().unwrap_or("").is_empty() {
                return Err(nook_err!("Er is nog geen sleutel voor {}.", other.title()));
            }
            Box::new(OpenAIConversation::new(other, &model, key, system, &[], prompt, images, Some(max_tokens)))
        }
    };
    let turn = conversation.next(&[], None).await?;
    Ok(turn.text.trim().to_string())
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn claude_code(model: &str, system: &str, prompt: &str, images: &[PromptImage]) -> Result<Box<dyn ModelConversation>> {
    let mut conversation = crate::brain::claude_code::ClaudeCodeConversation::new(model, system, prompt, false);
    conversation.attach(images);
    Ok(Box::new(conversation))
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn claude_code(_model: &str, _system: &str, _prompt: &str, _images: &[PromptImage]) -> Result<Box<dyn ModelConversation>> {
    Err(nook_err!("Claude Code draait niet op een telefoon. Kies een ander brein bij Instellingen › Brein."))
}
