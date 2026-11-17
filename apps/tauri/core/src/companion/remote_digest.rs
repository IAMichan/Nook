//! The pure half of the companion's `remote` area on Windows and Linux: what a session's conversation, its changes, its
//! folder and the older sessions look like on the phone, with the same shapes and limits as the Mac
//! (`packages/protocol/Sources/CompanionModels.swift`, `CompanionHistory.swift`, `CompanionWorkspace.swift`,
//! `CompanionServer+Remote.swift`). The app fills them from its own state (`src-tauri/src/companion/remote.rs`).

use std::path::{Path, PathBuf};

use base64::Engine as _;
use serde::{Deserialize, Serialize};

use super::models::{CompanionImage, CompanionPolicy, CompanionRequest};
use crate::agents::transcript::{AgentChatMessage, ChatKind};
use crate::workspace::git::{ChangeKind, FileChange};
use crate::workspace::models::{EventKind, EventState, PermissionPolicy, RunEvent, RunProvider, WorkspaceRun};

/// One line of a conversation as the phone sees it (`CompanionConstants.lineLimit`).
pub const LINE_LIMIT: usize = 4_000;
/// What the lines of one answer may take together (`CompanionConstants.linesBudget`).
pub const LINES_BUDGET: usize = 150_000;
/// Entries the Mac walks back for one page of a timeline.
pub const PAGE_ENTRIES: usize = 160;

// MARK: Text

/// `text` without carriage returns and surrounding white space, cut at `limit` characters with an ellipsis
/// (`CompanionPolicy.clip`). Only its start is read.
pub fn clip(text: &str, limit: usize) -> String {
    let start = text.trim_start();
    let mut head: String = start.chars().take(limit * 2 + 16).collect();
    let more = head.len() < start.len();
    head = head.replace('\r', "");
    let flat = head.trim();
    if !more && flat.chars().count() <= limit {
        return flat.to_string();
    }
    let mut cut: String = flat.chars().take(limit).collect();
    cut.push('…');
    cut
}

/// Whether [`clip`] cut `clipped`: a cut line is `limit` characters and the ellipsis.
pub fn was_clipped(clipped: &str, limit: usize) -> bool {
    clipped.chars().count() > limit
}

/// The newest items whose JSON together stays within `budget` bytes, oldest first (`CompanionPolicy.newestFitting`).
pub fn newest_fitting<T: Serialize + Clone>(items: &[T], budget: usize) -> Vec<T> {
    let mut used = 0;
    let mut kept = Vec::new();
    for item in items.iter().rev() {
        let size = serde_json::to_vec(item).map(|v| v.len()).unwrap_or(budget);
        if used + size > budget {
            break;
        }
        used += size;
        kept.push(item.clone());
    }
    kept.reverse();
    kept
}

// MARK: Timeline

/// One step of a session's conversation (`TimelineEntry`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineEntry {
    pub id: String,
    /// user, assistant, tool, change, error or notice.
    pub kind: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub date: f64,
    pub failed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clipped: Option<bool>,
}

impl TimelineEntry {
    /// The most of one entry `entry` sends (`TimelineEntry.fullLimit`).
    pub const FULL_LIMIT: usize = 100_000;
    /// How much of a step's output travels (`TimelineEntry.outputLimit`).
    pub const OUTPUT_LIMIT: usize = 900;
    /// The `detail` of a compaction note.
    pub const COMPACTED: &'static str = "compacted";
}

/// The end of a step's output, at most [`TimelineEntry::OUTPUT_LIMIT`] characters, starting at a line.
pub fn output_tail(output: Option<&str>) -> Option<String> {
    let trimmed = output?.trim();
    if trimmed.is_empty() {
        return None;
    }
    let count = trimmed.chars().count();
    if count <= TimelineEntry::OUTPUT_LIMIT {
        return Some(trimmed.to_string());
    }
    let tail: String = trimmed.chars().skip(count - TimelineEntry::OUTPUT_LIMIT).collect();
    let from_line = match tail.find('\n') {
        Some(i) => tail[i + 1..].to_string(),
        None => tail,
    };
    Some(format!("…\n{from_line}"))
}

/// The note the manager writes when the agent compacted its context (`ClaudeEvent::Notice("compact")`).
pub const COMPACTION_NOTE: &str = "De agent heeft het gesprek samengevat om ruimte te maken in de context.";

fn seconds(date: chrono::DateTime<chrono::Utc>) -> f64 {
    date.timestamp_millis() as f64 / 1000.0
}

/// What a step was about, as a terminal session's step says it ("npm test", not "Bash · npm test").
fn step_summary(text: &str, tool: Option<&str>) -> String {
    let text = text.trim_start_matches("↳ ").trim();
    if let Some((_, rest)) = text.split_once(" · ") {
        return rest.trim().to_string();
    }
    if tool.is_some_and(|t| t == text) {
        return String::new();
    }
    text.to_string()
}

