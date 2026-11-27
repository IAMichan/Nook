//! Live progress of a new worktree being set up (`WorktreeSetupProgress` on macOS, AG-94 / #1518).
//!
//! Tracks the four real steps between starting a session in a new worktree and the agent's first output:
//! 1. `FetchBase`: `git fetch` of a remote-tracking base (`origin/main`) with a 5-second cap.
//! 2. `CheckOut`: `git worktree add` to materialize the new branch and files.
//! 3. `RunSetup`: `runOnWorktreeCreate` scripts from `nook.json` (background or blocking with `async: false`).
//! 4. `StartAgent`: starting the agent process until its first output arrives.
//!
//! Lives in memory only: once the agent begins answering, the checklist disappears.

use std::collections::BTreeMap;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::i18n::{tr, trf};

/// Maximum time a new session waits for `git fetch` of a remote-tracking base branch before proceeding from the
/// last fetched state (`WorkspaceManager.startFetchTimeout` on macOS).
pub const START_FETCH_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a remote-tracking base fetch stays fresh per repository and base branch (2 minutes).
pub const REMOTE_BASE_REFRESH_TTL: Duration = Duration::from_secs(120);

/// One step in the worktree setup checklist, in execution order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SetupStep {
    FetchBase,
    CheckOut,
    RunSetup,
    StartAgent,
}

impl SetupStep {
    pub const ALL: [SetupStep; 4] = [Self::FetchBase, Self::CheckOut, Self::RunSetup, Self::StartAgent];
}

/// Live state of a single setup step.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StepState {
    Pending,
    Running { since: DateTime<Utc> },
    Done { seconds: f64 },
    Skipped,
    Failed { message: String },
}

/// A human-readable detail line shown under "Details" in the checklist.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupNote {
    pub id: usize,
    pub step: SetupStep,
    pub text: String,
}

/// What fetching a remote-tracking base came to (`RemoteBaseRefresh` on macOS).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteBaseRefresh {
    /// Fetched just now.
    Fetched,
    /// A local base, or a remote this repository does not have: nothing to fetch.
    Local,
    /// The fetch failed (offline, timeout, no access): the worktree starts from the last fetched state.
    Failed(String),
}

/// Step-by-step progress of setting up a new worktree session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeSetupProgress {
    pub states: BTreeMap<SetupStep, StepState>,
    pub notes: Vec<SetupNote>,
    pub started_at: DateTime<Utc>,
}

impl WorktreeSetupProgress {
    pub fn new(started_at: DateTime<Utc>) -> Self {
        let states = SetupStep::ALL.into_iter().map(|step| (step, StepState::Pending)).collect();
        Self { states, notes: Vec::new(), started_at }
    }

    pub fn state(&self, step: SetupStep) -> &StepState {
        self.states.get(&step).unwrap_or(&StepState::Pending)
    }

    pub fn is_running(&self, step: SetupStep) -> bool {
        matches!(self.state(step), StepState::Running { .. })
    }

    /// The step currently running, if any.
    pub fn current(&self) -> Option<SetupStep> {
        SetupStep::ALL.into_iter().find(|&step| self.is_running(step))
    }

    /// The first step that failed and its error message, if any.
    pub fn failure(&self) -> Option<(SetupStep, &str)> {
        for step in SetupStep::ALL {
            if let StepState::Failed { message } = self.state(step) {
                return Some((step, message.as_str()));
            }
        }
        None
    }

    /// True once every step is either done or skipped.
    pub fn is_complete(&self) -> bool {
        SetupStep::ALL.into_iter().all(|step| matches!(self.state(step), StepState::Done { .. } | StepState::Skipped))
    }

    pub fn begin(&mut self, step: SetupStep, now: DateTime<Utc>) {
        self.states.insert(step, StepState::Running { since: now });
    }

    /// Ends a running step and records its elapsed seconds (clamped to `>= 0`).
    pub fn finish(&mut self, step: SetupStep, now: DateTime<Utc>) {
        let seconds = match self.state(step) {
            StepState::Running { since } => {
                let ms = (now - *since).num_milliseconds();
                (ms.max(0) as f64) / 1000.0
            }
            _ => 0.0,
        };
        self.states.insert(step, StepState::Done { seconds });
    }

