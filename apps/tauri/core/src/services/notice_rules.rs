//! Your choices for notices, in one place (`NoticeRules` on the Mac, Settings › Notifications): how each source shows,
//! which apps may notify, and quiet hours. Pure, so what one notice does can be tested; every place that shows a notice
//! asks `decide` (in the app: `notices::decide` and the `notice_decide` command).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Where a notice comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NoticeSource {
    /// A coding agent, in a terminal or in Nook: done, failed or waiting on you.
    Agents,
    /// A new message in a chat app.
    Chats,
    /// Nook himself: an answer that finished while you looked elsewhere, call notes that are ready.
    Nook,
    /// Think Along: an offer about what is on your screen.
    Suggestions,
}

impl NoticeSource {
    pub const ALL: [Self; 4] = [Self::Agents, Self::Chats, Self::Nook, Self::Suggestions];

    pub fn id(self) -> &'static str {
        match self {
            Self::Agents => "agents",
            Self::Chats => "chats",
            Self::Nook => "nook",
            Self::Suggestions => "suggestions",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.id() == id)
    }
}

/// How a notice shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NoticeStyle {
    /// A card at the bar, with its content and buttons.
    Card,
    /// One slim line at the bar, with a button that opens it.
    #[serde(alias = "line")]
    Strip,
    /// A notification of the system; a click opens it in Nook.
    System,
    /// Nothing pops up: the notice is only kept in the list.
    #[serde(alias = "list")]
    Off,
}

impl NoticeStyle {
    pub const ALL: [Self; 4] = [Self::Card, Self::Strip, Self::System, Self::Off];

    pub fn id(self) -> &'static str {
        match self {
            Self::Card => "card",
            Self::Strip => "strip",
            Self::System => "system",
            Self::Off => "off",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        match id.trim().to_lowercase().as_str() {
            "card" | "detailed" => Some(Self::Card),
            "strip" | "line" | "compact" => Some(Self::Strip),
            "system" => Some(Self::System),
            "off" | "list" => Some(Self::Off),
            _ => None,
        }
    }
}

/// What one notice does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "style")]
pub enum NoticeDecision {
    /// Show it this way (never `Off`).
    Show(NoticeStyle),
    /// Keep it in the list only: no pop-up, no sound.
    HistoryOnly,
}

impl NoticeDecision {
    pub fn style(self) -> Option<NoticeStyle> {
        match self {
            Self::Show(style) => Some(style),
            Self::HistoryOnly => None,
        }
    }
}

/// Hours in which nothing pops up, on the computer and on the phone; `from` == `to` is none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuietHours {
    pub from: u32,
    pub to: u32,
    /// Approvals and questions still come through.
    pub allows_urgent: bool,
}

impl Default for QuietHours {
    /// The Mac's `.evening`: from 22:00 to 7:00, approvals and questions still come through.
    fn default() -> Self {
        Self::evening()
    }
}

impl QuietHours {
    pub const fn evening() -> Self {
        Self { from: 22, to: 7, allows_urgent: true }
    }

    /// Whether `hour` (0…23, local time) lies inside, the end excluded; across midnight when `from` > `to`.
    pub fn contains(&self, hour: u32) -> bool {
        let (from, to) = (self.from % 24, self.to % 24);
        if from == to {
            return false;
        }
        let hour = hour % 24;
        if from < to { hour >= from && hour < to } else { hour >= from || hour < to }
    }

