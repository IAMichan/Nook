//! Second opinion on a hooked session that still reads as busy (`SessionLiveness` on the Mac). Hooks can go missing
//! (Nook restarted mid-turn, a hook timed out, an agent version that skips `Stop`), and then a session would show
//! "working" for hours. Nook treats "running" as a claim to verify: the transcript says whether the last turn ended,
//! the process list says whether the agent is still there at all.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::sync::Mutex;
use std::time::SystemTime;

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::scanner::DetectedAgent;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Turn {
    Ended,
    Open,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// The transcript shows the turn finished, but no `Stop` arrived.
    TurnEnded,
    /// The agent's process is gone.
    ProcessGone,
}

/// How long the transcript and hooks must be quiet before the transcript is trusted over the hooks: Claude Code writes
/// the final line just before it fires `Stop`, and a normal `Stop`, or a new prompt reaching the file, should win.
pub const SETTLE_DELAY_SECS: i64 = 15;
/// How long a session must be quiet, and missing from the process list, before it counts as closed.
pub const GONE_DELAY_SECS: i64 = 30;
/// Scans in a row (10 s apart) a process must be missing, so one odd scan never ends a session.
pub const GONE_SCANS: usize = 2;
/// Enough of the transcript to find the last message line; a reply with a big tool result can be longer, and then the
/// turn stays unknown rather than guessed.
pub const TAIL_BYTES: u64 = 256 * 1024;

/// For a session that reads as busy: `working` when it runs, false when it waits for you.
pub fn verdict(
    working: bool,
    last_event: DateTime<Utc>,
    turn: Turn,
    transcript_modified: Option<DateTime<Utc>>,
    missing_scans: usize,
    now: DateTime<Utc>,
) -> Option<Verdict> {
    let latest = transcript_modified.map_or(last_event, |m| m.max(last_event));
    let quiet = (now - latest).num_seconds();
    if missing_scans >= GONE_SCANS && (now - last_event).num_seconds() >= GONE_DELAY_SECS {
        return Some(Verdict::ProcessGone);
    }
    // A waiting session asks something of you; only a vanished process settles it.
    if working && turn == Turn::Ended && quiet >= SETTLE_DELAY_SECS {
        return Some(Verdict::TurnEnded);
    }
    None
}

/// Whether the agent process of a session still runs. With `pid` (the process its hooks came from) only that process
/// counts: another session of the same agent in the same folder must not keep a closed one alive. Without it, any
/// process of the agent in `cwd` does; the hook's folder can be a subfolder of where the agent started, and a process
/// whose folder could not be read counts as a match.
pub fn is_running(agent: &str, cwd: &str, pid: Option<u32>, processes: &[DetectedAgent]) -> bool {
    if let Some(pid) = pid {
        return processes.iter().any(|p| p.pid == pid && p.name == agent);
    }
    processes.iter().any(|p| {
        p.name == agent
            && (p.cwd.is_empty()
                || cwd.is_empty()
                || p.cwd == cwd
                || cwd.starts_with(&format!("{}/", p.cwd))
                || cwd.starts_with(&format!("{}\\", p.cwd)))
    })
}

/// The agent process among `lineage` (the hook and the processes it was started from, nearest first): the first one
/// the process scan knows as this agent.
pub fn agent_process(agent: &str, lineage: &[u32], processes: &[DetectedAgent]) -> Option<u32> {
    lineage.iter().copied().find(|pid| processes.iter().any(|p| p.pid == *pid && p.name == agent))
}

// Transcript

#[derive(Clone, Copy, PartialEq, Eq)]
enum LocalCommand {
    Name,
    Output,
}

