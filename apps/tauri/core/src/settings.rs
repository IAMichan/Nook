use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::paths;
use crate::provider::AIProvider;
use crate::services::autocomplete::AutocompleteSettings;
use crate::services::energy::EnergyMode;
use crate::services::quiet::QuietBehavior;
use crate::services::telemetry::TelemetrySettings;

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

/// Nook's face (Settings › Appearance › Style and Face and finish, `NookLook` on the Mac): eyes "round", "bars" or
/// "dots"; mouth "expressive", "line" or "none"; lit like a ball; a soft glow around him; blushing when petted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NookLook {
    pub eyes: String,
    pub mouth: String,
    pub gloss: bool,
    pub glow: bool,
    pub cheeks: bool,
}

impl Default for NookLook {
    /// The classic look Nook always had.
    fn default() -> Self {
        Self { eyes: "bars".into(), mouth: "none".into(), gloss: true, glow: true, cheeks: true }
    }
}

/// Colors set by hand over a theme, per appearance: token name ("canvas", "accent", …) to "#rrggbb".
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ColorOverrides {
    pub dark: BTreeMap<String, String>,
    pub light: BTreeMap<String, String>,
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
    /// What Nook may do by itself from the chat (`brain::access`), chosen in the composer; `None` until the user chose
    /// one, when the old `auto_run_safe` switch decides (`access()`).
    pub nook_access: Option<crate::brain::access::NookAccess>,
    /// "top" (balk bovenaan het scherm, de "notch" op Windows/Linux) of "floating" (vrij te slepen).
    pub placement: String,
    pub float_x: Option<f64>,
    pub float_y: Option<f64>,
    pub screen_choice: String,
    pub accent_hex: u32,
    pub hide_when_idle: bool,
    pub panel_large: bool,
    /// Quitting from the tray asks first while a Workspace session is still at work (Settings › General ›
    /// Confirmations; `nook.quit.confirmWorking` on the Mac). On by default.
    pub confirm_quit: bool,
    /// The bar at the top of the screen shows (`showNotch` on the Mac); off, Nook stays out of sight until a shortcut or
    /// the tray opens him, and goes again when he closes. On by default.
    pub show_bar: bool,
    /// The main window opens every time Nook starts, in front when you started Nook and behind your app at login
    /// (Settings › General › Bar & windows, `openWindowAtLaunch` on the Mac). On by default.
    pub open_window_at_launch: bool,
    /// How large the bar's notification is when an agent (terminal or Workspace) finishes, fails or waits on you:
    /// "detailed" (a card with the summary and what changed), "compact" (one slim line in the bar) or "system" (a system
    /// notification, with Allow and Deny on a permission request; `nook_core::services::toast`).
    pub agent_notice: String,
    /// How the other sources show, which apps may notify, and quiet hours (Settings › Notifications,
    /// `services::notice_rules`). The agents' style is `agent_notice` (detailed = card, compact = one line).
    pub notice_rules: crate::services::notice_rules::NoticeRules,
    pub sounds: bool,
    /// Which sound each moment plays (Settings › Notifications › Sound & voice, `soundChoices` on the Mac), by
    /// `NookSound` name: missing or "" is Nook's own (your file in the Sounds folder first), "none" is silent, any
    /// other value the name of a system sound (`services::sounds::system_sounds`).
    pub sound_choices: BTreeMap<String, String>,
    pub speak_answers: bool,
    pub wake_word: bool,
    pub web_search: bool,
    pub live_screen: bool,
    pub screen_with_every_question: bool,
    /// Bronnen die alleen een lokaal brein mag lezen.
    pub local_only_sources: BTreeSet<String>,
    /// Settings › Brain › Screen work: the model on this computer that reads the screen while an external brain answers
    /// ("ollama:<model>", "lmstudio:<model>"; "" for none). See `brain::screen_brain`.
    pub screen_brain: String,
    /// The screen brain does not answer itself: it writes the chosen brain a filtered note (`brain::private_brief`).
    pub screen_brain_relays: bool,
    pub evidence_first: bool,
    pub check_answers: bool,
    /// A small bar above words you select anywhere in Nook asks, explains or translates them (`SelectionAsk`).
    pub selection_ask: bool,
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
    /// What the Home greeting calls you ("Good morning, Noah"); empty greets without a name.
    pub user_name: String,
    /// The features pinned to Home, in order (ids from `src/lib/features.ts`). `None` until you change them, so Home
    /// shows the default set and picks up new defaults.
    pub home_essentials: Option<Vec<String>>,
    /// Home's inbox items you dismissed, by id, with when (RFC 3339); the interface forgets them after two weeks.
    pub inbox_dismissed: BTreeMap<String, String>,
    /// Home's inbox items you snoozed, by id, with when they come back (RFC 3339).
    pub inbox_snoozed: BTreeMap<String, String>,
    /// Which sources may interrupt you: `all`, `work`, `deep` or `off_hours` (see `src/lib/focus.ts`).
    pub focus_mode: String,
    /// When you last looked at the inbox (RFC 3339), so "Catch me up" can summarise what came after.
    pub inbox_seen_at: Option<String>,
    /// Start a local brain (Ollama, LM Studio) that is installed but not running, at launch and from a chat error.
    pub start_local_brain: bool,
    /// The one-time note that closing the main window keeps Nook running in the tray was shown.
    pub tray_hint_shown: bool,
    /// Where the main window was, in physical pixels, so it opens there again.
    pub main_window: Option<WindowPlacement>,
    /// The windows' look (Settings › Appearance): "system", "light" or "dark". Files from before it existed stay dark.
    pub theme: String,
    /// How much room text and rows get (`NookDensity` on the Mac): "compact", "comfortable" or "spacious".
    pub density: String,
    /// The theme shown in dark and in light (Settings › Appearance › Theme, `darkThemeID`/`lightThemeID` on the Mac):
    /// a built-in id ("nook", "warm", "mono", "midnight", "paper", "contrast") or an imported theme's id.
    pub dark_theme: String,
    pub light_theme: String,
    /// VS Code themes you imported, as the window draws them (`lib/palette.ts`): id, name, and a palette for dark and/or
    /// light. Kept as JSON; only the main window reads it.
    pub custom_themes: Vec<serde_json::Value>,
    /// Colors set one by one over the chosen themes (Settings › Appearance › Colors): per appearance, a token and its
    /// color ("#rrggbb").
    pub color_overrides: ColorOverrides,
    /// The colors of added and removed lines: "redGreen" or "blueOrange" (for red-green color blindness).
    pub diff_colors: String,
    /// `$…$`, `$$…$$` and math blocks are typeset with KaTeX (bundled, offline); off shows their source.
    pub render_math: bool,
    /// Markdown shows its style in the composer as you type (bold, italic, code, headings, lists); what is sent stays
    /// plain Markdown (`richComposer` on the Mac).
    pub rich_composer: bool,
    /// Nook reads the newest messages of an open conversation and offers above the field what it can do for them
    /// (`suggestChatActions` on the Mac); nothing runs until you click Do it.
    pub suggest_chat_actions: bool,
    /// The model of the brain's service that looks for those suggestions; empty is the brain's own model.
    pub action_suggestion_model: String,
    /// Nook's face (`NookLook`).
    pub nook_look: NookLook,
    /// Nook as a buddy: the small moments (a hop hello, waking up, a giggle after three pokes, a blush when petted).
    pub buddy_moments: bool,
    /// The default answer style (`ResponseStyle` on the Mac, Settings › Instructions); see `crate::instructions`.
    pub answer_style: String,
    /// The user's own standing instructions for Nook, sent with every question (Settings › Instructions).
    pub instructions: String,
    /// Worktree creation and automatic cleanup rules (Settings › Worktrees, matching macOS `SourceControlGlobalRows`
    /// and `WorktreeCleanup`).
    #[serde(default)]
    pub worktrees: WorktreeSettings,
    /// OpenTelemetry OTLP/HTTP export configuration (Settings › Maintenance › OpenTelemetry export).
    #[serde(default)]
    pub telemetry: TelemetrySettings,
    /// Skill file paths toggled off by the user in Settings › Coding agents › Skills (non-destructive).
    #[serde(default)]
    pub disabled_skills: BTreeSet<String>,
}

