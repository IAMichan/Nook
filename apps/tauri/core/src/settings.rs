use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::paths;
use crate::provider::AIProvider;
use crate::services::autocomplete::AutocompleteSettings;
use crate::services::energy::EnergyMode;
use crate::services::quiet::QuietBehavior;

/// Waar het denken gebeurt. Op Windows, Linux en Android is er (nog) geen ingebouwd MLX-model:
/// lokaal betekent Ollama of LM Studio.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BrainRuntime {
    Ollama,
    Lmstudio,
    External,
}

impl BrainRuntime {
    pub fn is_local(self) -> bool {
        self != Self::External
    }
}

/// Het ene antwoord op "welk brein is actief": runtime, model, en voor een externe dienst welke.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrainSelection {
    pub runtime: BrainRuntime,
    pub provider: AIProvider,
    pub model: String,
}

impl BrainSelection {
    pub fn resolve(provider: AIProvider, model: String) -> Self {
        let runtime = match provider {
            AIProvider::Ollama => BrainRuntime::Ollama,
            AIProvider::Lmstudio => BrainRuntime::Lmstudio,
            _ => BrainRuntime::External,
        };
        Self { runtime, provider, model }
    }

    pub fn is_local(&self) -> bool {
        self.runtime.is_local()
    }
}

/// Alle instellingen, als één JSON-bestand in de gegevensmap. Namen gelijk aan de `UserDefaults`-sleutels op de Mac,
/// zodat een export van de ene naar de andere te lezen is. Onbekende of ontbrekende velden krijgen hun standaard.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Taal van de interface: nl, en, de.
    pub app_language: String,
    /// Taal van Nooks antwoorden: een code, of "auto" (de taal van je vraag).
    pub language: String,
    pub provider: AIProvider,
    /// Model per dienst.
    pub provider_models: BTreeMap<String, String>,
    pub auto_watch: bool,
    pub auto_run_safe: bool,
    /// "top" (balk bovenaan het scherm, de "notch" op Windows/Linux) of "floating" (vrij te slepen).
    pub placement: String,
    pub float_x: Option<f64>,
    pub float_y: Option<f64>,
    pub screen_choice: String,
    pub accent_hex: u32,
    pub hide_when_idle: bool,
    pub panel_large: bool,
    /// How large the bar's notification is when an agent (terminal or Workspace) finishes, fails or waits on you:
    /// "detailed" (a card with the summary and what changed) or "compact" (one slim line in the bar).
    pub agent_notice: String,
    pub sounds: bool,
    pub speak_answers: bool,
    pub wake_word: bool,
    pub web_search: bool,
    pub live_screen: bool,
    pub screen_with_every_question: bool,
    /// Bronnen die alleen een lokaal brein mag lezen.
    pub local_only_sources: BTreeSet<String>,
    pub evidence_first: bool,
    pub check_answers: bool,
    pub use_memory: bool,
    pub learn_from_chats: bool,
    pub onboarding_done: bool,
    pub demo_data: bool,
    /// Sneltoetsen, als Tauri-accelerators ("Alt+Space").
    pub shortcuts: BTreeMap<String, String>,
    /// GitHub organizations ("acme") and repositories ("acme/web") whose pull requests show under Agents › Pull
    /// requests as well (Settings › Accounts & connections). See `connectors::pulls::add_watched`.
    pub watched_pull_requests: Vec<String>,
    /// What Nook does while you share your screen (Settings › Voice and sound › Meetings and screen sharing).
    pub quiet_while_sharing: QuietBehavior,
    /// What Nook does during a meeting; "hide from viewers" counts as quiet here.
    pub quiet_in_meetings: QuietBehavior,
    /// An event going on in your calendar counts as a meeting.
    pub quiet_use_calendar: bool,
    /// Nook's windows are always left out of screen sharing, screenshots and recordings (Windows).
    pub hide_from_captures: bool,
    /// The system's screenshot tool does not count as sharing your screen, so Nook appears in your screenshots.
    pub show_in_screenshots: bool,
    /// How much Nook does by himself on battery or a busy computer (Settings › General › Energy).
    pub energy_mode: EnergyMode,
    /// Autocomplete Anywhere (Settings › Autocomplete). Off by default.
    pub autocomplete: AutocompleteSettings,
}

