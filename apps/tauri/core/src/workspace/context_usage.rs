//! Session goals (`/goal`), compaction progress, and context window breakdown (`SessionGoal`, `CompactionProgress`,
//! `ContextUsage`, `ContextMeter`, and `AutoCompactMark` on macOS). Pure logic without processes so unit tests can
//! drive every edge case directly.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::models::{EventKind, EventState, RunEvent, WorkspaceRun};

/// The `tool` tag on compaction timeline rows (`CompactionProgress.tool` on macOS).
pub const COMPACTION_TOOL: &str = "compaction";

/// The `tool` tag on goal timeline rows.
pub const GOAL_TOOL: &str = "goal";

/// Default token count where Nook suggests/starts auto-compacting (`SizeCompaction.defaultTokens` on macOS).
pub const DEFAULT_AUTO_COMPACT_TOKENS: u64 = 350_000;

/// Never wait past 80 % of the model's context window before auto-compacting (`SizeCompaction.windowShare`).
pub const AUTO_COMPACT_WINDOW_SHARE: f64 = 0.8;

/// Base overhead estimated for the agent's built-in system prompt and tool definitions when the session has tokens.
const BASE_SYSTEM_PROMPT_TOKENS: u64 = 2_500;

// MARK: Goals (AG-67)

/// A `/goal` slash command parsed from user input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GoalCommand {
    /// `/goal <objective>`
    Set(String),
    /// `/goal clear` or bare `/goal` with empty text.
    Clear,
}

/// Parses `/goal <text>`, `/goal clear`, or empty `/goal`. Returns `None` for any other message (including `/goals`).
pub fn parse_goal_command(text: &str) -> Option<GoalCommand> {
    let clean = text.trim();
    if clean.len() < 5 || !clean[..5].eq_ignore_ascii_case("/goal") {
        return None;
    }
    let rest = &clean[5..];
    if let Some(first) = rest.chars().next() {
        if !first.is_whitespace() {
            return None;
        }
    }
    let arg = rest.trim();
    if arg.is_empty() || arg.eq_ignore_ascii_case("clear") {
        Some(GoalCommand::Clear)
    } else {
        Some(GoalCommand::Set(arg.to_string()))
    }
}

/// Normalizes a goal string from the UI or slash command: trims whitespace and turns empty into `None`.
pub fn normalize_goal(goal: Option<&str>) -> Option<String> {
    goal.map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// Parses Claude Code's synthetic `/goal` status responses (`SessionGoals.claude(synthetic:)` on macOS).
/// Returns `Some(Some(objective))` when a goal was set/active, `Some(None)` when cleared/absent, `None` otherwise.
pub fn parse_claude_synthetic_goal(text: &str) -> Option<Option<String>> {
    let clean = text.trim();
    if let Some(rest) = clean.strip_prefix("Goal set: ") {
        let objective = rest.trim();
        return (!objective.is_empty()).then(|| Some(objective.to_string()));
    }
    if clean.starts_with("Goal cleared: ") || clean.starts_with("No goal set") {
        return Some(None);
    }
    if let Some(rest) = clean.strip_prefix("Goal active: ") {
        let open = rest.rfind(" (")?;
        let objective = rest[..open].trim();
        let note = &rest[open + 2..];
        if !objective.is_empty() && (note.starts_with("not yet evaluated") || note.contains("turn")) {
            return Some(Some(objective.to_string()));
        }
    }
    None
}

// MARK: Compaction progress (AG-65)

/// Whether `text` is a `/compact` slash command (with or without instructions), not `/compacting`.
pub fn is_compact_command(text: &str) -> bool {
    let clean = text.trim();
    if clean.len() < 8 || !clean[..8].eq_ignore_ascii_case("/compact") {
        return false;
    }
    clean[8..].chars().next().is_none_or(char::is_whitespace)
}

pub fn is_compaction_event(event: &RunEvent) -> bool {
    event.kind == EventKind::System && event.tool.as_deref() == Some(COMPACTION_TOOL)
}

pub fn is_compaction_running(event: &RunEvent) -> bool {
    is_compaction_event(event) && event.state == Some(EventState::Running)
}

/// The running compaction event of the latest turn (scanning backwards until a user message), matching macOS
/// `CompactionProgress.running(in:)`.
pub fn running_compaction_id(events: &[RunEvent]) -> Option<Uuid> {
    for event in events.iter().rev() {
        if is_compaction_running(event) {
            return Some(event.id);
        }
        if event.kind == EventKind::User {
            return None;
        }
    }
    None
}

// MARK: Context meter & breakdown (AG-65 & AG-66)

/// How close the session is to the auto-compact threshold (or context limit).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContextLevel {
    Normal,
    /// Amber: past 80 % of the auto-compact threshold / window.
    Warning,
    /// Coral: past 90 % of the auto-compact threshold / window.
    Critical,
}

