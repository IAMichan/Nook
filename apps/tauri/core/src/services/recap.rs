//! Het weekoverzicht: wat je agents per dag deden, bewaard in `recap.json` (de laatste tien weken). De agents-laag
//! meldt prompts, tools, wijzigingen en beslissingen; het overzicht op maandag telt ze per week op (`RecapStore` op
//! de Mac).

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use chrono::{DateTime, Datelike, Days, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::paths;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RecapDay {
    pub sessions: Vec<String>,
    pub prompts: u32,
    pub tool_uses: u32,
    pub commands: u32,
    pub edits: u32,
    pub lines_added: u32,
    pub lines_removed: u32,
    pub allowed: u32,
    pub denied: u32,
    pub questions: u32,
    pub active_seconds: f64,
    pub projects: BTreeMap<String, f64>,
    pub agents: BTreeMap<String, u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WeekSummary {
    /// Maandag van de week.
    pub start: NaiveDate,
    pub active_seconds: f64,
    pub sessions: u32,
    pub prompts: u32,
    pub commands: u32,
    pub edits: u32,
    pub lines_added: u32,
    pub lines_removed: u32,
    pub allowed: u32,
    pub denied: u32,
    pub questions: u32,
    pub top_project: Option<String>,
    pub top_agent: Option<String>,
    pub busiest_day: Option<NaiveDate>,
    pub busiest_seconds: f64,
}

impl WeekSummary {
    pub fn is_empty(&self) -> bool {
        self.prompts == 0 && self.sessions == 0
    }
}

#[derive(Debug, Default)]
pub struct RecapStore {
    file: Option<PathBuf>,
    days: BTreeMap<String, RecapDay>,
    turn_starts: HashMap<String, (DateTime<Utc>, String)>,
}

fn key(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

fn today(now: DateTime<Utc>) -> NaiveDate {
    now.with_timezone(&Local).date_naive()
}

impl RecapStore {
    pub fn open_default() -> Self {
        Self::open(paths::support_directory().join("recap.json"))
    }

    pub fn open(file: PathBuf) -> Self {
        let days = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { file: Some(file), days, turn_starts: HashMap::new() }
    }

    /// Een prompt aan een agent in een sessie.
    pub fn prompt(&mut self, session: &str, project: &str, agent: &str, now: DateTime<Utc>) {
        self.update(now, |day| {
            day.prompts += 1;
            if !day.sessions.iter().any(|s| s == session) {
                day.sessions.push(session.into());
            }
            *day.agents.entry(agent.into()).or_default() += 1;
        });
        self.turn_starts.insert(session.into(), (now, project.into()));
    }

    pub fn tool_use(&mut self, tool: &str, now: DateTime<Utc>) {
        self.update(now, |day| {
            day.tool_uses += 1;
            if ["Bash", "shell", "run_shell_command", "exec_command"].contains(&tool) {
                day.commands += 1;
            }
        });
    }

    pub fn edit(&mut self, added: u32, removed: u32, now: DateTime<Utc>) {
        self.update(now, |day| {
            day.edits += 1;
            day.lines_added += added;
            day.lines_removed += removed;
        });
    }

    pub fn decision(&mut self, allowed: bool, now: DateTime<Utc>) {
        self.update(now, |day| if allowed { day.allowed += 1 } else { day.denied += 1 });
    }

    pub fn question_answered(&mut self, now: DateTime<Utc>) {
        self.update(now, |day| day.questions += 1);
    }

    /// Een beurt van een agent is klaar: de tijd sinds de prompt telt als actieve tijd (hooguit twee uur).
    pub fn turn_ended(&mut self, session: &str, now: DateTime<Utc>) {
        let Some((start, project)) = self.turn_starts.remove(session) else { return };
        let seconds = ((now - start).num_milliseconds() as f64 / 1000.0).min(2.0 * 3600.0);
        if seconds <= 0.0 {
            return;
        }
        self.update(now, |day| {
            day.active_seconds += seconds;
            *day.projects.entry(project).or_default() += seconds;
        });
    }

    pub fn clear(&mut self) {
        self.days.clear();
        self.turn_starts.clear();
        self.save(Utc::now());
    }

    fn update(&mut self, now: DateTime<Utc>, change: impl FnOnce(&mut RecapDay)) {
        change(self.days.entry(key(today(now))).or_default());
        self.save(now);
    }

    fn save(&mut self, now: DateTime<Utc>) {
        // Alleen de laatste tien weken.
        let cutoff = key(today(now).checked_sub_days(Days::new(70)).unwrap_or(today(now)));
        self.days.retain(|k, _| *k >= cutoff);
        if let (Some(file), Ok(bytes)) = (&self.file, serde_json::to_vec(&self.days)) {
            let _ = paths::write_atomic(file, &bytes);
        }
    }

    /// De week (maandag tot en met zondag) waarin `date` valt.
    pub fn summary(&self, date: NaiveDate) -> WeekSummary {
        let start = week_start(date);
        let mut result = WeekSummary {
            start,
            active_seconds: 0.0,
            sessions: 0,
            prompts: 0,
            commands: 0,
            edits: 0,
            lines_added: 0,
            lines_removed: 0,
            allowed: 0,
            denied: 0,
            questions: 0,
            top_project: None,
            top_agent: None,
            busiest_day: None,
            busiest_seconds: 0.0,
        };
        let mut projects: BTreeMap<String, f64> = BTreeMap::new();
        let mut agents: BTreeMap<String, u32> = BTreeMap::new();
        for offset in 0..7 {
            let Some(day_date) = start.checked_add_days(Days::new(offset)) else { continue };
            let Some(day) = self.days.get(&key(day_date)) else { continue };
            result.active_seconds += day.active_seconds;
            result.sessions += day.sessions.len() as u32;
            result.prompts += day.prompts;
            result.commands += day.commands;
            result.edits += day.edits;
            result.lines_added += day.lines_added;
            result.lines_removed += day.lines_removed;
            result.allowed += day.allowed;
            result.denied += day.denied;
            result.questions += day.questions;
            for (name, seconds) in &day.projects {
                *projects.entry(name.clone()).or_default() += seconds;
            }
            for (name, count) in &day.agents {
                *agents.entry(name.clone()).or_default() += count;
            }
            if day.active_seconds > result.busiest_seconds {
                result.busiest_seconds = day.active_seconds;
                result.busiest_day = Some(day_date);
            }
        }
        result.top_project = projects.into_iter().max_by(|a, b| a.1.total_cmp(&b.1)).map(|(k, _)| k);
        result.top_agent = agents.into_iter().max_by_key(|(_, v)| *v).map(|(k, _)| k);
        result
    }
}

/// Waar de hub en de werkruimte hun werk melden (`hub.recap = recap` op de Mac). Leeg tot de app er een overzicht
/// in zet; dan (en in tests) gebeurt er niets.
#[derive(Default)]
pub struct RecapSink(OnceLock<Arc<Mutex<RecapStore>>>);

impl RecapSink {
    pub fn set(&self, store: Arc<Mutex<RecapStore>>) {
        let _ = self.0.set(store);
    }

    pub fn note(&self, change: impl FnOnce(&mut RecapStore, DateTime<Utc>)) {
        if let Some(store) = self.0.get() {
            change(&mut store.lock().unwrap_or_else(|e| e.into_inner()), Utc::now());
        }
    }
}

/// Maandag van de week van `date`.
pub fn week_start(date: NaiveDate) -> NaiveDate {
    date.checked_sub_days(Days::new(date.weekday().num_days_from_monday() as u64)).unwrap_or(date)
}

/// "45 min" of "2 u 5 min".
pub fn duration(seconds: f64) -> String {
    let minutes = (seconds / 60.0) as u64;
    if minutes < 60 {
        format!("{minutes} min")
    } else {
        format!("{} u {} min", minutes / 60, minutes % 60)
    }
}

/// Welke week het overzicht toont: op maandag (of als deze week nog leeg is) de vorige week.
pub fn recap_week(store: &RecapStore, now: NaiveDate) -> (WeekSummary, &'static str) {
    let this_week = store.summary(now);
    let last_week = store.summary(now.checked_sub_days(Days::new(7)).unwrap_or(now));
    if (now.weekday() == chrono::Weekday::Mon || this_week.is_empty()) && !last_week.is_empty() {
        (last_week, "Vorige week")
    } else {
        (this_week, "Deze week")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(y: i32, m: u32, d: u32, h: u32) -> DateTime<Utc> {
        Local.with_ymd_and_hms(y, m, d, h, 0, 0).unwrap().with_timezone(&Utc)
    }

    use chrono::TimeZone;

    #[test]
    fn counts_a_week_of_agent_work() {
        let mut store = RecapStore::default();
        // Dinsdag 13 en woensdag 14 oktober 2026.
        store.prompt("s1", "nook", "Claude Code", at(2026, 10, 13, 9));
        store.tool_use("Bash", at(2026, 10, 13, 9));
        store.edit(40, 10, at(2026, 10, 13, 9));
        store.decision(true, at(2026, 10, 13, 9));
        store.turn_ended("s1", at(2026, 10, 13, 10));
        store.prompt("s2", "site", "Codex", at(2026, 10, 14, 9));
        store.decision(false, at(2026, 10, 14, 9));
        store.turn_ended("s2", at(2026, 10, 14, 9) + chrono::Duration::minutes(30));

        let week = store.summary(NaiveDate::from_ymd_opt(2026, 10, 15).unwrap());
        assert_eq!(week.start, NaiveDate::from_ymd_opt(2026, 10, 12).unwrap());
        assert_eq!((week.sessions, week.prompts, week.commands, week.edits), (2, 2, 1, 1));
        assert_eq!((week.lines_added, week.lines_removed, week.allowed, week.denied), (40, 10, 1, 1));
        assert_eq!(week.active_seconds, 5400.0);
        assert_eq!(week.top_project.as_deref(), Some("nook"));
        assert_eq!(week.busiest_day, NaiveDate::from_ymd_opt(2026, 10, 13));
        assert_eq!(duration(week.active_seconds), "1 u 30 min");
        assert!(store.summary(NaiveDate::from_ymd_opt(2026, 10, 20).unwrap()).is_empty());
    }

    #[test]
    fn monday_shows_last_week() {
        let mut store = RecapStore::default();
        store.prompt("s1", "nook", "Claude Code", at(2026, 10, 14, 9));
        let monday = NaiveDate::from_ymd_opt(2026, 10, 19).unwrap();
        let (week, label) = recap_week(&store, monday);
        assert_eq!(label, "Vorige week");
        assert_eq!(week.prompts, 1);
        assert_eq!(duration(300.0), "5 min");
        assert_eq!(week_start(monday), monday);
    }
}
