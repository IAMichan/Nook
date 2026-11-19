//! The companion's home and usage answers (`HomeDigest`, `UsageDigest` in `packages/protocol/Sources/CompanionModels.swift`),
//! built from what this app knows, the way `CompanionServer+Home.swift` builds them on the Mac. Pure: the app reads its
//! state and hands it in, so the shapes and the rules are tested here.

use std::collections::BTreeMap;

use chrono::{DateTime, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use super::models::SessionDigest;
use super::sessions::HUB_PREFIX;
use crate::agents::models::PlanUsage;
use crate::connectors::agenda::AgendaEntry;
use crate::i18n::{tr, trf};
use crate::platform::NowPlaying;
use crate::workspace::store::{UsageRange, UsageReport};

/// The Mac shows at most this many rows of "For you" (`todayItems`).
pub const MAX_LINES: usize = 5;
/// Events and suggestions on the phone's home.
pub const MAX_EVENTS: usize = 8;
pub const MAX_SUGGESTIONS: usize = 4;
/// The Mac reads its agenda this far ahead (`refreshUpcoming`).
pub const AGENDA_HOURS: i64 = 36;
/// The next meeting is a row of "For you" when it starts within this many hours.
pub const NEXT_EVENT_HOURS: i64 = 3;
const FIVE_HOURS: f64 = 5.0 * 3600.0;
const WEEK: f64 = 7.0 * 24.0 * 3600.0;

/// Nook's home on the phone, as the main window shows it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeDigest {
    pub lines: Vec<HomeLine>,
    pub events: Vec<HomeEvent>,
    pub suggestions: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<HomeTrack>,
    pub accounts: Vec<UsageAccount>,
    /// A new version of Nook the computer can install (`feature::INSTALL_UPDATE`); absent when there is none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update: Option<UpdateOffer>,
}

/// A Nook update on the computer, as the phone's home shows it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateOffer {
    pub version: String,
    /// "available", "installing", "readyToRestart" (waits for agents) or "failed".
    pub state: String,
    /// How many changes it brings (pull requests or commits); 0 when unknown.
    pub changes: u32,
    /// How far the download is (0…1), while it downloads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
}

