//! Quitting and opening Nook again (`QuitShutdown`, `RestartContinuation`, `RestartRequests` on the Mac). Quitting waits
//! for the agents Nook runs to exit (interrupt, then terminate after a grace, then kill at one shared deadline), so an
//! agent is never cut off while it writes its transcript. What a session waited on (a question) is saved with it and
//! comes back, and with "Continue after restart" on a session that quitting stopped goes on by itself once.

use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::models::{EventKind, RunEvent, RunStatus, WorkspaceRun};
use crate::agents::models::QuestionItem;

/// Continuations in a row, at most, within `LOOP_WINDOW`, so a session that keeps crashing Nook does not loop.
pub const LIMIT: u32 = 3;
/// Continuations count towards the cap only while they follow each other this closely.
pub const LOOP_WINDOW_SECONDS: i64 = 5 * 60;
/// A session cut off by anything but your quit goes on only when that was this recent.
pub const MAX_AGE_SECONDS: i64 = 30 * 60;
/// What the agent reads. A restart can cut a turn off after a command ran but before its result reached the agent, so it
/// is told to look before it repeats anything that changes state.
pub const MESSAGE: &str = "Continue where you left off. Nook restarted while you were working, so check the current state first \
(files, git status, what is still running) and do not repeat a step that changes something unless you are sure it did not finish.";

/// A question the agent asked before Nook quit (`SavedQuestion`): it comes back to be answered as a message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedQuestion {
    pub id: String,
    pub items: Vec<QuestionItem>,
    pub created: DateTime<Utc>,
}

/// What a session keeps for the next launch.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RestartState {
    /// Nook's last quit stopped this session: the next launch goes on with it however long Nook stayed closed, then
    /// clears this.
    pub stopped_by_quit: bool,
    /// The quit cut it off while it waited for your approval: that approval is gone, so Nook does not go on by itself.
    pub interrupted_while_waiting: bool,
    /// Times in a row Nook went on after a restart; back to zero after a turn that ends normally.
    pub continuations: u32,
    pub last_continued_at: Option<DateTime<Utc>>,
    /// The questions that waited on you.
    pub questions: Vec<SavedQuestion>,
    /// The approvals that waited on you, as a line each: they expire, and say so in the timeline.
    pub approvals: Vec<String>,
}

impl RestartState {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }
}

/// Continuations in a row that still count: none once the last one is older than the loop window.
pub fn chain_length(run: &WorkspaceRun, now: DateTime<Utc>) -> u32 {
    let count = run.restart.continuations;
    match run.restart.last_continued_at {
        Some(last) if count > 0 => {
            if (now - last).num_seconds() <= LOOP_WINDOW_SECONDS {
                count
            } else {
                0
            }
        }
        _ => count,
    }
}

/// Should this session get the continue message after Nook started? Never one you archived, settled or snoozed
/// (`skipped`), one that waits on a question, one that waited on an approval the restart cut off, or one stopped by a
/// usage limit (which has its own resume). A session your quit stopped goes on however long that took; any other only
/// when it was cut off just now.
pub fn should_continue(run: &WorkspaceRun, enabled: bool, has_pending_question: bool, skipped: bool, now: DateTime<Utc>) -> bool {
    if !enabled || run.archived || skipped || has_pending_question || run.restart.interrupted_while_waiting {
        return false;
    }
    if run.status != RunStatus::Stopped || run.status_detail.as_deref() != Some("interrupted") {
        return false;
    }
    if !run.restart.stopped_by_quit && (now - run.updated_at).num_seconds() > MAX_AGE_SECONDS {
        return false;
    }
    run.limited_at.is_none() && chain_length(run, now) < LIMIT
}

/// Whether the conversation's last turn had ended when Nook stopped: its result comes after your last message. The
/// timeline is saved as it comes and the session's status a moment later, so a crash in between leaves a finished turn
/// that reads as cut off; continuing it would send the agent back to work it already finished.
pub fn turn_ended(events: &[RunEvent]) -> bool {
    let Some(result) = events.iter().rposition(|e| e.kind == EventKind::Result) else { return false };
    match events.iter().rposition(|e| e.kind == EventKind::User) {
        Some(message) => result > message,
        None => true,
    }
}

/// Your answers as the message the agent gets: each question with what you chose or wrote. After a restart the agent no
/// longer waits for them, so the message says what they answer.
pub fn answer_message(items: &[QuestionItem], selections: &[Vec<String>], restored: bool) -> String {
    let lines = items
        .iter()
        .zip(selections.iter().chain(std::iter::repeat(&Vec::new())))
        .map(|(item, chosen)| format!("{} → {}", item.question, chosen.join(", ")))
        .collect::<Vec<_>>()
        .join("\n");
    if restored {
        format!("My answers to the questions you asked before Nook restarted:\n{lines}")
    } else {
        lines
    }
}

/// How the processes ended (`QuitShutdown.Outcome`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    NothingRunning,
    /// They all exited after the interrupt.
    Interrupted,
    /// Some needed a terminate, and all were gone by the deadline.
    Terminated,
    /// Some were still alive at the deadline and were killed.
    Killed,
}

/// The time agents get: a grace after the interrupt to save and exit on their own, and one deadline for all of them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Timing {
    pub grace: Duration,
    pub deadline: Duration,
    pub poll: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self { grace: Duration::from_secs(2), deadline: Duration::from_millis(4500), poll: Duration::from_millis(50) }
    }
}