impl ContextLevel {
    /// Amber above 80 %, coral above 90 % (`ContextMeter.level` on macOS).
    pub fn from_pressure(pressure: f64) -> Self {
        if pressure > 0.9 {
            Self::Critical
        } else if pressure > 0.8 {
            Self::Warning
        } else {
            Self::Normal
        }
    }
}

/// What role a slice plays in the context window bar (`ContextUsage.Kind` on macOS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContextPartKind {
    Used,
    Buffer,
    Free,
}

/// One part of the context window breakdown.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextPart {
    /// Category id matching macOS: `"system_prompt"`, `"messages"`, `"system_tools"`, `"conversation"`,
    /// `"autocompact_buffer"`, `"free_space"`.
    pub id: String,
    pub tokens: u64,
    /// Share of the full window, `0.0..=1.0`.
    pub share: f64,
    pub kind: ContextPartKind,
}

/// Full context window breakdown and compaction pressure for a session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextUsage {
    pub used_tokens: u64,
    pub window: u64,
    /// `used_tokens / window`, clamped to `0.0..=1.0`.
    pub fraction: f64,
    /// Pressure measured against `auto_compact_at` (when inside `window`), else `window` (`ContextMeter.pressure`).
    pub pressure: f64,
    pub level: ContextLevel,
    /// Token count where the conversation auto-compacts, if applicable.
    pub auto_compact_at: Option<u64>,
    /// Tokens remaining before `auto_compact_at` (or before `window` when no auto-compact threshold is set).
    pub headroom_tokens: u64,
    /// Whether a compaction is actively running right now.
    pub compacting: bool,
    /// False for estimates derived from usage + timeline events; true when reported directly by the agent.
    pub detailed: bool,
    pub parts: Vec<ContextPart>,
}

/// Token count where the session is summarized automatically (`SizeCompaction.limit` on macOS).
pub fn auto_compact_threshold(context_window: Option<u64>, setting_tokens: u64) -> Option<u64> {
    if setting_tokens == 0 {
        return None;
    }
    match context_window {
        Some(window) if window > 0 => Some(setting_tokens.min((window as f64 * AUTO_COMPACT_WINDOW_SHARE) as u64)),
        _ => Some(setting_tokens),
    }
}

/// How close `used` is to `auto_compact_at` (or `window`), clamped to `0.0..=1.0` (`ContextMeter.pressure` on macOS).
pub fn pressure(used: u64, window: u64, auto_compact_at: Option<u64>) -> f64 {
    let budget = auto_compact_at.map(|a| a.min(window)).filter(|&b| b > 0).unwrap_or(window);
    if budget == 0 {
        return 0.0;
    }
    (used as f64 / budget as f64).min(1.0)
}

/// Rough token count for a string (~4 characters per token).
fn approx_tokens(text: &str) -> u64 {
    let chars = text.chars().count() as u64;
    if chars == 0 {
        0
    } else {
        chars.div_ceil(4)
    }
}

