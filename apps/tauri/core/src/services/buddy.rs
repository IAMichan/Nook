//! Buddy moments (`BuddyMoments` / `BuddyService` on macOS) — SV-19.
//!
//! The small, friendly moments Nook shares on his own: a good morning, welcome back after an away gap
//! (including how many agents finished while you were away), a break reminder after long stretches,
//! session and word milestones, late-night check-in, Friday wrap, and your birthday.
//!
//! A friend knows when to be quiet, so moments are rare by design:
//! - At most 4 per day, with a minimum cooldown between moments, and per-kind caps;
//! - Never while in a meeting/event, while another surface is busy, or while away;
//! - Never guilt-trips you about being away. Coming back is only ever welcomed.
//!
//! All planning and activity logic is pure so tests supply the clock and signals directly.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, Duration, FixedOffset, NaiveDate, Timelike, Utc, Weekday};
use serde::{Deserialize, Serialize};

use crate::i18n::{tr, trf};
use crate::paths;

/// What kind of buddy moment Nook is sharing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BuddyMomentKind {
    /// First time active in the morning (05:00–11:30).
    Morning,
    /// Back after being away for a while (>= 45 min), optionally with a while-you-were-away count.
    WelcomeBack,
    /// A long uninterrupted work stretch (>= 90 min) during the day.
    BreakTime,
    /// Still working late at night (23:00–04:00), once per night across midnight.
    LateNight,
    /// Friday afternoon (16:00–18:30), once.
    FridayWrap,
    /// User's birthday (from 07:00 on), once.
    Birthday,
    /// A round number of finished agent sessions or dictated/written words.
    Milestone,
}

impl BuddyMomentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Morning => "morning",
            Self::WelcomeBack => "welcomeBack",
            Self::BreakTime => "breakTime",
            Self::LateNight => "lateNight",
            Self::FridayWrap => "fridayWrap",
            Self::Birthday => "birthday",
            Self::Milestone => "milestone",
        }
    }
}

/// Whether a milestone counts finished agent sessions or dictated/written words.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum MilestoneUnit {
    #[default]
    Sessions,
    Words,
}

/// How playful Nook's words are. The moments are the same; only the wording changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum BuddyTone {
    Calm,
    #[default]
    Warm,
    Playful,
}

impl BuddyTone {
    pub fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "calm" => Self::Calm,
            "playful" => Self::Playful,
            _ => Self::Warm,
        }
    }
}

/// A calendar month and day (for birthdays), matching macOS `NookMonthDay`.
/// Leap-day birthdays (Feb 29) are celebrated on Feb 28 in non-leap years.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MonthDay {
    pub month: u32,
    pub day: u32,
}

impl MonthDay {
    pub fn new(month: u32, day: u32) -> Option<Self> {
        let max_day = match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 => 29,
            _ => return None,
        };
        if (1..=max_day).contains(&day) {
            Some(Self { month, day })
        } else {
            None
        }
    }

    /// Parses `"MM-DD"` (e.g. `"06-12"`).
    pub fn parse(stored: &str) -> Option<Self> {
        let (m, d) = stored.trim().split_once('-')?;
        Self::new(m.parse().ok()?, d.parse().ok()?)
    }

    pub fn matches(self, date: NaiveDate) -> bool {
        if self.month == 2 && self.day == 29 && !is_leap_year(date.year()) {
            return date.month() == 2 && date.day() == 28;
        }
        date.month() == self.month && date.day() == self.day
    }
}

fn is_leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// One planned moment before localization/presentation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuddyMoment {
    pub kind: BuddyMomentKind,
    /// Unique per occurrence (e.g. `"morning@2026-05-06"`), so the same moment is never shown twice.
    pub id: String,
    /// Events today (morning), agents finished while away (welcomeBack), or milestone number.
    #[serde(default)]
    pub count: usize,
    /// Minutes worked without a break (breakTime).
    #[serde(default)]
    pub minutes: u32,
    /// Unit for `Milestone` moments (`sessions` or `words`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<MilestoneUnit>,
}

/// What the frontend renders for a buddy moment (mirrors macOS `NookMoment`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuddyMomentView {
    pub id: String,
    pub kind: BuddyMomentKind,
    /// One of Nook's 17 moods (e.g. `"cozy"`, `"surprised"`, `"caring"`, `"sleepy"`, `"proud"`, `"celebrate"`).
    pub mood: String,
    pub line: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_title: Option<String>,
    pub seconds: u32,
    pub count: usize,
    pub minutes: u32,
}

/// What you have been doing, built up from system idle time sampled periodically.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuddyActivity {
    /// When you were last active.
    pub last_active: Option<DateTime<Utc>>,
    /// When the current uninterrupted stretch of work began.
    pub stretch_start: Option<DateTime<Utc>>,
    /// First activity of the current local day.
    pub day_start: Option<DateTime<Utc>>,
    /// Local day key for `day_start` (`YYYY-MM-DD`).
    pub day_key: String,
    /// When you returned after a long away gap.
    pub returned_at: Option<DateTime<Utc>>,
    /// Duration of that away gap in seconds.
    pub away_for_secs: i64,
}

impl BuddyActivity {
    /// Considered away after 5 minutes without input.
    pub const AWAY_AFTER_SECS: i64 = 5 * 60;
    /// Considered actively present if last input was within 2 minutes.
    pub const PRESENT_WITHIN_SECS: i64 = 2 * 60;
    /// Away for 45 minutes or more warrants a welcome-back moment.
    pub const LONG_AWAY_SECS: i64 = 45 * 60;
    /// How long "just started day" and "just returned" stay fresh so a moment can wait for a free slot.
    pub const FRESH_FOR_SECS: i64 = 15 * 60;

    /// Records a sample with `idle_secs` since last keyboard/mouse activity at local time `now`.
    pub fn note(&mut self, idle_secs: f64, now: DateTime<FixedOffset>) {
        let clamped_idle = idle_secs.max(0.0);
        if clamped_idle >= Self::AWAY_AFTER_SECS as f64 {
            return;
        }
        let active_local = now - Duration::milliseconds((clamped_idle * 1000.0) as i64);
        let active_utc = active_local.with_timezone(&Utc);
        let today = Self::day_key(active_local);

        let Some(last) = self.last_active else {
            self.last_active = Some(active_utc);
            self.stretch_start = Some(active_utc);
            self.day_start = Some(active_utc);
            self.day_key = today;
            return;
        };

        if active_utc <= last {
            return;
        }

        let gap_secs = (active_utc - last).num_seconds();
        if gap_secs >= Self::AWAY_AFTER_SECS {
            self.stretch_start = Some(active_utc);
        }
        if gap_secs >= Self::LONG_AWAY_SECS {
            self.returned_at = Some(active_utc);
            self.away_for_secs = gap_secs;
        }
        if today != self.day_key {
            self.day_start = Some(active_utc);
            self.day_key = today;
        }
        self.last_active = Some(active_utc);
    }

