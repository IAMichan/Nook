//! Counters per day and per app, for Settings › Autocomplete › Statistics, and the apps autocomplete has seen. Only
//! counts and app names: never what was typed. Ported from `CompletionStats` in `CompletionLearning.swift`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use chrono::{Duration, NaiveDate};
use serde::{Deserialize, Serialize};

use super::suggestion::word_count;
use crate::paths;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Day {
    /// Suggestions shown.
    pub shown: u32,
    /// Suggestions taken (at least one word of it).
    pub accepted: u32,
    /// Times a key took something: every word, every "all".
    pub takes: u32,
    pub words: u32,
    pub characters: u32,
}

impl Day {
    fn add(&mut self, other: &Day) {
        self.shown += other.shown;
        self.accepted += other.accepted;
        self.takes += other.takes;
        self.words += other.words;
        self.characters += other.characters;
    }
}

/// One app's share.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppCount {
    pub takes: u32,
    pub words: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CompletionStats {
    /// By day, "2026-10-19".
    pub days: BTreeMap<String, Day>,
    /// By app id.
    pub apps: BTreeMap<String, AppCount>,
}

/// The totals Settings shows.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatsSummary {
    pub today: Day,
    pub week: Day,
    pub total: Day,
    /// Share of shown suggestions taken, 0…1.
    pub acceptance: f64,
    pub minutes_saved: f64,
    pub streak: u32,
    /// The apps used most, by times taken.
    pub top_apps: Vec<(String, AppCount)>,
}

pub fn day_key(date: NaiveDate) -> String {
    date.format("%Y-%m-%d").to_string()
}

impl CompletionStats {
    pub fn day(&self, date: NaiveDate) -> Day {
        self.days.get(&day_key(date)).copied().unwrap_or_default()
    }

    pub fn record_shown(&mut self, date: NaiveDate) {
        self.days.entry(day_key(date)).or_default().shown += 1;
    }

    /// `first`: false for the second, third… word taken from the same suggestion.
    pub fn record_accepted(&mut self, text: &str, first: bool, app: Option<&str>, date: NaiveDate) {
        let words = word_count(text) as u32;
        let day = self.days.entry(day_key(date)).or_default();
        if first {
            day.accepted += 1;
        }
        day.takes += 1;
        day.words += words;
        day.characters += text.chars().count() as u32;
        if let Some(app) = app.filter(|a| !a.is_empty()) {
            let count = self.apps.entry(app.to_string()).or_default();
            count.takes += 1;
            count.words += words;
        }
    }

    pub fn total(&self) -> Day {
        let mut total = Day::default();
        for day in self.days.values() {
            total.add(day);
        }
        total
    }

    pub fn acceptance(&self) -> f64 {
        let total = self.total();
        if total.shown == 0 {
            0.0
        } else {
            (total.accepted as f64 / total.shown as f64).min(1.0)
        }
    }

    /// The last seven days added up, today included.
    pub fn week(&self, today: NaiveDate) -> Day {
        let mut total = Day::default();
        for offset in 0..7 {
            total.add(&self.day(today - Duration::days(offset)));
        }
        total
    }

    /// Days in a row, up to today (or yesterday, when today has nothing yet), on which something was taken.
    pub fn streak(&self, today: NaiveDate) -> u32 {
        let mut date = today;
        if self.day(date).takes == 0 {
            date -= Duration::days(1);
        }
        let mut count = 0;
        while self.day(date).takes > 0 {
            count += 1;
            date -= Duration::days(1);
        }
        count
    }

    pub fn top_apps(&self, limit: usize) -> Vec<(String, AppCount)> {
        let mut apps: Vec<(String, AppCount)> = self.apps.iter().map(|(k, v)| (k.clone(), *v)).collect();
        apps.sort_by(|a, b| b.1.takes.cmp(&a.1.takes).then_with(|| a.0.cmp(&b.0)));
        apps.truncate(limit);
        apps
    }

    pub fn summary(&self, today: NaiveDate) -> StatsSummary {
        let total = self.total();
        StatsSummary {
            today: self.day(today),
            week: self.week(today),
            total,
            acceptance: self.acceptance(),
            // Typing at about 40 words a minute.
            minutes_saved: total.words as f64 / 40.0,
            streak: self.streak(today),
            top_apps: self.top_apps(5),
        }
    }
}