    pub fn skip(&mut self, step: SetupStep) {
        self.states.insert(step, StepState::Skipped);
    }

    /// Fails `step`; steps after it remain pending.
    pub fn fail(&mut self, step: SetupStep, message: impl Into<String>) {
        self.states.insert(step, StepState::Failed { message: message.into() });
    }

    pub fn note(&mut self, step: SetupStep, text: impl Into<String>) {
        let text = text.into();
        if text.is_empty() {
            return;
        }
        let id = self.notes.len();
        self.notes.push(SetupNote { id, step, text });
    }

    /// Records the result of `git.refresh_remote_base(...)` into `FetchBase` and adds its detail note.
    pub fn record_fetch(&mut self, result: &RemoteBaseRefresh, base: &str, now: DateTime<Utc>) {
        match result {
            RemoteBaseRefresh::Fetched => {
                self.finish(SetupStep::FetchBase, now);
                self.note(SetupStep::FetchBase, trf("Nieuwste {base} opgehaald", "Fetched the latest {base}", &[("base", &base)]));
            }
            RemoteBaseRefresh::Local => {
                self.skip(SetupStep::FetchBase);
                self.note(
                    SetupStep::FetchBase,
                    trf("{base} is een lokale branch: niets op te halen", "{base} is a local branch: nothing to fetch", &[("base", &base)]),
                );
            }
            RemoteBaseRefresh::Failed(message) => {
                // Offline or without access: the worktree starts from the last fetched state, so setup continues.
                self.finish(SetupStep::FetchBase, now);
                self.note(
                    SetupStep::FetchBase,
                    trf(
                        "{base} ophalen lukte niet, dus de worktree begint bij de laatst opgehaalde stand: {message}",
                        "Couldn't fetch {base}, so the worktree starts from the last fetched state: {message}",
                        &[("base", &base), ("message", &message.as_str())],
                    ),
                );
            }
        }
    }

    pub fn note_fetched_recently(&mut self, base: &str) {
        self.note(
            SetupStep::FetchBase,
            trf("{base} is minder dan twee minuten geleden opgehaald", "{base} was fetched less than two minutes ago", &[("base", &base)]),
        );
    }

    pub fn note_local_base(&mut self, base: &str) {
        self.note(
            SetupStep::FetchBase,
            trf("{base} is een lokale branch: niets op te halen", "{base} is a local branch: nothing to fetch", &[("base", &base)]),
        );
    }

    pub fn note_checkout(&mut self, branch: &str, base: &str, path: &str) {
        self.note(
            SetupStep::CheckOut,
            trf(
                "Branch {branch} vanaf {base} in {path}",
                "Branch {branch} from {base} in {path}",
                &[("branch", &branch), ("base", &base), ("path", &path)],
            ),
        );
        self.note(SetupStep::CheckOut, tr("Bestanden uitgecheckt door Git", "Files checked out by Git"));
    }

    pub fn note_no_script(&mut self) {
        self.note(
            SetupStep::RunSetup,
            tr("Geen setup-script in nook.json (runOnWorktreeCreate)", "No setup script in nook.json (runOnWorktreeCreate)"),
        );
    }

    pub fn note_script(&mut self, name: &str, async_run: bool) {
        if async_run {
            self.note(
                SetupStep::RunSetup,
                trf("{name} draait in een terminal naast de sessie", "{name} runs in a terminal beside the session", &[("name", &name)]),
            );
        } else {
            self.note(
                SetupStep::RunSetup,
                trf(
                    "{name} draait in een terminal; de agent wacht tot het klaar is",
                    "{name} runs in a terminal; the agent waits until it ends",
                    &[("name", &name)],
                ),
            );
        }
    }