    /// True when the user was active within the last 2 minutes.
    pub fn is_active(&self, now: DateTime<FixedOffset>) -> bool {
        let now_utc = now.with_timezone(&Utc);
        self.last_active
            .is_some_and(|last| (now_utc - last).num_seconds() < Self::PRESENT_WITHIN_SECS)
    }

    /// True when the user sat down for the first time today within the freshness window.
    pub fn just_started_day(&self, now: DateTime<FixedOffset>) -> bool {
        let Some(start) = self.day_start else { return false };
        let now_utc = now.with_timezone(&Utc);
        (now_utc - start).num_seconds() < Self::FRESH_FOR_SECS && self.day_key == Self::day_key(now)
    }

    /// Returns the away duration in seconds if the user just returned after a long away gap.
    pub fn just_returned(&self, now: DateTime<FixedOffset>) -> Option<i64> {
        let back = self.returned_at?;
        let now_utc = now.with_timezone(&Utc);
        if (now_utc - back).num_seconds() < Self::FRESH_FOR_SECS {
            Some(self.away_for_secs)
        } else {
            None
        }
    }

    /// Seconds worked in the current uninterrupted stretch.
    pub fn stretch_secs(&self, now: DateTime<FixedOffset>) -> i64 {
        let Some(start) = self.stretch_start else { return 0 };
        if !self.is_active(now) {
            return 0;
        }
        (now.with_timezone(&Utc) - start).num_seconds().max(0)
    }

    /// Starts a fresh stretch (after a break or after Nook just suggested one).
    pub fn restart_stretch(&mut self, now: DateTime<FixedOffset>) {
        self.stretch_start = Some(now.with_timezone(&Utc));
    }

    /// Local date key (`YYYY-MM-DD`).
    pub fn day_key(now: DateTime<FixedOffset>) -> String {
        format!("{:04}-{:02}-{:02}", now.year(), now.month(), now.day())
    }
}

/// What Nook already shared, so he does not repeat himself or spam. Stored between launches.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BuddyLedger {
    pub day: String,
    pub shown_today: Vec<String>,
    pub last_shown: Option<DateTime<Utc>>,
    /// Late-night spans midnight, so it uses an 8-hour cooldown apart from the daily list.
    pub last_late_night: Option<DateTime<Utc>>,
    /// Session milestones already celebrated, ever.
    pub milestones: Vec<usize>,
    /// Word milestones already celebrated, ever.
    pub word_milestones: Vec<usize>,
}

impl BuddyLedger {
    /// Maximum moments per day.
    pub const MAX_PER_DAY: usize = 4;
    /// Minimum gap between any two moments (20 minutes).
    pub const MIN_COOLDOWN_SECS: i64 = 20 * 60;
    /// Minimum gap between late-night moments across midnight (8 hours).
    pub const LATE_NIGHT_COOLDOWN_SECS: i64 = 8 * 3600;

    /// Resets per-day counters when the local date changes.
    pub fn roll(&mut self, day: &str) {
        if self.day != day {
            self.day = day.to_string();
            self.shown_today.clear();
        }
    }

    /// How many moments of `kind` have already been shown today.
    pub fn count(&self, kind: BuddyMomentKind) -> usize {
        let prefix = format!("{}@", kind.as_str());
        self.shown_today.iter().filter(|id| id.starts_with(&prefix)).count()
    }

    /// Whether the daily budget and minimum cooldown allow another moment right now.
    pub fn can_show(&self, now: DateTime<FixedOffset>) -> bool {
        let day = BuddyActivity::day_key(now);
        let today_count = if self.day == day { self.shown_today.len() } else { 0 };
        if today_count >= Self::MAX_PER_DAY {
            return false;
        }
        if let Some(last) = self.last_shown {
            if (now.with_timezone(&Utc) - last).num_seconds() < Self::MIN_COOLDOWN_SECS {
                return false;
            }
        }
        true
    }

    /// Records a shown moment in the ledger.
    pub fn record(&mut self, moment: &BuddyMoment, now: DateTime<FixedOffset>) {
        let day = BuddyActivity::day_key(now);
        self.roll(&day);
        if !self.shown_today.contains(&moment.id) {
            self.shown_today.push(moment.id.clone());
        }
        let now_utc = now.with_timezone(&Utc);
        self.last_shown = Some(now_utc);
        if moment.kind == BuddyMomentKind::Milestone {
            match moment.unit.unwrap_or(MilestoneUnit::Sessions) {
                MilestoneUnit::Sessions => {
                    if !self.milestones.contains(&moment.count) {
                        self.milestones.push(moment.count);
                    }
                }
                MilestoneUnit::Words => {
                    if !self.word_milestones.contains(&moment.count) {
                        self.word_milestones.push(moment.count);
                    }
                }
            }
        }
        if moment.kind == BuddyMomentKind::LateNight {
            self.last_late_night = Some(now_utc);
        }
    }

    pub fn from_bytes(bytes: &[u8]) -> Self {
        serde_json::from_slice(bytes).unwrap_or_default()
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec_pretty(self).unwrap_or_default()
    }
}

/// Inputs gathered for one planning pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuddySignals {
    pub now: DateTime<FixedOffset>,
    /// True during a calendar event, call, screen share, or quiet hours.
    pub in_event: bool,
    /// True when the bar/home surface is free to show a moment.
    pub surface_free: bool,
    /// True when the user has been active recently.
    pub active: bool,
    /// First activity of the local day.
    pub first_of_day: bool,
    /// Away gap in seconds if the user just came back.
    pub returned_after_secs: Option<i64>,
    /// Current uninterrupted stretch in seconds.
    pub stretch_secs: i64,
    /// Events remaining today (for morning greeting).
    pub events_today: usize,
    /// Agent sessions that finished while the user was away.
    pub finished_while_away: usize,
    /// Total finished agent sessions ever.
    pub finished_total: usize,
    /// Total dictated/written words ever.
    pub words_total: usize,
    /// Optional user birthday.
    pub birthday: Option<MonthDay>,
}