/// What the phone shows of one event; thinking, approvals and turn results are left out (`CompanionServer.entry`).
pub fn timeline_entry(event: &RunEvent) -> Option<TimelineEntry> {
    let mut text = event.text.clone();
    let mut detail = event.tool.clone();
    let kind = match event.kind {
        EventKind::User => "user",
        EventKind::Assistant => "assistant",
        EventKind::Tool => {
            text = step_summary(&event.text, event.tool.as_deref());
            "tool"
        }
        EventKind::FileChange => {
            if text.is_empty() {
                text = event.detail.clone().unwrap_or_default();
            }
            "change"
        }
        EventKind::Error => "error",
        // How the agent was started is for the computer, not the phone.
        EventKind::System if event.tool.as_deref() == Some("launch") => return None,
        EventKind::System if event.text == COMPACTION_NOTE => {
            detail = Some(TimelineEntry::COMPACTED.into());
            "notice"
        }
        EventKind::System => {
            detail = None;
            "notice"
        }
        EventKind::Thinking | EventKind::Approval | EventKind::Result => return None,
    };
    let clipped = clip(&text, LINE_LIMIT);
    // A step can be about nothing in particular (a task list): its tool alone says what it was.
    if clipped.is_empty() && kind != "tool" {
        return None;
    }
    let output = if kind == "tool" || kind == "change" { output_tail(event.output.as_deref()) } else { None };
    let was = kind != "tool" && was_clipped(&clipped, LINE_LIMIT);
    Some(TimelineEntry {
        id: event.id.to_string(),
        kind: kind.into(),
        text: clipped,
        detail: detail.map(|d| clip(&d, 120)),
        date: seconds(event.date),
        failed: event.state == Some(EventState::Failed),
        output,
        clipped: was.then_some(true),
    })
}

/// Whether an event has this id, in either case (the Mac sends upper case ids).
pub fn same_id(event: &RunEvent, id: &str) -> bool {
    event.id.to_string().eq_ignore_ascii_case(id)
}

/// The recent conversation of a session within one answer; with `before`, the page older than that entry (empty when
/// there is none or the entry is unknown).
pub fn timeline_page(events: &[RunEvent], before: Option<&str>) -> Vec<TimelineEntry> {
    let events = match before {
        Some(id) => match events.iter().position(|e| same_id(e, id)) {
            Some(index) => &events[..index],
            None => return vec![],
        },
        None => events,
    };
    let mut page = Vec::new();
    for event in events.iter().rev() {
        if let Some(entry) = timeline_entry(event) {
            page.push(entry);
        }
        if page.len() == PAGE_ENTRIES {
            break;
        }
    }
    page.reverse();
    newest_fitting(&page, LINES_BUDGET)
}

/// The conversation of an agent in a terminal, from its own transcript (prompts and answers; thinking stays out). The
/// transcript has no times, so every entry carries `date` (when the session was last heard from).
pub fn transcript_page(messages: &[AgentChatMessage], date: f64, before: Option<&str>) -> Vec<TimelineEntry> {
    let messages = match before {
        Some(id) => match messages.iter().position(|m| m.id == id) {
            Some(index) => &messages[..index],
            None => return vec![],
        },
        None => messages,
    };
    let mut page: Vec<TimelineEntry> = messages
        .iter()
        .rev()
        .filter_map(|m| {
            let kind = match m.kind {
                ChatKind::User => "user",
                ChatKind::Assistant => "assistant",
                ChatKind::Thinking => return None,
            };
            let text = clip(&m.text, LINE_LIMIT);
            (!text.is_empty()).then(|| TimelineEntry {
                id: m.id.clone(),
                kind: kind.into(),
                clipped: was_clipped(&text, LINE_LIMIT).then_some(true),
                text,
                detail: None,
                date,
                failed: false,
                output: None,
            })
        })
        .take(PAGE_ENTRIES)
        .collect();
    page.reverse();
    newest_fitting(&page, LINES_BUDGET)
}