    pub fn silences(&self, urgent: bool, hour: u32) -> bool {
        self.contains(hour) && !(urgent && self.allows_urgent)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NoticeRules {
    /// How each source shows; a source missing here uses its default.
    pub styles: BTreeMap<String, NoticeStyle>,
    /// Apps switched on or off by you, as "source:app"; an app missing here uses its default.
    pub apps: BTreeMap<String, bool>,
    /// Quiet hours for every notice Nook gives by himself; none when absent.
    pub quiet_hours: Option<QuietHours>,
    /// Quiet for the session you are watching: no notice while its app is in front.
    pub quiet_while_watching: bool,
}

impl NoticeRules {
    /// The way each source shows until you choose (`defaultStyle`).
    pub fn default_style(source: NoticeSource) -> NoticeStyle {
        match source {
            NoticeSource::Suggestions => NoticeStyle::Strip,
            _ => NoticeStyle::Card,
        }
    }

    /// Whether an app may notify until you choose (`defaultOn` on the Mac). Chat apps other than WhatsApp already show
    /// their own desktop notifications, so Nook stays quiet about them unless you turn them on.
    pub fn default_on(source: NoticeSource, app: &str) -> bool {
        match source {
            NoticeSource::Agents | NoticeSource::Nook | NoticeSource::Suggestions => true,
            NoticeSource::Chats => Self::normalized_app(app) == "whatsapp",
        }
    }

    pub fn normalized_app(app: &str) -> String {
        let trimmed = app.trim().to_lowercase();
        match trimmed.as_str() {
            "googlechat" => "google chat".to_string(),
            _ => trimmed,
        }
    }

    pub fn style(&self, source: NoticeSource) -> NoticeStyle {
        self.styles.get(source.id()).copied().unwrap_or_else(|| Self::default_style(source))
    }

    pub fn set_style(&mut self, source: NoticeSource, style: NoticeStyle) {
        if style == Self::default_style(source) {
            self.styles.remove(source.id());
        } else {
            self.styles.insert(source.id().to_string(), style);
        }
    }

    pub fn app_key(source: NoticeSource, app: &str) -> String {
        format!("{}:{}", source.id(), Self::normalized_app(app))
    }

    /// Whether `app` may notify; an empty app always may.
    pub fn is_on(&self, source: NoticeSource, app: &str) -> bool {
        if Self::normalized_app(app).is_empty() {
            return true;
        }
        self.apps.get(&Self::app_key(source, app)).copied().unwrap_or_else(|| Self::default_on(source, app))
    }

    /// Switches `app` on or off for `source`. A choice equal to the default is removed rather than stored.
    pub fn set_app(&mut self, source: NoticeSource, app: &str, on: bool) {
        if Self::normalized_app(app).is_empty() {
            return;
        }
        let key = Self::app_key(source, app);
        if on == Self::default_on(source, app) {
            self.apps.remove(&key);
        } else {
            self.apps.insert(key, on);
        }
    }

    /// Whether any source shows as system notifications (`usesSystem` on the Mac).
    pub fn uses_system(&self) -> bool {
        NoticeSource::ALL.into_iter().any(|s| self.style(s) == NoticeStyle::System)
    }

    /// What one notice does (`decide` on the Mac). `urgent`: an agent waits for your decision; it always reaches you, as
    /// a system notification when that is your choice, else as a card. `quiet`: you share your screen or sit in a meeting
    /// and chose quiet. `watching`: you look at what it is about already. `hour`: inside the quiet hours only the list
    /// keeps it, unless it is urgent and urgent may come through.
    pub fn decide(&self, source: NoticeSource, app: &str, urgent: bool, quiet: bool, watching: bool, hour: u32) -> NoticeDecision {
        let style = self.style(source);
        if self.quiet_hours.is_some_and(|q| q.silences(urgent, hour)) {
            return NoticeDecision::HistoryOnly;
        }
        if urgent {
            return NoticeDecision::Show(if style == NoticeStyle::System { NoticeStyle::System } else { NoticeStyle::Card });
        }
        if (watching && self.quiet_while_watching) || quiet || style == NoticeStyle::Off || !self.is_on(source, app) {
            return NoticeDecision::HistoryOnly;
        }
        NoticeDecision::Show(style)
    }

    /// Whether an agent push may go to a paired phone (`allowsAgentPush` on the Mac): approvals and questions always
    /// may; finished/failed/limited turns only while the agent's app switch is on and the session is neither snoozed nor
    /// settled.
    pub fn allows_agent_push(&self, urgent: bool, app: &str, snoozed: bool, settled: bool) -> bool {
        if urgent {
            return true;
        }
        self.is_on(NoticeSource::Agents, app) && !snoozed && !settled
    }

    /// Adopts legacy quiet hours once, while the rules have none yet (`adoptingQuietHours` on the Mac).
    pub fn adopting_quiet_hours(&mut self, legacy: Option<QuietHours>, adopted: bool) -> bool {
        if adopted || self.quiet_hours.is_some() {
            return false;
        }
        let Some(hours) = legacy else { return false };
        self.quiet_hours = Some(hours);
        true
    }

    /// Migrates pre-rules choices (`NoticeRules.migrated` on the Mac).
    pub fn migrated(
        agent_notice: Option<&str>,
        notice_delivery: Option<&str>,
        whatsapp_notify: Option<bool>,
        think_along_muted: &[&str],
    ) -> Self {
        let mut rules = Self::default();
        if notice_delivery == Some("system") {
            rules.set_style(NoticeSource::Agents, NoticeStyle::System);
        } else if let Some(style) = agent_notice.map(Self::agent_style) {
            rules.set_style(NoticeSource::Agents, style);
        }
        if let Some(on) = whatsapp_notify {
            rules.set_app(NoticeSource::Chats, "whatsapp", on);
        }
        for app in think_along_muted {
            rules.set_app(NoticeSource::Suggestions, app, false);
        }
        rules
    }

    /// The agents' style from the older single choice (`agent_notice`: detailed, compact, system, off).
    pub fn agent_style(agent_notice: &str) -> NoticeStyle {
        match agent_notice {
            "compact" | "strip" | "line" => NoticeStyle::Strip,
            "system" => NoticeStyle::System,
            "off" | "list" => NoticeStyle::Off,
            _ => NoticeStyle::Card,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_source_shows_the_way_it_is_set() {
        let mut rules = NoticeRules::default();
        assert_eq!(rules.decide(NoticeSource::Agents, "", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Chats, "whatsapp", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Nook, "", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Suggestions, "", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Strip));

        rules.set_style(NoticeSource::Chats, NoticeStyle::System);
        rules.set_style(NoticeSource::Nook, NoticeStyle::Off);
        assert_eq!(rules.decide(NoticeSource::Chats, "whatsapp", false, false, false, 12), NoticeDecision::Show(NoticeStyle::System));
        assert_eq!(rules.decide(NoticeSource::Nook, "", false, false, false, 12), NoticeDecision::HistoryOnly);
        assert_eq!(rules.decide(NoticeSource::Agents, "", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));
    }

    #[test]
    fn choice_equal_to_default_is_not_stored() {
        let mut rules = NoticeRules::default();
        rules.set_style(NoticeSource::Agents, NoticeStyle::Strip);
        rules.set_style(NoticeSource::Agents, NoticeStyle::Card);
        rules.set_app(NoticeSource::Agents, "codex", false);
        rules.set_app(NoticeSource::Agents, "codex", true);
        rules.set_app(NoticeSource::Chats, "telegram", true);
        rules.set_app(NoticeSource::Chats, "telegram", false);
        assert_eq!(rules, NoticeRules::default());
    }

    #[test]
    fn per_app_switches_and_chat_defaults_match_macos() {
        let mut rules = NoticeRules::default();
        rules.set_app(NoticeSource::Agents, "codex", false);
        assert_eq!(rules.decide(NoticeSource::Agents, "Codex", false, false, false, 12), NoticeDecision::HistoryOnly);
        assert_eq!(rules.decide(NoticeSource::Agents, "claude", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));

        // WhatsApp notifies by default; other chat apps start off until switched on.
        assert_eq!(rules.decide(NoticeSource::Chats, "WhatsApp", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Chats, "Telegram", false, false, false, 12), NoticeDecision::HistoryOnly);
        assert_eq!(rules.decide(NoticeSource::Chats, "Google Chat", false, false, false, 12), NoticeDecision::HistoryOnly);

        rules.set_app(NoticeSource::Chats, "telegram", true);
        rules.set_app(NoticeSource::Chats, "googlechat", true);
        assert_eq!(rules.decide(NoticeSource::Chats, "Telegram", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Chats, "Google Chat", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));

        rules.set_app(NoticeSource::Chats, "WhatsApp", false);
        assert_eq!(rules.decide(NoticeSource::Chats, "whatsapp", false, false, false, 12), NoticeDecision::HistoryOnly);
    }

    #[test]
    fn urgent_agent_notices_reach_you_even_when_off_muted_or_quiet() {
        let mut rules = NoticeRules::default();
        rules.set_style(NoticeSource::Agents, NoticeStyle::Off);
        rules.set_app(NoticeSource::Agents, "claude", false);
        assert_eq!(rules.decide(NoticeSource::Agents, "claude", true, true, true, 12), NoticeDecision::Show(NoticeStyle::Card));

        rules.set_style(NoticeSource::Agents, NoticeStyle::Strip);
        assert_eq!(rules.decide(NoticeSource::Agents, "", true, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));

        rules.set_style(NoticeSource::Agents, NoticeStyle::System);
        assert_eq!(rules.decide(NoticeSource::Agents, "", true, false, false, 12), NoticeDecision::Show(NoticeStyle::System));
    }

    #[test]
    fn quiet_hours_wrap_midnight_and_respect_urgent_setting() {
        let hours = QuietHours::evening();
        assert!(hours.contains(22) && hours.contains(23) && hours.contains(0) && hours.contains(3));
        assert!(!hours.contains(7) && !hours.contains(12));

        let mut rules = NoticeRules { quiet_hours: Some(hours), ..Default::default() };
        assert_eq!(rules.decide(NoticeSource::Chats, "whatsapp", false, false, false, 23), NoticeDecision::HistoryOnly);
        assert_eq!(rules.decide(NoticeSource::Agents, "", true, false, false, 23), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Agents, "", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));

        rules.quiet_hours = Some(QuietHours { from: 9, to: 17, allows_urgent: false });
        assert_eq!(rules.decide(NoticeSource::Agents, "", true, false, false, 10), NoticeDecision::HistoryOnly);
        assert_eq!(rules.decide(NoticeSource::Agents, "", false, false, false, 18), NoticeDecision::Show(NoticeStyle::Card));

        // Equal from/to disables quiet hours.
        assert!(!QuietHours { from: 10, to: 10, allows_urgent: false }.contains(10));
    }

    #[test]
    fn quiet_while_watching_only_holds_back_when_enabled() {
        let mut rules = NoticeRules::default();
        assert_eq!(rules.decide(NoticeSource::Agents, "claude", false, false, true, 12), NoticeDecision::Show(NoticeStyle::Card));

        rules.quiet_while_watching = true;
        for source in NoticeSource::ALL {
            assert_eq!(rules.decide(source, "whatsapp", false, false, true, 12), NoticeDecision::HistoryOnly);
            assert_eq!(rules.decide(source, "whatsapp", false, true, false, 12), NoticeDecision::HistoryOnly);
        }
        // Urgent still breaks through while watching.
        assert_eq!(rules.decide(NoticeSource::Agents, "claude", true, false, true, 12), NoticeDecision::Show(NoticeStyle::Card));
    }

    #[test]
    fn uses_system_and_agent_push_and_migration() {
        let mut rules = NoticeRules::default();
        assert!(!rules.uses_system());
        rules.set_style(NoticeSource::Suggestions, NoticeStyle::System);
        assert!(rules.uses_system());

        assert!(rules.allows_agent_push(false, "claude", false, false));
        assert!(!rules.allows_agent_push(false, "claude", true, false));
        assert!(!rules.allows_agent_push(false, "claude", false, true));
        assert!(rules.allows_agent_push(true, "claude", true, true));
        rules.set_app(NoticeSource::Agents, "claude", false);
        assert!(!rules.allows_agent_push(false, "claude", false, false));
        assert!(rules.allows_agent_push(true, "claude", false, false));

        assert!(!rules.adopting_quiet_hours(None, false));
        assert!(rules.adopting_quiet_hours(Some(QuietHours::evening()), false));
        assert!(!rules.adopting_quiet_hours(Some(QuietHours { from: 1, to: 5, allows_urgent: false }), false));

        assert_eq!(NoticeRules::migrated(None, None, None, &[]), NoticeRules::default());
        assert_eq!(NoticeRules::migrated(Some("compact"), None, None, &[]).style(NoticeSource::Agents), NoticeStyle::Strip);
        assert_eq!(NoticeRules::migrated(Some("compact"), Some("system"), None, &[]).style(NoticeSource::Agents), NoticeStyle::System);
        let migrated = NoticeRules::migrated(None, None, Some(false), &["notepad.exe"]);
        assert!(!migrated.is_on(NoticeSource::Chats, "whatsapp"));
        assert!(!migrated.is_on(NoticeSource::Suggestions, "notepad.exe"));
        assert!(migrated.is_on(NoticeSource::Suggestions, "code.exe"));
    }

    #[test]
    fn rules_survive_json_round_trip_and_style_aliases() {
        let mut rules = NoticeRules::default();
        rules.set_style(NoticeSource::Agents, NoticeStyle::System);
        rules.set_app(NoticeSource::Chats, "slack", true);
        rules.quiet_while_watching = true;
        rules.quiet_hours = Some(QuietHours::evening());
        let json = serde_json::to_string(&rules).unwrap();
        let decoded: NoticeRules = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, rules);

        let aliased: NoticeRules = serde_json::from_str(r#"{"styles":{"agents":"line","nook":"list"}}"#).unwrap();
        assert_eq!(aliased.style(NoticeSource::Agents), NoticeStyle::Strip);
        assert_eq!(aliased.style(NoticeSource::Nook), NoticeStyle::Off);
    }
}
