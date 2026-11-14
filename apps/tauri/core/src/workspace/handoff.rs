//! Handing a session to another agent (`ContextHandoff.swift` and `WorkspaceManager+Handoff.swift` on the Mac). The
//! new agent cannot read the old agent's conversation, so what happened is handed over at the start of its first turn:
//! a budgeted selection of the timeline, not a summary a model wrote. Messages keep their own words; commands and
//! changed files take a line. It is deterministic, bounded and shown in the timeline: nothing is slipped into a prompt
//! unseen. Switching back to an agent that took part before resumes its own conversation and hands over only what it
//! missed.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::manager::Manager;
use super::models::{EventKind, EventState, PermissionPolicy, RunEvent, RunProvider};
use crate::i18n::{tr, trf};

/// The most the summary may cost the new agent, in tokens.
pub const TOKEN_BUDGET: usize = 16_000;
/// What one message may say in its own words; a longer one is cut with a note.
pub const MESSAGE_LIMIT: usize = 6_000;
/// What one tool call or file change may say.
pub const LINE_LIMIT: usize = 160;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    pub text: String,
    /// Items in the summary, and older items that no longer fit.
    pub included: usize,
    pub omitted: usize,
    /// The timeline length this summary covers: the next delta starts here.
    pub covered_events: usize,
}

pub fn approx_tokens(text: &str) -> usize {
    text.chars().count().div_ceil(4)
}

fn clip(text: &str, limit: usize) -> String {
    let single = text.replace('\n', " ").replace("  ", " ");
    if single.chars().count() > limit {
        format!("{}…", single.chars().take(limit).collect::<String>())
    } else {
        single
    }
}

fn whole(text: &str) -> String {
    if text.chars().count() > MESSAGE_LIMIT {
        format!("{}… (cut here)", text.chars().take(MESSAGE_LIMIT).collect::<String>())
    } else {
        text.to_string()
    }
}

/// One timeline entry as a line of the summary; `None` for entries that say nothing about the work.
pub fn line(event: &RunEvent) -> Option<String> {
    let text = event.text.trim();
    match event.kind {
        EventKind::User if !text.is_empty() => Some(format!("- User: {}", whole(text))),
        EventKind::Assistant if !text.is_empty() => Some(format!("- Agent: {}", whole(text))),
        EventKind::Tool if !text.is_empty() => {
            let failed = if event.state == Some(EventState::Failed) { " (failed)" } else { "" };
            Some(format!("- Ran: {}{failed}", clip(text, LINE_LIMIT)))
        }
        EventKind::FileChange => {
            let path = if text.is_empty() { event.detail.as_deref().unwrap_or_default().trim() } else { text };
            if path.is_empty() {
                return None;
            }
            let how = event.tool.as_deref().map(|t| format!(" ({t})")).unwrap_or_default();
            Some(format!("- Changed: {}{how}", clip(path, LINE_LIMIT)))
        }
        EventKind::Error if !text.is_empty() => Some(format!("- Error: {}", clip(text, LINE_LIMIT))),
        _ => None,
    }
}

/// The summary of `events` from index `start` on, or `None` when there is nothing to tell. The newest items are kept
/// when the budget runs out (and always the request that started it all); the summary says how many older ones are
/// left out.
pub fn render(events: &[RunEvent], start: usize, source: &str, budget: usize) -> Option<Rendered> {
    let slice = events.get(start..).unwrap_or_default();
    let lines: Vec<String> = slice.iter().filter_map(line).collect();
    if lines.is_empty() {
        return None;
    }
    let header = format!(
        "[Context handoff] This session continues work that {source} did before you. What happened (oldest first; you cannot see that conversation):"
    );
    let original = slice.iter().find(|e| e.kind == EventKind::User).and_then(line);
    let original_index = original.as_ref().and_then(|o| lines.iter().position(|l| l == o));
    let mut chosen: Vec<usize> = original_index.into_iter().collect();
    let mut used = approx_tokens(&header) + 40 + original.as_deref().map_or(0, |o| approx_tokens(o) + 1);
    for (index, l) in lines.iter().enumerate().rev() {
        if Some(index) == original_index {
            continue;
        }
        let cost = approx_tokens(l) + 1;
        if used + cost > budget && !chosen.is_empty() {
            break;
        }
        chosen.push(index);
        used += cost;
    }
    chosen.sort_unstable();
    let included = chosen.len();
    let omitted = lines.len() - included;
    let mut parts = vec![header];
    if omitted > 0 {
        parts.push(format!("({omitted} earlier item{} left out.)", if omitted == 1 { "" } else { "s" }));
    }
    for (position, index) in chosen.iter().enumerate() {
        if position > 0 && *index != chosen[position - 1] + 1 {
            parts.push("(…)".into());
        }
        parts.push(lines[*index].clone());
    }
    parts.push("[End of handoff] Continue from here. Check the files yourself before relying on any of this.".into());
    Some(Rendered { text: parts.join("\n"), included, omitted, covered_events: events.len() })
}

