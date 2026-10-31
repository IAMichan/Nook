//! What Nook remembers of the current match: round by round, every event it saw or you logged. This is
//! match-specific memory; general knowledge about agents is [`super::catalog`], and earlier matches stay in the
//! history without leaking into the current one.

use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::catalog;
use crate::paths;

/// Who did it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Side {
    #[default]
    Enemy,
    Me,
    Ally,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum EventKind {
    /// An ability was used or found (a trip, a flash, a recon bolt).
    #[default]
    Utility,
    /// I died.
    Death,
    /// I got a kill.
    Kill,
}

/// What the event did to me.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Effect {
    /// Seen, nothing more.
    #[default]
    Seen,
    /// It caught me: I triggered the trip, got flashed, got revealed.
    Hit,
    /// I saw it coming and dodged it (turned away from the flash, shot the trip).
    Avoided,
    /// I or a teammate destroyed it.
    Destroyed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    /// You logged it.
    #[default]
    Manual,
    /// Nook read it from a screenshot.
    Screen,
}

/// One thing that happened in a round. Agent and ability are catalog ids, so "Tripwire" and "Trapwire" are one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MatchEvent {
    pub id: String,
    pub round: u32,
    #[serde(default)]
    pub kind: EventKind,
    #[serde(default)]
    pub side: Side,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub ability: Option<String>,
    pub location: String,
    /// Seconds since the round started (the end of the buy phase).
    #[serde(default)]
    pub round_time: Option<u32>,
    #[serde(default)]
    pub effect: Effect,
    /// 0 to 1: how sure Nook is that it read this right. A logged event is 1.
    pub confidence: f32,
    #[serde(default)]
    pub source: Source,
    pub at: DateTime<Utc>,
}

impl MatchEvent {
    /// The setup this event belongs to: agent, ability, and place. Events with the same key are one habit of the
    /// enemy, even if they are written differently.
    pub fn setup_key(&self) -> Option<String> {
        Some(format!("{}/{}/{}", self.agent.as_deref()?, self.ability.as_deref()?, catalog::location_key(&self.location)))
    }
}