// MARK: Starting a session

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchModel {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchAgent {
    pub id: String,
    pub name: String,
    pub can_plan: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub models: Option<Vec<LaunchModel>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_main_thread: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchProject {
    pub path: String,
    pub name: String,
    pub can_worktree: bool,
}

/// What the phone may choose from to start a session (`LaunchOptions`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchOptions {
    pub agents: Vec<LaunchAgent>,
    pub projects: Vec<LaunchProject>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_project: Option<String>,
    pub default_plan: bool,
    pub default_worktree: bool,
}

/// Whether a session may run with this policy while nobody watches the computer (`PermissionPolicy.isUnattendedSafe`).
pub fn unattended_safe(policy: PermissionPolicy) -> bool {
    !matches!(policy, PermissionPolicy::Bypass)
}

/// The user's default for this agent, at most "allow edits": a session started from a phone keeps asking. Plan mode
/// takes the safest policy, as the composer does (`CompanionServer.phonePermission`).
pub fn phone_permission(provider: RunProvider, preferred: PermissionPolicy, plan: bool) -> PermissionPolicy {
    let offered: Vec<PermissionPolicy> = provider.capabilities().policies.into_iter().filter(|p| unattended_safe(*p)).collect();
    if plan {
        return offered.first().copied().unwrap_or(PermissionPolicy::AcceptEdits);
    }
    if offered.contains(&preferred) {
        preferred
    } else if offered.contains(&PermissionPolicy::AcceptEdits) {
        PermissionPolicy::AcceptEdits
    } else {
        offered.first().copied().unwrap_or(PermissionPolicy::AcceptEdits)
    }
}

// MARK: Managing a session

/// What the phone may do to a session Nook runs here (`SessionAction` names): rename it, and archive it once it rests.
/// Snoozing and the main thread are not part of this app's workspace, so they are not offered.
pub fn run_actions(run: &WorkspaceRun) -> Vec<String> {
    let mut actions = vec!["rename".to_string()];
    if !run.status.is_active() {
        actions.push("archive".into());
    }
    actions
}

// MARK: Changes

/// One file a session changed (`DiffFileDigest`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffFileDigest {
    pub path: String,
    /// added, modified, deleted, renamed, copied, untracked, conflicted or typeChanged (`GitChangeKind`).
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub patch: Option<String>,
    pub truncated: bool,
}

impl DiffFileDigest {
    pub const MAX_PATCH: usize = 40 * 1024;
    pub const MAX_TOTAL: usize = 150 * 1024;
    pub const MAX_FILES: usize = 60;
}

pub fn change_kind(kind: ChangeKind) -> &'static str {
    match kind {
        ChangeKind::Added => "added",
        ChangeKind::Modified => "modified",
        ChangeKind::Deleted => "deleted",
        ChangeKind::Renamed => "renamed",
        ChangeKind::Copied => "copied",
        ChangeKind::Untracked => "untracked",
        ChangeKind::Conflicted => "conflicted",
        ChangeKind::TypeChanged => "typeChanged",
    }
}

/// The longest start of `text` of at most `bytes` bytes that ends on a character.
fn byte_prefix(text: &str, bytes: usize) -> &str {
    let mut end = bytes.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

/// Every changed file, the most changed first, with its patch while they fit in one answer (`CompanionServer.diff`).
pub fn diff_digests(mut files: Vec<FileChange>, patch: impl Fn(&FileChange) -> Option<String>) -> Vec<DiffFileDigest> {
    let size = |f: &FileChange| f.added.unwrap_or(0) + f.removed.unwrap_or(0);
    files.sort_by_key(|f| std::cmp::Reverse(size(f)));
    let mut total = 0;
    files
        .into_iter()
        .take(DiffFileDigest::MAX_FILES)
        .map(|file| {
            let mut text = patch(&file);
            let mut truncated = false;
            if let Some(full) = &text {
                let room = DiffFileDigest::MAX_PATCH.min(DiffFileDigest::MAX_TOTAL.saturating_sub(total));
                if full.len() > room {
                    text = (room > 0).then(|| byte_prefix(full, room).to_string());
                    truncated = true;
                }
                total += text.as_ref().map(String::len).unwrap_or(0);
            }
            DiffFileDigest {
                path: file.path.clone(),
                kind: change_kind(file.kind).into(),
                added: file.added,
                removed: file.removed,
                patch: text,
                truncated,
            }
        })
        .collect()
}

// MARK: Older sessions

/// The newest sessions the live list holds, and one page of `history` (`CompanionHistory`).
pub const LIVE_COUNT: usize = 25;
pub const PAGE_SIZE: usize = 25;
pub const MAX_QUERY: usize = 200;

/// The words of a search, cleaned: no control characters, at most [`MAX_QUERY`] characters.
pub fn clean_query(query: Option<&str>) -> String {
    let kept: String = query.unwrap_or_default().chars().filter(|c| !c.is_control()).collect();
    kept.trim().chars().take(MAX_QUERY).collect()
}

fn fold(text: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    text.nfd().filter(|c| !unicode_normalization::char::is_combining_mark(*c)).collect::<String>().to_lowercase()
}

/// Whether every word of `query` is found in one of `fields`, ignoring case and accents.
pub fn matches_query(query: &str, fields: &[&str]) -> bool {
    let fields: Vec<String> = fields.iter().map(|f| fold(f)).collect();
    query.split_whitespace().all(|word| {
        let word = fold(word);
        fields.iter().any(|f| f.contains(&word))
    })
}

/// Where a page ends: the last session's time and id ("1700000000.000000|id").
fn parse_cursor(text: Option<&str>) -> Option<(f64, String)> {
    let (time, id) = text?.split_once('|')?;
    let updated: f64 = time.parse().ok().filter(|t: &f64| t.is_finite())?;
    Some((updated, id.to_string()))
}

/// One page of `items` (newest first, then by id), after `cursor`: at most `limit`, and the next cursor while there are
/// more (`CompanionHistory.page`).
pub fn history_page<T: Clone>(
    items: &[T],
    updated: impl Fn(&T) -> f64,
    id: impl Fn(&T) -> String,
    cursor: Option<&str>,
    limit: usize,
) -> (Vec<T>, Option<String>) {
    let mut sorted: Vec<&T> = items.iter().collect();
    sorted.sort_by(|a, b| {
        let (ua, ub) = (updated(a), updated(b));
        if ua != ub {
            ub.partial_cmp(&ua).unwrap_or(std::cmp::Ordering::Equal)
        } else {
            id(a).cmp(&id(b))
        }
    });
    let rest: Vec<&T> = match parse_cursor(cursor) {
        Some((at, after)) => sorted.into_iter().filter(|x| updated(x) < at || (updated(x) == at && id(x) > after)).collect(),
        None => sorted,
    };
    let page: Vec<T> = rest.iter().take(limit.max(1)).map(|x| (*x).clone()).collect();
    let next = (rest.len() > page.len()).then(|| page.last().map(|l| format!("{:.6}|{}", updated(l), id(l)))).flatten();
    (page, next)
}

// MARK: A session's folder

/// One terminal of a session: its last lines (`TerminalDigest`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalDigest {
    pub id: String,
    pub title: String,
    pub running: bool,
    pub output: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderEntry {
    pub name: String,
    pub is_folder: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
}

/// One folder, or one file's text (`FolderDigest`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderDigest {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entries: Option<Vec<FolderEntry>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary: Option<bool>,
}

