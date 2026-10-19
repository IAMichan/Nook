//! Eén lijst van agentsessies (`AgentSessionRegistry` op de Mac). Vier bronnen kennen sessies: hooks (status en
//! goedkeuringen), de proceslijst (draait, niet gekoppeld), transcripten (eerdere gesprekken) en de sessies die Nook
//! zelf draait. [`merge`] maakt er één lijst van waarin elk gesprek één keer staat, en twee processen in één map
//! twee rijen blijven.

use std::collections::{BTreeSet, HashMap};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Rijkere bronnen winnen als hetzelfde gesprek uit meerdere bekend is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Transcript,
    Process,
    Hook,
    Nook,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    /// Wacht op een antwoord of goedkeuring.
    NeedsYou,
    Working,
    Idle,
    Failed,
    Finished,
}

/// Waar de rij in de lijst hoort.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Section {
    NeedsYou,
    Active,
    InNook,
    Earlier,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecord {
    pub id: String,
    pub sources: BTreeSet<Source>,
    pub agent: String,
    pub account_home: String,
    pub conversation_id: String,
    pub pid: Option<u32>,
    pub cwd: String,
    pub title: String,
    pub phase: Phase,
    pub updated: DateTime<Utc>,
}

impl SessionRecord {
    pub fn leading(&self) -> Source {
        self.sources.iter().max().copied().unwrap_or(Source::Transcript)
    }

    /// Loopt het gesprek nu (in tegenstelling tot een verslag van een gesprek dat voorbij is)?
    pub fn is_live(&self) -> bool {
        self.sources.contains(&Source::Hook)
            || self.sources.contains(&Source::Process)
            || (self.sources.contains(&Source::Nook) && self.phase != Phase::Finished)
    }

    pub fn section(&self) -> Section {
        if self.phase == Phase::NeedsYou || self.phase == Phase::Failed && self.is_live() {
            return Section::NeedsYou;
        }
        if self.is_live() && self.phase == Phase::Working {
            return Section::Active;
        }
        if self.sources.contains(&Source::Nook) && self.phase != Phase::Finished {
            return Section::InNook;
        }
        if self.is_live() {
            return Section::Active;
        }
        Section::Earlier
    }

    pub fn conversation_key(&self) -> Option<String> {
        (!self.conversation_id.is_empty()).then(|| format!("{}|{}|{}", self.agent, self.account_home, self.conversation_id))
    }
}

pub fn merge(records: Vec<SessionRecord>) -> Vec<SessionRecord> {
    let mut by_conversation: HashMap<String, SessionRecord> = HashMap::new();
    let mut order: Vec<String> = vec![];
    let mut processes: Vec<SessionRecord> = vec![];
    for record in records {
        if let Some(key) = record.conversation_key() {
            if let Some(existing) = by_conversation.remove(&key) {
                by_conversation.insert(key, fold(existing, record));
            } else {
                by_conversation.insert(key.clone(), record);
                order.push(key);
            }
        } else if record.sources.len() == 1 && record.sources.contains(&Source::Process) {
            processes.push(record);
        } else {
            // Alleen bekend op id (een hook zonder gesprek-id): een eigen rij.
            order.push(record.id.clone());
            by_conversation.insert(record.id.clone(), record);
        }
    }
    let merged: Vec<SessionRecord> = order.into_iter().filter_map(|k| by_conversation.remove(&k)).collect();
    // Een proces staat er al als een lopende sessie met hooks of van Nook in dezelfde map met dezelfde agent werkt.
    let mut covered: HashMap<String, usize> = HashMap::new();
    for r in merged.iter().filter(|r| r.is_live() && (r.sources.contains(&Source::Hook) || r.sources.contains(&Source::Nook))) {
        *covered.entry(format!("{}|{}", r.agent, r.cwd)).or_default() += 1;
    }
    processes.sort_by_key(|p| p.pid.unwrap_or(0));
    let mut remaining = vec![];
    for p in processes {
        match covered.get_mut(&format!("{}|{}", p.agent, p.cwd)) {
            Some(count) if *count > 0 => *count -= 1,
            _ => remaining.push(p),
        }
    }
    let mut all: Vec<SessionRecord> = merged.into_iter().chain(remaining).collect();
    all.sort_by(|a, b| a.section().cmp(&b.section()).then(b.updated.cmp(&a.updated)));
    all
}