/// A row of "For you". `icon` is "symbol:<SF Symbol>", "agent:<agent name>" or "source:<connection id>"; `tone` is
/// "iris", "mint", "amber" or "coral".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeLine {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub icon: String,
    pub tone: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeEvent {
    pub id: String,
    pub title: String,
    pub start: f64,
    pub end: f64,
    pub location: String,
    pub calendar: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeTrack {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub app: String,
    pub playing: bool,
    /// Seconds into the track when the computer answered, and its length (0 when unknown).
    pub position: f64,
    pub duration: f64,
}

/// What Settings › Usage shows: the limits of every account, then what Nook's sessions used.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageDigest {
    pub accounts: Vec<UsageAccount>,
    pub range: String,
    pub sessions: u64,
    pub completed: u64,
    pub failed: u64,
    pub running: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    pub days: Vec<UsageDay>,
    pub models: Vec<UsageModel>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageLimit {
    pub label: String,
    pub percent: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<f64>,
    /// Shown instead of a reset time ("Starts with your first message").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// How long the window lasts in seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageAccount {
    pub id: String,
    /// The agent's short name ("Claude", "Codex").
    pub agent: String,
    /// The account's name ("Work", "Personal").
    pub account: String,
    pub limits: Vec<UsageLimit>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageDay {
    pub day: f64,
    pub agent: String,
    pub tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageModel {
    pub agent: String,
    pub model: String,
    pub sessions: u64,
    pub tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
}

/// `CompanionPolicy.clip`: leading whitespace and carriage returns out, at most `limit` characters and an ellipsis.
pub fn clip(text: &str, limit: usize) -> String {
    let flat = text.replace('\r', "");
    let flat = flat.trim();
    if flat.chars().count() <= limit {
        return flat.to_string();
    }
    let mut cut: String = flat.chars().take(limit).collect();
    cut.push('…');
    cut
}

fn seconds(date: DateTime<Utc>) -> f64 {
    date.timestamp_millis() as f64 / 1000.0
}

// MARK: Home

/// The phone's player buttons (`text` of `music`); nothing else is controlled from the phone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MusicButton {
    PlayPause,
    Next,
    Previous,
}

impl MusicButton {
    pub fn parse(text: Option<&str>) -> Option<Self> {
        match text? {
            "playpause" => Some(Self::PlayPause),
            "next" => Some(Self::Next),
            "previous" => Some(Self::Previous),
            _ => None,
        }
    }
}

/// What plays, as the phone shows it.
pub fn track(now: &NowPlaying) -> HomeTrack {
    HomeTrack {
        title: clip(&now.title, 200),
        artist: clip(&now.artist, 200),
        album: clip(&now.album, 200),
        app: clip(&now.app, 60),
        playing: now.playing,
        position: now.position.unwrap_or(0.0).max(0.0),
        duration: now.duration.unwrap_or(0.0).max(0.0),
    }
}

/// A stable id for an event from a calendar that gives none: its calendar, title and start.
pub fn event_id(entry: &AgendaEntry) -> String {
    // FNV-1a, so the id stays the same between answers and builds.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in format!("{}|{}|{}", entry.calendar, entry.title, entry.start.timestamp()).bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{:016x}", hash)
}

/// The calendars' events that have not ended and start within `AGENDA_HOURS`, soonest first, once each.
pub fn upcoming(entries: &[AgendaEntry], now: DateTime<Utc>) -> Vec<AgendaEntry> {
    let until = now + chrono::Duration::hours(AGENDA_HOURS);
    let mut list: Vec<AgendaEntry> = entries.iter().filter(|e| e.end > now && e.start < until).cloned().collect();
    list.sort_by(|a, b| a.start.cmp(&b.start).then_with(|| a.title.cmp(&b.title)));
    list.dedup_by(|a, b| a.title == b.title && a.start == b.start);
    list
}

/// The agenda on the phone's home.
pub fn events(upcoming: &[AgendaEntry]) -> Vec<HomeEvent> {
    upcoming
        .iter()
        .take(MAX_EVENTS)
        .map(|e| HomeEvent {
            id: event_id(e),
            title: clip(&e.title, 200),
            start: seconds(e.start),
            end: seconds(e.end),
            location: clip(&e.location, 120),
            calendar: clip(&e.calendar, 120),
        })
        .collect()
}

/// The local time of day, as the rows show it.
pub fn time_of_day(date: DateTime<Utc>) -> String {
    date.with_timezone(&Local).format("%H:%M").to_string()
}

/// The next meeting as a row, when it starts within `NEXT_EVENT_HOURS` (or runs now). `time` writes a time of day.
pub fn next_event_line(upcoming: &[AgendaEntry], now: DateTime<Utc>, time: impl Fn(DateTime<Utc>) -> String) -> Option<HomeLine> {
    let next = upcoming.iter().find(|e| e.end > now)?;
    if next.start - now >= chrono::Duration::hours(NEXT_EVENT_HOURS) {
        return None;
    }
    let when = if next.start <= now {
        tr("Nu bezig", "In progress").to_string()
    } else {
        trf("Om {time}", "At {time}", &[("time", &time(next.start))])
    };
    let place = if next.location.trim().is_empty() { String::new() } else { format!(" · {}", next.location.trim()) };
    Some(HomeLine {
        id: format!("event-{}", event_id(next)),
        title: next.title.clone(),
        subtitle: format!("{when}{place}"),
        icon: "source:calendar".into(),
        tone: "iris".into(),
    })
}

/// How much a row asks of you, most first (an approval before a question, before a failure, before what is only news).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LineRank {
    Approval,
    Input,
    Failure,
    Soon,
    Info,
}

/// The sessions that wait on you (and terminal sessions that got stuck), as rows: Today's `agentAttention`.
pub fn agent_lines(sessions: &[SessionDigest]) -> Vec<(LineRank, HomeLine)> {
    let mut lines = Vec::new();
    for s in sessions {
        let hub = s.id.strip_prefix(HUB_PREFIX);
        let rank = match s.attention.as_str() {
            "approval" => LineRank::Approval,
            "input" => LineRank::Input,
            // A failed session Nook runs already showed its card; only one in a terminal stays a row, as on the Mac.
            "failed" if hub.is_some() => LineRank::Failure,
            _ => continue,
        };
        let agent = if s.agent.trim().is_empty() { "Agent".to_string() } else { s.agent.clone() };
        let title = if rank == LineRank::Failure {
            trf("{agent} liep vast", "{agent} got stuck", &[("agent", &agent)])
        } else {
            trf("{agent} wacht op je", "{agent} is waiting for you", &[("agent", &agent)])
        };
        let (id, subtitle) = match hub {
            Some(key) => (format!("agent-{key}"), s.folder.clone()),
            None => (format!("run-{}", s.id), if s.title.trim().is_empty() { s.folder.clone() } else { s.title.clone() }),
        };
        let tone = if rank == LineRank::Failure { "coral" } else { "amber" };
        lines.push((rank, HomeLine { id, title, subtitle, icon: format!("agent:{agent}"), tone: tone.into() }));
    }
    lines
}

/// A connection that needs you ("GitHub: 2 checks failed").
pub fn connector_line(id: &str, title: &str, headline: &str, detail: &str, first_item: Option<&str>) -> HomeLine {
    let subtitle = if detail.trim().is_empty() { first_item.unwrap_or_default().to_string() } else { detail.to_string() };
    HomeLine {
        id: format!("connector-{id}"),
        title: if headline.trim().is_empty() { title.to_string() } else { format!("{title}: {headline}") },
        subtitle,
        icon: format!("source:{id}"),
        tone: "amber".into(),
    }
}

/// Nook's offer from thinking along that you have not looked at yet.
pub fn nudge_line(id: &str, line: &str, app: &str, time: &str) -> HomeLine {
    HomeLine {
        id: format!("nudge-{id}"),
        title: line.to_string(),
        subtitle: trf("Ik dacht mee in {app} · {time}", "I was thinking along in {app} · {time}", &[("app", &app), ("time", &time)]),
        icon: "symbol:sparkles".into(),
        tone: "iris".into(),
    }
}

/// The rows of "For you": most pressing first, then in the order they came, at most `MAX_LINES`, texts clipped.
pub fn rank_lines(mut lines: Vec<(LineRank, HomeLine)>) -> Vec<HomeLine> {
    lines.sort_by_key(|(rank, _)| *rank);
    lines
        .into_iter()
        .take(MAX_LINES)
        .map(|(_, mut line)| {
            line.title = clip(&line.title, 200);
            line.subtitle = clip(&line.subtitle, 200);
            line
        })
        .collect()
}

pub fn suggestions(list: &[String]) -> Vec<String> {
    list.iter().filter(|s| !s.trim().is_empty()).take(MAX_SUGGESTIONS).map(|s| clip(s, 200)).collect()
}

// MARK: Limits

/// A window as reported, or, when there is none or it has reset, an idle one: 0% that starts with the next message
/// (`QuotaService.window` on the Mac).
fn window(reported: Option<(f64, DateTime<Utc>)>, label: &str, duration: f64, now: DateTime<Utc>) -> UsageLimit {
    match reported {
        Some((percent, resets)) if resets > now => {
            UsageLimit { label: label.into(), percent, resets_at: Some(seconds(resets)), note: None, duration: Some(duration) }
        }
        _ => UsageLimit {
            label: label.into(),
            percent: 0.0,
            resets_at: None,
            note: Some(tr("Start bij je eerste bericht", "Starts with your first message").into()),
            duration: Some(duration),
        },
    }
}

/// A Claude subscription's two windows, from the status line; none when it never reported one.
pub fn claude_limits(usage: Option<&PlanUsage>, now: DateTime<Utc>) -> Vec<UsageLimit> {
    let Some(usage) = usage else { return vec![] };
    vec![
        window(usage.five_hour.as_ref().map(|w| (w.used_percent, w.resets_at)), tr("5 uur", "5 hours"), FIVE_HOURS, now),
        window(usage.seven_day.as_ref().map(|w| (w.used_percent, w.resets_at)), tr("Week", "Week"), WEEK, now),
    ]
}

/// The account's name as Settings shows it: your own label, else its organization, else "Personal".
pub fn account_name(label: &str, organization: Option<&str>) -> String {
    if !label.trim().is_empty() {
        return label.trim().to_string();
    }
    match organization.map(str::trim).filter(|o| !o.is_empty()) {
        Some(org) => org.to_string(),
        None => tr("Persoonlijk", "Personal").into(),
    }
}

// MARK: Usage

/// The range the phone asks for (`item`); a week when it says nothing or something unknown.
pub fn range(item: Option<&str>) -> UsageRange {
    match item {
        Some("today") => UsageRange::Today,
        Some("month") => UsageRange::Month,
        Some("all") => UsageRange::All,
        _ => UsageRange::Week,
    }
}

fn range_name(range: UsageRange) -> &'static str {
    match range {
        UsageRange::Today => "today",
        UsageRange::Week => "week",
        UsageRange::Month => "month",
        UsageRange::All => "all",
    }
}