/// A piece of one file (`FileChunk`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChunk {
    pub path: String,
    pub offset: u64,
    pub total: u64,
    pub data: String,
}

impl FileChunk {
    pub const MAX_CHUNK_BYTES: u64 = 128 * 1024;
    pub const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;

    /// What to read for a request from `offset` in a file of `total` bytes; `None` for an offset outside it, or a file
    /// too large to preview.
    pub fn range(offset: i64, total: u64) -> Option<std::ops::Range<u64>> {
        if total > Self::MAX_FILE_BYTES || offset < 0 {
            return None;
        }
        let offset = offset as u64;
        if !(offset < total || (offset == 0 && total == 0)) {
            return None;
        }
        Some(offset..total.min(offset + Self::MAX_CHUNK_BYTES))
    }
}

pub const MAX_TEXT_BYTES: usize = 128 * 1024;
pub const MAX_ENCODED_BYTES: usize = 200 * 1024;
pub const MAX_ENTRIES: usize = 500;
pub const MAX_TERMINAL_LINES: usize = 200;

/// `.git` and what holds keys by its name: these never go to the phone (`CompanionWorkspace.isSecret`).
pub fn is_secret(name: &str) -> bool {
    let lower = name.to_lowercase();
    if [".git", ".ssh", ".aws", ".npmrc", ".netrc"].contains(&lower.as_str()) {
        return true;
    }
    if lower == ".env" || lower.starts_with(".env.") {
        return !lower.ends_with(".example") && !lower.ends_with(".sample");
    }
    if lower.starts_with("id_rsa") || lower.starts_with("id_ed25519") {
        return true;
    }
    [".pem", ".key", ".p12", ".pfx", ".keychain"].iter().any(|s| lower.ends_with(s))
}