/// The state of the last turn, from the end of a Claude Code or Codex transcript (JSONL).
pub fn last_turn(tail: &[u8]) -> Turn {
    // The first line may be cut off by the tail read; it simply fails to parse.
    let objects: Vec<Value> = tail.split(|b| *b == b'\n').filter_map(|line| serde_json::from_slice::<Value>(line).ok()).collect();
    let commands: Vec<Option<LocalCommand>> = objects.iter().map(local_command).collect();
    let turns: Vec<Option<Turn>> = objects.iter().map(|o| claude_turn(o).or_else(|| codex_turn(o))).collect();
    // The message line next to `index` in one direction, past bookkeeping lines.
    let neighbour = |index: usize, forward: bool| -> Option<usize> {
        let mut next = index;
        loop {
            next = if forward { next.checked_add(1)? } else { next.checked_sub(1)? };
            if next >= objects.len() {
                return None;
            }
            if commands[next].is_some() || turns[next].is_some() {
                return Some(next);
            }
        }
    };
    for index in (0..objects.len()).rev() {
        match commands[index] {
            Some(LocalCommand::Output) => continue,
            Some(LocalCommand::Name) => {
                // A command that printed something ran in Claude Code itself; one that did not may be a prompt of yours.
                let ran_locally = [neighbour(index, false), neighbour(index, true)]
                    .into_iter()
                    .any(|side| side.is_some_and(|i| commands[i] == Some(LocalCommand::Output)));
                if ran_locally {
                    continue;
                }
                return Turn::Open;
            }
            None => {
                if let Some(turn) = turns[index] {
                    return turn;
                }
            }
        }
    }
    Turn::Unknown
}

fn flag(object: &Value, key: &str) -> bool {
    object.get(key).and_then(Value::as_bool) == Some(true)
}

/// Claude Code writes each block of a message as its own line, with `stop_reason` null on all but the last and
/// `tool_use` when a tool call follows. Only a final assistant line ends the turn; any other message keeps it open.
fn claude_turn(object: &Value) -> Option<Turn> {
    let kind = object.get("type").and_then(Value::as_str)?;
    if kind != "assistant" && kind != "user" {
        return None;
    }
    let message = object.get("message").filter(|m| m.is_object())?;
    let content = message.get("content").filter(|c| !c.is_null())?;
    // Subagent and bookkeeping lines (skill text, command echoes) say nothing about the main turn.
    if flag(object, "isSidechain") || flag(object, "isMeta") {
        return None;
    }
    if kind != "assistant" {
        return Some(if is_interruption(content) { Turn::Ended } else { Turn::Open });
    }
    // An API error Claude Code gave up on (a usage limit, an overloaded API) ends the turn, whatever its stop reason.
    if flag(object, "isApiErrorMessage") {
        return Some(Turn::Ended);
    }
    let Some(stop) = message.get("stop_reason").and_then(Value::as_str) else { return Some(Turn::Open) };
    Some(if stop == "tool_use" || stop == "pause_turn" { Turn::Open } else { Turn::Ended })
}

/// A slash command run in Claude Code itself (`/exit`, `/usage`, the menu after a usage limit) leaves two user lines,
/// the command and what it printed, but starts no turn: the turn stands as it was before them.
fn local_command(object: &Value) -> Option<LocalCommand> {
    if object.get("type").and_then(Value::as_str) != Some("user") || flag(object, "isSidechain") {
        return None;
    }
    let content = object.get("message")?.get("content")?;
    let text = match content {
        Value::String(s) => s.as_str(),
        Value::Array(blocks) if blocks.len() == 1 => blocks[0].get("text").and_then(Value::as_str)?,
        _ => return None,
    };
    let trimmed = text.trim();
    if trimmed.starts_with("<local-command-stdout>") || trimmed.starts_with("<local-command-stderr>") {
        return Some(LocalCommand::Output);
    }
    if trimmed.starts_with("<command-name>") || trimmed.starts_with("<command-message>") {
        return Some(LocalCommand::Name);
    }
    None
}

/// Esc in Claude Code ends the turn without a `Stop` hook; the transcript gets this marker instead.
fn is_interruption(content: &Value) -> bool {
    const MARKER: &str = "[Request interrupted by user";
    match content {
        Value::String(s) => s.starts_with(MARKER),
        Value::Array(blocks) if blocks.len() == 1 => blocks[0].get("text").and_then(Value::as_str).is_some_and(|t| t.starts_with(MARKER)),
        _ => false,
    }
}