/// What a switch lets the new agent start from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Strategy {
    /// A summary of everything.
    FullSummary,
    /// It resumes its own earlier conversation: a summary of what happened since it last took part.
    Delta { since: usize },
}

pub fn strategy(has_native_session: bool, cursor: Option<usize>) -> Strategy {
    match cursor {
        Some(since) if has_native_session => Strategy::Delta { since },
        _ => Strategy::FullSummary,
    }
}

/// "claude/claude-work": one agent with one account.
pub fn instance_key(provider: RunProvider, profile_id: &str) -> String {
    format!("{}/{profile_id}", provider.id())
}

/// Per session, the conversations of the agents it had and how far each one took part.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HandoffState {
    pub sessions: BTreeMap<String, String>,
    pub cursors: BTreeMap<String, usize>,
}

/// `handoffs.json` next to the sessions.
pub struct HandoffStore {
    file: PathBuf,
    states: Mutex<BTreeMap<Uuid, HandoffState>>,
}

impl HandoffStore {
    pub fn new(directory: &Path) -> Self {
        let file = directory.join("handoffs.json");
        let states = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { file, states: Mutex::new(states) }
    }

    pub fn state(&self, id: Uuid) -> HandoffState {
        self.states.lock().map(|s| s.get(&id).cloned().unwrap_or_default()).unwrap_or_default()
    }

    fn set(&self, id: Uuid, state: HandoffState) {
        let Ok(mut states) = self.states.lock() else { return };
        states.insert(id, state);
        if let Ok(bytes) = serde_json::to_vec_pretty(&*states) {
            let _ = crate::paths::write_atomic(&self.file, &bytes);
        }
    }
}

/// What a switch did, for the interface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Switched {
    pub included: usize,
    pub omitted: usize,
    pub resumed: bool,
}