/// Events belonging to the current active context window (everything after the last `/clear` or completed compaction).
fn active_window_events(events: &[RunEvent]) -> &[RunEvent] {
    let boundary = events.iter().rposition(|e| {
        e.kind == EventKind::System
            && (e.tool.as_deref() == Some("clear") || (e.tool.as_deref() == Some(COMPACTION_TOOL) && e.state == Some(EventState::Done)))
    });
    match boundary {
        Some(idx) => &events[idx + 1..],
        None => events,
    }
}

/// Computes the context window breakdown for a run from its reported usage and timeline events.
/// Returns `None` when the session has no known context window or has zero used tokens and is not compacting.
pub fn compute(run: &WorkspaceRun, events: &[RunEvent], setting_tokens: u64) -> Option<ContextUsage> {
    let window = run.usage.context_window.filter(|&w| w > 0)?;
    compute_with_mark(run, events, auto_compact_threshold(Some(window), setting_tokens))
}

/// Computes the context window breakdown using an explicit `auto_compact_at` threshold (`AutoCompactMark` on macOS).
pub fn compute_with_mark(run: &WorkspaceRun, events: &[RunEvent], auto_compact_at: Option<u64>) -> Option<ContextUsage> {
    let compacting = run.compacting || running_compaction_id(events).is_some();
    let window = run.usage.context_window.filter(|&w| w > 0)?;
    let used_raw = run.usage.context_tokens.unwrap_or(0);
    if used_raw == 0 && !compacting {
        return None;
    }

    let used = used_raw.min(window);
    let fraction = (used as f64 / window as f64).min(1.0);
    let p = pressure(used, window, auto_compact_at);
    let level = ContextLevel::from_pressure(p);

    // Estimate share of `used` across system/instructions, messages, and tool inputs/outputs from the active timeline.
    let slice = active_window_events(events);
    let mut raw_messages: u64 = 0;
    let mut raw_tools: u64 = 0;
    for e in slice {
        if e.rolled_back == Some(true) {
            continue;
        }
        match e.kind {
            EventKind::User | EventKind::Assistant | EventKind::Thinking => {
                raw_messages = raw_messages.saturating_add(approx_tokens(&e.text));
            }
            EventKind::Tool | EventKind::FileChange => {
                raw_tools = raw_tools
                    .saturating_add(approx_tokens(&e.text))
                    .saturating_add(e.detail.as_deref().map_or(0, approx_tokens))
                    .saturating_add(e.output.as_deref().map_or(0, approx_tokens));
            }
            _ => {}
        }
    }

    let raw_system = if used > 0 {
        let base = BASE_SYSTEM_PROMPT_TOKENS.min(used / 4).max(if !run.instructions.trim().is_empty() { 1 } else { 0 });
        base.saturating_add(approx_tokens(&run.instructions))
    } else {
        0
    };

    let mut parts: Vec<ContextPart> = Vec::new();
    let push_part = |parts: &mut Vec<ContextPart>, id: &str, tokens: u64, kind: ContextPartKind| {
        if tokens > 0 {
            parts.push(ContextPart { id: id.to_string(), tokens, share: tokens as f64 / window as f64, kind });
        }
    };

    if used > 0 {
        let content_total = raw_messages.saturating_add(raw_tools);
        if content_total == 0 {
            // Adopted or brand-new session with reported context tokens but no timeline breakdown yet.
            if raw_system > 0 && raw_system < used {
                push_part(&mut parts, "system_prompt", raw_system, ContextPartKind::Used);
                push_part(&mut parts, "conversation", used - raw_system, ContextPartKind::Used);
            } else {
                push_part(&mut parts, "conversation", used, ContextPartKind::Used);
            }
        } else {
            let system_tokens = raw_system.min(used / 3);
            let remaining = used.saturating_sub(system_tokens);
            let message_tokens = ((remaining as u128 * raw_messages as u128) / content_total as u128) as u64;
            let tool_tokens = remaining.saturating_sub(message_tokens);
            push_part(&mut parts, "system_prompt", system_tokens, ContextPartKind::Used);
            push_part(&mut parts, "messages", message_tokens, ContextPartKind::Used);
            push_part(&mut parts, "system_tools", tool_tokens, ContextPartKind::Used);
        }
    }

    let buffer = auto_compact_at.map(|at| window.saturating_sub(at.max(used))).unwrap_or(0);
    let free = window.saturating_sub(used).saturating_sub(buffer);
    push_part(&mut parts, "autocompact_buffer", buffer, ContextPartKind::Buffer);
    push_part(&mut parts, "free_space", free, ContextPartKind::Free);

    let headroom_tokens = auto_compact_at.map(|at| at.saturating_sub(used)).unwrap_or_else(|| window.saturating_sub(used));

    Some(ContextUsage {
        used_tokens: used,
        window,
        fraction,
        pressure: p,
        level,
        auto_compact_at,
        headroom_tokens,
        compacting,
        detailed: false,
        parts,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::models::{tests::run as make_run, RunStatus};

    #[test]
    fn goal_command_parses_set_clear_and_ignores_other_commands() {
        assert_eq!(parse_goal_command("/goal Ship Windows v1.1"), Some(GoalCommand::Set("Ship Windows v1.1".into())));
        assert_eq!(parse_goal_command("  /GOAL   Keep tests green  "), Some(GoalCommand::Set("Keep tests green".into())));
        assert_eq!(parse_goal_command("/goal clear"), Some(GoalCommand::Clear));
        assert_eq!(parse_goal_command("/goal CLEAR"), Some(GoalCommand::Clear));
        assert_eq!(parse_goal_command("/goal"), Some(GoalCommand::Clear));
        assert_eq!(parse_goal_command("  /goal   "), Some(GoalCommand::Clear));
        assert_eq!(parse_goal_command("/goals list"), None);
        assert_eq!(parse_goal_command("hello /goal test"), None);
    }

    #[test]
    fn claude_synthetic_goal_parsing_matches_macos() {
        assert_eq!(parse_claude_synthetic_goal("Goal set: tests pass"), Some(Some("tests pass".into())));
        assert_eq!(parse_claude_synthetic_goal("Goal active: a (b) c (3 turns)"), Some(Some("a (b) c".into())));
        assert_eq!(parse_claude_synthetic_goal("Goal active: x (not yet evaluated)"), Some(Some("x".into())));
        assert_eq!(parse_claude_synthetic_goal("Goal cleared: x"), Some(None));
        assert_eq!(parse_claude_synthetic_goal("No goal set."), Some(None));
        assert_eq!(parse_claude_synthetic_goal("Regular assistant reply"), None);
    }

    #[test]
    fn compact_command_matches_only_compact_word() {
        assert!(is_compact_command("/compact"));
        assert!(is_compact_command("  /COMPACT focus on recent changes "));
        assert!(!is_compact_command("/compacting"));
        assert!(!is_compact_command("please /compact"));
    }

    #[test]
    fn auto_compact_threshold_and_pressure_levels() {
        assert_eq!(auto_compact_threshold(Some(200_000), DEFAULT_AUTO_COMPACT_TOKENS), Some(160_000));
        assert_eq!(auto_compact_threshold(Some(1_000_000), DEFAULT_AUTO_COMPACT_TOKENS), Some(350_000));
        assert_eq!(auto_compact_threshold(Some(200_000), 0), None);

        // 200k window -> 160k auto-compact threshold: 120k is 75% (normal), 135k is 84.4% (amber warning), 150k is 93.8% (critical).
        let p_normal = pressure(120_000, 200_000, Some(160_000));
        assert_eq!(ContextLevel::from_pressure(p_normal), ContextLevel::Normal);
        let p_warn = pressure(135_000, 200_000, Some(160_000));
        assert_eq!(ContextLevel::from_pressure(p_warn), ContextLevel::Warning);
        let p_crit = pressure(150_000, 200_000, Some(160_000));
        assert_eq!(ContextLevel::from_pressure(p_crit), ContextLevel::Critical);
    }

    #[test]
    fn compute_returns_breakdown_summing_to_window_and_respects_headroom() {
        let mut run = make_run(RunStatus::Completed);
        run.instructions = "Follow strict coding standards.".repeat(40);
        run.usage.context_window = Some(200_000);
        run.usage.context_tokens = Some(136_000);

        let mut tool = RunEvent::new(EventKind::Tool, "Read manager.rs").with_tool("Read").with_detail("{\"path\":\"manager.rs\"}");
        tool.output = Some("fn main() {}\n".repeat(400));

        let events = vec![
            RunEvent::new(EventKind::User, "Please refactor the workspace module".repeat(100)),
            tool,
            RunEvent::new(EventKind::Assistant, "Here is the refactored module.".repeat(80)),
        ];

        let usage = compute(&run, &events, DEFAULT_AUTO_COMPACT_TOKENS).expect("expected breakdown");
        assert_eq!(usage.used_tokens, 136_000);
        assert_eq!(usage.window, 200_000);
        assert_eq!(usage.auto_compact_at, Some(160_000));
        assert_eq!(usage.headroom_tokens, 24_000);
        assert_eq!(usage.level, ContextLevel::Warning);
        assert!(!usage.compacting);

        let total: u64 = usage.parts.iter().map(|p| p.tokens).sum();
        assert_eq!(total, 200_000);
        assert!(usage.parts.iter().any(|p| p.id == "system_prompt" && p.kind == ContextPartKind::Used));
        assert!(usage.parts.iter().any(|p| p.id == "messages" && p.kind == ContextPartKind::Used));
        assert!(usage.parts.iter().any(|p| p.id == "system_tools" && p.kind == ContextPartKind::Used));
        assert!(usage.parts.iter().any(|p| p.id == "autocompact_buffer" && p.tokens == 40_000 && p.kind == ContextPartKind::Buffer));
        assert!(usage.parts.iter().any(|p| p.id == "free_space" && p.tokens == 24_000 && p.kind == ContextPartKind::Free));
    }

    #[test]
    fn compute_slices_after_compaction_and_tracks_live_compacting() {
        let mut run = make_run(RunStatus::Running);
        run.usage.context_window = Some(200_000);
        run.usage.context_tokens = Some(40_000);

        let mut old_tool = RunEvent::new(EventKind::Tool, "Huge old tool output").with_tool("Bash");
        old_tool.output = Some("x".repeat(40_000));
        let compacted = RunEvent::new(EventKind::System, "Compacted").with_tool(COMPACTION_TOOL).with_state(EventState::Done);
        let fresh_msg = RunEvent::new(EventKind::User, "Short follow-up");
        let running_compact = RunEvent::new(EventKind::System, "Compacting").with_tool(COMPACTION_TOOL).with_state(EventState::Running);

        let events = vec![old_tool, compacted, fresh_msg, running_compact];
        assert!(running_compaction_id(&events).is_some());

        let usage = compute(&run, &events, DEFAULT_AUTO_COMPACT_TOKENS).expect("expected breakdown");
        assert!(usage.compacting);
        // After compaction, old tool output is excluded so system_tools should be absent.
        assert!(!usage.parts.iter().any(|p| p.id == "system_tools"));
        assert!(usage.parts.iter().any(|p| p.id == "messages"));
    }

    #[test]
    fn compute_returns_none_without_window_or_usage() {
        let mut run = make_run(RunStatus::Completed);
        assert!(compute(&run, &[], DEFAULT_AUTO_COMPACT_TOKENS).is_none());
        run.usage.context_window = Some(200_000);
        assert!(compute(&run, &[], DEFAULT_AUTO_COMPACT_TOKENS).is_none());
        run.compacting = true;
        assert!(compute(&run, &[], DEFAULT_AUTO_COMPACT_TOKENS).is_some());
    }
}