    /// Formats a step duration the way macOS `WorktreeSetupProgress.duration(_:)` does:
    /// `"774ms"`, `"1.4s"`, `"2m 05s"`.
    pub fn format_duration(seconds: f64) -> String {
        let clamped = seconds.max(0.0);
        if clamped < 1.0 {
            return format!("{}ms", (clamped * 1000.0).round() as i64);
        }
        if clamped < 60.0 {
            return format!("{clamped:.1}s");
        }
        let whole = clamped.round() as i64;
        format!("{}m {:02}s", whole / 60, whole % 60)
    }
}

#[cfg(test)]
mod tests {
    use chrono::Duration as ChronoDuration;

    use super::*;

    #[test]
    fn steps_transition_and_measure_real_elapsed_time() {
        let start = Utc::now();
        let mut p = WorktreeSetupProgress::new(start);
        assert!(!p.is_complete());
        assert_eq!(p.current(), None);
        assert_eq!(p.failure(), None);

        p.begin(SetupStep::FetchBase, start);
        assert_eq!(p.current(), Some(SetupStep::FetchBase));
        let t1 = start + ChronoDuration::milliseconds(774);
        p.record_fetch(&RemoteBaseRefresh::Fetched, "origin/main", t1);
        assert_eq!(p.state(SetupStep::FetchBase), &StepState::Done { seconds: 0.774 });
        assert_eq!(p.notes.len(), 1);

        p.begin(SetupStep::CheckOut, t1);
        let t2 = t1 + ChronoDuration::milliseconds(1400);
        p.finish(SetupStep::CheckOut, t2);
        assert_eq!(p.state(SetupStep::CheckOut), &StepState::Done { seconds: 1.4 });

        p.skip(SetupStep::RunSetup);
        p.begin(SetupStep::StartAgent, t2);
        let t3 = t2 + ChronoDuration::seconds(2);
        p.finish(SetupStep::StartAgent, t3);
        assert!(p.is_complete());
    }

    #[test]
    fn failed_fetch_continues_while_failed_checkout_records_failure() {
        let start = Utc::now();
        let mut p = WorktreeSetupProgress::new(start);
        p.begin(SetupStep::FetchBase, start);
        p.record_fetch(&RemoteBaseRefresh::Failed("offline".into()), "origin/main", start + ChronoDuration::seconds(5));
        assert!(matches!(p.state(SetupStep::FetchBase), StepState::Done { .. }));
        assert_eq!(p.failure(), None);

        p.begin(SetupStep::CheckOut, start + ChronoDuration::seconds(5));
        p.fail(SetupStep::CheckOut, "branch exists");
        assert_eq!(p.failure(), Some((SetupStep::CheckOut, "branch exists")));
        assert!(!p.is_complete());
    }

    #[test]
    fn local_base_skips_fetch_step() {
        let start = Utc::now();
        let mut p = WorktreeSetupProgress::new(start);
        p.begin(SetupStep::FetchBase, start);
        p.record_fetch(&RemoteBaseRefresh::Local, "main", start);
        assert_eq!(p.state(SetupStep::FetchBase), &StepState::Skipped);
        assert_eq!(p.notes.len(), 1);
    }

    #[test]
    fn format_duration_matches_macos() {
        assert_eq!(WorktreeSetupProgress::format_duration(0.0), "0ms");
        assert_eq!(WorktreeSetupProgress::format_duration(0.774), "774ms");
        assert_eq!(WorktreeSetupProgress::format_duration(1.42), "1.4s");
        assert_eq!(WorktreeSetupProgress::format_duration(125.0), "2m 05s");
    }

    #[test]
    fn json_serialization_uses_camel_case_and_tagged_states() {
        let start = Utc::now();
        let mut p = WorktreeSetupProgress::new(start);
        p.skip(SetupStep::FetchBase);
        p.begin(SetupStep::CheckOut, start);
        p.note_no_script();
        let value = serde_json::to_value(&p).unwrap();
        assert_eq!(value["states"]["fetchBase"]["kind"], "skipped");
        assert_eq!(value["states"]["checkOut"]["kind"], "running");
        assert!(value["states"]["checkOut"]["since"].is_string());
        assert_eq!(value["notes"][0]["step"], "runSetup");
    }
}