/// Moves a session to another agent (or another account of the same agent) between turns. The old conversation is
/// kept: switching back resumes it and hands over only what it missed. The handoff goes ahead of your next message
/// and is shown in the timeline. `installed`: the new agent is on this computer.
pub fn switch(
    manager: &Manager,
    store: &HandoffStore,
    id: Uuid,
    provider: RunProvider,
    profile_id: &str,
    model: &str,
    installed: bool,
) -> Result<Switched, String> {
    let run = manager.run(id).ok_or_else(|| tr("Deze sessie bestaat niet meer.", "This session no longer exists.").to_string())?;
    if run.status.is_active() {
        return Err(tr(
            "Dat kan niet terwijl de agent werkt. Wacht tot de beurt klaar is of stop hem.",
            "Not while the agent works. Wait for the turn to finish, or stop it.",
        )
        .into());
    }
    if !installed {
        return Err(trf(
            "{agent} staat niet op deze computer.",
            "{agent} is not on this computer.",
            &[("agent", &provider.display_name())],
        ));
    }
    let leaving = instance_key(run.provider, &run.profile_id);
    let arriving = instance_key(provider, profile_id);
    if leaving == arriving {
        return Err(tr("Deze sessie draait al met die agent.", "This session already runs with that agent.").into());
    }
    let events = manager.timeline(id);
    let mut state = store.state(id);
    if let Some(session) = &run.provider_session_id {
        state.sessions.insert(leaving.clone(), session.clone());
    }
    state.cursors.insert(leaving, events.len());
    let native = state.sessions.get(&arriving).cloned();
    let source = run.provider.display_name();
    let rendered = match strategy(native.is_some(), state.cursors.get(&arriving).copied()) {
        Strategy::FullSummary => render(&events, 0, source, TOKEN_BUDGET),
        Strategy::Delta { since } => render(&events, since, source, TOKEN_BUDGET),
    };
    let policies = provider.capabilities().policies;
    let changed = manager.update_between_turns(id, |r| {
        r.provider = provider;
        r.profile_id = profile_id.to_string();
        r.model = model.trim().to_string();
        r.resolved_model = None;
        r.provider_session_id = native.clone();
        r.pending_handoff = rendered.as_ref().map(|h| h.text.clone());
        if !policies.contains(&r.permission) {
            r.permission = if policies.contains(&PermissionPolicy::Ask) { PermissionPolicy::Ask } else { policies[0] };
        }
    });
    if !changed {
        return Err(tr(
            "Dat kan niet terwijl de agent werkt. Wacht tot de beurt klaar is of stop hem.",
            "Not while the agent works. Wait for the turn to finish, or stop it.",
        )
        .into());
    }
    store.set(id, state);
    manager.note(
        id,
        &trf(
            "Overgedragen van {from} aan {to}.",
            "Handed over from {from} to {to}.",
            &[("from", &source), ("to", &provider.display_name())],
        ),
    );
    if let Some(h) = &rendered {
        manager.note(
            id,
            &trf(
                "Overdracht van context: {included} onderdelen gaan mee met je volgende bericht, {omitted} oudere niet.",
                "Context handoff: {included} items go along with your next message, {omitted} older ones do not.",
                &[("included", &h.included), ("omitted", &h.omitted)],
            ),
        );
    }
    Ok(Switched {
        included: rendered.as_ref().map_or(0, |h| h.included),
        omitted: rendered.as_ref().map_or(0, |h| h.omitted),
        resumed: native.is_some(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(kind: EventKind, text: &str) -> RunEvent {
        RunEvent::new(kind, text)
    }

    #[test]
    fn renders_the_work_in_order_without_noise() {
        let events = vec![
            e(EventKind::User, "Fix the login"),
            e(EventKind::Thinking, "hmm"),
            e(EventKind::Tool, "npm test\nwith output"),
            e(EventKind::FileChange, "src/login.ts"),
            e(EventKind::System, "Worktree gemaakt"),
            e(EventKind::Assistant, "Fixed it."),
        ];
        let r = render(&events, 0, "Claude Code", TOKEN_BUDGET).unwrap();
        assert!(r.text.starts_with("[Context handoff] This session continues work that Claude Code did"));
        assert!(r.text.contains("- User: Fix the login\n- Ran: npm test with output\n- Changed: src/login.ts\n- Agent: Fixed it."));
        assert!(!r.text.contains("hmm"));
        assert!(!r.text.contains("Worktree"));
        assert_eq!((r.included, r.omitted, r.covered_events), (4, 0, 6));
        assert!(render(&[e(EventKind::System, "x")], 0, "Codex", TOKEN_BUDGET).is_none());
    }

    #[test]
    fn keeps_the_first_request_and_the_newest_items_within_the_budget() {
        let mut events = vec![e(EventKind::User, "The original request")];
        for i in 0..200 {
            events.push(e(EventKind::Assistant, &format!("Step {i} {}", "x".repeat(200))));
        }
        let r = render(&events, 0, "Codex", 2_000).unwrap();
        assert!(r.text.contains("- User: The original request"));
        assert!(r.text.contains("Step 199"));
        assert!(!r.text.contains("Step 0 "));
        assert!(r.omitted > 0);
        assert!(r.text.contains("earlier items left out"));
        assert!(r.text.contains("(…)"));
        assert!(approx_tokens(&r.text) <= 2_100);
    }

    #[test]
    fn a_delta_starts_where_the_agent_left() {
        let events = vec![e(EventKind::User, "first"), e(EventKind::Assistant, "one"), e(EventKind::User, "second")];
        let r = render(&events, 2, "Gemini CLI", TOKEN_BUDGET).unwrap();
        assert!(r.text.contains("- User: second"));
        assert!(!r.text.contains("- User: first"));
        assert_eq!(strategy(true, Some(2)), Strategy::Delta { since: 2 });
        assert_eq!(strategy(false, Some(2)), Strategy::FullSummary);
        assert_eq!(strategy(true, None), Strategy::FullSummary);
    }

    #[test]
    fn long_messages_are_cut_with_a_note() {
        let long = "y".repeat(MESSAGE_LIMIT + 10);
        let l = line(&e(EventKind::User, &long)).unwrap();
        assert!(l.ends_with("… (cut here)"));
    }
}
