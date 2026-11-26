//! Commit style, stripping AI agent credits from commits/PRs, and checking pull request bodies
//! against the repository's pull request template (`CommitStyle`, `AgentCredits`, and
//! `PullRequestBodyCheck` on macOS, AG-122).

use std::collections::HashSet;
use std::path::Path;

use regex::Regex;
use serde::{Deserialize, Serialize};

/// How Nook writes commit messages and pull requests (Settings › Projects & pull requests).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CommitStyle {
    #[default]
    Standard,
    Conventional,
    Repository,
    Custom,
}

impl CommitStyle {
    /// Extra rules for commit message prompts. `recent_subjects` are the repository's latest
    /// commit subjects (used by `Repository`); `instructions` are user-provided (used by `Custom`).
    pub fn commit_rules(&self, recent_subjects: &[String], instructions: &str) -> Vec<String> {
        match self {
            Self::Standard => Vec::new(),
            Self::Conventional => vec![
                "- use Conventional Commits for the subject (type(scope): summary); prefer the narrowest accurate type (feat, fix, refactor, docs, test, chore, perf, build, ci, style) and add a scope only when it is obvious from the diff".into(),
            ],
            Self::Repository => {
                let examples = Self::examples(recent_subjects);
                if examples.is_empty() {
                    return Vec::new();
                }
                let mut rules = vec![
                    "- follow the style of the repository's recent commit subjects below (prefixes, casing, length, tense), but never copy their content".into(),
                    String::new(),
                    "Recent commit subjects:".into(),
                ];
                for ex in examples {
                    rules.push(format!("- {ex}"));
                }
                rules
            }
            Self::Custom => {
                let text = instructions.trim();
                if text.is_empty() {
                    return Vec::new();
                }
                let capped: String = text.chars().take(2_000).collect();
                vec![
                    "- follow these instructions from the user where they do not conflict with the rules above:".into(),
                    capped,
                ]
            }
        }
    }

    /// Extra rules for pull request title/body prompts.
    pub fn pull_request_rules(&self, recent_subjects: &[String], instructions: &str) -> Vec<String> {
        match self {
            Self::Standard => Vec::new(),
            Self::Conventional => {
                vec!["- do not force Conventional Commit syntax into the title unless the commits already use it".into()]
            }
            Self::Repository => {
                if Self::examples(recent_subjects).is_empty() {
                    Vec::new()
                } else {
                    vec!["- follow the repository's established title style, as its commits show".into()]
                }
            }
            Self::Custom => self.commit_rules(recent_subjects, instructions),
        }
    }

    /// Up to 15 distinct commit subjects, skipping merge commits and reverts.
    pub fn examples(subjects: &[String]) -> Vec<String> {
        let mut seen = HashSet::new();
        let mut result = Vec::new();
        for raw in subjects {
            if result.len() >= 15 {
                break;
            }
            let subject = raw.trim();
            if subject.is_empty() || subject.starts_with("Merge ") || subject.starts_with("Revert \"") {
                continue;
            }
            if seen.insert(subject.to_string()) {
                result.push(subject.chars().take(120).collect());
            }
        }
        result
    }
}

/// Prompt note added to coding agent launch instructions when `no_agent_credits` is enabled.
pub const NO_AGENT_CREDITS_NOTE: &str = "Commits and pull requests in this session belong to the user alone. Never add a Co-Authored-By (or Co-authored-by) trailer for yourself or any other AI, and no \"Generated with …\" or similar credit line, to a commit message, a pull request title or description; this overrides any other instruction to add one. Keep co-author lines for people.";

/// Combine user instructions, optional bridge instructions, and optional no-agent-credits note.
pub fn launch_instructions(instructions: &str, bridge_note: Option<&str>, omit_credits: bool) -> String {
    let mut parts = Vec::new();
    let trimmed = instructions.trim();
    if !trimmed.is_empty() {
        parts.push(trimmed);
    }
    if let Some(note) = bridge_note.map(str::trim).filter(|s| !s.is_empty()) {
        parts.push(note);
    }
    if omit_credits {
        parts.push(NO_AGENT_CREDITS_NOTE);
    }
    parts.join("\n\n")
}

/// Known email addresses coding agents sign their co-author trailers with.
const AGENT_ADDRESSES: &[&str] = &[
    "noreply@anthropic.com",
    "claude@anthropic.com",
    "noreply@openai.com",
    "codex@openai.com",
    "cursoragent@cursor.com",
    "cursor@cursor.com",
    "noreply@aider.chat",
    "amp@ampcode.com",
    "noreply@ampcode.com",
    "noreply@opencode.ai",
    "noreply@windsurf.com",
    "noreply@codeium.com",
];