/// Worktree creation and automatic cleanup preferences (Settings › Worktrees, matching macOS).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorktreeSettings {
    /// Use fast copy-on-write clones when supported by the filesystem.
    pub fast_worktrees: bool,
    /// Submodule checkout strategy for new worktrees: "recursive", "topLevel", or "skip".
    pub submodules: String,
    /// Fetch and fast-forward the default branch roughly every 15 minutes when clean and idle.
    pub auto_pull_default_branch: bool,
    /// Clone repositories into `host/owner/repo` under ~/Developer.
    pub clone_host_layout: bool,
    /// Remove a worktree once its session's pull request is merged.
    pub cleanup_on_merge: bool,
    /// Days after a settled session before removing its worktree (0 = never, 3, 7, 30).
    pub cleanup_settled_days: u32,
    /// Days of inactivity before removing a quiet session's worktree (0 = never, 3, 7, 30).
    pub cleanup_inactive_days: u32,
    /// Remove a worktree with no commits beyond its base branch.
    pub cleanup_unchanged: bool,
    /// Remove a worktree when its last session is deleted.
    pub cleanup_on_delete: bool,
    /// What local changes keep a worktree from being removed:
    /// "uncommittedChanges", "anyLocalFiles", or "editedTrackedFiles".
    pub keep_when: String,
}