/// The start of a local day in seconds since 1970, as the Mac sends a day.
fn day_start(day: NaiveDate) -> f64 {
    day.and_hms_opt(0, 0, 0).and_then(|d| d.and_local_timezone(Local).earliest()).map(|d| d.timestamp() as f64).unwrap_or_default()
}

/// The model as the Mac names it in the report ("default" when none was chosen).
fn model_name(model: &str) -> String {
    if model == "standaard" {
        "default".into()
    } else {
        clip(model, 120)
    }
}

/// What the sessions used over `range`, with every account's limits.
pub fn usage(report: &UsageReport, range: UsageRange, accounts: Vec<UsageAccount>) -> UsageDigest {
    UsageDigest {
        accounts,
        range: range_name(range).into(),
        sessions: report.sessions.into(),
        completed: report.completed.into(),
        failed: report.failed.into(),
        running: report.running.into(),
        input_tokens: report.input_tokens,
        output_tokens: report.output_tokens,
        cache_tokens: report.cache_read_tokens + report.cache_write_tokens,
        cost: report.reported_cost_usd,
        days: report
            .days
            .iter()
            .map(|d| UsageDay { day: day_start(d.day), agent: d.provider.display_name().into(), tokens: d.tokens })
            .collect(),
        models: report
            .rows
            .iter()
            .take(20)
            .map(|r| UsageModel {
                agent: r.provider.display_name().into(),
                model: model_name(&r.model),
                sessions: r.sessions.into(),
                tokens: r.input_tokens + r.output_tokens + r.cache_read_tokens,
                cost: r.reported_cost_usd,
            })
            .collect(),
    }
}