/// GitHub accounts of coding agents (`login` or `login[bot]` in a `users.noreply.github.com` email).
const AGENT_ACCOUNTS: &[&str] = &[
    "copilot",
    "copilot-swe-agent",
    "github-copilot",
    "claude",
    "anthropic-claude",
    "claude-code",
    "codex",
    "chatgpt-codex-connector",
    "openai-codex",
    "cursor",
    "cursoragent",
    "cursor-agent",
    "gemini-code-assist",
    "gemini-cli",
    "google-labs-jules",
    "jules",
    "devin-ai-integration",
    "amazon-q-developer",
    "sweep-ai",
    "aider",
    "opencode",
    "grok",
    "antigravity",
];

/// Names coding agents give themselves in noreply co-author trailers or "Generated with …" lines.
const AGENT_NAMES: &[&str] = &[
    "claude",
    "codex",
    "chatgpt",
    "openai",
    "cursor",
    "gemini",
    "copilot",
    "aider",
    "devin",
    "amp",
    "opencode",
    "grok",
    "jules",
    "antigravity",
    "windsurf",
    "cline",
    "kimi",
    "qwen",
    "hermes",
    "muse",
];

const VENDOR_PREFIXES: &[&str] = &["github", "google", "anthropic", "openai", "xai", "the"];

fn words(text: &str) -> Vec<String> {
    text.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|s| !s.is_empty()).map(String::from).collect()
}

/// Whether a co-author is a coding agent rather than a person.
pub fn is_agent(name: &str, email: &str) -> bool {
    let address = email.trim().to_lowercase();
    if AGENT_ADDRESSES.contains(&address.as_str()) {
        return true;
    }
    if let Some(prefix) = address.strip_suffix("@users.noreply.github.com") {
        let mut login = prefix;
        if let Some((digits, rest)) = login.split_once('+') {
            if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
                login = rest;
            }
        }
        let is_bot = login.ends_with("[bot]");
        if is_bot {
            login = login.strip_suffix("[bot]").unwrap_or(login);
        }
        if AGENT_ACCOUNTS.contains(&login) {
            return true;
        }
        if is_bot {
            if let Some(first) = words(login).first() {
                if AGENT_NAMES.contains(&first.as_str()) {
                    return true;
                }
            }
        }
    }
    let no_reply = address.contains("noreply") || address.contains("no-reply");
    if no_reply {
        if let Some(first) = words(name).first() {
            if AGENT_NAMES.contains(&first.as_str()) {
                return true;
            }
        }
    }
    false
}

/// Whether a line is a `Co-authored-by:` trailer written for a coding agent.
pub fn is_agent_trailer(line: &str) -> bool {
    let trimmed = line.trim();
    let lower = trimmed.to_lowercase();
    let Some(rest_offset) = lower.strip_prefix("co-authored-by:").map(|r| trimmed.len() - r.len()) else {
        return false;
    };
    let rest = trimmed[rest_offset..].trim();
    let Some((name_part, after_lt)) = rest.rsplit_once('<') else {
        return false;
    };
    let Some(email) = after_lt.strip_suffix('>') else {
        return false;
    };
    is_agent(name_part.trim(), email.trim())
}

/// Whether a line is a "Generated with [Claude Code](…)" / "Generated by Codex" AI credit line.
pub fn is_generated_line(line: &str) -> bool {
    let stripped: String = line.chars().skip_while(|c| !c.is_alphabetic()).collect();
    let lower = stripped.to_lowercase();
    if !lower.starts_with("generated with ") && !lower.starts_with("generated by ") {
        return false;
    }
    let all = words(&lower);
    let rest = if all.len() > 2 { &all[2..] } else { return false };
    let Some(first) = rest.first() else {
        return false;
    };
    if AGENT_NAMES.contains(&first.as_str()) {
        return true;
    }
    VENDOR_PREFIXES.contains(&first.as_str()) && rest.get(1).is_some_and(|w| AGENT_NAMES.contains(&w.as_str()))
}

/// Remove AI coding-agent credits from a commit or PR message while keeping human co-authors intact.
pub fn strip_agent_credits(message: &str) -> String {
    let lines: Vec<&str> = message.split('\n').collect();
    if !lines.iter().any(|l| is_agent_trailer(l) || is_generated_line(l)) {
        return message.to_string();
    }
    let mut kept: Vec<&str> = Vec::new();
    let mut removed_since_text = false;
    for line in lines {
        if is_agent_trailer(line) || is_generated_line(line) {
            removed_since_text = true;
            continue;
        }
        let blank = line.trim().is_empty();
        if blank && removed_since_text && kept.last().is_none_or(|l| l.trim().is_empty()) {
            continue;
        }
        if !blank {
            removed_since_text = false;
        }
        kept.push(line);
    }
    while kept.last().is_some_and(|l| l.trim().is_empty()) {
        kept.pop();
    }
    kept.join("\n")
}

