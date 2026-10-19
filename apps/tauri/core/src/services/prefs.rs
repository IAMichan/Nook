//! Instellingen van de platformdiensten die niet in `Settings` staan (die deelt de app met de Mac): klembord,
//! spraakherkenning, meedenken per app, eigen sneltoetsen. Een eigen bestand `services.json` in de gegevensmap.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::paths;

/// Waar spraak tekst wordt. Nooit stilletjes naar de cloud: een externe dienst kiest de gebruiker zelf.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SpeechEngine {
    /// Op deze computer: whisper.cpp (`whisper-cli`) met een model dat de gebruiker koos.
    #[default]
    Local,
    /// De spraakherkenning van Windows. Vrije tekst gaat daarbij via de online spraakherkenning van Microsoft.
    Windows,
    /// OpenAI (`audio/transcriptions`, met de OpenAI-sleutel uit de kluis).
    Openai,
    /// Groq (zelfde API, met de Groq-sleutel).
    Groq,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ServicePrefs {
    /// Klembord lezen, standaard uit zoals op de Mac.
    pub clipboard: bool,
    pub speech_engine: SpeechEngine,
    /// Het model van whisper.cpp (`ggml-*.bin`) voor herkenning op deze computer.
    pub whisper_model: String,
    /// Apps waarin Nook niet meedenkt (id → naam).
    pub think_along_muted: BTreeMap<String, String>,
    /// Sneltoets voor een schermdeel (⌥⌘4 op de Mac).
    pub screen_part_shortcut: String,
    /// Sneltoets om de Notetaker te starten en te stoppen.
    pub notes_shortcut: String,
    /// Bestanden zoeken en lezen voor het brein.
    pub files: bool,
    /// Gesprekken van de Notetaker als bron voor de chat.
    pub call_notes: bool,
    /// Het overzicht van vorige week op maandag gezien (maandag als "2026-10-19").
    pub recap_seen: String,
}

impl Default for ServicePrefs {
    fn default() -> Self {
        Self {
            clipboard: false,
            speech_engine: SpeechEngine::Local,
            whisper_model: String::new(),
            think_along_muted: BTreeMap::new(),
            screen_part_shortcut: "Alt+CommandOrControl+4".into(),
            notes_shortcut: "Alt+CommandOrControl+R".into(),
            files: true,
            call_notes: true,
            recap_seen: String::new(),
        }
    }
}

impl ServicePrefs {
    pub fn file() -> PathBuf {
        paths::support_directory().join("services.json")
    }

    pub fn load() -> Self {
        Self::load_from(&Self::file())
    }

    pub fn load_from(path: &std::path::Path) -> Self {
        std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        self.save_to(&Self::file())
    }

    pub fn save_to(&self, path: &std::path::Path) -> std::io::Result<()> {
        paths::write_atomic(path, &serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_is_off_and_speech_stays_local_by_default() {
        let prefs: ServicePrefs = serde_json::from_str("{}").unwrap();
        assert!(!prefs.clipboard);
        assert_eq!(prefs.speech_engine, SpeechEngine::Local);
        let dir = std::env::temp_dir().join(format!("nook-prefs-{}", uuid::Uuid::new_v4()));
        let file = dir.join("services.json");
        let prefs = ServicePrefs { clipboard: true, speech_engine: SpeechEngine::Groq, ..Default::default() };
        prefs.save_to(&file).unwrap();
        assert_eq!(ServicePrefs::load_from(&file), prefs);
        let _ = std::fs::remove_dir_all(dir);
    }
}