fn fold(a: SessionRecord, b: SessionRecord) -> SessionRecord {
    let updated = a.updated.max(b.updated);
    let sources: BTreeSet<Source> = a.sources.union(&b.sources).copied().collect();
    let (mut lead, other) = if a.leading() >= b.leading() { (a, b) } else { (b, a) };
    lead.sources = sources;
    if lead.title.is_empty() {
        lead.title = other.title;
    }
    if lead.cwd.is_empty() {
        lead.cwd = other.cwd;
    }
    if lead.pid.is_none() {
        lead.pid = other.pid;
    }
    lead.updated = updated;
    lead
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn record(
        id: &str,
        sources: &[Source],
        conversation: &str,
        pid: Option<u32>,
        cwd: &str,
        phase: Phase,
        home: &str,
        updated: i64,
    ) -> SessionRecord {
        SessionRecord {
            id: id.into(),
            sources: sources.iter().copied().collect(),
            agent: "Claude Code".into(),
            account_home: home.into(),
            conversation_id: conversation.into(),
            pid,
            cwd: cwd.into(),
            title: id.into(),
            phase,
            updated: Utc.timestamp_opt(updated, 0).unwrap(),
        }
    }

    fn r(id: &str, sources: &[Source], conversation: &str, phase: Phase) -> SessionRecord {
        record(id, sources, conversation, None, "/work/app", phase, "", 100)
    }

    #[test]
    fn same_conversation_from_hook_transcript_and_run_is_one_row() {
        let merged = merge(vec![
            r("hook", &[Source::Hook], "abc", Phase::Working),
            record("past", &[Source::Transcript], "abc", None, "/work/app", Phase::Finished, "", 50),
            r("run", &[Source::Nook], "abc", Phase::Working),
        ]);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].sources.len(), 3);
        assert_eq!(merged[0].leading(), Source::Nook);
    }

    #[test]
    fn same_conversation_in_two_accounts_stays_two_rows() {
        let merged = merge(vec![
            r("a", &[Source::Transcript], "abc", Phase::Finished),
            record("b", &[Source::Transcript], "abc", None, "/work/app", Phase::Finished, "/x/.claude-work", 100),
        ]);
        assert_eq!(merged.len(), 2);
    }

    #[test]
    fn processes() {
        let p = |id: &str, pid, cwd: &str| record(id, &[Source::Process], "", Some(pid), cwd, Phase::Idle, "", 100);
        assert_eq!(merge(vec![p("p1", 10, "/work/app"), p("p2", 11, "/work/app")]).len(), 2);
        let merged = merge(vec![r("hook", &[Source::Hook], "abc", Phase::Working), p("p1", 10, "/work/app"), p("p2", 11, "/work/app")]);
        let mut ids: Vec<_> = merged.iter().map(|m| m.id.clone()).collect();
        ids.sort();
        assert_eq!(ids, vec!["hook", "p2"]);
        assert_eq!(merge(vec![r("hook", &[Source::Hook], "abc", Phase::Working), p("p1", 10, "/other")]).len(), 2);
    }

    #[test]
    fn sections_and_order() {
        let live = merge(vec![r("hook", &[Source::Hook], "abc", Phase::Working), r("past", &[Source::Transcript], "abc", Phase::Finished)]);
        assert_eq!(live.len(), 1);
        assert_eq!(live[0].section(), Section::Active);
        let merged = merge(vec![
            record("old", &[Source::Transcript], "1", None, "/w", Phase::Finished, "", 10),
            record("busy", &[Source::Hook], "2", None, "/w", Phase::Working, "", 20),
            record("asks", &[Source::Hook], "3", None, "/w", Phase::NeedsYou, "", 5),
            record("mine", &[Source::Nook], "4", None, "/w", Phase::Idle, "", 30),
        ]);
        assert_eq!(merged.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), vec!["asks", "busy", "mine", "old"]);
        assert_eq!(
            merged.iter().map(|m| m.section()).collect::<Vec<_>>(),
            vec![Section::NeedsYou, Section::Active, Section::InNook, Section::Earlier]
        );
    }
}