impl BuddySignals {
    pub fn new(now: DateTime<FixedOffset>) -> Self {
        Self {
            now,
            in_event: false,
            surface_free: true,
            active: true,
            first_of_day: false,
            returned_after_secs: None,
            stretch_secs: 0,
            events_today: 0,
            finished_while_away: 0,
            finished_total: 0,
            words_total: 0,
            birthday: None,
        }
    }
}

/// Pure planner deciding which buddy moment, if any, Nook should share right now.
pub struct BuddyPlanner;

impl BuddyPlanner {
    /// Suggest a break after 90 minutes without one.
    pub const BREAK_AFTER_SECS: i64 = 90 * 60;
    /// Round numbers of finished agent sessions worth celebrating.
    pub const SESSION_MILESTONES: &'static [usize] = &[10, 25, 50, 100, 250, 500, 1000, 2500, 5000];
    /// Round numbers of words worth celebrating.
    pub const WORD_MILESTONES: &'static [usize] = &[1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000];

    /// Plans the next buddy moment if signals and ledger rules permit one.
    pub fn next(signals: &BuddySignals, ledger: &BuddyLedger) -> Option<BuddyMoment> {
        if !signals.active || !signals.surface_free || signals.in_event {
            return None;
        }
        if !ledger.can_show(signals.now) {
            return None;
        }

        let day = BuddyActivity::day_key(signals.now);
        let mut rolled = ledger.clone();
        rolled.roll(&day);

        let hour = signals.now.hour();
        let minutes_of_day = hour * 60 + signals.now.minute();
        let once = |kind: BuddyMomentKind, limit: usize, suffix: String| -> Option<String> {
            (rolled.count(kind) < limit).then(|| format!("{}@{}{}", kind.as_str(), day, suffix))
        };

        // 1. Birthday comes first: once, from 07:00 onward.
        if let Some(bday) = signals.birthday {
            if bday.matches(signals.now.date_naive()) && hour >= 7 {
                if let Some(id) = once(BuddyMomentKind::Birthday, 1, String::new()) {
                    return Some(BuddyMoment { kind: BuddyMomentKind::Birthday, id, count: 0, minutes: 0, unit: None });
                }
            }
        }

        // 2. Good morning: first activity of the day, 05:00–11:30.
        if signals.first_of_day && (5 * 60..11 * 60 + 30).contains(&minutes_of_day) {
            if let Some(id) = once(BuddyMomentKind::Morning, 1, String::new()) {
                return Some(BuddyMoment {
                    kind: BuddyMomentKind::Morning,
                    id,
                    count: signals.events_today,
                    minutes: 0,
                    unit: None,
                });
            }
        }

        // 3. Welcome back after a long away gap (at most twice a day; morning already says hello).
        if let Some(away) = signals.returned_after_secs {
            if away >= BuddyActivity::LONG_AWAY_SECS && !signals.first_of_day {
                let n = rolled.count(BuddyMomentKind::WelcomeBack);
                if let Some(id) = once(BuddyMomentKind::WelcomeBack, 2, format!("#{n}")) {
                    return Some(BuddyMoment {
                        kind: BuddyMomentKind::WelcomeBack,
                        id,
                        count: signals.finished_while_away,
                        minutes: 0,
                        unit: None,
                    });
                }
            }
        }

        // 4. Session milestone, celebrated once ever when freshly reached (within 5 sessions).
        if let Some(&reached) = Self::SESSION_MILESTONES.iter().rev().find(|&&m| m <= signals.finished_total) {
            if !rolled.milestones.contains(&reached) && signals.finished_total - reached < 5 {
                return Some(BuddyMoment {
                    kind: BuddyMomentKind::Milestone,
                    id: format!("milestone@{reached}"),
                    count: reached,
                    minutes: 0,
                    unit: Some(MilestoneUnit::Sessions),
                });
            }
        }

        // 5. Word milestone, celebrated once ever when freshly reached (within 15% of the milestone).
        if let Some(&reached) = Self::WORD_MILESTONES.iter().rev().find(|&&m| m <= signals.words_total) {
            let freshness = (reached / 6).max(250);
            if !rolled.word_milestones.contains(&reached) && signals.words_total - reached < freshness {
                return Some(BuddyMoment {
                    kind: BuddyMomentKind::Milestone,
                    id: format!("wordMilestone@{reached}"),
                    count: reached,
                    minutes: 0,
                    unit: Some(MilestoneUnit::Words),
                });
            }
        }

        // 6. Late at night (23:00–04:00), once per night across midnight (8h cooldown).
        if hour >= 23 || hour < 4 {
            let night_ok = rolled
                .last_late_night
                .is_none_or(|last| (signals.now.with_timezone(&Utc) - last).num_seconds() > BuddyLedger::LATE_NIGHT_COOLDOWN_SECS);
            if night_ok {
                return Some(BuddyMoment {
                    kind: BuddyMomentKind::LateNight,
                    id: format!("lateNight@{day}"),
                    count: 0,
                    minutes: 0,
                    unit: None,
                });
            }
        }

        // 7. Break reminder after >= 90 minutes without a break, 08:00–22:00, at most twice a day.
        if signals.stretch_secs >= Self::BREAK_AFTER_SECS && (8..22).contains(&hour) {
            let n = rolled.count(BuddyMomentKind::BreakTime);
            if let Some(id) = once(BuddyMomentKind::BreakTime, 2, format!("#{n}")) {
                return Some(BuddyMoment {
                    kind: BuddyMomentKind::BreakTime,
                    id,
                    count: 0,
                    minutes: (signals.stretch_secs / 60) as u32,
                    unit: None,
                });
            }
        }

        // 8. Friday afternoon wrap (16:00–18:30), once.
        if signals.now.weekday() == Weekday::Fri && (16 * 60..18 * 60 + 30).contains(&minutes_of_day) {
            if let Some(id) = once(BuddyMomentKind::FridayWrap, 1, String::new()) {
                return Some(BuddyMoment { kind: BuddyMomentKind::FridayWrap, id, count: 0, minutes: 0, unit: None });
            }
        }

        None
    }

