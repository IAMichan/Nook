//! "Automatic" under the composer's "Runs on" (`MachineBalance` on the Mac; t3code's "Auto balance"): Nook picks where
//! a new session of a project runs, this computer or one of your machines over SSH. Pure, so it is tested apart.
//!
//! A project is shared with a machine once a session of it ran there: the machine keeps the project's folder there
//! (`RemoteMachine::project_folders`). Among this computer and the shared machines that answered and have the agent,
//! the place with the fewest working sessions for its weight wins. Levels: Prefer (weight 4), Normal (2), Less often
//! (1), Manual only (never picked automatically). A tie goes to this computer, then to the machine listed first. With
//! no place left, the session starts on this computer.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BalanceLevel {
    Prefer,
    #[default]
    Normal,
    LessOften,
    ManualOnly,
}

impl BalanceLevel {
    /// Its share of the work: a place with twice the weight takes twice the sessions before another is picked.
    pub fn weight(self) -> u32 {
        match self {
            Self::Prefer => 4,
            Self::Normal => 2,
            Self::LessOften => 1,
            Self::ManualOnly => 0,
        }
    }
}

/// One place a session could run: this computer (`machine_id` `None`) or a machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub machine_id: Option<String>,
    pub level: BalanceLevel,
    /// Sessions that work there now.
    pub active: u32,
    /// It answered, has the agent and, for a machine, knows the project's folder.
    pub available: bool,
}

/// The place to start on: `None` is this computer, else the machine's id.
pub fn pick(candidates: &[Candidate]) -> Option<String> {
    candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| c.available && c.level.weight() > 0)
        // Fewest sessions for its weight (a/b < c/d ⇔ a·d < c·b), then this computer, then the order given.
        .min_by(|(i, a), (j, b)| {
            (a.active * b.level.weight())
                .cmp(&(b.active * a.level.weight()))
                .then_with(|| b.machine_id.is_none().cmp(&a.machine_id.is_none()))
                .then_with(|| i.cmp(j))
        })
        .and_then(|(_, c)| c.machine_id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn place(id: Option<&str>, level: BalanceLevel, active: u32, available: bool) -> Candidate {
        Candidate { machine_id: id.map(String::from), level, active, available }
    }

    #[test]
    fn the_least_busy_place_for_its_weight_wins() {
        use BalanceLevel::*;
        assert_eq!(pick(&[place(None, Normal, 2, true), place(Some("box"), Prefer, 3, true)]).as_deref(), Some("box"));
        assert_eq!(pick(&[place(None, Normal, 1, true), place(Some("box"), LessOften, 1, true)]), None);
        assert_eq!(pick(&[place(None, Normal, 3, true), place(Some("box"), LessOften, 1, true)]).as_deref(), Some("box"));
    }

    #[test]
    fn a_tie_stays_here_then_goes_in_order() {
        use BalanceLevel::*;
        assert_eq!(pick(&[place(Some("a"), Normal, 0, true), place(None, Normal, 0, true)]), None);
        assert_eq!(
            pick(&[place(None, Normal, 1, true), place(Some("a"), Normal, 0, true), place(Some("b"), Normal, 0, true)]).as_deref(),
            Some("a")
        );
    }

    #[test]
    fn manual_only_and_unavailable_places_are_never_picked() {
        use BalanceLevel::*;
        assert_eq!(pick(&[place(None, ManualOnly, 0, true), place(Some("a"), ManualOnly, 0, true)]), None);
        assert_eq!(pick(&[place(None, ManualOnly, 0, true), place(Some("a"), Normal, 5, true)]).as_deref(), Some("a"));
        assert_eq!(pick(&[place(None, Normal, 9, true), place(Some("a"), Prefer, 0, false)]), None);
    }

    #[test]
    fn levels_read_and_unknown_ones_fall_back() {
        let m: super::super::remote::RemoteMachine =
            serde_json::from_str(r#"{"name":"b","host":"h","balance":"lessOften","projectFolders":{"/me/app":"~/app"}}"#).unwrap();
        assert_eq!(m.balance_level(), BalanceLevel::LessOften);
        assert_eq!(m.folder_for("/me/app/"), Some("~/app"));
        let newer: super::super::remote::RemoteMachine = serde_json::from_str(r#"{"name":"b","host":"h","balance":"sometimes"}"#).unwrap();
        assert_eq!(newer.balance_level(), BalanceLevel::Normal);
    }
}