/// Stops what runs and waits, at most `timing.deadline`: `interrupt` asks politely, `terminate` is the second ask after
/// the grace, `kill` the last at the deadline. `alive` says whether anything of them still runs. Blocks.
pub fn stop_all(
    running: usize,
    timing: Timing,
    interrupt: impl Fn(),
    alive: impl Fn() -> bool,
    terminate: impl Fn(),
    kill: impl Fn(),
    sleep: impl Fn(Duration),
    now: impl Fn() -> Instant,
) -> Outcome {
    if running == 0 {
        return Outcome::NothingRunning;
    }
    let start = now();
    interrupt();
    let wait = |limit: Duration| -> bool {
        loop {
            if !alive() {
                return true;
            }
            let spent = now().saturating_duration_since(start);
            if spent >= limit {
                return false;
            }
            sleep(timing.poll.min(limit - spent));
        }
    };
    if wait(timing.grace) {
        return Outcome::Interrupted;
    }
    terminate();
    if wait(timing.deadline.max(timing.grace)) {
        return Outcome::Terminated;
    }
    kill();
    Outcome::Killed
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    fn run(status: RunStatus, detail: Option<&str>) -> WorkspaceRun {
        let mut run = crate::workspace::models::tests::run(status);
        run.status_detail = detail.map(String::from);
        run
    }

    #[test]
    fn continues_only_what_a_quit_cut_off() {
        let now = Utc::now();
        let mut cut = run(RunStatus::Stopped, Some("interrupted"));
        cut.updated_at = now;
        assert!(should_continue(&cut, true, false, false, now));
        assert!(!should_continue(&cut, false, false, false, now), "the setting is off");
        assert!(!should_continue(&cut, true, true, false, now), "a question waits on you");
        assert!(!should_continue(&cut, true, false, true, now), "settled or snoozed");
        let mut archived = cut.clone();
        archived.archived = true;
        assert!(!should_continue(&archived, true, false, false, now));
        let mut waiting = cut.clone();
        waiting.restart.interrupted_while_waiting = true;
        assert!(!should_continue(&waiting, true, false, false, now), "its approval is gone");
        let mut limited = cut.clone();
        limited.limited_at = Some(now);
        assert!(!should_continue(&limited, true, false, false, now), "a limit has its own resume");
        assert!(!should_continue(&run(RunStatus::Stopped, None), true, false, false, now), "you stopped it");
        // Old: yours to pick up, unless your quit stopped it.
        let mut old = cut.clone();
        old.updated_at = now - chrono::Duration::hours(5);
        assert!(!should_continue(&old, true, false, false, now));
        old.restart.stopped_by_quit = true;
        assert!(should_continue(&old, true, false, false, now));
    }

    #[test]
    fn a_session_that_keeps_stopping_is_not_continued_forever() {
        let now = Utc::now();
        let mut cut = run(RunStatus::Stopped, Some("interrupted"));
        cut.updated_at = now;
        cut.restart.continuations = LIMIT;
        cut.restart.last_continued_at = Some(now - chrono::Duration::seconds(30));
        assert!(!should_continue(&cut, true, false, false, now));
        // The last one was long ago: the chain starts over.
        cut.restart.last_continued_at = Some(now - chrono::Duration::minutes(10));
        assert_eq!(chain_length(&cut, now), 0);
        assert!(should_continue(&cut, true, false, false, now));
    }

    #[test]
    fn reads_whether_the_turn_had_ended() {
        let event = |kind| RunEvent::new(kind, "x");
        assert!(!turn_ended(&[event(EventKind::User), event(EventKind::Assistant)]));
        assert!(turn_ended(&[event(EventKind::User), event(EventKind::Assistant), event(EventKind::Result)]));
        assert!(!turn_ended(&[event(EventKind::Result), event(EventKind::User)]));
    }

    #[test]
    fn answers_become_a_message_that_says_what_they_answer() {
        let item = QuestionItem { question: "Which one?".into(), header: String::new(), options: vec![], multi_select: false };
        assert_eq!(answer_message(&[item.clone()], &[vec!["A".into(), "B".into()]], false), "Which one? → A, B");
        assert!(answer_message(&[item], &[vec!["A".into()]], true).starts_with("My answers to the questions you asked before Nook restarted:\n"));
    }

    fn timed(alive_for: u64, timing: Timing) -> (Outcome, Vec<&'static str>) {
        let clock = Cell::new(0u64);
        let base = Instant::now();
        let calls = RefCell::new(Vec::new());
        let outcome = stop_all(
            2,
            timing,
            || calls.borrow_mut().push("interrupt"),
            || clock.get() < alive_for,
            || calls.borrow_mut().push("terminate"),
            || calls.borrow_mut().push("kill"),
            |d| clock.set(clock.get() + d.as_millis() as u64),
            || base + Duration::from_millis(clock.get()),
        );
        (outcome, calls.into_inner())
    }

    #[test]
    fn quitting_waits_for_the_agents_and_escalates() {
        let timing = Timing::default();
        assert_eq!(timed(0, timing).0, Outcome::Interrupted);
        assert_eq!(timed(500, timing), (Outcome::Interrupted, vec!["interrupt"]));
        assert_eq!(timed(3000, timing), (Outcome::Terminated, vec!["interrupt", "terminate"]));
        assert_eq!(timed(60_000, timing), (Outcome::Killed, vec!["interrupt", "terminate", "kill"]));
        let none = stop_all(0, timing, || {}, || false, || {}, || {}, |_| {}, Instant::now);
        assert_eq!(none, Outcome::NothingRunning);
    }
}
