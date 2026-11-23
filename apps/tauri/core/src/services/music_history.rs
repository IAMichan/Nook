//! What Nook remembers of the user's listening, as `MusicHistory.swift` does on the Mac: Recent, recent searches and a log
//! of plays, with the statistics, streaks and the recap made from them. Plain data and pure functions; `save`/`load`
//! keep one file in the data folder, and nothing here leaves the computer.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use chrono::{DateTime, Datelike, Duration, FixedOffset, NaiveDate, Timelike, Utc};
use serde::{Deserialize, Serialize};

use super::music::{MusicTrack, RecentTracks};

/// One track listened to. `played_at` is when it ended, as Spotify's own history counts it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicPlay {
    pub id: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album: String,
    pub app: String,
    #[serde(default)]
    pub artwork_url: Option<String>,
    pub duration: u32,
    /// Seconds actually listened to.
    pub listened: u32,
    pub played_at: DateTime<Utc>,
}

impl MusicPlay {
    /// False for a play no player could have made: a Spotify track id is 22 letters and digits; sample data is not.
    pub fn is_real(&self) -> bool {
        match self.id.strip_prefix("spotify:track:") {
            Some(rest) => rest.len() == 22 && rest.chars().all(|c| c.is_ascii_alphanumeric()),
            None => true,
        }
    }

    /// The same recording, also when the player gave no id.
    pub fn key(&self) -> String {
        if self.id.is_empty() { format!("{}|{}", self.artist, self.title) } else { self.id.clone() }
    }

    pub fn track(&self) -> MusicTrack {
        MusicTrack { id: self.id.clone(), title: self.title.clone(), artist: self.artist.clone(), duration: self.duration, artwork_url: self.artwork_url.clone(), album: self.album.clone() }
    }
}

/// Everything Nook keeps, saved as one file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct MusicHistory {
    /// Oldest first.
    pub plays: Vec<MusicPlay>,
    pub recent: RecentTracks,
    /// Newest first, each once.
    pub searches: Vec<String>,
}

impl MusicHistory {
    /// A year or more of listening, and a file that stays a few megabytes.
    pub const PLAY_LIMIT: usize = 10_000;
    pub const SEARCH_LIMIT: usize = 8;
    /// A play from the player's own history this close to one Nook measured is the same play.
    pub const SAME_PLAY_SECONDS: i64 = 600;

    pub fn is_empty(&self) -> bool {
        self.plays.is_empty() && self.recent.tracks.is_empty() && self.searches.is_empty()
    }

    pub fn add(&mut self, play: MusicPlay) {
        self.plays.push(play);
        self.trim();
    }

    /// Adds plays from the player's own history that Nook did not see itself; true when any were new.
    pub fn merge(&mut self, imported: Vec<MusicPlay>) -> bool {
        let mut known: HashMap<String, Vec<DateTime<Utc>>> = HashMap::new();
        for p in &self.plays {
            known.entry(p.key()).or_default().push(p.played_at);
        }
        let mut fresh = vec![];
        for play in imported {
            let seen = known.get(&play.key()).is_some_and(|d| d.iter().any(|t| (*t - play.played_at).num_seconds().abs() < Self::SAME_PLAY_SECONDS));
            if !seen {
                known.entry(play.key()).or_default().push(play.played_at);
                fresh.push(play);
            }
        }
        if fresh.is_empty() {
            return false;
        }
        self.plays.extend(fresh);
        self.plays.sort_by_key(|p| p.played_at);
        self.trim();
        true
    }

    /// Remembers what was searched for; differently cased, it is the same search.
    pub fn remember_search(&mut self, text: &str) {
        let query = text.trim();
        if query.is_empty() {
            return;
        }
        self.searches.retain(|s| !s.eq_ignore_ascii_case(query) && s.to_lowercase() != query.to_lowercase());
        self.searches.insert(0, query.to_string());
        self.searches.truncate(Self::SEARCH_LIMIT);
    }