/// What the interface or a screenshot hands in: names may be loose ("tripwire", "kay/o").
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EventInput {
    /// The round it happened in; the current round when left out.
    pub round: Option<u32>,
    pub kind: EventKind,
    pub side: Side,
    pub agent: Option<String>,
    pub ability: Option<String>,
    pub location: String,
    pub round_time: Option<u32>,
    pub effect: Effect,
    pub confidence: Option<f32>,
    pub source: Source,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Round {
    pub number: u32,
    pub started: DateTime<Utc>,
    /// The round is over; anything not seen in it was not there (as far as Nook watched).
    #[serde(default)]
    pub closed: bool,
    #[serde(default)]
    pub events: Vec<MatchEvent>,
}

impl Round {
    fn new(number: u32, now: DateTime<Utc>) -> Self {
        Self { number, started: now, closed: false, events: vec![] }
    }

    /// Nook saw something of this round. A round without any event says nothing about whether a setup was there.
    pub fn observed(&self) -> bool {
        !self.events.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Match {
    pub id: String,
    pub started: DateTime<Utc>,
    #[serde(default)]
    pub ended: Option<DateTime<Utc>>,
    #[serde(default)]
    pub map: Option<String>,
    /// The agent I play (catalog id).
    #[serde(default)]
    pub my_agent: Option<String>,
    pub rounds: Vec<Round>,
}

impl Match {
    pub fn new(map: Option<String>, my_agent: Option<String>, now: DateTime<Utc>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            started: now,
            ended: None,
            map: map.as_deref().and_then(catalog::map).map(String::from),
            my_agent: my_agent.as_deref().and_then(catalog::agent).map(|a| a.id.to_string()),
            rounds: vec![Round::new(1, now)],
        }
    }

    pub fn current_round(&self) -> u32 {
        self.rounds.last().map(|r| r.number).unwrap_or(1)
    }

    pub fn round(&self, number: u32) -> Option<&Round> {
        self.rounds.iter().find(|r| r.number == number)
    }

    pub fn events(&self) -> impl Iterator<Item = &MatchEvent> {
        self.rounds.iter().flat_map(|r| r.events.iter())
    }

    /// Enemy agents seen this match, in the order they first showed up.
    pub fn enemy_agents(&self) -> Vec<String> {
        let mut seen: Vec<String> = vec![];
        for e in self.events().filter(|e| e.side == Side::Enemy) {
            if let Some(agent) = &e.agent {
                if !seen.contains(agent) {
                    seen.push(agent.clone());
                }
            }
        }
        seen
    }

    /// Moves to round `number`, closing every round before it. Never goes back: a screenshot of an old scoreboard
    /// must not reopen a round.
    pub fn advance_to(&mut self, number: u32, now: DateTime<Utc>) {
        let number = number.clamp(1, 60);
        while self.current_round() < number {
            if let Some(last) = self.rounds.last_mut() {
                last.closed = true;
            }
            let next = self.current_round() + 1;
            self.rounds.push(Round::new(next, now));
        }
    }

    /// Adds an event, or makes an existing one surer when it is the same thing seen again in the same round (a
    /// screenshot every few seconds sees the same trip many times). `None` when the input is not something Nook
    /// knows (an agent or ability that does not exist) or carries no place.
    pub fn record(&mut self, input: EventInput, now: DateTime<Utc>) -> Option<MatchEvent> {
        let location = input.location.trim();
        if location.is_empty() || location.chars().count() > 60 {
            return None;
        }
        let agent = match input.agent.as_deref().filter(|a| !a.trim().is_empty()) {
            Some(name) => Some(catalog::agent(name)?),
            None => None,
        };
        let ability = match (agent, input.ability.as_deref().filter(|a| !a.trim().is_empty())) {
            (Some(agent), Some(name)) => Some(catalog::ability_of(agent, name)?),
            (None, Some(_)) => return None,
            _ => None,
        };
        if input.kind == EventKind::Utility && ability.is_none() {
            return None;
        }
        let round = input.round.unwrap_or_else(|| self.current_round()).max(1);
        if round > self.current_round() {
            self.advance_to(round, now);
        }
        let event = MatchEvent {
            id: uuid::Uuid::new_v4().to_string(),
            round,
            kind: input.kind,
            side: input.side,
            agent: agent.map(|a| a.id.to_string()),
            ability: ability.map(|b| b.id.to_string()),
            location: location.to_string(),
            round_time: input.round_time.filter(|t| *t <= 180),
            effect: input.effect,
            confidence: input.confidence.unwrap_or(1.0).clamp(0.0, 1.0),
            source: input.source,
            at: now,
        };
        let slot = self.rounds.iter_mut().find(|r| r.number == round)?;
        let key = (event.kind, event.side, event.agent.clone(), event.ability.clone(), catalog::location_key(&event.location));
        if let Some(existing) =
            slot.events.iter_mut().find(|e| (e.kind, e.side, e.agent.clone(), e.ability.clone(), catalog::location_key(&e.location)) == key)
        {
            existing.confidence = existing.confidence.max(event.confidence);
            existing.round_time = existing.round_time.or(event.round_time);
            // A later screenshot can show it caught me or I dodged it; that is the more telling effect.
            if existing.effect == Effect::Seen {
                existing.effect = event.effect;
            }
            return Some(existing.clone());
        }
        slot.events.push(event.clone());
        Some(event)
    }

    pub fn remove(&mut self, event_id: &str) -> bool {
        let mut removed = false;
        for round in &mut self.rounds {
            let before = round.events.len();
            round.events.retain(|e| e.id != event_id);
            removed |= round.events.len() != before;
        }
        removed
    }
}

/// How Gamer Mode behaves. Kept with the game data, not in the settings that are shared with the Mac.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GamerPrefs {
    /// Gamer Mode is on: Nook may look at the game while it is in front.
    pub enabled: bool,
    /// Seconds between two looks at the screen while the game is in front. A look never starts while the previous
    /// one is still with the brain, so a slow brain looks less often than this.
    pub interval_secs: u32,
    /// Show new coaching as a notice.
    pub notify: bool,
}

impl Default for GamerPrefs {
    fn default() -> Self {
        Self { enabled: false, interval_secs: 3, notify: true }
    }
}

impl GamerPrefs {
    pub fn interval(&self) -> u32 {
        self.interval_secs.clamp(3, 300)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Saved {
    prefs: GamerPrefs,
    current: Option<Match>,
    history: Vec<Match>,
}

/// Valorant's part of Gamer Mode on disk (`games/valorant.json` in Nook's data folder): the settings, the match in
/// progress, and the last few finished matches.
pub struct ValorantStore {
    file: Option<PathBuf>,
    pub prefs: GamerPrefs,
    pub current: Option<Match>,
    pub history: Vec<Match>,
}

/// Finished matches kept for later.
pub const HISTORY_LIMIT: usize = 20;

impl ValorantStore {
    pub fn open_default() -> Self {
        Self::open(paths::support_directory().join("games").join("valorant.json"))
    }

    pub fn open(file: PathBuf) -> Self {
        let saved: Saved = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { file: Some(file), prefs: saved.prefs, current: saved.current, history: saved.history }
    }

    pub fn in_memory() -> Self {
        Self { file: None, prefs: GamerPrefs::default(), current: None, history: vec![] }
    }

    pub fn save(&self) {
        let saved = Saved { prefs: self.prefs.clone(), current: self.current.clone(), history: self.history.clone() };
        if let (Some(file), Ok(bytes)) = (&self.file, serde_json::to_vec(&saved)) {
            let _ = paths::write_atomic(file, &bytes);
        }
    }

    /// Starts a new match, putting the one in progress in the history.
    pub fn start_match(&mut self, map: Option<String>, my_agent: Option<String>, now: DateTime<Utc>) -> &mut Match {
        self.end_match(now);
        self.current.insert(Match::new(map, my_agent, now))
    }

    pub fn end_match(&mut self, now: DateTime<Utc>) {
        if let Some(mut m) = self.current.take() {
            if m.events().next().is_none() {
                return;
            }
            m.ended = Some(now);
            if let Some(last) = m.rounds.last_mut() {
                last.closed = true;
            }
            self.history.insert(0, m);
            self.history.truncate(HISTORY_LIMIT);
        }
    }

    /// The match in progress, started when there is none.
    pub fn current_or_start(&mut self, now: DateTime<Utc>) -> &mut Match {
        self.current.get_or_insert_with(|| Match::new(None, None, now))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trip(round: u32, location: &str) -> EventInput {
        EventInput {
            round: Some(round),
            agent: Some("Cypher".into()),
            ability: Some("Tripwire".into()),
            location: location.into(),
            effect: Effect::Hit,
            confidence: Some(0.91),
            ..Default::default()
        }
    }

    #[test]
    fn records_with_catalog_ids_and_opens_rounds() {
        let now = Utc::now();
        let mut m = Match::new(Some("sunset".into()), Some("Jett".into()), now);
        assert_eq!(m.map.as_deref(), Some("Sunset"));
        assert_eq!(m.my_agent.as_deref(), Some("jett"));
        let e = m.record(trip(2, "B Main"), now).unwrap();
        assert_eq!((e.agent.as_deref(), e.ability.as_deref()), (Some("cypher"), Some("trapwire")));
        assert_eq!(m.current_round(), 2);
        assert!(m.round(1).unwrap().closed);
        assert!(!m.round(2).unwrap().closed);
    }

    #[test]
    fn the_same_thing_seen_twice_in_a_round_is_one_event() {
        let now = Utc::now();
        let mut m = Match::new(None, None, now);
        let mut seen = trip(1, "B Main");
        seen.effect = Effect::Seen;
        seen.confidence = Some(0.6);
        m.record(seen, now).unwrap();
        m.record(trip(1, "main b"), now).unwrap();
        let events = &m.round(1).unwrap().events;
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].effect, Effect::Hit);
        assert!((events[0].confidence - 0.91).abs() < 1e-6);
    }

    #[test]
    fn rejects_what_does_not_exist() {
        let now = Utc::now();
        let mut m = Match::new(None, None, now);
        let mut wrong = trip(1, "B Main");
        wrong.ability = Some("Guiding Light".into());
        assert!(m.record(wrong, now).is_none());
        let mut nobody = trip(1, "B Main");
        nobody.agent = Some("Gandalf".into());
        assert!(m.record(nobody, now).is_none());
        assert!(m.record(trip(1, "  "), now).is_none());
        // A death needs no ability.
        let death = EventInput { kind: EventKind::Death, side: Side::Me, location: "B Main".into(), ..Default::default() };
        assert!(m.record(death, now).is_some());
    }

    #[test]
    fn looks_every_three_seconds_by_default() {
        assert_eq!(GamerPrefs::default().interval(), 3);
        assert_eq!(GamerPrefs { interval_secs: 1, ..Default::default() }.interval(), 3);
    }

    #[test]
    fn rounds_never_go_back() {
        let now = Utc::now();
        let mut m = Match::new(None, None, now);
        m.advance_to(5, now);
        m.advance_to(3, now);
        assert_eq!(m.current_round(), 5);
        assert_eq!(m.rounds.len(), 5);
    }

    #[test]
    fn keeps_matches_apart_and_survives_a_restart() {
        let dir = std::env::temp_dir().join(format!("nook-valorant-{}", uuid::Uuid::new_v4()));
        let file = dir.join("valorant.json");
        let now = Utc::now();
        let mut store = ValorantStore::open(file.clone());
        store.prefs.enabled = true;
        store.start_match(Some("Sunset".into()), None, now).record(trip(1, "B Main"), now);
        store.start_match(Some("Bind".into()), None, now);
        store.save();
        let reopened = ValorantStore::open(file);
        assert!(reopened.prefs.enabled);
        assert_eq!(reopened.history.len(), 1);
        assert_eq!(reopened.history[0].map.as_deref(), Some("Sunset"));
        let current = reopened.current.unwrap();
        assert_eq!(current.map.as_deref(), Some("Bind"));
        assert_eq!(current.events().count(), 0);
        let _ = std::fs::remove_dir_all(dir);
    }
}
