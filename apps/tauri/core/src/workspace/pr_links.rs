//! Pull request request-detection (`PullRequestAsked`, #1602) and timeline mention extraction
//! (`PullRequestMentions`) for workspace sessions (AG-123).

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::bridge::{parse_pr_url, PullRequestRef};
use super::models::{EventKind, RunEvent};

/// A pull or merge request referenced in a session command or user message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MentionedPullRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    pub number: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Working directory the command moved to before running (`cd ../app && gh pr view 12`); `None` means the session's folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
}

impl MentionedPullRequest {
    fn dedupe_key(&self) -> String {
        let base = if let Some(url) = &self.url {
            url.to_ascii_lowercase()
        } else if let Some(repo) = &self.repo {
            format!("{}#{}", repo.to_ascii_lowercase(), self.number)
        } else {
            format!("#{}", self.number)
        };
        format!("{}\n{}", self.directory.as_deref().unwrap_or(""), base)
    }
}

/// First pull/merge request URL mentioned in a timeline event (`RunPullRequestLinks.pullRequest(in:)` on macOS).
pub fn pull_request_in_event(event: &RunEvent) -> Option<PullRequestRef> {
    if event.rolled_back == Some(true) {
        return None;
    }
    let rx = link_regex();
    for field in [Some(event.text.as_str()), event.output.as_deref()].into_iter().flatten() {
        for m in rx.find_iter(field) {
            let trimmed = m.as_str().trim_end_matches(['.', ',', ';', ':', '!', '?']);
            if let Some(pr) = parse_pr_url(trimmed) {
                return Some(pr);
            }
        }
    }
    None
}

// ============================================================================
// PullRequestAsked (#1602): skip approval when the user asked for a PR
// ============================================================================

/// Whether the user asked this session for a pull request since the last PR appeared in the timeline.
/// A request already answered with a PR does not authorize a second one. When `delegated` is true,
/// the session's first user message is the delegating agent's brief rather than the user's own words.
pub fn asked_in_events(events: &[RunEvent], delegated: bool) -> bool {
    let first_user_id = if delegated { events.iter().find(|e| e.kind == EventKind::User).map(|e| e.id) } else { None };
    for event in events.iter().rev() {
        if pull_request_in_event(event).is_some() {
            return false;
        }
        if event.kind != EventKind::User || event.rolled_back == Some(true) {
            continue;
        }
        if Some(event.id) == first_user_id || is_from_agent(&event.text) {
            continue;
        }
        if asks_for_pr(&event.text) {
            return true;
        }
    }
    false
}

/// Whether the session's origin system line indicates it was delegated/started by another agent.
pub fn is_delegated_timeline(events: &[RunEvent]) -> bool {
    events.iter().take(4).any(|e| {
        if e.kind != EventKind::System || e.tool.as_deref() != Some("origin") {
            return false;
        }
        let lower = e.text.to_ascii_lowercase();
        lower.contains("delegat") || lower.contains("gedelegeerd") || lower.contains("another agent")
    })
}

/// A message another agent sent with `session_send` (never counts as the user asking for a PR).
pub fn is_from_agent(text: &str) -> bool {
    text.starts_with("Message from ") && text.contains("(another agent, not the user")
}

/// Whether one message from the user asks to create/open a pull request.
/// Rejects negations ("no PR yet") and questions about an existing PR ("is the PR still open?").
pub fn asks_for_pr(message: &str) -> bool {
    split_sentences(message).into_iter().any(|(sentence, question)| {
        let words = split_words(&sentence);
        if !names_pr(&words, &sentence) {
            return false;
        }
        if words.iter().any(|w| NEGATIONS.contains(&w.as_str())) {
            return false;
        }
        words.iter().any(|w| ACTIONS.contains(&w.as_str()) && !(question && ABOUT_EXISTING.contains(&w.as_str())))
    })
}

