//! The Valorant coach: general knowledge ([`catalog`]), the memory of the match in progress ([`memory`]), the
//! analysis that looks back through it ([`coach`]), and reading a screenshot ([`observe`]).

pub mod catalog;
pub mod coach;
pub mod memory;
pub mod observe;

use chrono::{DateTime, Utc};

use memory::Match;
use observe::Observation;

pub const GAME_ID: &str = "valorant";
pub const PROCESSES: &[&str] = &["valorant-win64-shipping.exe", "valorant.exe"];

/// Puts what a screenshot showed into the match: the round moves on, map and agent fill in, events are remembered.
/// Returns how many events it added or confirmed.
pub fn apply(m: &mut Match, observation: Observation, now: DateTime<Utc>) -> usize {
    if !observation.in_game {
        return 0;
    }
    if let Some(round) = observation.round {
        m.advance_to(round, now);
    }
    if m.map.is_none() {
        m.map = observation.map;
    }
    if m.my_agent.is_none() {
        m.my_agent = observation.my_agent;
    }
    observation.events.into_iter().filter_map(|e| m.record(e, now)).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn three_screenshots_over_three_rounds_make_a_habit() {
        let now = Utc::now();
        let mut m = Match::new(None, None, now);
        for round in 1..=3 {
            let answer = format!(
                r#"{{"inGame": true, "map": "Sunset", "round": {round}, "events": [
                    {{"agent": "Cypher", "ability": "Trapwire", "location": "B Main", "effect": "hit", "confidence": 0.9}}]}}"#
            );
            // The same screenshot read twice in a round counts once.
            apply(&mut m, observe::parse(&answer).unwrap(), now);
            apply(&mut m, observe::parse(&answer).unwrap(), now);
        }
        assert_eq!(m.map.as_deref(), Some("Sunset"));
        let a = coach::analyze(&m);
        assert_eq!(a.patterns[0].occurrences, 3);
        assert_eq!(a.patterns[0].hits, 3);
    }
}