fn names(path: &Path) -> Vec<String> {
    path.components()
        .filter_map(|c| match c {
            std::path::Component::Normal(n) => Some(n.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect()
}

/// The real path of `relative` (with `/` between its parts) in `folder`, or `None` when it leaves the folder or passes
/// a secret. Links are followed first (`resolve`), so one that points out of the folder stays out.
pub fn resolve_in(relative: &str, folder: &str, resolve: impl Fn(&Path) -> Option<PathBuf>) -> Option<PathBuf> {
    let parts: Vec<&str> = relative.split('/').filter(|p| !p.is_empty()).collect();
    if relative.starts_with('/') || parts.iter().any(|p| *p == ".." || *p == "." || p.contains(['\\', ':']) || is_secret(p)) {
        return None;
    }
    let root = resolve(Path::new(folder))?;
    // A session in ~/.ssh or ~/.aws is all secret, whatever its files are called.
    if names(&root).iter().any(|n| is_secret(n)) {
        return None;
    }
    let mut joined = PathBuf::from(folder);
    joined.extend(&parts);
    let full = resolve(&joined)?;
    let inside = full.strip_prefix(&root).ok()?;
    // A link inside the folder can hide a secret's real name.
    if names(inside).iter().any(|n| is_secret(n)) {
        return None;
    }
    Some(full)
}

/// A file's bytes as an answer (`CompanionWorkspace.digest`).
pub fn file_digest(path: &str, data: &[u8]) -> FolderDigest {
    let head = &data[..data.len().min(MAX_TEXT_BYTES)];
    if head.contains(&0) {
        return FolderDigest { path: path.into(), binary: Some(true), ..Default::default() };
    }
    let mut text = std::str::from_utf8(head).ok();
    if text.is_none() && data.len() > MAX_TEXT_BYTES {
        // A cut can fall inside a character of up to four bytes.
        text = (1..=3).find_map(|drop| std::str::from_utf8(&head[..head.len().saturating_sub(drop)]).ok());
    }
    let Some(text) = text else { return FolderDigest { path: path.into(), binary: Some(true), ..Default::default() } };
    let mut text = text.to_string();
    let mut shortened = data.len() > MAX_TEXT_BYTES;
    while !text.is_empty() && serde_json::to_vec(&text).map(|v| v.len()).unwrap_or(0) > MAX_ENCODED_BYTES {
        let half = text.chars().count() / 2;
        text = text.chars().take(half).collect();
        shortened = true;
    }
    FolderDigest { path: path.into(), text: Some(text), truncated: shortened.then_some(true), ..Default::default() }
}

/// A folder's entries: folders first, without secrets, cut at [`MAX_ENTRIES`] (`CompanionWorkspace.listing`).
pub fn listing(path: &str, entries: Vec<FolderEntry>) -> FolderDigest {
    let mut shown: Vec<FolderEntry> = entries.into_iter().filter(|e| !is_secret(&e.name)).collect();
    shown.sort_by_key(|e| (!e.is_folder, e.name.to_lowercase()));
    let more = shown.len() > MAX_ENTRIES;
    shown.truncate(MAX_ENTRIES);
    FolderDigest { path: path.into(), entries: Some(shown), truncated: more.then_some(true), ..Default::default() }
}

/// The terminals in one answer: as many as fit, each cut from its top when needed (`CompanionWorkspace.fitting`).
pub fn fitting(terminals: Vec<TerminalDigest>) -> Vec<TerminalDigest> {
    let size = |t: &TerminalDigest| serde_json::to_vec(t).map(|v| v.len()).unwrap_or(0);
    let mut room = MAX_ENCODED_BYTES;
    terminals
        .into_iter()
        .filter_map(|mut t| {
            while size(&t) > room && !t.output.is_empty() {
                let count = t.output.chars().count();
                t.output = t.output.chars().skip(count - count / 2).collect();
            }
            let used = size(&t);
            if used > room {
                return None;
            }
            room -= used;
            Some(t)
        })
        .collect()
}

// MARK: Pictures from the phone

/// The pictures of a request, checked (JPEGs within the limit, at most `MAX_COUNT`); `None` when one may not go.
pub fn image_bytes(images: Option<&[CompanionImage]>) -> Option<Vec<Vec<u8>>> {
    let images = images.unwrap_or_default();
    if images.len() > CompanionImage::MAX_COUNT || images.iter().any(|i| !i.is_valid()) {
        return None;
    }
    images.iter().map(|i| base64::engine::general_purpose::STANDARD.decode(&i.jpeg).ok()).collect()
}

/// The words with the pictures' paths under them (`CompanionImages.attach`).
pub fn attach_paths(words: &str, paths: &[String]) -> String {
    if paths.is_empty() {
        return words.to_string();
    }
    let words = words.trim();
    let head = if words.is_empty() { String::new() } else { format!("{words}\n\n") };
    head + &paths.join("\n")
}

/// Saves one picture where the composer keeps pictures for agents (`<support>/images/phone-xxxxxxxx.jpg`), readable by
/// the user only.
pub fn save_image(folder: &Path, data: &[u8]) -> Option<PathBuf> {
    std::fs::create_dir_all(folder).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700));
    }
    let name = format!("phone-{}.jpg", &uuid::Uuid::new_v4().simple().to_string()[..8]);
    let path = folder.join(name);
    crate::paths::write_atomic(&path, data).ok()?;
    Some(path)
}