fn split_sentences(text: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let mut current = String::new();
    for ch in text.to_lowercase().chars() {
        if matches!(ch, '.' | '!' | '?' | '\n' | ';') {
            if !current.is_empty() {
                out.push((std::mem::take(&mut current), ch == '?'));
            }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        out.push((current, false));
    }
    out
}

fn split_words(sentence: &str) -> Vec<String> {
    sentence.split(|c: char| !c.is_alphanumeric()).filter(|s| !s.is_empty()).map(ToString::to_string).collect()
}

fn names_pr(words: &[String], sentence: &str) -> bool {
    if words.iter().any(|w| matches!(w.as_str(), "pr" | "prs" | "pullrequest" | "mr")) {
        return true;
    }
    ["pull request", "pull-request", "merge request", "merge-request"].iter().any(|p| sentence.contains(p))
}

const NEGATIONS: &[&str] = &[
    "no", "not", "don", "dont", "never", "without", "geen", "niet", "nooit", "zonder", "kein", "keine", "keinen", "nicht", "nie", "ohne",
    "pas", "ne", "sans", "jamais", "sin", "nunca",
];

const ACTIONS: &[&str] = &[
    "make",
    "create",
    "file",
    "submit",
    "raise",
    "send",
    "push",
    "put",
    "commit",
    "ship",
    "please",
    "maak",
    "maken",
    "aanmaken",
    "open",
    "openen",
    "indienen",
    "zet",
    "stuur",
    "doe",
    "graag",
    "aub",
    "mach",
    "mache",
    "erstelle",
    "erstellen",
    "öffne",
    "öffnen",
    "eröffne",
    "schick",
    "bitte",
    "fais",
    "faire",
    "crée",
    "créer",
    "ouvre",
    "ouvrir",
    "envoie",
    "stp",
    "svp",
    "haz",
    "hacer",
    "crea",
    "crear",
    "abre",
    "abrir",
    "envía",
    "envia",
    "favor",
];

const ABOUT_EXISTING: &[&str] = &[
    "open", "openen", "push", "commit", "send", "stuur", "ship", "put", "file", "zet", "doe", "öffne", "öffnen", "schick", "ouvre",
    "ouvrir", "envoie", "abre", "abrir", "envía", "envia",
];

// ============================================================================
// PullRequestMentions: CLI commands (`gh pr`, `glab mr`) & messages (`#12`, URLs)
// ============================================================================

fn command_regex() -> &'static Regex {
    static RX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RX.get_or_init(|| {
        Regex::new(
            r#"(?i)(?:^|[\s;&|(`"'])(?:gh\s+pr|glab\s+mr)\s+(?:checkout|co|view|show|checks|diff|edit|comment|note|merge|ready|review|approve|close|reopen|update-branch|rebase)\b([^;&|\n`)]*)"#,
        )
        .expect("valid PR command regex")
    })
}