impl Default for WorktreeSettings {
    fn default() -> Self {
        Self {
            fast_worktrees: true,
            submodules: "recursive".into(),
            auto_pull_default_branch: false,
            clone_host_layout: false,
            cleanup_on_merge: true,
            cleanup_settled_days: 7,
            cleanup_inactive_days: 0,
            cleanup_unchanged: false,
            cleanup_on_delete: false,
            keep_when: "uncommittedChanges".into(),
        }
    }
}

/// The main window's last place and size on the desktop.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowPlacement {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub maximized: bool,
}

impl WindowPlacement {
    /// Whether the window's title bar would land on one of these screens (`(x, y, width, height)`), so a window that
    /// was on a screen that is gone now does not open out of reach.
    pub fn visible_on(&self, screens: &[(i32, i32, u32, u32)]) -> bool {
        if self.width < 200 || self.height < 200 {
            return false;
        }
        // A point in the title bar, a little in from the left edge.
        let (px, py) = (self.x.saturating_add(60), self.y.saturating_add(12));
        screens.iter().any(|&(x, y, w, h)| px >= x && py >= y && px < x.saturating_add(w as i32) && py < y.saturating_add(h as i32))
    }
}

impl Default for Settings {
    fn default() -> Self {
        let mut shortcuts = BTreeMap::new();
        shortcuts.insert("talk".into(), "Alt+Space".into());
        shortcuts.insert("chat".into(), "Alt+CommandOrControl+Space".into());
        shortcuts.insert("window".into(), "Alt+CommandOrControl+W".into());
        shortcuts.insert("lookAlong".into(), "Alt+CommandOrControl+N".into());
        Self {
            app_language: system_language().into(),
            language: system_language().into(),
            // Lokaal eerst: niets verlaat de computer tot de gebruiker zelf voor een externe AI kiest.
            provider: AIProvider::Ollama,
            provider_models: BTreeMap::new(),
            auto_watch: false,
            auto_run_safe: false,
            nook_access: None,
            placement: "top".into(),
            float_x: None,
            float_y: None,
            screen_choice: "auto".into(),
            accent_hex: 0xF4_F3_F7,
            hide_when_idle: false,
            panel_large: false,
            confirm_quit: true,
            show_bar: true,
            open_window_at_launch: true,
            agent_notice: "detailed".into(),
            notice_rules: Default::default(),
            sounds: true,
            sound_choices: BTreeMap::new(),
            speak_answers: false,
            wake_word: false,
            web_search: true,
            live_screen: false,
            screen_with_every_question: false,
            local_only_sources: BTreeSet::new(),
            screen_brain: String::new(),
            screen_brain_relays: false,
            evidence_first: false,
            check_answers: true,
            selection_ask: true,
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
            user_name: String::new(),
            home_essentials: None,
            inbox_dismissed: BTreeMap::new(),
            inbox_snoozed: BTreeMap::new(),
            focus_mode: "all".into(),
            inbox_seen_at: None,
            start_local_brain: true,
            tray_hint_shown: false,
            main_window: None,
            theme: "dark".into(),
            density: "comfortable".into(),
            dark_theme: "nook".into(),
            light_theme: "nook".into(),
            custom_themes: Vec::new(),
            color_overrides: ColorOverrides::default(),
            diff_colors: "redGreen".into(),
            render_math: true,
            rich_composer: true,
            suggest_chat_actions: true,
            action_suggestion_model: String::new(),
            nook_look: NookLook::default(),
            buddy_moments: true,
            answer_style: "standard".into(),
            instructions: String::new(),
            worktrees: WorktreeSettings::default(),
            telemetry: TelemetrySettings::default(),
            disabled_skills: BTreeSet::new(),
        }
    }
}

pub const ANSWER_LANGUAGES: [(&str, &str); 6] =
    [("en", "English"), ("nl", "Nederlands"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("auto", "Taal van mijn vraag")];

/// The interface languages, the same five as `AppLanguage` on the Mac.
pub const APP_LANGUAGES: [&str; 5] = ["en", "nl", "de", "fr", "es"];

/// The language Nook starts in: the system's preferred language when Nook speaks it, otherwise English (as on the Mac).
pub fn system_language() -> &'static str {
    let preferred = sys_locale::get_locale().unwrap_or_default().to_lowercase();
    language_of_locale(&preferred)
}