    /// Formats a planned moment into a localized `BuddyMomentView` with mood, line, and action.
    pub fn present(moment: &BuddyMoment, tone: BuddyTone) -> BuddyMomentView {
        let line = Self::line(moment, tone);
        let (mood, action, action_title, seconds) = match moment.kind {
            BuddyMomentKind::Morning => (
                "cozy",
                (moment.count > 0).then(|| "today".to_string()),
                (moment.count > 0).then(|| tr("Vandaag", "Today").to_string()),
                12,
            ),
            BuddyMomentKind::WelcomeBack => (
                "surprised",
                (moment.count > 0).then(|| "agents".to_string()),
                (moment.count > 0).then(|| tr("Bekijk", "View").to_string()),
                12,
            ),
            BuddyMomentKind::BreakTime => (
                "caring",
                Some("breathe".to_string()),
                Some(tr("Adem mee", "Breathe along").to_string()),
                16,
            ),
            BuddyMomentKind::LateNight => ("sleepy", None, None, 12),
            BuddyMomentKind::FridayWrap => ("proud", None, None, 12),
            BuddyMomentKind::Birthday => ("celebrate", None, None, 16),
            BuddyMomentKind::Milestone => {
                let open_agents = moment.unit.unwrap_or(MilestoneUnit::Sessions) == MilestoneUnit::Sessions;
                (
                    "celebrate",
                    open_agents.then(|| "agents".to_string()),
                    open_agents.then(|| tr("Bekijk", "View").to_string()),
                    14,
                )
            }
        };

        BuddyMomentView {
            id: moment.id.clone(),
            kind: moment.kind,
            mood: mood.to_string(),
            line,
            action,
            action_title,
            seconds,
            count: moment.count,
            minutes: moment.minutes,
        }
    }

    /// Localized line for a moment in the chosen tone (matching macOS `I18n+Buddy.swift`).
    pub fn line(moment: &BuddyMoment, tone: BuddyTone) -> String {
        let n = moment.count;
        let m = moment.minutes;
        match moment.kind {
            BuddyMomentKind::Morning => match (n, tone) {
                (0, BuddyTone::Calm) => tr("Goedemorgen. Vandaag staat er niets in je agenda.", "Good morning. Nothing in your calendar today.").to_string(),
                (0, BuddyTone::Warm) => tr("Morgen! Een vrije dag, geen afspraken.", "Morning! A free day, no events at all.").to_string(),
                (0, BuddyTone::Playful) => tr("Goeiemorgen, zonnetje! Geen enkele meeting vandaag.", "Morning, sunshine! Not a single meeting today.").to_string(),
                (1, BuddyTone::Calm) => tr("Goedemorgen. Je hebt vandaag één afspraak.", "Good morning. One event in your calendar today.").to_string(),
                (1, BuddyTone::Warm) => tr("Morgen! Maar één ding in je agenda vandaag.", "Morning! Just one thing on your calendar today.").to_string(),
                (1, BuddyTone::Playful) => tr("Goeiemorgen, zonnetje! Maar één meeting vandaag.", "Morning, sunshine! Only one meeting today. Easy.").to_string(),
                (_, BuddyTone::Calm) => trf("Goedemorgen. Je hebt vandaag {n} afspraken.", "Good morning. {n} events in your calendar today.", &[("n", &n)]),
                (_, BuddyTone::Warm) => trf("Morgen! Je hebt vandaag {n} dingen op de planning.", "Morning! You have {n} things on today.", &[("n", &n)]),
                (_, BuddyTone::Playful) => trf("Goeiemorgen, zonnetje! {n} afspraken vandaag. Eerst koffie?", "Morning, sunshine! {n} events today. Coffee first?", &[("n", &n)]),
            },
            BuddyMomentKind::WelcomeBack => match (n, tone) {
                (0, BuddyTone::Calm) => tr("Welkom terug. Er is niets gebeurd terwijl je weg was.", "Welcome back. Nothing happened while you were away.").to_string(),
                (0, BuddyTone::Warm) => tr("Hé, je bent er weer! Alles was rustig.", "Hey, you're back! All quiet while you were gone.").to_string(),
                (0, BuddyTone::Playful) => tr("Daar ben je! Ik heb je plekje warm gehouden.", "There you are! I kept your seat warm.").to_string(),
                (1, BuddyTone::Calm) => tr("Welkom terug. Er is een agent klaar terwijl je weg was.", "Welcome back. An agent finished while you were away.").to_string(),
                (1, BuddyTone::Warm) => tr("Hé, je bent er weer! Er is intussen een agent klaar.", "Hey, you're back! One agent finished in the meantime.").to_string(),
                (1, BuddyTone::Playful) => tr("Daar ben je! Een agent is klaar terwijl je weg was.", "There you are! An agent wrapped up while you were out.").to_string(),
                (_, BuddyTone::Calm) => trf("Welkom terug. Er zijn {n} agents klaar terwijl je weg was.", "Welcome back. {n} agents finished while you were away.", &[("n", &n)]),
                (_, BuddyTone::Warm) => trf("Hé, je bent er weer! Intussen zijn {n} agents klaar.", "Hey, you're back! {n} agents finished in the meantime.", &[("n", &n)]),
                (_, BuddyTone::Playful) => trf("Daar ben je! {n} agents klaar, ik heb ze in de gaten gehouden.", "There you are! {n} agents done, I kept an eye on them.", &[("n", &n)]),
            },
            BuddyMomentKind::BreakTime => match tone {
                BuddyTone::Calm => trf("Je werkt al {n} minuten. Tijd voor een korte pauze?", "You've been working for {n} minutes. Time for a short break?", &[("n", &m)]),
                BuddyTone::Warm => trf("Al {n} minuten zonder pauze. Even je benen strekken?", "{n} minutes without a break. Stretch your legs?", &[("n", &m)]),
                BuddyTone::Playful => trf("{n} minuten aan één stuk! Even bewegen?", "{n} minutes straight! Time to wiggle a bit?", &[("n", &m)]),
            },
            BuddyMomentKind::LateNight => match tone {
                BuddyTone::Calm => tr("Het is laat. Ik houd alles in de gaten.", "It's late. I'll keep an eye on things.").to_string(),
                BuddyTone::Warm => tr("Het wordt laat. Ik let wel op als je gaat slapen.", "It's getting late. I'll keep watch if you head to bed.").to_string(),
                BuddyTone::Playful => tr("*gaap* Al zo laat. Bedtijd voor ons allebei?", "*yawn* Late already. Bedtime for both of us?").to_string(),
            },
            BuddyMomentKind::FridayWrap => match tone {
                BuddyTone::Calm => tr("Het is vrijdagmiddag. Goed gewerkt deze week.", "It's Friday afternoon. Nice work this week.").to_string(),
                BuddyTone::Warm => tr("Vrijdagmiddag! Je hebt deze week goed werk gedaan.", "Friday afternoon! You did good work this week.").to_string(),
                BuddyTone::Playful => tr("Vrijdagmiddag! Het weekend is in zicht.", "Friday afternoon! The weekend is in sight.").to_string(),
            },
            BuddyMomentKind::Birthday => match tone {
                BuddyTone::Calm => tr("Gefeliciteerd met je verjaardag!", "Happy birthday!").to_string(),
                BuddyTone::Warm => tr("Gefeliciteerd! Ik hoop dat het een mooie dag wordt.", "Happy birthday! I hope it's a lovely day.").to_string(),
                BuddyTone::Playful => tr("Hoera, je bent jarig! Ik heb mijn feesthoedje op.", "Happy birthday! I put on my party hat for you.").to_string(),
            },
            BuddyMomentKind::Milestone => match (moment.unit.unwrap_or(MilestoneUnit::Sessions), tone) {
                (MilestoneUnit::Sessions, BuddyTone::Calm) => trf("{n} agent-sessies afgerond met Nook.", "{n} agent sessions finished with Nook.", &[("n", &n)]),
                (MilestoneUnit::Sessions, BuddyTone::Warm) => trf("Al {n} agent-sessies samen. Mooi!", "That's {n} agent sessions together. Nice!", &[("n", &n)]),
                (MilestoneUnit::Sessions, BuddyTone::Playful) => trf("{n} agent-sessies! Dat vraagt om een feestje.", "{n} agent sessions! That calls for a party.", &[("n", &n)]),
                (MilestoneUnit::Words, BuddyTone::Calm) => trf("{n} woorden geschreven met Nook.", "{n} words written with Nook.", &[("n", &n)]),
                (MilestoneUnit::Words, BuddyTone::Warm) => trf("Al {n} woorden samen. Lekker bezig!", "That's {n} words together. Nice going!", &[("n", &n)]),
                (MilestoneUnit::Words, BuddyTone::Playful) => trf("{n} woorden! Een heel boek in wording.", "{n} words! A whole book in the making.", &[("n", &n)]),
            },
        }
    }