fn change_dir_regex() -> &'static Regex {
    static RX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RX.get_or_init(|| Regex::new(r#"(?:^|[\s;&|(])(?:cd|pushd)\s+(?:-[LPe@]+\s+)*("[^"]*"|'[^']*'|[^\s;&|()]+)"#).expect("valid cd regex"))
}

fn link_regex() -> &'static Regex {
    static RX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RX.get_or_init(|| Regex::new(r#"(?i)https?://[^\s<>()\[\]"'`]+"#).expect("valid URL regex"))
}

fn hash_number_regex() -> &'static Regex {
    static RX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RX.get_or_init(|| Regex::new(r#"(^|[^\w#/&])#(\d{1,7})\b"#).expect("valid hash PR regex"))
}

const VALUE_FLAGS: &[&str] = &[
    "-b",
    "--body",
    "-F",
    "--body-file",
    "-t",
    "--title",
    "-m",
    "--message",
    "--subject",
    "-q",
    "--jq",
    "--json",
    "--template",
    "-B",
    "--base",
    "--branch",
    "--add-label",
    "--remove-label",
    "--add-reviewer",
    "--remove-reviewer",
    "--add-assignee",
    "--remove-assignee",
    "--milestone",
    "-i",
    "--interval",
    "--match-head-commit",
    "--author-email",
    "-A",
    "--assignee",
    "-l",
    "--label",
    "--reviewer",
    "--target-branch",
    "--source-branch",
    "--description",
];

/// Extracts pull requests targeted by shell commands (`gh pr ...` / `glab mr ...`), tracking preceding `cd`/`pushd`.
pub fn mentions_in_command(parts: &[&str], base_dir: Option<&str>) -> Vec<MentionedPullRequest> {
    let cmd_rx = command_regex();
    let cd_rx = change_dir_regex();
    let mut found = Vec::new();

    for text in parts {
        let moves: Vec<(usize, &str)> = cd_rx.captures_iter(text).filter_map(|c| Some((c.get(0)?.start(), c.get(1)?.as_str()))).collect();

        for cap in cmd_rx.captures_iter(text) {
            let Some(whole) = cap.get(0) else { continue };
            let Some(args) = cap.get(1) else { continue };
            let Some(mut mention) = parse_command_target(args.as_str()) else { continue };

            if mention.repo.is_none() && mention.url.is_none() {
                if let Some((_, raw_dir)) = moves.iter().rev().find(|(pos, _)| *pos < whole.start()) {
                    let Some(clean_dir) = normalize_dir_word(raw_dir) else {
                        // Unknown shell directory (`cd -`, `cd "$DIR"`): skip rather than guess the session's repo.
                        continue;
                    };
                    mention.directory = Some(resolve_relative(base_dir, &clean_dir));
                } else {
                    mention.directory = base_dir.map(ToString::to_string);
                }
            }
            found.push(mention);
        }
    }

    dedupe_mentions(found)
}

/// Working directory explicitly passed in a shell tool input (`workdir`, `cwd`, `Cwd`, `dir_path`, `directory`).
pub fn folder_in_input(input: &Map<String, Value>) -> Option<String> {
    for key in ["workdir", "cwd", "Cwd", "dir_path", "directory"] {
        if let Some(raw) = input.get(key).and_then(Value::as_str) {
            if let Some(dir) = normalize_dir_word(raw) {
                return Some(dir);
            }
        }
    }
    None
}

/// Extracts pull request URLs and standalone `#123` mentions from a user message.
pub fn mentions_in_message(text: &str) -> Vec<MentionedPullRequest> {
    let mut found = Vec::new();
    for m in link_regex().find_iter(text) {
        let url = m.as_str().trim_end_matches(['.', ',', ';', ':', '!', '?']);
        if let Some(pr) = parse_pr_url(url) {
            found.push(MentionedPullRequest { repo: Some(pr.repo), number: pr.number, url: Some(pr.url), directory: None });
        }
    }
    for cap in hash_number_regex().captures_iter(text) {
        if let Some(num) = cap.get(2).and_then(|m| m.as_str().parse::<i64>().ok()).filter(|&n| n > 0) {
            found.push(MentionedPullRequest { repo: None, number: num, url: None, directory: None });
        }
    }
    dedupe_mentions(found)
}

/// Collects all PR mentions across a session's timeline (user messages, CLI tool calls, and PR links in events).
pub fn mentions_in_events(events: &[RunEvent]) -> Vec<MentionedPullRequest> {
    let mut found = Vec::new();
    for event in events {
        if event.rolled_back == Some(true) {
            continue;
        }
        match event.kind {
            EventKind::User => {
                found.extend(mentions_in_message(&event.text));
            }
            EventKind::Tool => {
                let mut parts: Vec<String> = vec![event.text.clone()];
                let mut dir = None;
                if let Some(detail) = &event.detail {
                    if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(detail) {
                        dir = folder_in_input(&map);
                        for key in ["command", "CommandLine", "cmd", "script"] {
                            if let Some(s) = map.get(key).and_then(Value::as_str) {
                                parts.push(s.to_string());
                            }
                        }
                    } else {
                        parts.push(detail.clone());
                    }
                }
                let refs: Vec<&str> = parts.iter().map(String::as_str).collect();
                found.extend(mentions_in_command(&refs, dir.as_deref()));
                if let Some(pr) = pull_request_in_event(event) {
                    found.push(MentionedPullRequest { repo: Some(pr.repo), number: pr.number, url: Some(pr.url), directory: None });
                }
            }
            _ => {
                if let Some(pr) = pull_request_in_event(event) {
                    found.push(MentionedPullRequest { repo: Some(pr.repo), number: pr.number, url: Some(pr.url), directory: None });
                }
            }
        }
    }
    dedupe_mentions(found)
}

fn parse_command_target(arguments: &str) -> Option<MentionedPullRequest> {
    let words: Vec<&str> =
        arguments.split_whitespace().map(|w| w.trim_matches(|c| c == '"' || c == '\'')).filter(|w| !w.is_empty()).collect();
    let mut repo: Option<String> = None;
    let mut number: Option<i64> = None;
    let mut linked: Option<PullRequestRef> = None;
    let mut i = 0;

    while i < words.len() {
        let word = words[i];
        if word == "-R" || word == "--repo" {
            if i + 1 < words.len() {
                repo = Some(words[i + 1].to_string());
            }
            i += 2;
            continue;
        }
        if let Some(rest) = word.strip_prefix("--repo=") {
            repo = Some(rest.to_string());
        } else if word.starts_with('-') {
            if VALUE_FLAGS.contains(&word) {
                i += 1;
            }
        } else if number.is_none() && linked.is_none() {
            if word.contains("://") {
                if let Some(pr) = parse_pr_url(word) {
                    linked = Some(pr);
                }
            } else {
                let raw = word.strip_prefix('#').unwrap_or(word);
                if let Ok(n) = raw.parse::<i64>() {
                    if n > 0 {
                        number = Some(n);
                    }
                }
            }
        }
        i += 1;
    }

    if let Some(pr) = linked {
        return Some(MentionedPullRequest { repo: Some(pr.repo), number: pr.number, url: Some(pr.url), directory: None });
    }
    let number = number?;
    let clean_repo = repo.filter(|r| r.contains('/') && !r.contains("://"));
    Some(MentionedPullRequest { repo: clean_repo, number, url: None, directory: None })
}

fn normalize_dir_word(word: &str) -> Option<String> {
    let mut s = word.trim();
    if s.len() >= 2 && ((s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\''))) {
        s = &s[1..s.len() - 1];
    }
    if s.is_empty() || s == "-" || s.contains('$') || s.contains('`') {
        return None;
    }
    if let Some(rest) = s.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return Some(home.join(rest).to_string_lossy().into_owned());
        }
    }
    Some(s.to_string())
}