impl Default for Settings {
    fn default() -> Self {
        let mut shortcuts = BTreeMap::new();
        shortcuts.insert("talk".into(), "Alt+Space".into());
        shortcuts.insert("chat".into(), "Alt+CommandOrControl+Space".into());
        shortcuts.insert("window".into(), "Alt+CommandOrControl+W".into());
        shortcuts.insert("lookAlong".into(), "Alt+CommandOrControl+N".into());
        Self {
            app_language: "nl".into(),
            language: "nl".into(),
            // Lokaal eerst: niets verlaat de computer tot de gebruiker zelf voor een externe AI kiest.
            provider: AIProvider::Ollama,
            provider_models: BTreeMap::new(),
            auto_watch: false,
            auto_run_safe: false,
            placement: "top".into(),
            float_x: None,
            float_y: None,
            screen_choice: "auto".into(),
            accent_hex: 0xF4_F3_F7,
            hide_when_idle: false,
            panel_large: false,
            agent_notice: "detailed".into(),
            sounds: true,
            speak_answers: false,
            wake_word: false,
            web_search: true,
            live_screen: false,
            screen_with_every_question: false,
            local_only_sources: BTreeSet::new(),
            evidence_first: false,
            check_answers: true,
            use_memory: true,
            learn_from_chats: true,
            onboarding_done: false,
            demo_data: false,
            shortcuts,
            watched_pull_requests: vec![],
            quiet_while_sharing: QuietBehavior::HideFromShare,
            quiet_in_meetings: QuietBehavior::Quiet,
            quiet_use_calendar: true,
            hide_from_captures: false,
            show_in_screenshots: false,
            energy_mode: EnergyMode::Automatic,
            autocomplete: AutocompleteSettings::default(),
        }
    }
}

pub const ANSWER_LANGUAGES: [(&str, &str); 6] =
    [("nl", "Nederlands"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("auto", "Taal van mijn vraag")];

impl Settings {
    pub fn load() -> Self {
        Self::load_from(&paths::settings_file())
    }

    pub fn load_from(path: &std::path::Path) -> Self {
        std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        self.save_to(&paths::settings_file())
    }

    pub fn save_to(&self, path: &std::path::Path) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        paths::write_atomic(path, &bytes)
    }

    /// Model van de actieve dienst.
    pub fn active_model(&self) -> String {
        self.provider_models.get(self.provider.id()).cloned().unwrap_or_else(|| self.provider.default_model().to_string())
    }

    pub fn set_provider_model(&mut self, model: &str) {
        self.provider_models.insert(self.provider.id().into(), model.into());
    }

    pub fn selection(&self) -> BrainSelection {
        BrainSelection::resolve(self.provider, self.active_model())
    }

    pub fn is_local_brain(&self) -> bool {
        self.selection().is_local()
    }

    /// De bronnen die het actieve brein niet mag zien.
    pub fn private_sources(&self) -> BTreeSet<String> {
        if self.is_local_brain() {
            BTreeSet::new()
        } else {
            self.local_only_sources.clone()
        }
    }

    /// Korte naam voor de chip bij het invoerveld: "Ollama · llama3.2".
    pub fn brain_label(&self) -> String {
        let model = self.active_model();
        let name = if model.is_empty() { "eerste model".to_string() } else { model };
        let title = self.provider.title().split(" (").next().unwrap_or(self.provider.title());
        format!("{title} · {name}")
    }

    /// Promptzin, bv. "Always respond in Nederlands."
    pub fn language_instruction(&self, request: &str) -> String {
        if self.language == "auto" {
            return match detect_language(request) {
                Some(name) => {
                    format!("Always respond in {name}, the language of the request, even if the data or tools are in a different language.")
                }
                None => "Respond in the language the user writes in.".into(),
            };
        }
        let name = ANSWER_LANGUAGES.iter().find(|(c, _)| *c == self.language).map(|(_, n)| *n).unwrap_or("Nederlands");
        format!("Always respond in {name}, even if the data or tools are in a different language.")
    }

    /// The language code for a request Nook writes itself (looking at the screen, thinking along). Its text is Nook's
    /// own, not the user's, so with "auto" the language comes from the app language instead of from that text.
    pub fn own_language(&self) -> &str {
        let code = if self.language == "auto" { self.app_language.as_str() } else { self.language.as_str() };
        if ANSWER_LANGUAGES.iter().any(|(c, _)| *c == code && *c != "auto") {
            code
        } else {
            "nl"
        }
    }

    /// These settings for a request Nook wrote itself: the answer language is fixed to `own_language`, so the prompt
    /// never asks to answer in the language of Nook's own (often English) request text.
    pub fn for_own_request(&self) -> Settings {
        Settings { language: self.own_language().to_string(), ..self.clone() }
    }
}