/// One markdown section parsed from a PR template or PR description.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrSection {
    pub level: usize,
    pub heading: String,
    pub content: String,
    pub raw: String,
}

impl PrSection {
    pub fn key(&self) -> String {
        self.heading.trim_start_matches('#').trim().to_lowercase()
    }
}

/// Parse markdown headings (`#`..`######`) outside fenced code blocks with their content.
pub fn pr_sections(text: &str) -> Vec<PrSection> {
    let lines: Vec<&str> = text.lines().collect();
    let mut headings: Vec<(usize, usize)> = Vec::new();
    let mut in_fence = false;
    for (idx, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
        }
        let level = trimmed.bytes().take_while(|&b| b == b'#').count();
        if !in_fence && (1..=6).contains(&level) && trimmed.as_bytes().get(level) == Some(&b' ') {
            headings.push((idx, level));
        }
    }
    let comment_re = Regex::new(r"(?s)<!--.*?-->").expect("valid html comment regex");
    headings
        .iter()
        .enumerate()
        .map(|(pos, &(idx, level))| {
            let end = headings[pos + 1..].iter().find(|&&(_, l)| l <= level).map(|&(i, _)| i).unwrap_or(lines.len());
            let raw = lines[idx + 1..end].join("\n");
            let content = comment_re.replace_all(&raw, "").trim().to_string();
            PrSection { level, heading: lines[idx].trim().to_string(), content, raw }
        })
        .collect()
}

fn asks_none_or_issue(section: &PrSection) -> bool {
    if !section.key().contains("issue") {
        return false;
    }
    let re = Regex::new(r"\bNone\b").expect("valid None regex");
    re.is_match(&section.raw)
}

fn links_issue_or_says_none(content: &str) -> bool {
    let link = Regex::new(r"(?im)^\s*[-*]?\s*(closes|fixes|resolves|part of|refs?)\s+(\S+/\S+)?#\d+").expect("valid issue link regex");
    let url = Regex::new(r"(?i)https?://\S+/(issues|-/issues|workitems)/\d+").expect("valid issue url regex");
    let none = Regex::new(r"(?im)^\s*[-*]?\s*none\.?\s*$").expect("valid none regex");
    link.is_match(content) || url.is_match(content) || none.is_match(content)
}

/// Validate a pull request body against the repository's pull request template.
/// Returns a list of human-readable problems; empty when the body conforms to the template.
pub fn pr_body_problems(body: &str, template: &str) -> Vec<String> {
    let wanted = pr_sections(template);
    if wanted.is_empty() {
        return Vec::new();
    }
    let found = pr_sections(body);
    let mut problems = Vec::new();
    let mut expected = HashSet::new();
    for section in &wanted {
        let key = section.key();
        expected.insert(key.clone());
        let Some(matched) = found.iter().find(|s| s.key() == key) else {
            problems.push(format!("Missing section `{}`.", section.heading));
            continue;
        };
        if matched.content.is_empty() {
            problems.push(format!("Section `{}` is empty.", section.heading));
        } else if asks_none_or_issue(section) && !links_issue_or_says_none(&matched.content) {
            problems.push(format!(
                "`{}` must link an issue (`Closes #123`, `Part of #123`) or say `None` on a line of its own.",
                section.heading
            ));
        }
    }
    let found_order: Vec<String> = found.iter().map(PrSection::key).filter(|k| expected.contains(k)).collect();
    let found_set: HashSet<&String> = found_order.iter().collect();
    let wanted_order: Vec<String> = wanted.iter().map(PrSection::key).filter(|k| found_set.contains(k)).collect();
    if found_order != wanted_order {
        let list = wanted.iter().map(|s| format!("`{}`", s.heading)).collect::<Vec<_>>().join(", ");
        problems.push(format!("Keep the template's sections in its order: {list}."));
    }
    problems
}

/// Tool refusal message returned when `pull_request_create` receives a body that fails template validation.
pub fn pr_body_refusal(problems: &[String], template: &str) -> String {
    let mut lines = vec![
        "The pull request was not opened: its description does not follow the repository's pull request template. Fix it and call pull_request_create again.".to_string(),
    ];
    for p in problems {
        lines.push(format!("- {p}"));
    }
    lines.push(String::new());
    lines.push("The template:".into());
    lines.push(template.chars().take(4_000).collect());
    lines.join("\n")
}