    pub fn forget_search(&mut self, text: &str) {
        self.searches.retain(|s| s != text);
    }

    /// Drops plays no player made; true when any went, so the file is written again.
    pub fn drop_unreal_plays(&mut self) -> bool {
        let before = self.plays.len();
        self.plays.retain(MusicPlay::is_real);
        self.plays.len() != before
    }

    /// Forgets the whole listening history (Settings › Services › Music).
    pub fn clear(&mut self) {
        *self = Self::default();
    }

    fn trim(&mut self) {
        if self.plays.len() > Self::PLAY_LIMIT {
            let extra = self.plays.len() - Self::PLAY_LIMIT;
            self.plays.drain(..extra);
        }
    }

    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("music-history.json")
    }

    pub fn load() -> Self {
        let mut history: Self = std::fs::read(Self::file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        history.drop_unreal_plays();
        history
    }

    pub fn save(&self) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(self).map_err(std::io::Error::other)?;
        crate::paths::write_atomic(&Self::file(), &bytes)
    }
}

/// Follows the playing track and measures how long it really sounded. `update` hands back a finished play when the track
/// changes and it counts: half the track, or 30 seconds of a longer one, like a play on Spotify or Last.fm.
#[derive(Debug, Clone, Default)]
pub struct MusicListening {
    draft: Option<MusicPlay>,
    since: Option<DateTime<Utc>>,
    seconds: f64,
}

impl MusicListening {
    /// Without a length (a stream) a track counts this long at most.
    pub const STREAM_LIMIT: f64 = 3.0 * 3600.0;

    /// Call with what plays now (none for nothing) on every change, with the moment of the change.
    pub fn update(&mut self, playing: Option<MusicPlay>, is_playing: bool, now: DateTime<Utc>) -> Option<MusicPlay> {
        if let Some(since) = self.since.take() {
            self.seconds += (now - since).num_milliseconds().max(0) as f64 / 1000.0;
        }
        let mut finished = None;
        if self.draft.as_ref().map(MusicPlay::key) != playing.as_ref().map(MusicPlay::key) {
            finished = self.finish(now);
            self.draft = playing;
            self.seconds = 0.0;
        }
        if self.draft.is_some() && is_playing {
            self.since = Some(now);
        }
        finished
    }

    /// Nook quits: what was playing counts as far as it got.
    pub fn finish(&mut self, now: DateTime<Utc>) -> Option<MusicPlay> {
        if let Some(since) = self.since.take() {
            self.seconds += (now - since).num_milliseconds().max(0) as f64 / 1000.0;
        }
        let mut play = self.draft.take()?;
        let heard = self.seconds.min(if play.duration > 0 { f64::from(play.duration) } else { Self::STREAM_LIMIT });
        self.seconds = 0.0;
        if !Self::counts(heard, play.duration) {
            return None;
        }
        play.listened = heard as u32;
        play.played_at = now;
        Some(play)
    }

    pub fn counts(heard: f64, duration: u32) -> bool {
        heard >= if duration > 0 { 30f64.min(f64::from(duration) / 2.0) } else { 30.0 }
    }
}

/// The time the statistics look back over. Rolling, so a Monday morning still has a week to show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StatsPeriod {
    Week,
    Month,
    Year,
    All,
}

fn month_start(date: NaiveDate) -> NaiveDate {
    date.with_day(1).unwrap_or(date)
}

fn add_months(date: NaiveDate, months: i32) -> NaiveDate {
    let total = date.year() * 12 + date.month0() as i32 + months;
    NaiveDate::from_ymd_opt(total.div_euclid(12), total.rem_euclid(12) as u32 + 1, 1).unwrap_or(date)
}

impl StatsPeriod {
    /// The first day of the period, or none for everything.
    pub fn start(self, today: NaiveDate) -> Option<NaiveDate> {
        match self {
            Self::Week => Some(today - Duration::days(6)),
            Self::Month => Some(today - Duration::days(29)),
            Self::Year => Some(add_months(month_start(today), -11)),
            Self::All => None,
        }
    }