/// Een simpele taalherkenning op veelvoorkomende woorden (op de Mac doet NaturalLanguage dit).
/// Geeft alleen een antwoord als het duidelijk is.
pub fn detect_language(text: &str) -> Option<&'static str> {
    if text.trim().chars().count() < 8 {
        return None;
    }
    const WORDS: [(&str, &[&str]); 5] = [
        (
            "Dutch",
            &[
                "de", "het", "een", "en", "ik", "je", "is", "van", "wat", "niet", "dat", "voor", "mijn", "met", "zijn", "kun", "maak",
                "morgen",
            ],
        ),
        (
            "English",
            &["the", "a", "and", "i", "you", "is", "of", "what", "not", "that", "for", "my", "with", "can", "make", "tomorrow", "please"],
        ),
        ("German", &["der", "die", "das", "und", "ich", "du", "ist", "nicht", "was", "für", "mein", "mit", "kannst", "bitte", "morgen"]),
        ("French", &["le", "la", "les", "et", "je", "tu", "est", "pas", "que", "pour", "mon", "avec", "peux", "demain"]),
        ("Spanish", &["el", "la", "los", "y", "yo", "tú", "es", "no", "que", "para", "mi", "con", "puedes", "mañana"]),
    ];
    let lower = text.to_lowercase();
    let tokens: Vec<&str> = lower.split(|c: char| !c.is_alphanumeric() && c != 'ü' && c != 'ñ').filter(|t| !t.is_empty()).collect();
    let mut scores: Vec<(&str, usize)> =
        WORDS.iter().map(|(name, words)| (*name, tokens.iter().filter(|t| words.contains(t)).count())).collect();
    scores.sort_by_key(|s| std::cmp::Reverse(s.1));
    let (best, top) = scores[0];
    let second = scores[1].1;
    (top >= 2 && top > second).then_some(best)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_requests_answer_in_the_app_language() {
        let mut s = Settings { language: "auto".into(), app_language: "nl".into(), ..Default::default() };
        // Nook's own English request text says nothing about the language to answer in.
        assert_eq!(s.own_language(), "nl");
        assert!(s.for_own_request().language_instruction("This is what the user currently has on screen.").contains("Nederlands"));
        s.app_language = "de".into();
        assert_eq!(s.own_language(), "de");
        s.language = "fr".into();
        assert_eq!(s.own_language(), "fr");
        s.language = "auto".into();
        s.app_language = "xx".into();
        assert_eq!(s.own_language(), "nl");
    }

    #[test]
    fn defaults_are_local_first() {
        let s = Settings::default();
        assert!(s.is_local_brain());
        assert_eq!(s.active_model(), "llama3.2");
    }

    #[test]
    fn unknown_fields_keep_defaults() {
        let s: Settings = serde_json::from_str(r#"{"provider":"claude","nieuw":1}"#).unwrap();
        assert_eq!(s.provider, AIProvider::Claude);
        assert!(s.use_memory);
        assert!(!s.is_local_brain());
        // Files from before autocomplete existed: off, local only.
        assert!(!s.autocomplete.enabled);
        assert_eq!(s.autocomplete.engine, crate::services::autocomplete::prefs::EngineChoice::Local);
    }

    #[test]
    fn old_settings_files_get_the_quiet_and_energy_defaults() {
        let s: Settings = serde_json::from_str(r#"{"provider":"ollama"}"#).unwrap();
        assert_eq!(s.quiet_while_sharing, QuietBehavior::HideFromShare);
        assert_eq!(s.quiet_in_meetings, QuietBehavior::Quiet);
        assert!(s.quiet_use_calendar && !s.hide_from_captures && !s.show_in_screenshots);
        assert_eq!(s.energy_mode, EnergyMode::Automatic);
        let s: Settings = serde_json::from_str(r#"{"quietWhileSharing":"hide","energyMode":"saver"}"#).unwrap();
        assert_eq!(s.quiet_while_sharing, QuietBehavior::Hide);
        assert_eq!(s.energy_mode, EnergyMode::Saver);
    }

    #[test]
    fn round_trips_to_disk() {
        let dir = std::env::temp_dir().join(format!("nook-settings-{}", uuid::Uuid::new_v4()));
        let file = dir.join("settings.json");
        let mut s = Settings { provider: AIProvider::Openai, ..Default::default() };
        s.set_provider_model("gpt-4.1");
        s.save_to(&file).unwrap();
        assert_eq!(Settings::load_from(&file), s);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn detects_languages() {
        assert_eq!(detect_language("wat staat er morgen in mijn agenda"), Some("Dutch"));
        assert_eq!(detect_language("what is on my calendar tomorrow please"), Some("English"));
        assert_eq!(detect_language("hoi"), None);
    }
}