fn codex_turn(object: &Value) -> Option<Turn> {
    if object.get("type").and_then(Value::as_str) != Some("event_msg") {
        return None;
    }
    match object.get("payload")?.get("type")?.as_str()? {
        "task_complete" | "turn_aborted" => Some(Turn::Ended),
        "task_started" | "user_message" => Some(Turn::Open),
        _ => None,
    }
}

type TurnCache = HashMap<String, (SystemTime, u64, Turn)>;
static TURN_CACHE: Mutex<Option<TurnCache>> = Mutex::new(None);

/// The last turn of the transcript at `path` and when it was last written; `None` when it cannot be read. Asked every
/// ten seconds per working session: the tail is only read again when the file changed.
pub fn read_turn(path: &str) -> Option<(Turn, Option<DateTime<Utc>>)> {
    if path.is_empty() {
        return None;
    }
    let meta = std::fs::metadata(path).ok()?;
    let modified = meta.modified().ok();
    let size = meta.len();
    let stamp = modified.map(DateTime::<Utc>::from);
    if let Some(m) = modified {
        let cache = TURN_CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((cm, cs, turn)) = cache.as_ref().and_then(|c| c.get(path)) {
            if *cm == m && *cs == size {
                return Some((*turn, stamp));
            }
        }
    }
    let mut file = std::fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(size.saturating_sub(TAIL_BYTES))).ok()?;
    let mut data = Vec::new();
    file.read_to_end(&mut data).ok()?;
    let turn = last_turn(&data);
    if let Some(m) = modified {
        let mut cache = TURN_CACHE.lock().unwrap_or_else(|e| e.into_inner());
        let map = cache.get_or_insert_with(HashMap::new);
        if map.len() > 64 {
            map.clear();
        }
        map.insert(path.into(), (m, size, turn));
    }
    Some((turn, stamp))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    const PROMPT: &str = r#"{"type":"user","message":{"role":"user","content":"Fix the bug"}}"#;
    const TOOL_CALL: &str =
        r#"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#;
    const TOOL_RESULT: &str = r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#;
    const REPLY: &str = r#"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#;

    fn tail(lines: &[&str]) -> Vec<u8> {
        lines.join("\n").into_bytes()
    }

    fn agent(pid: u32, name: &str, cwd: &str) -> DetectedAgent {
        DetectedAgent { pid, name: name.into(), cwd: cwd.into(), home: String::new() }
    }

    #[test]
    fn claude_turns() {
        assert_eq!(last_turn(&tail(&[PROMPT, TOOL_CALL])), Turn::Open);
        assert_eq!(last_turn(&tail(&[PROMPT, TOOL_CALL, TOOL_RESULT])), Turn::Open);
        assert_eq!(last_turn(&tail(&[PROMPT, TOOL_CALL, TOOL_RESULT, REPLY])), Turn::Ended);
        let interrupted = r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#;
        assert_eq!(last_turn(&tail(&[PROMPT, TOOL_CALL, interrupted])), Turn::Ended);
        assert_eq!(last_turn(b"garbage"), Turn::Unknown);
    }

    #[test]
    fn slash_commands_between_turns_keep_the_turn_as_it_was() {
        let exit = r#"{"type":"user","message":{"role":"user","content":"<command-name>/exit</command-name>\n<command-message>exit</command-message>\n<command-args></command-args>"}}"#;
        let caveat =
            r#"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: …</local-command-caveat>"}}"#;
        let bye = r#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Goodbye!</local-command-stdout>"}}"#;
        let system = r#"{"type":"system","subtype":"local_command","content":"…"}"#;
        assert_eq!(last_turn(&tail(&[PROMPT, REPLY, caveat, exit, bye])), Turn::Ended, "/exit after the answer");
        assert_eq!(last_turn(&tail(&[PROMPT, REPLY, caveat, exit, system, bye])), Turn::Ended);
        assert_eq!(last_turn(&tail(&[PROMPT, TOOL_CALL, exit, bye])), Turn::Open, "a command run mid-turn");
        let review = r#"{"type":"user","message":{"role":"user","content":"<command-message>review is running…</command-message>\n<command-name>/review</command-name>"}}"#;
        let expanded = r#"{"type":"user","isMeta":true,"message":{"role":"user","content":"Review the diff."}}"#;
        assert_eq!(last_turn(&tail(&[REPLY, review, expanded])), Turn::Open, "a command that prompts the agent");
    }

    #[test]
    fn an_api_error_ends_the_turn() {
        let limit = r#"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","stop_reason":null,"content":[{"type":"text","text":"You've hit your limit"}]}}"#;
        assert_eq!(last_turn(&tail(&[PROMPT, TOOL_CALL, TOOL_RESULT, limit])), Turn::Ended);
    }

    #[test]
    fn codex_rollout_events() {
        let started = r#"{"type":"event_msg","payload":{"type":"task_started"}}"#;
        let complete = r#"{"type":"event_msg","payload":{"type":"task_complete"}}"#;
        let other = r#"{"type":"response_item","payload":{"type":"message"}}"#;
        assert_eq!(last_turn(&tail(&[started, other])), Turn::Open);
        assert_eq!(last_turn(&tail(&[started, complete, other])), Turn::Ended);
    }

    #[test]
    fn verdicts() {
        let now = Utc::now();
        let old = now - Duration::seconds(60);
        assert_eq!(verdict(true, old, Turn::Ended, Some(old), 0, now), Some(Verdict::TurnEnded));
        assert_eq!(verdict(true, now, Turn::Ended, Some(now), 0, now), None, "too fresh");
        assert_eq!(verdict(false, old, Turn::Ended, Some(old), 0, now), None, "waiting asks you");
        assert_eq!(verdict(false, old, Turn::Unknown, None, 2, now), Some(Verdict::ProcessGone));
        assert_eq!(verdict(true, old, Turn::Open, None, 1, now), None, "one missed scan is not enough");
    }

    #[test]
    fn process_matching_allows_subfolders() {
        let processes = [agent(40, "Claude Code", "/Users/me/nook")];
        assert!(is_running("Claude Code", "/Users/me/nook", None, &processes));
        assert!(is_running("Claude Code", "/Users/me/nook/apps/macos", None, &processes));
        assert!(!is_running("Claude Code", "/Users/me/nook-old", None, &processes));
        assert!(!is_running("Codex", "/Users/me/nook", None, &processes));
        assert!(is_running("Claude Code", "/elsewhere", None, &[agent(41, "Claude Code", "")]), "unknown folder");
    }

    #[test]
    fn a_known_process_is_matched_by_itself() {
        let other = [agent(50, "Claude Code", "/Users/me/site")];
        assert!(!is_running("Claude Code", "/Users/me/site", Some(42), &other), "another session does not keep a closed one alive");
        assert!(is_running("Claude Code", "/Users/me/site", Some(50), &other));
        assert!(!is_running("Codex", "/Users/me/site", Some(50), &other));
    }

    #[test]
    fn the_agent_is_found_among_the_hooks_parents() {
        let processes = [agent(50, "Claude Code", "/a"), agent(60, "Codex", "/a")];
        // The hook, its shell, the agent, the terminal.
        assert_eq!(agent_process("Claude Code", &[90, 80, 50, 10], &processes), Some(50));
        assert_eq!(agent_process("Claude Code", &[90, 80, 60], &processes), None);
        assert_eq!(agent_process("Claude Code", &[], &processes), None);
    }

    #[test]
    fn reads_the_tail_of_a_transcript_file() {
        let dir = std::env::temp_dir().join(format!("nook-liveness-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("t.jsonl");
        std::fs::write(&file, tail(&[PROMPT, REPLY])).unwrap();
        let path = file.to_string_lossy().into_owned();
        let (turn, modified) = read_turn(&path).unwrap();
        assert_eq!(turn, Turn::Ended);
        assert!(modified.is_some());
        assert!(read_turn("").is_none());
        assert!(read_turn(&dir.join("missing").to_string_lossy()).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }
}