fn language_of_locale(locale: &str) -> &'static str {
    let code = locale.split(['-', '_', '.']).next().unwrap_or("");
    APP_LANGUAGES.iter().copied().find(|c| *c == code).unwrap_or("en")
}

impl Settings {
    pub fn load() -> Self {
        let settings = Self::load_from(&paths::settings_file());
        crate::i18n::set_language(&settings.app_language);
        settings
    }

    pub fn load_from(path: &std::path::Path) -> Self {
        std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        crate::i18n::set_language(&self.app_language);
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

    /// The chosen access level, or the one the old "small things right away" switch meant.
    pub fn access(&self) -> crate::brain::access::NookAccess {
        crate::brain::access::NookAccess::migrated(self.nook_access, self.auto_run_safe)
    }

    pub fn selection(&self) -> BrainSelection {
        BrainSelection::resolve(self.provider, self.active_model())
    }

    pub fn is_local_brain(&self) -> bool {
        self.selection().is_local()
    }

    /// The model on this computer that does the screen work, while the chosen brain is external and the screen stays
    /// here (`brain::screen_brain::worker`).
    pub fn screen_worker(&self) -> Option<BrainSelection> {
        crate::brain::screen_brain::worker(&self.selection(), self.local_only_sources.contains("screen"), &self.screen_brain)
    }

    /// The screen brain when it writes the chosen brain a note instead of answering itself.
    pub fn relay_worker(&self) -> Option<BrainSelection> {
        self.screen_worker().filter(|_| self.screen_brain_relays)
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
        let name = ANSWER_LANGUAGES.iter().find(|(c, _)| *c == self.language).map(|(_, n)| *n).unwrap_or("English");
        format!("Always respond in {name}, even if the data or tools are in a different language.")
    }

    /// The language code for a request Nook writes itself (looking at the screen, thinking along). Its text is Nook's
    /// own, not the user's, so with "auto" the language comes from the app language instead of from that text.
    pub fn own_language(&self) -> &str {
        let code = if self.language == "auto" { self.app_language.as_str() } else { self.language.as_str() };
        if ANSWER_LANGUAGES.iter().any(|(c, _)| *c == code && *c != "auto") {
            code
        } else {
            "en"
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
mod window_placement_tests {
    use super::*;

    #[test]
    fn a_window_on_a_screen_that_is_gone_does_not_count() {
        let placement = WindowPlacement { x: 2200, y: 100, width: 1080, height: 720, maximized: false };
        let one = [(0, 0, 1920, 1080)];
        let two = [(0, 0, 1920, 1080), (1920, 0, 2560, 1440)];
        assert!(!placement.visible_on(&one));
        assert!(placement.visible_on(&two));
        assert!(!WindowPlacement { width: 50, ..placement }.visible_on(&two));
        assert!(WindowPlacement { x: -1800, y: 40, ..placement }.visible_on(&[(-1920, 0, 1920, 1080)]));
    }
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
        assert_eq!(s.own_language(), "en");
    }

    #[test]
    fn first_start_follows_the_system_language_or_english() {
        assert_eq!(language_of_locale("nl-nl"), "nl");
        assert_eq!(language_of_locale("de_de.utf-8"), "de");
        assert_eq!(language_of_locale("fr"), "fr");
        assert_eq!(language_of_locale("es-419"), "es");
        assert_eq!(language_of_locale("ja-jp"), "en");
        assert_eq!(language_of_locale(""), "en");
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
    fn old_settings_files_keep_the_dark_look() {
        let s: Settings = serde_json::from_str(r#"{"provider":"ollama"}"#).unwrap();
        assert_eq!(s.theme, "dark");
        assert_eq!(s.density, "comfortable");
        assert_eq!(s.answer_style, "standard");
        assert!(s.instructions.is_empty());
        let s: Settings = serde_json::from_str(r#"{"theme":"light","instructions":"Call me Sam."}"#).unwrap();
        assert_eq!(s.theme, "light");
        assert_eq!(s.instructions, "Call me Sam.");
    }

    #[test]
    fn old_settings_files_get_worktrees_and_telemetry_defaults() {
        let s: Settings = serde_json::from_str(r#"{"provider":"ollama"}"#).unwrap();
        assert!(s.worktrees.fast_worktrees);
        assert_eq!(s.worktrees.submodules, "recursive");
        assert!(s.worktrees.cleanup_on_merge);
        assert_eq!(s.worktrees.cleanup_settled_days, 7);
        assert_eq!(s.worktrees.keep_when, "uncommittedChanges");
        assert!(!s.telemetry.enabled);
        assert!(s.telemetry.traces_endpoint.is_empty());
        assert!(s.disabled_skills.is_empty());
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
