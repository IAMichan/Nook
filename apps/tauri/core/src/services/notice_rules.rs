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
    Strip,
    /// A notification of the system; a click opens it in Nook.
    System,
    /// Nothing pops up: the notice is only kept in the list.
    Off,
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
        Self { from: 22, to: 7, allows_urgent: true }
    }
}

impl QuietHours {
    /// Whether `hour` (0…23, local time) lies inside, the end excluded; across midnight when `from` > `to`.
    pub fn contains(&self, hour: u32) -> bool {
        let (from, to) = (self.from % 24, self.to % 24);
        if from == to {
            return false;
        }
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
    /// Apps switched on or off by you, as "source:app"; an app missing here may notify.
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

    pub fn style(&self, source: NoticeSource) -> NoticeStyle {
        self.styles.get(source.id()).copied().unwrap_or_else(|| Self::default_style(source))
    }

    pub fn app_key(source: NoticeSource, app: &str) -> String {
        format!("{}:{}", source.id(), app.trim().to_lowercase())
    }

    /// Whether `app` may notify; an empty app always may.
    pub fn is_on(&self, source: NoticeSource, app: &str) -> bool {
        if app.trim().is_empty() {
            return true;
        }
        self.apps.get(&Self::app_key(source, app)).copied().unwrap_or(true)
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

    /// The agents' style from the older single choice (`agent_notice`: detailed, compact, system, off).
    pub fn agent_style(agent_notice: &str) -> NoticeStyle {
        match agent_notice {
            "compact" => NoticeStyle::Strip,
            "system" => NoticeStyle::System,
            "off" => NoticeStyle::Off,
            _ => NoticeStyle::Card,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quiet_hours_wrap_midnight_and_let_urgent_through() {
        let hours = QuietHours::default();
        assert!(hours.contains(23) && hours.contains(3) && !hours.contains(7) && !hours.contains(12));
        let rules = NoticeRules { quiet_hours: Some(hours), ..Default::default() };
        assert_eq!(rules.decide(NoticeSource::Chats, "", false, false, false, 23), NoticeDecision::HistoryOnly);
        assert_eq!(rules.decide(NoticeSource::Agents, "", true, false, false, 23), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Agents, "", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Card));
    }

    #[test]
    fn off_and_quiet_keep_it_in_the_list_but_urgent_still_shows() {
        let mut rules = NoticeRules::default();
        rules.styles.insert("agents".into(), NoticeStyle::Off);
        assert_eq!(rules.decide(NoticeSource::Agents, "", false, false, false, 12), NoticeDecision::HistoryOnly);
        assert_eq!(rules.decide(NoticeSource::Agents, "", true, true, false, 12), NoticeDecision::Show(NoticeStyle::Card));
        assert_eq!(rules.decide(NoticeSource::Suggestions, "", false, false, false, 12), NoticeDecision::Show(NoticeStyle::Strip));
        rules.apps.insert(NoticeRules::app_key(NoticeSource::Chats, "Telegram"), false);
        assert_eq!(rules.decide(NoticeSource::Chats, "telegram", false, false, false, 12), NoticeDecision::HistoryOnly);
    }
}
