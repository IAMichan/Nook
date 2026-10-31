//! The coach: reads back through every round of the match and finds what the enemy keeps repeating, where a habit
//! stopped (the enemy adapted), and what I keep running into. Pure functions over a [`Match`], so the same memory
//! always gives the same advice.
//!
//! Advice comes out as [`Insight`]s with the facts filled in; the interface words them in the user's language.

use std::collections::BTreeMap;

use serde::Serialize;

use super::catalog::{self, AbilityKind};
use super::memory::{Effect, EventKind, Match, MatchEvent, Side};

/// How sure Nook is that a setup is a habit of the enemy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Confidence {
    Low,
    Medium,
    High,
}

/// Is the habit still in use?
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum PatternStatus {
    /// Seen in the latest round Nook watched, or no round has been watched since.
    Active,
    /// Not there in the latest round Nook watched: the enemy may have changed it. `moved_to` when the same ability
    /// turned up somewhere else in that round.
    Changed { round: u32, moved_to: Option<String> },
    /// Missing for two or more watched rounds: history, not something to count on.
    Stale { since: u32 },
}

/// A setup of one enemy agent: the same ability at the same place, over several rounds.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pattern {
    pub key: String,
    pub agent: String,
    pub agent_name: String,
    pub ability: String,
    pub ability_name: String,
    pub kind: Option<AbilityKind>,
    /// The place as it was written most often.
    pub location: String,
    /// Rounds it was seen in (each round counts once).
    pub rounds: Vec<u32>,
    pub occurrences: u32,
    /// Rounds in a row up to the last time it was seen.
    pub streak: u32,
    /// Typical moment in the round, in seconds (the median of what was seen).
    pub typical_time: Option<u32>,
    /// Times it caught me, and times I dodged it.
    pub hits: u32,
    pub avoided: u32,
    pub confidence: Confidence,
    pub status: PatternStatus,
}

impl Pattern {
    pub fn last_round(&self) -> u32 {
        self.rounds.last().copied().unwrap_or(0)
    }