    /// The same length just before `start`, to compare with.
    fn previous_start(self, start: NaiveDate) -> Option<NaiveDate> {
        match self {
            Self::Week => Some(start - Duration::days(7)),
            Self::Month => Some(start - Duration::days(30)),
            Self::Year => Some(add_months(start, -12)),
            Self::All => None,
        }
    }

    /// Bars per day for the short periods, per month for the long ones.
    pub fn by_day(self) -> bool {
        matches!(self, Self::Week | Self::Month)
    }
}

/// The part of the day someone listens most.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ListenerType {

    Afternoon,
    Evening,
    Morning,
    Night,
}

impl ListenerType {
    pub fn from_hour(hour: u32) -> Self {
        match hour {
            5..=11 => Self::Morning,
            12..=17 => Self::Afternoon,
            18..=22 => Self::Evening,
            _ => Self::Night,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bucket {
    /// The day (or the first day of the month), as `YYYY-MM-DD`.
    pub start: String,
    pub seconds: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackRank {
    pub track: MusicTrack,
    pub plays: u32,
    pub seconds: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtistRank {
    pub name: String,
    pub plays: u32,
    pub seconds: u32,
    pub artwork_url: Option<String>,
}

/// The statistics over one period.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicStats {
    pub period: StatsPeriod,
    pub seconds: u32,
    pub plays: u32,
    pub unique_tracks: u32,
    pub unique_artists: u32,
    /// The period before, for the comparison; none when there is nothing to compare with.
    pub previous_seconds: Option<u32>,
    pub buckets: Vec<Bucket>,
    /// Seconds per hour of the day, 0 to 23.
    pub hours: Vec<u32>,
    /// Seconds per day of the week (Monday first) and hour.
    pub week_hours: Vec<Vec<u32>>,
    /// Artists in this period never played before it; none for all time.
    pub new_artists: Option<u32>,
    pub top_tracks: Vec<TrackRank>,
    pub top_artists: Vec<ArtistRank>,
    /// Days in a row with music, up to today or yesterday.
    pub streak: u32,
    pub best_day: Option<Bucket>,
    pub peak_hour: Option<u32>,
    pub listener_type: Option<ListenerType>,
}

impl MusicStats {
    pub const RANK_LIMIT: usize = 10;

    pub fn is_empty(&self) -> bool {
        self.plays == 0
    }

    /// The change against the period before, in percent, when it can be said.
    pub fn change(&self) -> Option<i32> {
        let before = self.previous_seconds.filter(|s| *s > 0)?;
        Some(((f64::from(self.seconds) - f64::from(before)) / f64::from(before) * 100.0).round() as i32)
    }

    /// `all` oldest first, as `MusicHistory` keeps them; days are those of `offset` (the user's time zone).
    pub fn new(all: &[MusicPlay], period: StatsPeriod, now: DateTime<Utc>, offset: FixedOffset) -> Self {
        let day = |t: DateTime<Utc>| t.with_timezone(&offset).date_naive();
        let today = day(now);
        let start = period.start(today);
        let in_period = |p: &&MusicPlay| p.played_at <= now && start.is_none_or(|s| day(p.played_at) >= s);
        let shown: Vec<&MusicPlay> = all.iter().filter(in_period).collect();
        let mut stats = Self {
            period,
            seconds: 0,
            plays: 0,
            unique_tracks: 0,
            unique_artists: 0,
            previous_seconds: None,
            buckets: Self::empty_buckets(period, all.first().map(|p| day(p.played_at)), today),
            hours: vec![0; 24],
            week_hours: vec![vec![0; 24]; 7],
            new_artists: None,
            top_tracks: vec![],
            top_artists: vec![],
            streak: Self::streak(all, today, offset),
            best_day: None,
            peak_hour: None,
            listener_type: None,
        };
        if let Some((start, before)) = start.and_then(|s| period.previous_start(s).map(|b| (s, b))) {
            let earlier: Vec<&MusicPlay> = all.iter().filter(|p| day(p.played_at) >= before && day(p.played_at) < start).collect();
            stats.previous_seconds = (!earlier.is_empty()).then(|| earlier.iter().map(|p| p.listened).sum());
        }
        if shown.is_empty() {
            return stats;
        }
        stats.plays = shown.len() as u32;
        stats.seconds = shown.iter().map(|p| p.listened).sum();
        let mut days: HashMap<NaiveDate, u32> = HashMap::new();
        let mut tracks: HashMap<String, TrackRank> = HashMap::new();
        let mut artists: HashMap<String, ArtistRank> = HashMap::new();
        for play in &shown {
            let local = play.played_at.with_timezone(&offset);
            let date = local.date_naive();
            *days.entry(date).or_default() += play.listened;
            let bucket = if period.by_day() { date } else { month_start(date) }.format("%Y-%m-%d").to_string();
            if let Some(b) = stats.buckets.iter_mut().find(|b| b.start == bucket) {
                b.seconds += play.listened;
            }
            let hour = local.hour() as usize;
            stats.hours[hour] += play.listened;
            stats.week_hours[local.weekday().num_days_from_monday() as usize][hour] += play.listened;
            let rank = tracks.entry(play.key()).or_insert_with(|| TrackRank { track: play.track(), plays: 0, seconds: 0 });
            rank.plays += 1;
            rank.seconds += play.listened;
            rank.track = play.track();
            if !play.artist.is_empty() {
                let artist = artists.entry(play.artist.clone()).or_insert_with(|| ArtistRank { name: play.artist.clone(), plays: 0, seconds: 0, artwork_url: None });
                artist.plays += 1;
                artist.seconds += play.listened;
                artist.artwork_url = play.artwork_url.clone().or(artist.artwork_url.take());
            }
        }
        stats.unique_tracks = tracks.len() as u32;
        stats.unique_artists = artists.len() as u32;
        if let Some(start) = start {
            let known: HashSet<&str> = all.iter().filter(|p| day(p.played_at) < start).map(|p| p.artist.as_str()).collect();
            stats.new_artists = Some(artists.keys().filter(|a| !known.contains(a.as_str())).count() as u32);
        }
        let mut top: Vec<TrackRank> = tracks.into_values().collect();
        top.sort_by(|a, b| (b.plays, b.seconds, &a.track.title).cmp(&(a.plays, a.seconds, &b.track.title)));
        top.truncate(Self::RANK_LIMIT);
        stats.top_tracks = top;
        let mut top: Vec<ArtistRank> = artists.into_values().collect();
        top.sort_by(|a, b| (b.seconds, &a.name).cmp(&(a.seconds, &b.name)));
        top.truncate(Self::RANK_LIMIT);
        stats.top_artists = top;
        stats.best_day = days.iter().max_by(|a, b| (a.1, b.0).cmp(&(b.1, a.0))).map(|(d, s)| Bucket { start: d.format("%Y-%m-%d").to_string(), seconds: *s });
        let peak = (0..24).max_by_key(|h| (stats.hours[*h], std::cmp::Reverse(*h))).unwrap_or(0);
        if stats.hours[peak] > 0 {
            stats.peak_hour = Some(peak as u32);
            // By the part of the day, not one peak hour: an evening spread over hours beats one busy lunch.
            let mut parts: HashMap<ListenerType, u32> = HashMap::new();
            for (hour, seconds) in stats.hours.iter().enumerate() {
                *parts.entry(ListenerType::from_hour(hour as u32)).or_default() += seconds;
            }
            stats.listener_type = (stats.plays >= 5).then(|| parts.into_iter().max_by(|a, b| (a.1, b.0).cmp(&(b.1, a.0))).map(|p| p.0)).flatten();
        }
        stats
    }

    /// One empty bar for every day or month of the period, so a silent day shows as a gap.
    fn empty_buckets(period: StatsPeriod, first: Option<NaiveDate>, today: NaiveDate) -> Vec<Bucket> {
        let this_month = month_start(today);
        let mut start = period.start(today);
        if period == StatsPeriod::All {
            // Every month since the first play, half a year at least and two years at most.
            let earliest = add_months(this_month, -23);
            let latest = add_months(this_month, -5);
            let first_month = first.map(month_start).unwrap_or(latest);
            start = Some(earliest.max(latest.min(first_month)));
        }
        let Some(mut date) = start else { return vec![] };
        let end = if period.by_day() { today } else { this_month };
        let mut result = vec![];
        while date <= end && result.len() < 40 {
            result.push(Bucket { start: date.format("%Y-%m-%d").to_string(), seconds: 0 });
            date = if period.by_day() { date + Duration::days(1) } else { add_months(date, 1) };
        }
        result
    }

    /// Days in a row with music. Today may still come; the streak only breaks when yesterday stayed silent too.
    fn streak(plays: &[MusicPlay], today: NaiveDate, offset: FixedOffset) -> u32 {
        let days: HashSet<NaiveDate> = plays.iter().map(|p| p.played_at.with_timezone(&offset).date_naive()).collect();
        let mut day = if days.contains(&today) { today } else { today - Duration::days(1) };
        let mut count = 0;
        while days.contains(&day) {
            count += 1;
            day -= Duration::days(1);
        }
        count
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(day: u32, hour: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, day, hour, 0, 0).unwrap()
    }

    fn play(id: &str, artist: &str, listened: u32, played_at: DateTime<Utc>) -> MusicPlay {
        MusicPlay { id: id.into(), title: format!("T-{id}"), artist: artist.into(), album: String::new(), app: "Spotify".into(), artwork_url: None, duration: 200, listened, played_at }
    }

    fn utc() -> FixedOffset {
        FixedOffset::east_opt(0).unwrap()
    }

    #[test]
    fn a_play_counts_after_half_the_track_or_thirty_seconds() {
        let mut l = MusicListening::default();
        let t0 = at(20, 10);
        let a = play("spotify:track:aaaaaaaaaaaaaaaaaaaaaa", "A", 0, t0);
        assert!(l.update(Some(a.clone()), true, t0).is_none());
        // A pause does not count; 60 s of sound do.
        assert!(l.update(Some(a.clone()), false, t0 + Duration::seconds(60)).is_none());
        assert!(l.update(Some(a.clone()), true, t0 + Duration::seconds(600)).is_none());
        let b = play("spotify:track:bbbbbbbbbbbbbbbbbbbbbb", "B", 0, t0);
        let done = l.update(Some(b), true, t0 + Duration::seconds(610)).expect("the first track counted");
        assert_eq!((done.id.as_str(), done.listened), ("spotify:track:aaaaaaaaaaaaaaaaaaaaaa", 70));
        // Skipped after 5 seconds: no play.
        assert!(l.update(None, false, t0 + Duration::seconds(615)).is_none());
        assert!(MusicListening::counts(10.0, 20) && !MusicListening::counts(9.0, 20) && MusicListening::counts(30.0, 0));
    }

    #[test]
    fn merging_the_players_history_skips_plays_nook_saw() {
        let mut h = MusicHistory::default();
        h.add(play("x", "A", 100, at(20, 10)));
        let again = play("x", "A", 200, at(20, 10) + Duration::seconds(120));
        let other = play("y", "B", 200, at(20, 12));
        assert!(h.merge(vec![again.clone(), other]));
        assert_eq!(h.plays.len(), 2);
        assert!(!h.merge(vec![again]));
    }

    #[test]
    fn searches_are_kept_once_newest_first_and_capped() {
        let mut h = MusicHistory::default();
        h.remember_search("Coldplay");
        h.remember_search("  ");
        h.remember_search("coldplay");
        assert_eq!(h.searches, vec!["coldplay"]);
        for i in 0..12 {
            h.remember_search(&format!("q{i}"));
        }
        assert_eq!(h.searches.len(), MusicHistory::SEARCH_LIMIT);
        assert_eq!(h.searches[0], "q11");
        h.forget_search("q11");
        assert_eq!(h.searches[0], "q10");
    }

    #[test]
    fn sample_plays_are_dropped_and_the_file_roundtrips() {
        let mut h = MusicHistory::default();
        h.add(play("spotify:track:GetLucky", "Fake", 100, at(20, 10)));
        h.add(play("spotify:track:aaaaaaaaaaaaaaaaaaaaaa", "Real", 100, at(20, 11)));
        assert!(h.drop_unreal_plays());
        assert_eq!(h.plays.len(), 1);
        let json = serde_json::to_string(&h).unwrap();
        assert_eq!(serde_json::from_str::<MusicHistory>(&json).unwrap(), h);
    }

    #[test]
    fn the_week_counts_seconds_ranks_and_streaks() {
        let now = at(22, 20);
        let mut plays = vec![
            // Before the week: Old is not a new artist this week.
            play("o", "Old", 100, at(1, 9)),
            play("a", "Alpha", 300, at(20, 20)),
            play("a", "Alpha", 300, at(21, 20)),
            play("a", "Alpha", 300, at(22, 9)),
            play("b", "Beta", 100, at(22, 10)),
            play("o2", "Old", 50, at(22, 11)),
        ];
        plays.sort_by_key(|p| p.played_at);
        let s = MusicStats::new(&plays, StatsPeriod::Week, now, utc());
        assert_eq!((s.plays, s.seconds, s.unique_tracks, s.unique_artists), (5, 1050, 3, 3));
        assert_eq!(s.streak, 3);
        assert_eq!(s.top_artists[0].name, "Alpha");
        assert_eq!(s.top_tracks[0].plays, 3);
        assert_eq!(s.new_artists, Some(2));
        assert_eq!(s.buckets.len(), 7);
        assert_eq!(s.buckets.last().unwrap(), &Bucket { start: "2026-11-22".into(), seconds: 450 });
        assert_eq!(s.best_day.as_ref().unwrap().start, "2026-11-22");
        assert_eq!(s.peak_hour, Some(20));
        assert_eq!(s.listener_type, Some(ListenerType::Evening));
        assert_eq!(s.week_hours[6][9], 300);
        // The week before holds nothing: no comparison.
        assert_eq!((s.previous_seconds, s.change()), (None, None));
    }

    #[test]
    fn the_streak_survives_today_but_not_two_silent_days() {
        let plays = vec![play("a", "A", 60, at(20, 10)), play("a", "A", 60, at(21, 10))];
        assert_eq!(MusicStats::new(&plays, StatsPeriod::Week, at(22, 8), utc()).streak, 2);
        assert_eq!(MusicStats::new(&plays, StatsPeriod::Week, at(23, 8), utc()).streak, 0);
    }

    #[test]
    fn a_period_is_compared_with_the_one_before() {
        let plays = vec![play("a", "A", 100, at(5, 10)), play("a", "A", 150, at(20, 10))];
        let s = MusicStats::new(&plays, StatsPeriod::Week, at(22, 8), utc());
        assert_eq!(s.previous_seconds, None);
        let s = MusicStats::new(&plays, StatsPeriod::Month, at(22, 8), utc());
        assert_eq!(s.seconds, 250);
        let plays = vec![play("a", "A", 100, at(12, 10)), play("a", "A", 150, at(20, 10))];
        let s = MusicStats::new(&plays, StatsPeriod::Week, at(22, 8), utc());
        assert_eq!((s.previous_seconds, s.change()), (Some(100), Some(50)));
    }

    #[test]
    fn listener_types_follow_the_hour() {
        assert_eq!(ListenerType::from_hour(7), ListenerType::Morning);
        assert_eq!(ListenerType::from_hour(13), ListenerType::Afternoon);
        assert_eq!(ListenerType::from_hour(20), ListenerType::Evening);
        assert_eq!(ListenerType::from_hour(2), ListenerType::Night);
    }
}