/// An app autocomplete saw a text field in, for the Apps tab. No text, only the name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeenApp {
    pub id: String,
    pub name: String,
}

/// The apps seen most recently first, at most `limit`.
pub fn remember_app(list: &mut Vec<SeenApp>, id: &str, name: &str, limit: usize) {
    if id.is_empty() {
        return;
    }
    let wanted = super::prefs::normalize_app(id);
    list.retain(|a| super::prefs::normalize_app(&a.id) != wanted);
    list.insert(0, SeenApp { id: id.into(), name: if name.is_empty() { id.into() } else { name.into() } });
    list.truncate(limit);
}

pub fn folder() -> PathBuf {
    paths::support_directory().join("autocomplete")
}

pub fn stats_file() -> PathBuf {
    folder().join("stats.json")
}

pub fn apps_file() -> PathBuf {
    folder().join("apps.json")
}

pub fn load<T: for<'de> Deserialize<'de> + Default>(path: &Path) -> T {
    std::fs::read(path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}

pub fn save<T: Serialize>(value: &T, path: &Path) -> std::io::Result<()> {
    let bytes = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    paths::write_atomic(path, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, d).unwrap()
    }

    #[test]
    fn counts_without_text() {
        let mut stats = CompletionStats::default();
        stats.record_shown(date(19));
        stats.record_shown(date(19));
        stats.record_accepted(" see you", true, Some("outlook"), date(19));
        stats.record_accepted(" tomorrow", false, Some("outlook"), date(19));
        let day = stats.day(date(19));
        assert_eq!((day.shown, day.accepted, day.takes, day.words, day.characters), (2, 1, 2, 3, 17));
        assert_eq!(stats.acceptance(), 0.5);
        assert_eq!(stats.apps["outlook"], AppCount { takes: 2, words: 3 });
        let json = serde_json::to_string(&stats).unwrap();
        assert!(!json.contains("see you"));
    }

    #[test]
    fn week_and_streak() {
        let mut stats = CompletionStats::default();
        for d in [10, 17, 18, 19] {
            stats.record_accepted("word", true, None, date(d));
        }
        assert_eq!(stats.week(date(19)).takes, 3);
        assert_eq!(stats.streak(date(19)), 3);
        // Nothing yet today: the streak up to yesterday still counts.
        assert_eq!(stats.streak(date(20)), 3);
        assert_eq!(stats.streak(date(22)), 0);
        let summary = stats.summary(date(19));
        assert_eq!(summary.total.words, 4);
        assert_eq!(summary.minutes_saved, 0.1);
    }

    #[test]
    fn top_apps_and_old_files() {
        let mut stats: CompletionStats = serde_json::from_str(r#"{"days":{"2026-10-19":{"shown":3}}}"#).unwrap();
        assert_eq!(stats.day(date(19)).shown, 3);
        stats.record_accepted("a", true, Some("b"), date(19));
        stats.record_accepted("a", true, Some("a"), date(19));
        stats.record_accepted("a", true, Some("b"), date(19));
        assert_eq!(stats.top_apps(1)[0].0, "b");
    }

    #[test]
    fn seen_apps() {
        let mut list = vec![];
        remember_app(&mut list, "notepad", "Kladblok", 3);
        remember_app(&mut list, "Outlook.exe", "Outlook", 3);
        remember_app(&mut list, "NOTEPAD.EXE", "", 3);
        assert_eq!(list.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), vec!["NOTEPAD.EXE", "Outlook.exe"]);
        assert_eq!(list[0].name, "NOTEPAD.EXE");
        remember_app(&mut list, "", "x", 3);
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn files_round_trip() {
        let dir = std::env::temp_dir().join(format!("nook-ac-{}", uuid::Uuid::new_v4()));
        let file = dir.join("stats.json");
        let mut stats = CompletionStats::default();
        stats.record_shown(date(1));
        save(&stats, &file).unwrap();
        assert_eq!(load::<CompletionStats>(&file), stats);
        assert_eq!(load::<CompletionStats>(&dir.join("missing.json")), CompletionStats::default());
        let _ = std::fs::remove_dir_all(dir);
    }
}