/// The user's words from the phone with the pictures that came along as paths below them; `None` when there are
/// neither, or a picture is not one the phone may send (`CompanionServer.message`).
pub fn message(request: &CompanionRequest, folder: &Path) -> Option<String> {
    let images = image_bytes(request.images.as_deref())?;
    let words = match CompanionPolicy::clean_message(request.text.as_deref().unwrap_or_default()) {
        Some(w) => w,
        None if !images.is_empty() => String::new(),
        None => return None,
    };
    let paths: Option<Vec<String>> = images.iter().map(|data| save_image(folder, data).map(|p| p.to_string_lossy().into_owned())).collect();
    Some(attach_paths(&words, &paths?))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::workspace::models::RunStatus;

    fn event(kind: EventKind, text: &str) -> RunEvent {
        RunEvent::new(kind, text)
    }

    #[test]
    fn clip_matches_the_mac() {
        assert_eq!(clip("  hi\r\n ", 10), "hi");
        assert_eq!(clip("abcdefghijk", 10), "abcdefghij…");
        assert!(was_clipped(&clip("abcdefghijk", 10), 10));
        assert!(!was_clipped(&clip("abc", 10), 10));
        let long = "x".repeat(LINE_LIMIT * 3);
        assert_eq!(clip(&long, LINE_LIMIT).chars().count(), LINE_LIMIT + 1);
    }

    #[test]
    fn newest_fitting_keeps_the_newest_in_order() {
        let items: Vec<String> = (0..10).map(|i| format!("{i}{}", "x".repeat(8))).collect();
        // Every item is 12 bytes of JSON ("0xxxxxxxx" with quotes is 11 + 0); three fit in 36.
        let kept = newest_fitting(&items, 3 * serde_json::to_vec(&items[0]).unwrap().len());
        assert_eq!(kept, items[7..].to_vec());
    }

    #[test]
    fn output_tail_starts_at_a_line() {
        assert_eq!(output_tail(Some("  \n ")), None);
        assert_eq!(output_tail(Some(" ok \n")), Some("ok".into()));
        let long = format!("{}\nlast line", "a".repeat(2000));
        let tail = output_tail(Some(&long)).unwrap();
        assert!(tail.starts_with("…\n"));
        assert!(tail.ends_with("last line"));
    }

    #[test]
    fn events_become_entries_with_the_swift_field_names() {
        let mut tool = event(EventKind::Tool, "Bash · npm test").with_tool("Bash").with_state(EventState::Failed);
        tool.output = Some("1 failed".into());
        let entry = timeline_entry(&tool).unwrap();
        let value = serde_json::to_value(&entry).unwrap();
        assert_eq!(value["kind"], "tool");
        assert_eq!(value["text"], "npm test");
        assert_eq!(value["detail"], "Bash");
        assert_eq!(value["failed"], true);
        assert_eq!(value["output"], "1 failed");
        assert!(value.get("clipped").is_none(), "nil keys stay out, as Swift's encoder leaves them out");
        assert_eq!(value["id"], tool.id.to_string());
        let keys: Vec<&str> = value.as_object().unwrap().keys().map(String::as_str).collect();
        for key in keys {
            assert!(["id", "kind", "text", "detail", "date", "failed", "output", "clipped"].contains(&key), "{key}");
        }

        let plain = timeline_entry(&event(EventKind::Tool, "TodoWrite").with_tool("TodoWrite")).unwrap();
        assert_eq!(plain.text, "", "a step about nothing in particular keeps its tool");

        let change = event(EventKind::FileChange, "src/a.rs").with_tool("modified").with_detail("/w/src/a.rs");
        let change = timeline_entry(&change).unwrap();
        assert_eq!((change.kind.as_str(), change.text.as_str(), change.detail.as_deref()), ("change", "src/a.rs", Some("modified")));

        let compacted = timeline_entry(&event(EventKind::System, COMPACTION_NOTE)).unwrap();
        assert_eq!((compacted.kind.as_str(), compacted.detail.as_deref()), ("notice", Some("compacted")));
        let mut launch = event(EventKind::System, "claude -p");
        launch.tool = Some("launch".into());
        assert!(timeline_entry(&launch).is_none());
        assert!(timeline_entry(&event(EventKind::Thinking, "hmm")).is_none());
        assert!(timeline_entry(&event(EventKind::Assistant, "  ")).is_none());

        let long = timeline_entry(&event(EventKind::Assistant, &"y".repeat(LINE_LIMIT + 5))).unwrap();
        assert_eq!(long.clipped, Some(true));
    }

    #[test]
    fn timeline_pages_back_from_an_entry() {
        let events: Vec<RunEvent> = (0..400).map(|i| event(EventKind::Assistant, &format!("line {i}"))).collect();
        let newest = timeline_page(&events, None);
        assert_eq!(newest.len(), PAGE_ENTRIES);
        assert_eq!(newest.last().unwrap().text, "line 399");
        let older = timeline_page(&events, Some(&newest[0].id.to_uppercase()));
        assert_eq!(older.last().unwrap().text, "line 239");
        assert!(timeline_page(&events, Some("unknown")).is_empty());
    }

    #[test]
    fn a_transcript_leaves_thinking_out() {
        let m = |id: &str, kind, text: &str| AgentChatMessage { id: id.into(), kind, text: text.into() };
        let messages = vec![m("a", ChatKind::User, "Fix it"), m("b", ChatKind::Thinking, "hmm"), m("c", ChatKind::Assistant, "Done")];
        let page = transcript_page(&messages, 5.0, None);
        assert_eq!(page.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(), vec!["user", "assistant"]);
        assert_eq!(transcript_page(&messages, 5.0, Some("c")).len(), 1);
    }

    #[test]
    fn the_phone_never_starts_without_asking() {
        assert_eq!(phone_permission(RunProvider::Claude, PermissionPolicy::Bypass, false), PermissionPolicy::AcceptEdits);
        assert_eq!(phone_permission(RunProvider::Claude, PermissionPolicy::Ask, false), PermissionPolicy::Ask);
        assert_eq!(phone_permission(RunProvider::Codex, PermissionPolicy::AcceptEdits, true), PermissionPolicy::Ask);
        let options = LaunchOptions {
            agents: vec![LaunchAgent {
                id: "claude".into(),
                name: "Claude Code".into(),
                can_plan: true,
                models: Some(vec![LaunchModel { id: "".into(), name: "Default".into() }]),
                default_model: Some("".into()),
                can_main_thread: None,
            }],
            projects: vec![LaunchProject { path: "/w/app".into(), name: "app".into(), can_worktree: true }],
            default_agent: Some("claude".into()),
            default_project: None,
            default_plan: false,
            default_worktree: true,
        };
        let value = serde_json::to_value(&options).unwrap();
        assert_eq!(value["agents"][0]["canPlan"], true);
        assert_eq!(value["agents"][0]["defaultModel"], "");
        assert_eq!(value["projects"][0]["canWorktree"], true);
        assert_eq!(value["defaultWorktree"], true);
        assert!(value.get("defaultProject").is_none());
    }

    #[test]
    fn actions_follow_the_run() {
        let run = crate::workspace::models::tests::run(RunStatus::Running);
        assert_eq!(run_actions(&run), vec!["rename"]);
        let done = crate::workspace::models::tests::run(RunStatus::Completed);
        assert_eq!(run_actions(&done), vec!["rename", "archive"]);
    }

    #[test]
    fn diffs_fit_one_answer() {
        let file = |path: &str, added| FileChange {
            path: path.into(),
            old_path: None,
            kind: ChangeKind::Modified,
            staged: false,
            unstaged: true,
            added: Some(added),
            removed: Some(0),
        };
        let files = vec![file("small", 1), file("big", 100), file("new", 50)];
        let list = diff_digests(files, |f| Some(if f.path == "big" { "é".repeat(30_000) } else { "+x\n".into() }));
        assert_eq!(list.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(), vec!["big", "new", "small"]);
        assert!(list[0].truncated);
        assert!(list[0].patch.as_ref().unwrap().len() <= DiffFileDigest::MAX_PATCH);
        assert!(!list[1].truncated);
        let value = serde_json::to_value(&list[1]).unwrap();
        assert_eq!(value, json!({"path": "new", "kind": "modified", "added": 50, "removed": 0, "patch": "+x\n", "truncated": false}));
        assert_eq!(change_kind(ChangeKind::TypeChanged), "typeChanged");
    }

    #[test]
    fn history_pages_and_searches() {
        let items: Vec<(f64, String)> = (0..60).map(|i| (i as f64, format!("id{i:02}"))).collect();
        let (first, cursor) = history_page(&items, |x| x.0, |x| x.1.clone(), None, PAGE_SIZE);
        assert_eq!(first[0].1, "id59");
        assert_eq!(cursor.as_deref(), Some("35.000000|id35"));
        let (second, _) = history_page(&items, |x| x.0, |x| x.1.clone(), cursor.as_deref(), PAGE_SIZE);
        assert_eq!(second[0].1, "id34");
        let (last, end) = history_page(&items, |x| x.0, |x| x.1.clone(), Some("10.000000|id10"), PAGE_SIZE);
        assert_eq!((last.len(), end), (10, None));

        assert!(matches_query("cafe LOGIN", &["Fix the login", "Café"]));
        assert!(!matches_query("cafe bug", &["Fix the login", "Café"]));
        assert!(matches_query("", &[]));
        assert_eq!(clean_query(Some(" a\u{7}b ")), "ab");
    }

    #[test]
    fn the_folder_keeps_its_secrets() {
        assert!(is_secret(".env") && is_secret(".env.local") && !is_secret(".env.example"));
        assert!(is_secret("id_rsa.pub") && is_secret("cert.PEM") && is_secret(".git"));
        assert!(!is_secret("main.rs"));
        let identity = |p: &Path| Some(p.to_path_buf());
        assert_eq!(resolve_in("src/main.rs", "/w/app", identity), Some(PathBuf::from("/w/app/src/main.rs")));
        assert_eq!(resolve_in("", "/w/app", identity), Some(PathBuf::from("/w/app")));
        assert_eq!(resolve_in("../etc", "/w/app", identity), None);
        assert_eq!(resolve_in("/etc", "/w/app", identity), None);
        assert_eq!(resolve_in("a\\..\\..", "/w/app", identity), None);
        assert_eq!(resolve_in(".env", "/w/app", identity), None);
        assert_eq!(resolve_in("x", "/home/m/.ssh", identity), None);
        // A link that leads out of the folder, or to a secret by its real name.
        let out = |p: &Path| Some(if p.ends_with("link") { PathBuf::from("/etc/passwd") } else { p.to_path_buf() });
        assert_eq!(resolve_in("link", "/w/app", out), None);
        let hidden = |p: &Path| Some(if p.ends_with("link") { PathBuf::from("/w/app/.git/config") } else { p.to_path_buf() });
        assert_eq!(resolve_in("link", "/w/app", hidden), None);
    }

    #[test]
    fn files_and_listings() {
        assert_eq!(file_digest("a", b"hi\0").binary, Some(true));
        let text = file_digest("a", "hallo".as_bytes());
        assert_eq!((text.text.as_deref(), text.truncated), (Some("hallo"), None));
        let mut big = "é".repeat(MAX_TEXT_BYTES / 2).into_bytes();
        big.insert(0, b'a');
        let cut = file_digest("a", &big);
        assert_eq!(cut.truncated, Some(true));
        assert!(cut.text.is_some(), "a cut inside a character is mended");

        let entries = vec![
            FolderEntry { name: "b.rs".into(), is_folder: false, size: Some(3) },
            FolderEntry { name: ".env".into(), is_folder: false, size: Some(3) },
            FolderEntry { name: "Src".into(), is_folder: true, size: None },
            FolderEntry { name: "a.rs".into(), is_folder: false, size: Some(1) },
        ];
        let list = serde_json::to_value(listing("", entries)).unwrap();
        assert_eq!(
            list,
            json!({"path": "", "entries": [
                {"name": "Src", "isFolder": true},
                {"name": "a.rs", "isFolder": false, "size": 1},
                {"name": "b.rs", "isFolder": false, "size": 3}
            ]})
        );

        assert_eq!(FileChunk::range(0, 0), Some(0..0));
        assert_eq!(FileChunk::range(0, 10), Some(0..10));
        assert_eq!(FileChunk::range(10, 10), None);
        assert_eq!(FileChunk::range(-1, 10), None);
        assert_eq!(FileChunk::range(0, FileChunk::MAX_FILE_BYTES + 1), None);
        assert_eq!(FileChunk::range(0, 300 * 1024), Some(0..FileChunk::MAX_CHUNK_BYTES));

        let terminals = vec![
            TerminalDigest { id: "t1".into(), title: "a".into(), running: true, output: "x".repeat(150_000) },
            TerminalDigest { id: "t2".into(), title: "b".into(), running: false, output: "y".repeat(150_000) },
        ];
        let fit = fitting(terminals);
        let total: usize = fit.iter().map(|t| serde_json::to_vec(t).unwrap().len()).sum();
        assert!(total <= MAX_ENCODED_BYTES);
        assert_eq!(fit.len(), 2);
    }

    #[test]
    fn pictures_go_as_paths_below_the_words() {
        assert_eq!(attach_paths("Look", &[]), "Look");
        assert_eq!(attach_paths(" Look ", &["/a.jpg".into(), "/b.jpg".into()]), "Look\n\n/a.jpg\n/b.jpg");
        assert_eq!(attach_paths("", &["/a.jpg".into()]), "/a.jpg");
        let jpeg = base64::engine::general_purpose::STANDARD.encode([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]);
        let png = base64::engine::general_purpose::STANDARD.encode([0x89, b'P', b'N', b'G']);
        assert_eq!(image_bytes(Some(&[CompanionImage { jpeg: jpeg.clone() }])).map(|v| v.len()), Some(1));
        assert!(image_bytes(Some(&[CompanionImage { jpeg: png }])).is_none());
        assert!(image_bytes(Some(&vec![CompanionImage { jpeg: jpeg.clone() }; 3])).is_none());

        let dir = std::env::temp_dir().join(format!("nook-phone-images-{}", uuid::Uuid::new_v4()));
        let mut request = CompanionRequest::new(super::super::models::CompanionOp::Send);
        request.images = Some(vec![CompanionImage { jpeg }]);
        let text = message(&request, &dir).unwrap();
        let path = PathBuf::from(&text);
        assert!(path.starts_with(&dir) && path.exists());
        request.text = Some("See this".into());
        assert!(message(&request, &dir).unwrap().starts_with("See this\n\n"));
        request.images = None;
        request.text = Some("  ".into());
        assert!(message(&request, &dir).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }
}