    /// Time-of-day greeting for Home when no special buddy moment is active.
    pub fn time_of_day_greeting(hour: u32, name: &str) -> String {
        let hello = if hour < 12 {
            tr("Goedemorgen", "Good morning")
        } else if hour < 18 {
            tr("Goedemiddag", "Good afternoon")
        } else {
            tr("Goedenavond", "Good evening")
        };
        let clean = name.trim();
        if clean.is_empty() {
            format!("{hello}.")
        } else {
            format!("{hello}, {clean}.")
        }
    }
}

/// Persistent snapshot stored on disk by `BuddyService`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct BuddyDiskState {
    ledger: BuddyLedger,
    finished_total: usize,
    counted_sessions: Vec<String>,
    words_total: usize,
}

/// Stateful buddy service tracking activity, finished sessions, word counts, and the persisted ledger.
#[derive(Debug, Clone)]
pub struct BuddyService {
    pub activity: BuddyActivity,
    pub ledger: BuddyLedger,
    finished_total: usize,
    counted_sessions: Vec<String>,
    finishes: Vec<(DateTime<Utc>, String)>,
    words_total: usize,
    active_moment: Option<(BuddyMomentView, DateTime<Utc>)>,
    dismissed: HashSet<String>,
    storage_path: Option<PathBuf>,
}

impl Default for BuddyService {
    fn default() -> Self {
        Self::in_memory()
    }
}

impl BuddyService {
    const COUNTED_LIMIT: usize = 1000;
    const FINISHES_LIMIT: usize = 100;
    /// Keep a surfaced moment visible on Home for up to 10 minutes unless dismissed.
    const ACTIVE_TTL_SECS: i64 = 10 * 60;

    pub fn in_memory() -> Self {
        Self {
            activity: BuddyActivity::default(),
            ledger: BuddyLedger::default(),
            finished_total: 0,
            counted_sessions: Vec::new(),
            finishes: Vec::new(),
            words_total: 0,
            active_moment: None,
            dismissed: HashSet::new(),
            storage_path: None,
        }
    }

    pub fn default_path() -> PathBuf {
        paths::support_directory().join("buddy.json")
    }

    pub fn open_default() -> Self {
        Self::open(Self::default_path())
    }