fn resolve_relative(base: Option<&str>, dir: &str) -> String {
    let path = Path::new(dir);
    if path.is_absolute() {
        return normalize_path(path);
    }
    match base {
        Some(b) => normalize_path(&Path::new(b).join(path)),
        None => dir.to_string(),
    }
}

fn normalize_path(path: &Path) -> String {
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out.to_string_lossy().into_owned()
}

fn dedupe_mentions(items: Vec<MentionedPullRequest>) -> Vec<MentionedPullRequest> {
    let mut seen = HashSet::new();
    items.into_iter().filter(|m| seen.insert(m.dedupe_key())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user_event(text: &str) -> RunEvent {
        RunEvent::new(EventKind::User, text)
    }

    #[test]
    fn pull_request_asked_detects_multilingual_requests_and_rejects_negations_and_questions() {
        assert!(asks_for_pr("Commit the changes and open a PR please."));
        assert!(asks_for_pr("Maak er een PR voor"));
        assert!(asks_for_pr("Bitte erstelle einen Pull Request."));
        assert!(asks_for_pr("Peux-tu créer une PR ?"));
        assert!(asks_for_pr("Haz un pull request por favor"));
        assert!(asks_for_pr("Can you make a PR?"));

        // Negations & questions about existing PRs must NOT auto-approve.
        assert!(!asks_for_pr("Commit this, no PR yet."));
        assert!(!asks_for_pr("Geen PR aanmaken, alleen committen."));
        assert!(!asks_for_pr("Is the PR still open?"));
        assert!(!asks_for_pr("Did you push to the PR?"));
        assert!(!asks_for_pr("Fix the failing test."));
    }

    #[test]
    fn asked_in_events_stops_at_existing_pr_and_ignores_delegated_and_agent_messages() {
        let events = vec![user_event("Fix it and open a PR")];
        assert!(asked_in_events(&events, false));
        // Delegated session: first user message is another agent's brief.
        assert!(!asked_in_events(&events, true));

        // Once a PR was already opened, the earlier request no longer approves a second PR.
        let after_pr = vec![
            user_event("Fix it and open a PR"),
            RunEvent::new(EventKind::System, "Pull request geopend: https://github.com/acme/web/pull/42"),
        ];
        assert!(!asked_in_events(&after_pr, false));

        // A follow-up request from the user after the first PR DOES approve a new PR.
        let mut second_pr = after_pr.clone();
        second_pr.push(user_event("Now open another PR for the docs"));
        assert!(asked_in_events(&second_pr, false));

        // Agent-to-agent message via session_send never counts.
        let from_other_agent = vec![user_event("Message from Reviewer (another agent, not the user): please open a PR now.")];
        assert!(!asked_in_events(&from_other_agent, false));
    }

    #[test]
    fn mentions_in_command_extracts_gh_and_glab_targets_with_cd_and_flags() {
        let found = mentions_in_command(
            &[
                "gh pr checks 3877",
                "gh pr view --json title -R acme/web 42",
                "gh pr comment 9 --body 99",
                "glab mr view 5 -R group/app",
                "gh pr checkout https://github.com/acme/api/pull/12",
            ],
            None,
        );
        assert_eq!(found.len(), 5);
        assert_eq!(found[0], MentionedPullRequest { repo: None, number: 3877, url: None, directory: None });
        assert_eq!(found[1], MentionedPullRequest { repo: Some("acme/web".into()), number: 42, url: None, directory: None });
        assert_eq!(found[2], MentionedPullRequest { repo: None, number: 9, url: None, directory: None });
        assert_eq!(found[3], MentionedPullRequest { repo: Some("group/app".into()), number: 5, url: None, directory: None });
        assert_eq!(
            found[4],
            MentionedPullRequest {
                repo: Some("acme/api".into()),
                number: 12,
                url: Some("https://github.com/acme/api/pull/12".into()),
                directory: None,
            }
        );

        // `cd` before a bare PR number records the target folder; unknown `cd -` or `cd "$DIR"` is skipped.
        let moved = mentions_in_command(
            &["cd ../other && gh pr view 7", "cd - && gh pr view 8", "cd \"$DIR\" && gh pr view 9"],
            Some("/work/repo"),
        );
        assert_eq!(moved.len(), 1);
        assert_eq!(moved[0].number, 7);
        assert_eq!(moved[0].repo, None);
        assert_eq!(moved[0].url, None);
        assert_eq!(moved[0].directory.as_deref().map(|d| d.replace('\\', "/")), Some("/work/other".into()));
    }

    #[test]
    fn mentions_in_message_finds_urls_and_standalone_hash_numbers() {
        let found = mentions_in_message("Check #3877, https://github.com/acme/web/pull/19. Ignore abc#99 and # 1 heading.");
        assert_eq!(
            found,
            vec![
                MentionedPullRequest {
                    repo: Some("acme/web".into()),
                    number: 19,
                    url: Some("https://github.com/acme/web/pull/19".into()),
                    directory: None,
                },
                MentionedPullRequest { repo: None, number: 3877, url: None, directory: None },
            ]
        );
    }
}