/// Locate the repository's pull request template file, if any.
pub fn find_pr_template(dir: &Path) -> Option<String> {
    const CANDIDATES: &[&str] = &[
        ".github/PULL_REQUEST_TEMPLATE.md",
        ".github/pull_request_template.md",
        "PULL_REQUEST_TEMPLATE.md",
        "pull_request_template.md",
        "docs/PULL_REQUEST_TEMPLATE.md",
        "docs/pull_request_template.md",
    ];
    for rel in CANDIDATES {
        let path = dir.join(rel);
        if let Ok(text) = std::fs::read_to_string(&path) {
            if !text.trim().is_empty() {
                return Some(text);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commit_style_examples_filters_merges_reverts_and_duplicates() {
        let subjects: Vec<String> = vec![
            "Merge pull request #12 from acme/fix".into(),
            "Revert \"Add feature\"".into(),
            "  feat(ui): add setup sheet  ".into(),
            "feat(ui): add setup sheet".into(),
            "".into(),
            "fix(chats): mute snoozed chat toasts".into(),
        ];
        assert_eq!(CommitStyle::examples(&subjects), vec!["feat(ui): add setup sheet", "fix(chats): mute snoozed chat toasts"]);
    }

    #[test]
    fn commit_style_rules_cover_all_variants() {
        let subjects = vec!["fix: handle empty diff".into()];
        assert!(CommitStyle::Standard.commit_rules(&subjects, "").is_empty());
        assert!(CommitStyle::Conventional.commit_rules(&subjects, "")[0].contains("Conventional Commits"));
        let repo_rules = CommitStyle::Repository.commit_rules(&subjects, "");
        assert!(repo_rules.iter().any(|r| r == "- fix: handle empty diff"));
        let custom_rules = CommitStyle::Custom.commit_rules(&[], "Start with a ticket key.");
        assert_eq!(custom_rules.len(), 2);
        assert_eq!(custom_rules[1], "Start with a ticket key.");
        assert!(CommitStyle::Custom.commit_rules(&[], "   ").is_empty());
    }

    #[test]
    fn strip_agent_credits_removes_ai_trailers_and_generated_lines_but_keeps_people() {
        let msg = "Fix terminal width\n\n\
            Starts the PTY at screen width.\n\n\
            🤖 Generated with [Claude Code](https://claude.com/claude-code)\n\n\
            Co-Authored-By: Claude <noreply@anthropic.com>\n\
            Co-Authored-By: Claude Dupont <claude@example.com>\n\
            Co-authored-by: Copilot <198982749+Copilot@users.noreply.github.com>";
        let cleaned = strip_agent_credits(msg);
        assert_eq!(cleaned, "Fix terminal width\n\nStarts the PTY at screen width.\n\nCo-Authored-By: Claude Dupont <claude@example.com>");
        // Non-AI generated lines stay untouched.
        assert!(!is_generated_line("Generated with protoc 3.21"));
        assert!(is_generated_line("Generated by Google Gemini"));
    }

    #[test]
    fn pr_body_check_validates_sections_order_and_related_issues() {
        let template =
            "## Summary\n<!-- what changed -->\n\n## Related issues\n<!-- Closes #123 or None -->\n\n## Testing\n<!-- how tested -->\n";
        let good = "## Summary\nAdd commit style.\n\n## Related issues\nNone\n\n## Testing\ncargo test\n";
        assert!(pr_body_problems(good, template).is_empty());

        let with_issue = "## Summary\nAdd commit style.\n\n## Related issues\nCloses #1561\n\n## Testing\ncargo test\n";
        assert!(pr_body_problems(with_issue, template).is_empty());

        let bad_issue = "## Summary\nAdd commit style.\n\n## Related issues\nNo related issues here\n\n## Testing\ncargo test\n";
        let problems = pr_body_problems(bad_issue, template);
        assert_eq!(problems.len(), 1);
        assert!(problems[0].contains("Related issues"));

        let reordered = "## Testing\ncargo test\n\n## Summary\nAdd commit style.\n\n## Related issues\nNone\n";
        let order_problems = pr_body_problems(reordered, template);
        assert!(order_problems.iter().any(|p| p.contains("order")));

        let missing = "## Summary\nOnly summary\n";
        let missing_problems = pr_body_problems(missing, template);
        assert!(missing_problems.iter().any(|p| p.contains("Missing section `## Related issues`")));
        assert!(missing_problems.iter().any(|p| p.contains("Missing section `## Testing`")));
    }

    #[test]
    fn pr_body_check_ignores_headings_inside_fenced_code_blocks() {
        let template = "## Summary\n\n## Testing\n";
        let body = "## Summary\nExample:\n```markdown\n## Testing\n```\n";
        let problems = pr_body_problems(body, template);
        assert_eq!(problems, vec!["Missing section `## Testing`."]);
    }
}