    /// Seen often enough to call it a habit.
    pub fn strong(&self) -> bool {
        self.occurrences >= 3
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum Habit {
    /// I keep walking into the same enemy setup.
    RepeatTrigger {
        key: String,
        agent_name: String,
        ability_name: String,
        kind: Option<AbilityKind>,
        location: String,
        count: u32,
        rounds: Vec<u32>,
    },
    /// I keep dying at the same place.
    RepeatDeath { location: String, count: u32, rounds: Vec<u32> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Severity {
    Warning,
    Info,
    Success,
}

/// One piece of advice. `id` is stable for the same advice in the same round, so the interface can tell what is new.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Insight {
    pub id: String,
    pub round: u32,
    pub severity: Severity,
    #[serde(flatten)]
    pub body: InsightBody,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum InsightBody {
    /// Seen twice: maybe a habit.
    PatternForming {
        agent_name: String,
        ability_name: String,
        kind: Option<AbilityKind>,
        location: String,
        occurrences: u32,
        rounds: Vec<u32>,
    },
    /// Seen three times or more and still in use.
    PatternStrong {
        agent_name: String,
        ability_name: String,
        kind: Option<AbilityKind>,
        location: String,
        occurrences: u32,
        streak: u32,
        hits: u32,
        typical_time: Option<u32>,
    },
    /// The usual setup was not there this round.
    PatternChanged {
        agent_name: String,
        ability_name: String,
        kind: Option<AbilityKind>,
        location: String,
        occurrences: u32,
        moved_to: Option<String>,
    },
    /// I dodged a setup Nook had seen before.
    GoodAdaptation {
        agent_name: String,
        ability_name: String,
        kind: Option<AbilityKind>,
        location: String,
        occurrences: u32,
    },
    Habit {
        habit: Habit,
    },
}

/// General knowledge for an enemy agent in this match, not something seen in it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralTip {
    pub agent_name: String,
    pub ability_name: String,
    pub kind: AbilityKind,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Analysis {
    pub patterns: Vec<Pattern>,
    pub habits: Vec<Habit>,
    /// Newest first.
    pub insights: Vec<Insight>,
    pub general: Vec<GeneralTip>,
}

/// Events below this confidence are kept in memory but do not count toward a pattern.
pub const MIN_CONFIDENCE: f32 = 0.5;

fn counts(e: &MatchEvent) -> bool {
    e.confidence >= MIN_CONFIDENCE
}

fn median(mut values: Vec<u32>) -> Option<u32> {
    if values.is_empty() {
        return None;
    }
    values.sort_unstable();
    Some(values[values.len() / 2])
}

/// The spelling of a place that was used most (the first one on a tie).
fn usual_spelling<'a>(names: impl Iterator<Item = &'a str>) -> String {
    let mut tally: Vec<(&str, u32)> = vec![];
    for name in names {
        match tally.iter_mut().find(|(n, _)| *n == name) {
            Some((_, c)) => *c += 1,
            None => tally.push((name, 1)),
        }
    }
    let mut best: Option<(&str, u32)> = None;
    for (name, count) in tally {
        if best.is_none_or(|(_, c)| count > c) {
            best = Some((name, count));
        }
    }
    best.map(|(n, _)| n.to_string()).unwrap_or_default()
}

fn streak(rounds: &[u32]) -> u32 {
    let mut n = 0;
    let mut expected = rounds.last().copied();
    for r in rounds.iter().rev() {
        if Some(*r) != expected {
            break;
        }
        n += 1;
        expected = r.checked_sub(1);
    }
    n
}

/// Every enemy setup of the match, strongest first.
pub fn patterns(m: &Match) -> Vec<Pattern> {
    let mut groups: BTreeMap<String, Vec<&MatchEvent>> = BTreeMap::new();
    for e in m.events().filter(|e| e.kind == EventKind::Utility && e.side == Side::Enemy && counts(e)) {
        if let Some(key) = e.setup_key() {
            groups.entry(key).or_default().push(e);
        }
    }
    let mut out: Vec<Pattern> = groups
        .into_iter()
        .map(|(key, events)| {
            let agent = events[0].agent.clone().unwrap_or_default();
            let ability = events[0].ability.clone().unwrap_or_default();
            let (agent_name, ability_name) = catalog::names(&agent, &ability);
            let mut rounds: Vec<u32> = events.iter().map(|e| e.round).collect();
            rounds.sort_unstable();
            rounds.dedup();
            let occurrences = rounds.len() as u32;
            let mean_confidence = events.iter().map(|e| e.confidence).sum::<f32>() / events.len() as f32;
            let confidence = match occurrences {
                n if n >= 3 && mean_confidence >= 0.7 => Confidence::High,
                n if n >= 2 => Confidence::Medium,
                _ => Confidence::Low,
            };
            let status = status_of(m, &agent, &ability, &key, *rounds.last().unwrap_or(&0));
            Pattern {
                kind: catalog::kind_of(&agent, &ability),
                location: usual_spelling(events.iter().map(|e| e.location.as_str())),
                streak: streak(&rounds),
                typical_time: median(events.iter().filter_map(|e| e.round_time).collect()),
                hits: events.iter().filter(|e| e.effect == Effect::Hit).map(|e| e.round).collect::<std::collections::BTreeSet<_>>().len()
                    as u32,
                avoided: events
                    .iter()
                    .filter(|e| e.effect == Effect::Avoided)
                    .map(|e| e.round)
                    .collect::<std::collections::BTreeSet<_>>()
                    .len() as u32,
                key,
                agent,
                agent_name,
                ability,
                ability_name,
                rounds,
                occurrences,
                confidence,
                status,
            }
        })
        .collect();
    out.sort_by(|a, b| b.occurrences.cmp(&a.occurrences).then(b.last_round().cmp(&a.last_round())).then(a.key.cmp(&b.key)));
    out
}

/// Did the enemy stop using this setup? Only rounds Nook actually watched (with at least one event) and that are
/// over count as proof: a round nobody looked at proves nothing, and the round in progress is not over yet.
fn status_of(m: &Match, agent: &str, ability: &str, key: &str, last: u32) -> PatternStatus {
    let watched_since: Vec<u32> = m.rounds.iter().filter(|r| r.number > last && r.closed && r.observed()).map(|r| r.number).collect();
    match watched_since.as_slice() {
        [] => PatternStatus::Active,
        [round] => {
            let moved_to = m
                .round(*round)
                .into_iter()
                .flat_map(|r| r.events.iter())
                .find(|e| {
                    e.side == Side::Enemy
                        && e.agent.as_deref() == Some(agent)
                        && e.ability.as_deref() == Some(ability)
                        && e.setup_key().as_deref() != Some(key)
                })
                .map(|e| e.location.clone());
            PatternStatus::Changed { round: *round, moved_to }
        }
        [first, ..] => PatternStatus::Stale { since: *first },
    }
}

pub fn habits(m: &Match, patterns: &[Pattern]) -> Vec<Habit> {
    let mut out: Vec<Habit> = patterns
        .iter()
        .filter(|p| p.hits >= 2)
        .map(|p| {
            let mut rounds: Vec<u32> = m
                .events()
                .filter(|e| e.effect == Effect::Hit && e.setup_key().as_deref() == Some(p.key.as_str()))
                .map(|e| e.round)
                .collect();
            rounds.dedup();
            Habit::RepeatTrigger {
                key: p.key.clone(),
                agent_name: p.agent_name.clone(),
                ability_name: p.ability_name.clone(),
                kind: p.kind,
                location: p.location.clone(),
                count: p.hits,
                rounds,
            }
        })
        .collect();
    let mut deaths: BTreeMap<String, Vec<&MatchEvent>> = BTreeMap::new();
    for e in m.events().filter(|e| e.kind == EventKind::Death && e.side == Side::Me && counts(e)) {
        deaths.entry(catalog::location_key(&e.location)).or_default().push(e);
    }
    for events in deaths.values() {
        let mut rounds: Vec<u32> = events.iter().map(|e| e.round).collect();
        rounds.dedup();
        if rounds.len() >= 2 {
            out.push(Habit::RepeatDeath {
                location: usual_spelling(events.iter().map(|e| e.location.as_str())),
                count: rounds.len() as u32,
                rounds,
            });
        }
    }
    out
}

fn habit_round(h: &Habit) -> u32 {
    match h {
        Habit::RepeatTrigger { rounds, .. } | Habit::RepeatDeath { rounds, .. } => rounds.last().copied().unwrap_or(0),
    }
}

fn habit_key(h: &Habit) -> String {
    match h {
        Habit::RepeatTrigger { key, count, .. } => format!("trigger:{key}:{count}"),
        Habit::RepeatDeath { location, count, .. } => format!("death:{}:{count}", catalog::location_key(location)),
    }
}

/// The advice for this match, newest first.
pub fn insights(m: &Match, patterns: &[Pattern], habits: &[Habit]) -> Vec<Insight> {
    let mut out = vec![];
    for p in patterns {
        let (agent_name, ability_name, kind, location) = (p.agent_name.clone(), p.ability_name.clone(), p.kind, p.location.clone());
        match &p.status {
            PatternStatus::Changed { round, moved_to } if p.occurrences >= 2 => out.push(Insight {
                id: format!("changed:{}:{round}", p.key),
                round: *round,
                severity: Severity::Warning,
                body: InsightBody::PatternChanged {
                    agent_name,
                    ability_name,
                    kind,
                    location,
                    occurrences: p.occurrences,
                    moved_to: moved_to.clone(),
                },
            }),
            PatternStatus::Active if p.strong() => out.push(Insight {
                id: format!("strong:{}:{}", p.key, p.occurrences),
                round: p.last_round(),
                severity: Severity::Warning,
                body: InsightBody::PatternStrong {
                    agent_name,
                    ability_name,
                    kind,
                    location,
                    occurrences: p.occurrences,
                    streak: p.streak,
                    hits: p.hits,
                    typical_time: p.typical_time,
                },
            }),
            PatternStatus::Active if p.occurrences == 2 => out.push(Insight {
                id: format!("forming:{}", p.key),
                round: p.last_round(),
                severity: Severity::Info,
                body: InsightBody::PatternForming { agent_name, ability_name, kind, location, occurrences: 2, rounds: p.rounds.clone() },
            }),
            _ => {}
        }
        // Dodging a setup Nook had already seen at least once before that round.
        for e in m.events().filter(|e| e.effect == Effect::Avoided && e.setup_key().as_deref() == Some(p.key.as_str())) {
            let before = p.rounds.iter().filter(|r| **r < e.round).count();
            if before >= 1 {
                out.push(Insight {
                    id: format!("avoided:{}:{}", p.key, e.round),
                    round: e.round,
                    severity: Severity::Success,
                    body: InsightBody::GoodAdaptation {
                        agent_name: p.agent_name.clone(),
                        ability_name: p.ability_name.clone(),
                        kind: p.kind,
                        location: p.location.clone(),
                        occurrences: p.rounds.iter().filter(|r| **r <= e.round).count() as u32,
                    },
                });
            }
        }
    }
    for h in habits {
        out.push(Insight {
            id: habit_key(h),
            round: habit_round(h),
            severity: Severity::Warning,
            body: InsightBody::Habit { habit: h.clone() },
        });
    }
    let rank = |s: Severity| match s {
        Severity::Warning => 0,
        Severity::Success => 1,
        Severity::Info => 2,
    };
    out.sort_by(|a, b| b.round.cmp(&a.round).then(rank(a.severity).cmp(&rank(b.severity))).then(a.id.cmp(&b.id)));
    out
}

/// General knowledge about the enemy agents in this match: their traps, flashes, and recon, the things worth
/// expecting before Nook has seen them.
pub fn general(m: &Match) -> Vec<GeneralTip> {
    m.enemy_agents()
        .iter()
        .filter_map(|id| catalog::agent(id))
        .flat_map(|a| {
            a.abilities
                .iter()
                .filter(|b| matches!(b.kind, AbilityKind::Trap | AbilityKind::Flash | AbilityKind::Recon))
                .map(|b| GeneralTip { agent_name: a.name.into(), ability_name: b.name.into(), kind: b.kind })
        })
        .collect()
}

pub fn analyze(m: &Match) -> Analysis {
    let patterns = patterns(m);
    let habits = habits(m, &patterns);
    let insights = insights(m, &patterns, &habits);
    Analysis { general: general(m), insights, habits, patterns }
}

/// The patterns in a few lines for the brain, so a screenshot is read with the match so far in mind.
pub fn memory_brief(m: &Match, patterns: &[Pattern]) -> String {
    let mut lines = vec![format!("Round now: {}.", m.current_round())];
    if let Some(map) = &m.map {
        lines.push(format!("Map: {map}."));
    }
    let enemies: Vec<String> = m.enemy_agents().iter().map(|id| catalog::names(id, "").0).collect();
    if !enemies.is_empty() {
        lines.push(format!("Enemy agents seen: {}.", enemies.join(", ")));
    }
    for p in patterns.iter().take(8) {
        lines.push(format!("Known setup: {} {} at {} (rounds {:?}).", p.agent_name, p.ability_name, p.location, p.rounds));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::games::valorant::memory::EventInput;
    use chrono::Utc;

    fn utility(agent: &str, ability: &str, location: &str, effect: Effect, time: Option<u32>) -> EventInput {
        EventInput {
            agent: Some(agent.into()),
            ability: Some(ability.into()),
            location: location.into(),
            effect,
            round_time: time,
            confidence: Some(0.9),
            ..Default::default()
        }
    }

    /// Plays `rounds` rounds; each closure call adds that round's events.
    fn play(rounds: u32, mut each: impl FnMut(u32) -> Vec<EventInput>) -> Match {
        let now = Utc::now();
        let mut m = Match::new(Some("Sunset".into()), Some("Jett".into()), now);
        for r in 1..=rounds {
            m.advance_to(r, now);
            for mut e in each(r) {
                e.round = Some(r);
                m.record(e, now);
            }
        }
        m
    }

    fn cypher_trip(effect: Effect) -> EventInput {
        utility("Cypher", "Tripwire", "B Main", effect, None)
    }

    #[test]
    fn a_reused_trip_becomes_a_pattern_round_by_round() {
        let one = play(1, |_| vec![cypher_trip(Effect::Hit)]);
        let p = &patterns(&one)[0];
        assert_eq!((p.occurrences, p.confidence), (1, Confidence::Low));
        assert!(insights(&one, &patterns(&one), &[]).is_empty());

        let two = play(2, |_| vec![cypher_trip(Effect::Hit)]);
        let p = &patterns(&two)[0];
        assert_eq!((p.occurrences, p.rounds.clone(), p.confidence), (2, vec![1, 2], Confidence::Medium));
        assert!(analyze(&two).insights.iter().any(|i| matches!(i.body, InsightBody::PatternForming { .. })));

        let three = play(3, |_| vec![cypher_trip(Effect::Hit)]);
        let a = analyze(&three);
        let p = &a.patterns[0];
        assert_eq!((p.occurrences, p.streak, p.hits, p.confidence), (3, 3, 3, Confidence::High));
        assert_eq!(p.location, "B Main");
        assert_eq!(p.ability_name, "Trapwire");
        assert!(a
            .insights
            .iter()
            .any(|i| matches!(&i.body, InsightBody::PatternStrong { hits: 3, agent_name, .. } if agent_name == "Cypher")));
        assert!(a.habits.iter().any(|h| matches!(h, Habit::RepeatTrigger { count: 3, .. })));
    }

    #[test]
    fn a_moved_trip_is_called_out_instead_of_the_old_one() {
        let m = play(6, |r| {
            let mut events = vec![utility("Skye", "Guiding Light", "A Main", Effect::Seen, Some(6))];
            events.push(if r <= 5 { cypher_trip(Effect::Hit) } else { utility("Cypher", "Trapwire", "B Market", Effect::Seen, None) });
            events
        });
        // Round 6 is still running: nothing is proven yet.
        let b_main = patterns(&m).into_iter().find(|p| p.location == "B Main").unwrap();
        assert_eq!(b_main.status, PatternStatus::Active);

        let mut m = m;
        m.advance_to(7, Utc::now());
        let a = analyze(&m);
        let b_main = a.patterns.iter().find(|p| p.location == "B Main").unwrap();
        assert_eq!(b_main.status, PatternStatus::Changed { round: 6, moved_to: Some("B Market".into()) });
        assert!(a.insights.iter().any(|i| matches!(&i.body, InsightBody::PatternChanged { moved_to: Some(to), .. } if to == "B Market")));
        assert!(!a.insights.iter().any(|i| matches!(&i.body, InsightBody::PatternStrong { location, .. } if location == "B Main")));
    }

    #[test]
    fn a_round_nobody_watched_does_not_break_a_pattern() {
        let mut m = play(3, |_| vec![cypher_trip(Effect::Seen)]);
        m.advance_to(6, Utc::now());
        assert_eq!(patterns(&m)[0].status, PatternStatus::Active);
    }

    #[test]
    fn a_setup_missing_for_several_rounds_is_history() {
        let mut m = play(5, |r| {
            if r <= 2 {
                vec![cypher_trip(Effect::Seen)]
            } else {
                vec![utility("Sova", "Recon Bolt", "A Site", Effect::Seen, None)]
            }
        });
        m.advance_to(6, Utc::now());
        let trip = patterns(&m).into_iter().find(|p| p.agent == "cypher").unwrap();
        assert_eq!(trip.status, PatternStatus::Stale { since: 3 });
    }

    #[test]
    fn skye_flash_with_timing_and_a_good_dodge() {
        let m = play(4, |r| {
            let effect = if r == 4 { Effect::Avoided } else { Effect::Hit };
            vec![utility("Skye", "flash", "A Main", effect, Some(5 + r % 2 * 2))]
        });
        let a = analyze(&m);
        let p = &a.patterns[0];
        assert_eq!((p.ability_name.as_str(), p.occurrences, p.avoided), ("Guiding Light", 4, 1));
        assert_eq!(p.typical_time, Some(7));
        let first = &a.insights[0];
        assert_eq!(first.round, 4);
        assert!(a.insights.iter().any(|i| matches!(&i.body, InsightBody::GoodAdaptation { occurrences: 4, .. })));
    }

    #[test]
    fn unsure_reads_do_not_make_a_pattern() {
        let m = play(3, |_| {
            let mut e = cypher_trip(Effect::Seen);
            e.confidence = Some(0.3);
            vec![e]
        });
        assert!(patterns(&m).is_empty());
        assert_eq!(m.events().count(), 3);
    }

    #[test]
    fn repeated_deaths_are_a_habit_and_general_tips_follow_the_enemies() {
        let m = play(3, |r| {
            let mut v = vec![EventInput { kind: EventKind::Death, side: Side::Me, location: "Mid".into(), ..Default::default() }];
            if r == 1 {
                v.push(cypher_trip(Effect::Seen));
            }
            v
        });
        let a = analyze(&m);
        assert!(a.habits.iter().any(|h| matches!(h, Habit::RepeatDeath { count: 3, .. })));
        let tips: Vec<_> = a.general.iter().map(|t| t.ability_name.as_str()).collect();
        assert_eq!(tips, ["Trapwire", "Spycam"]);
    }

    #[test]
    fn works_for_any_agent_in_the_catalog() {
        for agent in catalog::AGENTS {
            let ability = agent.abilities[0];
            let m = play(3, |_| vec![utility(agent.name, ability.name, "A Long", Effect::Seen, None)]);
            assert_eq!(patterns(&m)[0].occurrences, 3, "{}", agent.name);
        }
    }
}