/// Plan usage by account folder, as the hub keeps it: the main account under "", others under their normalized folder.
pub fn plan_usage_for<'a>(
    main: Option<&'a PlanUsage>,
    by_home: &'a BTreeMap<String, PlanUsage>,
    profile_id: &str,
    home: Option<&str>,
) -> Option<&'a PlanUsage> {
    match home.map(crate::agents::profiles::normalize).filter(|h| !h.is_empty()) {
        Some(home) => by_home.get(&home).or_else(|| by_home.get(profile_id)),
        None => main.or_else(|| by_home.get(profile_id)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::models::PlanWindow;
    use crate::companion::models::{DigestItem, ItemKind};
    use crate::workspace::models::RunProvider;
    use crate::workspace::store::{UsageDay as ReportDay, UsageRow};
    use chrono::TimeZone;

    fn at(h: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000 + h * 3600, 0).unwrap()
    }

    fn entry(title: &str, start: i64, end: i64, location: &str) -> AgendaEntry {
        AgendaEntry {
            title: title.into(),
            start: at(start),
            end: at(end),
            all_day: false,
            busy: true,
            location: location.into(),
            calendar: "Work".into(),
        }
    }

    #[test]
    fn home_json_has_the_macs_keys() {
        let digest = HomeDigest {
            lines: vec![HomeLine { id: "a".into(), title: "t".into(), subtitle: "s".into(), icon: "symbol:x".into(), tone: "iris".into() }],
            events: events(&[entry("Standup", 1, 2, "Room")]),
            suggestions: vec!["Plan my day".into()],
            track: None,
            accounts: vec![UsageAccount { id: "claude".into(), agent: "Claude".into(), account: "Personal".into(), limits: vec![] }],
            update: None,
        };
        let json = serde_json::to_value(&digest).unwrap();
        assert!(json.get("track").is_none(), "nil is left out, as Swift does");
        assert!(json.get("update").is_none(), "no update, no key");
        let offered = HomeDigest {
            update: Some(UpdateOffer { version: "0.2.0".into(), state: "readyToRestart".into(), changes: 3, progress: None }),
            ..digest.clone()
        };
        let offer = serde_json::to_value(&offered).unwrap()["update"].clone();
        assert_eq!(offer, serde_json::json!({ "version": "0.2.0", "state": "readyToRestart", "changes": 3 }));
        let event = &json["events"][0];
        for key in ["id", "title", "start", "end", "location", "calendar"] {
            assert!(event.get(key).is_some(), "{key}");
        }
        assert_eq!(event["start"], 1_700_003_600.0);
        let back: HomeDigest = serde_json::from_value(json).unwrap();
        assert_eq!(back, digest);

        let usage = UsageDigest { cost: Some(1.5), ..Default::default() };
        let json = serde_json::to_value(&usage).unwrap();
        for key in ["inputTokens", "outputTokens", "cacheTokens", "cost", "days", "models", "accounts", "range"] {
            assert!(json.get(key).is_some(), "{key}");
        }
    }

    #[test]
    fn track_fills_unknown_times_with_zero() {
        let playing = NowPlaying {
            app: "Spotify".into(),
            title: "Song".into(),
            artist: "Band".into(),
            playing: true,
            position: Some(12.5),
            ..Default::default()
        };
        let t = track(&playing);
        assert_eq!((t.position, t.duration, t.playing), (12.5, 0.0, true));
        let json = serde_json::to_value(&t).unwrap();
        assert_eq!(json["app"], "Spotify");
        assert_eq!(json["album"], "");
    }

    #[test]
    fn music_buttons_are_only_the_three() {
        assert_eq!(MusicButton::parse(Some("playpause")), Some(MusicButton::PlayPause));
        assert_eq!(MusicButton::parse(Some("next")), Some(MusicButton::Next));
        assert_eq!(MusicButton::parse(Some("previous")), Some(MusicButton::Previous));
        assert_eq!(MusicButton::parse(Some("volume")), None);
        assert_eq!(MusicButton::parse(None), None);
    }

    #[test]
    fn agenda_keeps_what_has_not_ended_soonest_first() {
        let now = at(0);
        let list = upcoming(
            &[
                entry("Later", 5, 6, ""),
                entry("Done", -2, -1, ""),
                entry("Now", -1, 1, ""),
                entry("Later", 5, 6, ""),
                entry("Far", 40, 41, ""),
            ],
            now,
        );
        let titles: Vec<&str> = list.iter().map(|e| e.title.as_str()).collect();
        assert_eq!(titles, ["Now", "Later"]);
        assert_eq!(event_id(&list[1]), event_id(&entry("Later", 5, 6, "elsewhere")), "the id does not depend on the place");
    }

    #[test]
    fn next_event_is_a_row_only_when_soon() {
        crate::i18n::set_language("en");
        let now = at(0);
        let soon = upcoming(&[entry("Standup", 1, 2, "Room 4")], now);
        let line = next_event_line(&soon, now, |_| "10:00".into()).unwrap();
        assert_eq!((line.title.as_str(), line.subtitle.as_str(), line.icon.as_str()), ("Standup", "At 10:00 · Room 4", "source:calendar"));
        let running = upcoming(&[entry("Review", -1, 1, "")], now);
        assert_eq!(next_event_line(&running, now, |_| String::new()).unwrap().subtitle, "In progress");
        let later = upcoming(&[entry("Lunch", 4, 5, "")], now);
        assert!(next_event_line(&later, now, |_| String::new()).is_none());
    }

    fn session(id: &str, agent: &str, attention: &str) -> SessionDigest {
        SessionDigest {
            id: id.into(),
            title: "Fix the login".into(),
            agent: agent.into(),
            attention: attention.into(),
            folder: "nook".into(),
            items: vec![DigestItem { id: "p".into(), kind: ItemKind::Approval, ..Default::default() }],
            ..Default::default()
        }
    }

    #[test]
    fn agents_that_wait_come_first() {
        crate::i18n::set_language("en");
        let sessions = [
            session("hub:t1", "Codex", "failed"),
            session("r1", "Claude Code", "working"),
            session("r2", "Claude Code", "failed"),
            session("r3", "Claude Code", "input"),
            session("hub:t2", "Gemini CLI", "approval"),
        ];
        let mut lines = agent_lines(&sessions);
        lines.push((LineRank::Info, nudge_line("n1", "Reply to Anna?", "Mail", "09:30")));
        lines.push((LineRank::Soon, connector_line("github", "GitHub", "2 checks failed", "", Some("nook#12"))));
        let ranked = rank_lines(lines);
        let ids: Vec<&str> = ranked.iter().map(|l| l.id.as_str()).collect();
        assert_eq!(ids, ["agent-t2", "run-r3", "agent-t1", "connector-github", "nudge-n1"]);
        assert_eq!(ranked[0].title, "Gemini CLI is waiting for you");
        assert_eq!((ranked[0].subtitle.as_str(), ranked[0].icon.as_str(), ranked[0].tone.as_str()), ("nook", "agent:Gemini CLI", "amber"));
        assert_eq!(
            (ranked[1].subtitle.as_str(), ranked[2].title.as_str(), ranked[2].tone.as_str()),
            ("Fix the login", "Codex got stuck", "coral")
        );
        assert_eq!((ranked[3].title.as_str(), ranked[3].subtitle.as_str()), ("GitHub: 2 checks failed", "nook#12"));
        assert_eq!(ranked[4].subtitle, "I was thinking along in Mail · 09:30");
    }

    #[test]
    fn limits_follow_the_macs_windows() {
        crate::i18n::set_language("en");
        let now = at(0);
        assert!(claude_limits(None, now).is_empty(), "no status line yet: no limits");
        let usage = PlanUsage {
            five_hour: Some(PlanWindow { used_percent: 34.0, resets_at: at(2) }),
            seven_day: Some(PlanWindow { used_percent: 80.0, resets_at: at(-1) }),
            updated: now,
        };
        let limits = claude_limits(Some(&usage), now);
        assert_eq!(limits[0].label, "5 hours");
        assert_eq!((limits[0].percent, limits[0].resets_at, limits[0].duration), (34.0, Some(1_700_007_200.0), Some(FIVE_HOURS)));
        assert_eq!((limits[1].percent, limits[1].resets_at), (0.0, None), "a window that reset is idle");
        assert_eq!(limits[1].note.as_deref(), Some("Starts with your first message"));
        let json = serde_json::to_value(&limits[0]).unwrap();
        assert!(json.get("resetsAt").is_some() && json.get("note").is_none());
    }

    #[test]
    fn account_names_and_plan_usage_by_folder() {
        crate::i18n::set_language("en");
        assert_eq!(account_name("Work", Some("Acme")), "Work");
        assert_eq!(account_name("", Some("Acme")), "Acme");
        assert_eq!(account_name(" ", None), "Personal");
        let main = PlanUsage { five_hour: None, seven_day: None, updated: at(0) };
        let other = PlanUsage { five_hour: None, seven_day: None, updated: at(1) };
        let mut by_home = BTreeMap::new();
        by_home.insert(crate::agents::profiles::normalize("/home/me/.claude-work"), other.clone());
        assert_eq!(plan_usage_for(Some(&main), &by_home, "claude", None), Some(&main));
        assert_eq!(plan_usage_for(Some(&main), &by_home, "claude-work", Some("/home/me/.claude-work")), Some(&other));
        assert_eq!(plan_usage_for(None, &by_home, "claude-x", Some("/elsewhere")), None);
    }

    #[test]
    fn usage_maps_the_report() {
        assert_eq!(range(Some("today")), UsageRange::Today);
        assert_eq!(range(Some("bogus")), UsageRange::Week);
        assert_eq!(range(None), UsageRange::Week);
        let report = UsageReport {
            sessions: 3,
            completed: 1,
            failed: 1,
            running: 1,
            input_tokens: 100,
            output_tokens: 20,
            cache_read_tokens: 1000,
            cache_write_tokens: 50,
            reported_cost_usd: None,
            rows: vec![UsageRow {
                provider: RunProvider::Claude,
                model: "standaard".into(),
                sessions: 3,
                input_tokens: 100,
                output_tokens: 20,
                cache_read_tokens: 1000,
                reported_cost_usd: Some(0.25),
                sessions_without_tokens: 0,
            }],
            days: vec![ReportDay { day: NaiveDate::from_ymd_opt(2026, 11, 16).unwrap(), provider: RunProvider::Claude, tokens: 1170 }],
            ..Default::default()
        };
        let digest = usage(&report, UsageRange::Month, vec![]);
        assert_eq!((digest.range.as_str(), digest.sessions, digest.cache_tokens, digest.cost), ("month", 3, 1050, None));
        assert_eq!(digest.models[0].model, "default");
        assert_eq!(digest.models[0].tokens, 1120);
        assert_eq!(digest.models[0].agent, "Claude Code");
        assert_eq!(digest.days[0].tokens, 1170);
        let midnight = Local.with_ymd_and_hms(2026, 11, 16, 0, 0, 0).earliest().unwrap().timestamp() as f64;
        assert_eq!(digest.days[0].day, midnight);
        assert!(serde_json::to_value(&digest).unwrap().get("cost").is_none());
    }

    #[test]
    fn clip_cuts_with_an_ellipsis() {
        assert_eq!(clip("  hi\r\n", 10), "hi");
        assert_eq!(clip("abcdef", 3), "abc…");
    }
}