    pub fn open(path: PathBuf) -> Self {
        let disk: BuddyDiskState = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            activity: BuddyActivity::default(),
            ledger: disk.ledger,
            finished_total: disk.finished_total,
            counted_sessions: disk.counted_sessions,
            finishes: Vec::new(),
            words_total: disk.words_total,
            active_moment: None,
            dismissed: HashSet::new(),
            storage_path: Some(path),
        }
    }

    pub fn save(&self) {
        let Some(path) = &self.storage_path else { return };
        let _ = self.save_to(path);
    }

    pub fn save_to(&self, path: &Path) -> std::io::Result<()> {
        let disk = BuddyDiskState {
            ledger: self.ledger.clone(),
            finished_total: self.finished_total,
            counted_sessions: self.counted_sessions.clone(),
            words_total: self.words_total,
        };
        let bytes = serde_json::to_vec_pretty(&disk).unwrap_or_default();
        paths::write_atomic(path, &bytes)
    }

    pub fn finished_total(&self) -> usize {
        self.finished_total
    }

    pub fn words_total(&self) -> usize {
        self.words_total
    }

    /// Notes that an agent session finished a turn. Each session ID only counts once toward milestones.
    pub fn note_finished_agent(&mut self, session: &str, at: DateTime<Utc>) {
        if session.is_empty() {
            return;
        }
        let mut changed = false;
        if !self.counted_sessions.iter().any(|s| s == session) {
            self.finished_total += 1;
            self.counted_sessions.push(session.to_string());
            if self.counted_sessions.len() > Self::COUNTED_LIMIT {
                let drop = self.counted_sessions.len() - Self::COUNTED_LIMIT;
                self.counted_sessions.drain(..drop);
            }
            changed = true;
        }
        // The same finish fed again (the bar's timer reads every run each half minute) is kept once.
        if !self.finishes.iter().any(|(t, s)| *t == at && s == session) {
            self.finishes.push((at, session.to_string()));
        }
        if self.finishes.len() > Self::FINISHES_LIMIT {
            let drop = self.finishes.len() - Self::FINISHES_LIMIT;
            self.finishes.drain(..drop);
        }
        if changed {
            self.save();
        }
    }

    /// Updates total dictated/written words (monotonic high-water mark).
    pub fn sync_words_total(&mut self, total: usize) {
        if total > self.words_total {
            self.words_total = total;
            self.save();
        }
    }

    /// Adds newly dictated/written words.
    pub fn note_words(&mut self, words: usize) {
        if words > 0 {
            self.words_total = self.words_total.saturating_add(words);
            self.save();
        }
    }

    /// Unique agent sessions that finished strictly after `start` and up to `end`.
    pub fn finished_between(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> usize {
        let unique: HashSet<&str> = self
            .finishes
            .iter()
            .filter(|(at, _)| *at > start && *at <= end)
            .map(|(_, s)| s.as_str())
            .collect();
        unique.len()
    }

    /// Dismisses a currently surfaced moment so Home does not show it again.
    pub fn dismiss(&mut self, id: &str) {
        self.dismissed.insert(id.to_string());
        if self.active_moment.as_ref().is_some_and(|(m, _)| m.id == id) {
            self.active_moment = None;
        }
    }

    /// Samples activity, plans the next moment, records it if due, and returns its view.
    #[allow(clippy::too_many_arguments)]
    pub fn evaluate(
        &mut self,
        idle_secs: f64,
        now: DateTime<FixedOffset>,
        tone: BuddyTone,
        in_event: bool,
        surface_free: bool,
        events_today: usize,
        birthday: Option<MonthDay>,
    ) -> Option<BuddyMomentView> {
        let moment = self.plan(idle_secs, now, in_event, surface_free, events_today, birthday)?;
        Some(self.commit(&moment, now, tone))
    }

    /// The first half of `evaluate` (`buddyTick` on the Mac): notes whether you are at your computer and plans the
    /// moment that is due, without recording it, so the caller can first ask the notice pacer whether it may show.
    pub fn plan(
        &mut self,
        idle_secs: f64,
        now: DateTime<FixedOffset>,
        in_event: bool,
        surface_free: bool,
        events_today: usize,
        birthday: Option<MonthDay>,
    ) -> Option<BuddyMoment> {
        self.activity.note(idle_secs, now);

        let mut signals = BuddySignals::new(now);
        signals.in_event = in_event;
        signals.surface_free = surface_free;
        signals.active = self.activity.is_active(now);
        signals.first_of_day = self.activity.just_started_day(now);
        if let Some(away) = self.activity.just_returned(now) {
            signals.returned_after_secs = Some(away);
            let back = self.activity.returned_at.unwrap_or_else(|| now.with_timezone(&Utc));
            signals.finished_while_away = self.finished_between(back - Duration::seconds(away), back);
        }
        signals.stretch_secs = self.activity.stretch_secs(now);
        signals.events_today = events_today;
        signals.finished_total = self.finished_total;
        signals.words_total = self.words_total;
        signals.birthday = birthday;

        BuddyPlanner::next(&signals, &self.ledger)
    }

    /// The second half: records a shown moment in the ledger (a break also starts a fresh stretch) and returns it as
    /// Nook shows it, in the chosen tone.
    pub fn commit(&mut self, moment: &BuddyMoment, now: DateTime<FixedOffset>, tone: BuddyTone) -> BuddyMomentView {
        self.ledger.record(moment, now);
        if moment.kind == BuddyMomentKind::BreakTime {
            self.activity.restart_stretch(now);
        }
        let view = BuddyPlanner::present(moment, tone);
        self.active_moment = Some((view.clone(), now.with_timezone(&Utc)));
        self.save();
        view
    }

    /// The moment shown last, while it is fresh (ten minutes) and not dismissed; plans nothing.
    pub fn active(&mut self, now: DateTime<FixedOffset>) -> Option<BuddyMomentView> {
        let now_utc = now.with_timezone(&Utc);
        if let Some((view, shown_at)) = &self.active_moment {
            if !self.dismissed.contains(&view.id) && (now_utc - *shown_at).num_seconds() < Self::ACTIVE_TTL_SECS {
                return Some(view.clone());
            }
        }
        self.active_moment = None;
        None
    }

    /// "Breathe with Nook": a break taken, so the stretch of work starts again.
    pub fn breathed(&mut self, now: DateTime<FixedOffset>) {
        self.activity.restart_stretch(now);
    }

    /// Returns a newly planned moment, or keeps returning the recently surfaced moment within its TTL
    /// until dismissed (so polling from Home stays stable and respects quiet/in_event).
    #[allow(clippy::too_many_arguments)]
    pub fn current_moment(
        &mut self,
        idle_secs: f64,
        now: DateTime<FixedOffset>,
        tone: BuddyTone,
        in_event: bool,
        events_today: usize,
        birthday: Option<MonthDay>,
    ) -> Option<BuddyMomentView> {
        if in_event {
            return None;
        }
        if let Some(fresh) = self.evaluate(idle_secs, now, tone, in_event, true, events_today, birthday) {
            return Some(fresh);
        }
        self.active(now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn local(year: i32, month: u32, day: u32, hour: u32, min: u32) -> DateTime<FixedOffset> {
        let offset = FixedOffset::east_opt(2 * 3600).unwrap();
        offset.with_ymd_and_hms(year, month, day, hour, min, 0).unwrap()
    }

    #[test]
    fn leap_day_birthday_celebrates_on_feb_28_in_non_leap_years() {
        let leap = MonthDay::new(2, 29).unwrap();
        assert!(leap.matches(NaiveDate::from_ymd_opt(2027, 2, 28).unwrap()));
        assert!(!leap.matches(NaiveDate::from_ymd_opt(2028, 2, 28).unwrap()));
        assert!(leap.matches(NaiveDate::from_ymd_opt(2028, 2, 29).unwrap()));
        assert_eq!(MonthDay::parse("06-12"), MonthDay::new(6, 12));
        assert_eq!(MonthDay::parse("00-12"), None);
        assert_eq!(MonthDay::parse(""), None);
    }

    #[test]
    fn activity_detects_away_gap_and_resets_stretch() {
        let mut activity = BuddyActivity::default();
        let start = local(2026, 5, 6, 9, 0);
        for step in 0..=60 {
            activity.note(0.0, start + Duration::seconds(step * 30));
        }
        assert_eq!(activity.stretch_secs(start + Duration::minutes(30)), 30 * 60);

        // Idle sample above AWAY_AFTER_SECS is ignored.
        activity.note((20 * 60) as f64, start + Duration::minutes(50));
        let back = start + Duration::minutes(90);
        activity.note(0.0, back);

        assert_eq!(activity.just_returned(back), Some(60 * 60));
        assert_eq!(activity.stretch_secs(back), 0);
        assert_eq!(activity.just_returned(back + Duration::minutes(20)), None);
    }

    #[test]
    fn first_activity_of_day_is_fresh_for_fifteen_minutes() {
        let mut activity = BuddyActivity::default();
        activity.note(0.0, local(2026, 5, 6, 22, 0));
        let morning = local(2026, 5, 7, 8, 10);
        activity.note(0.0, morning);
        assert!(activity.just_started_day(morning));
        assert!(!activity.just_started_day(morning + Duration::minutes(40)));
    }

    #[test]
    fn morning_greeting_includes_events_and_only_fires_in_morning() {
        let mut morning = BuddySignals::new(local(2026, 5, 6, 8, 30));
        morning.first_of_day = true;
        morning.events_today = 3;
        let moment = BuddyPlanner::next(&morning, &BuddyLedger::default()).unwrap();
        assert_eq!(moment.kind, BuddyMomentKind::Morning);
        assert_eq!(moment.count, 3);
        let view = BuddyPlanner::present(&moment, BuddyTone::Warm);
        assert_eq!(view.mood, "cozy");
        assert_eq!(view.action.as_deref(), Some("today"));

        let mut afternoon = BuddySignals::new(local(2026, 5, 6, 14, 0));
        afternoon.first_of_day = true;
        assert!(BuddyPlanner::next(&afternoon, &BuddyLedger::default()).is_none());
    }

    #[test]
    fn stays_quiet_during_events_busy_surface_or_when_away() {
        let base = BuddySignals { first_of_day: true, ..BuddySignals::new(local(2026, 5, 6, 8, 30)) };
        let mut in_event = base.clone();
        in_event.in_event = true;
        assert!(BuddyPlanner::next(&in_event, &BuddyLedger::default()).is_none());

        let mut busy = base.clone();
        busy.surface_free = false;
        assert!(BuddyPlanner::next(&busy, &BuddyLedger::default()).is_none());

        let mut away = base;
        away.active = false;
        assert!(BuddyPlanner::next(&away, &BuddyLedger::default()).is_none());
    }

    #[test]
    fn cooldown_dedup_and_welcome_back_with_away_summary() {
        let now = local(2026, 5, 6, 8, 30);
        let mut morning = BuddySignals::new(now);
        morning.first_of_day = true;

        let mut ledger = BuddyLedger::default();
        let m = BuddyPlanner::next(&morning, &ledger).unwrap();
        assert_eq!(m.kind, BuddyMomentKind::Morning);
        ledger.record(&m, now);

        // 5 minutes later: blocked by 20-minute cooldown even for another moment.
        let mut too_soon = BuddySignals::new(now + Duration::minutes(5));
        too_soon.returned_after_secs = Some(3600);
        too_soon.finished_while_away = 2;
        assert!(BuddyPlanner::next(&too_soon, &ledger).is_none());

        // 30 minutes later: morning is not repeated, welcome back is allowed.
        let mut later = BuddySignals::new(now + Duration::minutes(30));
        later.first_of_day = true;
        assert!(BuddyPlanner::next(&later, &ledger).is_none());

        later.first_of_day = false;
        later.returned_after_secs = Some(3600);
        later.finished_while_away = 2;
        let welcome = BuddyPlanner::next(&later, &ledger).unwrap();
        assert_eq!(welcome.kind, BuddyMomentKind::WelcomeBack);
        assert_eq!(welcome.count, 2);
        let view = BuddyPlanner::present(&welcome, BuddyTone::Playful);
        assert_eq!(view.mood, "surprised");
        assert_eq!(view.action.as_deref(), Some("agents"));
    }

    #[test]
    fn daily_budget_caps_at_four_and_resets_next_day() {
        let base = local(2026, 5, 6, 9, 0);
        let mut ledger = BuddyLedger::default();
        for i in 0..4 {
            let t = base + Duration::hours(i);
            ledger.record(&BuddyMoment { kind: BuddyMomentKind::BreakTime, id: format!("breakTime@2026-05-06#{i}"), count: 0, minutes: 90, unit: None }, t);
        }
        assert!(!ledger.can_show(base + Duration::hours(5)));

        let tomorrow = base + Duration::hours(24);
        assert!(ledger.can_show(tomorrow));
        let mut sig = BuddySignals::new(tomorrow);
        sig.stretch_secs = 100 * 60;
        assert_eq!(BuddyPlanner::next(&sig, &ledger).unwrap().kind, BuddyMomentKind::BreakTime);
    }

    #[test]
    fn break_reminder_fires_after_ninety_minutes_during_day() {
        let mut sig = BuddySignals::new(local(2026, 5, 6, 15, 0));
        sig.stretch_secs = 95 * 60;
        let m = BuddyPlanner::next(&sig, &BuddyLedger::default()).unwrap();
        assert_eq!(m.kind, BuddyMomentKind::BreakTime);
        assert_eq!(m.minutes, 95);
        let view = BuddyPlanner::present(&m, BuddyTone::Calm);
        assert_eq!(view.mood, "caring");
        assert_eq!(view.action.as_deref(), Some("breathe"));
        assert_eq!(view.seconds, 16);

        sig.stretch_secs = 60 * 60;
        assert!(BuddyPlanner::next(&sig, &BuddyLedger::default()).is_none());
    }

    #[test]
    fn late_night_fires_once_per_night_across_midnight() {
        let evening = local(2026, 5, 6, 23, 20);
        let mut ledger = BuddyLedger::default();
        let m = BuddyPlanner::next(&BuddySignals::new(evening), &ledger).unwrap();
        assert_eq!(m.kind, BuddyMomentKind::LateNight);
        ledger.record(&m, evening);

        // After midnight is a new date, but still the same night (< 8h cooldown).
        assert!(BuddyPlanner::next(&BuddySignals::new(local(2026, 5, 7, 0, 50)), &ledger).is_none());
    }

    #[test]
    fn session_and_word_milestones_are_celebrated_once_when_fresh() {
        let now = local(2026, 5, 6, 11, 0);
        let mut sig = BuddySignals::new(now);
        sig.finished_total = 10;
        let mut ledger = BuddyLedger::default();
        let m = BuddyPlanner::next(&sig, &ledger).unwrap();
        assert_eq!(m.kind, BuddyMomentKind::Milestone);
        assert_eq!(m.count, 10);
        assert_eq!(m.unit, Some(MilestoneUnit::Sessions));
        ledger.record(&m, now - Duration::hours(1));

        sig.finished_total = 11;
        assert!(BuddyPlanner::next(&sig, &ledger).is_none());

        // Far past an uncelebrated milestone: skipped.
        sig.finished_total = 31;
        assert!(BuddyPlanner::next(&sig, &BuddyLedger::default()).is_none());

        // Word milestone when freshly crossed.
        let mut words = BuddySignals::new(now + Duration::hours(1));
        words.words_total = 10_120;
        let wm = BuddyPlanner::next(&words, &ledger).unwrap();
        assert_eq!(wm.kind, BuddyMomentKind::Milestone);
        assert_eq!(wm.count, 10_000);
        assert_eq!(wm.unit, Some(MilestoneUnit::Words));
    }

    #[test]
    fn birthday_takes_priority_and_friday_wrap_triggers() {
        let mut bday = BuddySignals::new(local(2026, 6, 12, 8, 30));
        bday.birthday = MonthDay::new(6, 12);
        bday.first_of_day = true;
        assert_eq!(BuddyPlanner::next(&bday, &BuddyLedger::default()).unwrap().kind, BuddyMomentKind::Birthday);

        // 2026-05-08 is a Friday.
        let fri = BuddySignals::new(local(2026, 5, 8, 17, 0));
        assert_eq!(BuddyPlanner::next(&fri, &BuddyLedger::default()).unwrap().kind, BuddyMomentKind::FridayWrap);
    }

    #[test]
    fn service_tracks_unique_sessions_while_away_and_persists_ledger() {
        let mut svc = BuddyService::in_memory();
        let t0 = local(2026, 5, 6, 9, 0);
        // First activity of the day.
        let morning = svc.evaluate(0.0, t0, BuddyTone::Warm, false, true, 1, None);
        assert_eq!(morning.unwrap().kind, BuddyMomentKind::Morning);

        // Away for 60 minutes while 2 unique sessions finish (one with two turns).
        let away_mid = (t0 + Duration::minutes(30)).with_timezone(&Utc);
        svc.note_finished_agent("sess-a", away_mid);
        svc.note_finished_agent("sess-a", away_mid + Duration::minutes(5));
        svc.note_finished_agent("sess-b", away_mid + Duration::minutes(10));
        assert_eq!(svc.finished_total(), 2);

        let back = t0 + Duration::minutes(60);
        let welcome = svc.evaluate(0.0, back, BuddyTone::Warm, false, true, 1, None).unwrap();
        assert_eq!(welcome.kind, BuddyMomentKind::WelcomeBack);
        assert_eq!(welcome.count, 2);

        // Ledger serialization round-trip.
        let bytes = svc.ledger.to_bytes();
        assert_eq!(BuddyLedger::from_bytes(&bytes), svc.ledger);
        assert_eq!(BuddyLedger::from_bytes(b"nonsense"), BuddyLedger::default());
    }

    #[test]
    fn birthday_is_celebrated_once_and_only_on_the_day() {
        let day = local(2026, 6, 12, 9, 0);
        let mut signals = BuddySignals::new(day);
        signals.birthday = MonthDay::parse("06-12");
        let mut ledger = BuddyLedger::default();
        let first = BuddyPlanner::next(&signals, &ledger).unwrap();
        assert_eq!(first.kind, BuddyMomentKind::Birthday);
        ledger.record(&first, day);
        // Later that day: no second birthday (Friday wrap etc. may follow, never the birthday again).
        let later = BuddySignals { now: day + Duration::hours(3), ..signals.clone() };
        assert!(BuddyPlanner::next(&later, &ledger).is_none_or(|m| m.kind != BuddyMomentKind::Birthday));
        // Before 07:00 and on another day: nothing.
        let early = BuddySignals { now: local(2026, 6, 12, 6, 30), ..signals.clone() };
        assert!(BuddyPlanner::next(&early, &BuddyLedger::default()).is_none());
        let other = BuddySignals { now: local(2026, 6, 13, 9, 0), ..signals };
        assert!(BuddyPlanner::next(&other, &BuddyLedger::default()).is_none());
    }

    #[test]
    fn plan_records_nothing_until_committed_and_active_keeps_the_moment() {
        let mut svc = BuddyService::in_memory();
        let t0 = local(2026, 5, 6, 9, 0);
        let planned = svc.plan(0.0, t0, false, true, 0, None).unwrap();
        assert_eq!(planned.kind, BuddyMomentKind::Morning);
        assert!(svc.ledger.shown_today.is_empty(), "planning alone is not showing");
        assert!(svc.active(t0).is_none());

        let view = svc.commit(&planned, t0, BuddyTone::Calm);
        assert_eq!(view.mood, "cozy");
        assert_eq!(svc.ledger.shown_today, vec![planned.id.clone()]);
        assert_eq!(svc.active(t0 + Duration::minutes(5)).map(|v| v.id), Some(planned.id.clone()));
        assert!(svc.active(t0 + Duration::minutes(11)).is_none(), "ten minutes on screen at most");

        // A quiet moment (meeting, screen share, quiet hours) plans nothing at all.
        let mut quiet = BuddyService::in_memory();
        assert!(quiet.plan(0.0, t0, true, true, 0, None).is_none());
    }

    #[test]
    fn tone_changes_the_words_not_the_moment() {
        crate::i18n::set_language("en");
        let moment = BuddyMoment { kind: BuddyMomentKind::Morning, id: "preview".into(), count: 3, minutes: 0, unit: None };
        assert_eq!(BuddyPlanner::line(&moment, BuddyTone::Calm), "Good morning. 3 events in your calendar today.");
        assert_eq!(BuddyPlanner::line(&moment, BuddyTone::Warm), "Morning! You have 3 things on today.");
        assert_eq!(BuddyPlanner::line(&moment, BuddyTone::Playful), "Morning, sunshine! 3 events today. Coffee first?");
        assert_eq!(BuddyTone::parse("PLAYFUL"), BuddyTone::Playful);
        assert_eq!(BuddyTone::parse(""), BuddyTone::Warm);
    }

    #[test]
    fn time_of_day_greeting_handles_all_dayparts() {
        crate::i18n::set_language("en");
        assert_eq!(BuddyPlanner::time_of_day_greeting(9, "Michan"), "Good morning, Michan.");
        assert_eq!(BuddyPlanner::time_of_day_greeting(14, ""), "Good afternoon.");
        assert_eq!(BuddyPlanner::time_of_day_greeting(20, "Alex"), "Good evening, Alex.");
    }
}
