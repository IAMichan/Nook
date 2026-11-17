//! "Merge all my PRs": several pull requests merged in one approved action (`PullRequestBatchMerge` on the Mac).
//! The list is written out in the plan, so the user sees (and can edit) exactly which pull requests go before anything
//! runs. Each one is checked again right before its merge; what is not ready is skipped with the reason instead of
//! stopping the rest.

use serde_json::Value;

use super::github::Ci;
use super::pulls::{DetailState, PullRequestDetail};
use crate::brain::action_gate::is_repository;
use crate::i18n::{tr, trf};

/// More than this in one action is no longer something the user can review at a glance.
pub const LIMIT: usize = 30;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Target {
    pub repo: String,
    pub number: i64,
}

impl Target {
    pub fn reference(&self) -> String {
        format!("{}#{}", self.repo, self.number)
    }
}

/// The pull requests in `pulls`: `"owner/name#12"`, `"owner/name/pull/12"` or a github.com link, separated by commas,
/// semicolons, spaces or new lines (or given as a JSON array). Duplicates count once; anything unreadable goes to
/// `invalid`.
pub fn targets(pulls: Option<&Value>) -> (Vec<Target>, Vec<String>) {
    let parts: Vec<String> = match pulls {
        Some(Value::Array(list)) => list.iter().map(|v| v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string())).collect(),
        Some(Value::String(text)) => text.split([',', ';', '\n', '\r', '\t', ' ']).map(str::to_string).collect(),
        _ => Vec::new(),
    };
    let mut found = Vec::new();
    let mut invalid = Vec::new();
    for raw in parts {
        let part = raw.trim_matches(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '`' | '[' | ']' | '(' | ')'));
        if part.is_empty() {
            continue;
        }
        let Some(target) = parse_target(part) else {
            invalid.push(part.to_string());
            continue;
        };
        if !found.contains(&target) {
            found.push(target);
        }
    }
    (found, invalid)
}

fn parse_target(text: &str) -> Option<Target> {
    let mut path = text;
    let lower = path.to_lowercase();
    for prefix in ["https://github.com/", "http://github.com/", "github.com/"] {
        if lower.starts_with(prefix) {
            path = &path[prefix.len()..];
            break;
        }
    }
    let (repo, number_str) = if let Some((r, rest)) = path.split_once("/pull/").or_else(|| path.split_once("/pulls/")) {
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        (r, digits)
    } else if let Some((r, n)) = path.rsplit_once('#') {
        (r, n.to_string())
    } else {
        return None;
    };
    if !is_repository(repo) {
        return None;
    }
    let number: i64 = number_str.parse().ok()?;
    (number > 0).then(|| Target { repo: repo.to_string(), number })
}

/// The plan's line: `"GitHub: merge 3 pull requests (squash): a/b#1, a/b#2, c/d#7"`.
pub fn summary(pulls: Option<&Value>, method: &str) -> String {
    let found = targets(pulls).0;
    if found.is_empty() {
        return "GitHub: merge pull requests".into();
    }
    let count = if found.len() == 1 { "1 pull request".to_string() } else { format!("{} pull requests", found.len()) };
    let refs: Vec<String> = found.iter().map(Target::reference).collect();
    format!("GitHub: merge {count} ({method}): {}", refs.join(", "))
}

/// What is wrong with the list itself, for the action gate. Empty when it can be proposed.
pub fn problems(pulls: Option<&Value>) -> Vec<String> {
    let (found, invalid) = targets(pulls);
    let mut out = Vec::new();
    if found.is_empty() {
        out.push(
            tr(
                "Geen pull requests herkend; schrijf ze als eigenaar/naam#nummer.",
                "No pull requests recognized; write them as owner/name#number.",
            )
            .to_string(),
        );
    }
    if found.len() > LIMIT {
        out.push(trf(
            "Te veel pull requests in één keer ({count}); maximaal {limit}.",
            "Too many pull requests at once ({count}); maximum {limit}.",
            &[("count", &found.len().to_string()), ("limit", &LIMIT.to_string())],
        ));
    }
    if !invalid.is_empty() {
        out.push(trf("Geen pull request: {list}.", "Not a pull request: {list}.", &[("list", &invalid.join(", "))]));
    }
    out
}

/// Why this pull request is not merged in a batch, or `None` when it goes ahead. Only what certainly fails or would
/// merge something unfinished is held back; branch protection and the like are left to GitHub, which says why it
/// refuses. CI that is still running does not hold a merge back: approving the plan is the user's deliberate choice
/// to merge now.
pub fn skip_reason(detail: &PullRequestDetail) -> Option<&'static str> {
    match detail.state {
        DetailState::Merged => return Some("already merged"),
        DetailState::Closed => return Some("closed"),
        DetailState::Draft => return Some("draft"),
        DetailState::Open => {}
    }
    if detail.can_push == Some(false) {
        return Some("no write access");
    }
    if detail.conflicted() {
        return Some("merge conflicts");
    }
    (detail.check_summary == Ci::Failing).then_some("CI failing")
}

/// How the report names a merge: the method, plus a note when CI had not finished yet.
pub fn merged_label(method: &str, detail: &PullRequestDetail) -> String {
    if detail.check_summary == Ci::Pending {
        format!("{method}, CI still running")
    } else {
        method.to_string()
    }
}

/// The method to use: the one asked for when the repository allows it, else the repository's first allowed method
/// (preferring `merge`) when none was asked for. `None` when the requested method is not allowed there.
pub fn pick_method<'a>(requested: Option<&'a str>, allowed: &'a [String]) -> Option<&'a str> {
    if let Some(req) = requested {
        return allowed.iter().find(|m| m.as_str() == req).map(String::as_str);
    }
    allowed.iter().find(|m| m.as_str() == "merge").or_else(|| allowed.first()).map(String::as_str)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Merged(String),
    Skipped(String),
    Failed(String),
}

/// The result the user and the brain read back: what was merged, what was skipped and why, what GitHub refused.
pub fn report(outcomes: &[(Target, Outcome)]) -> String {
    let merged = outcomes.iter().filter(|(_, o)| matches!(o, Outcome::Merged(_))).count();
    let mut lines = vec![format!("Merged {merged} of {} pull requests.", outcomes.len())];
    for (target, outcome) in outcomes {
        let r = target.reference();
        match outcome {
            Outcome::Merged(method) => lines.push(format!("✓ {r} merged ({method})")),
            Outcome::Skipped(reason) => lines.push(format!("– {r} skipped: {reason}")),
            Outcome::Failed(message) => lines.push(format!("✗ {r} failed: {message}")),
        }
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::connectors::pulls::{CheckOutcome, PullRequestCheck};

    fn t(repo: &str, number: i64) -> Target {
        Target { repo: repo.into(), number }
    }

    fn detail(
        state: DetailState,
        mergeable: Option<bool>,
        merge_state: &str,
        checks: Vec<CheckOutcome>,
        can_push: Option<bool>,
    ) -> PullRequestDetail {
        let check_list = checks
            .into_iter()
            .enumerate()
            .map(|(i, outcome)| PullRequestCheck {
                name: format!("c{i}"),
                outcome,
                detail: String::new(),
                url: None,
                check_run: true,
                running: false,
                started: None,
                finished: None,
            })
            .collect();
        PullRequestDetail {
            repo: "acme/app".into(),
            number: 1,
            title: "T".into(),
            body: String::new(),
            url: None,
            author: "ada".into(),
            state,
            base_branch: "main".into(),
            head_branch: "f".into(),
            head_sha: "abc".into(),
            additions: 0,
            deletions: 0,
            changed_files: 0,
            created: None,
            updated: None,
            mergeable,
            merge_state: merge_state.into(),
            checks: check_list,
            events: vec![],
            commits: vec![],
            files: vec![],
            methods: vec!["merge".into(), "squash".into()],
            can_push,
            permission: None,
            can_bypass: None,
            auto_merge: false,
            is_open: true,
            can_merge: true,
            check_summary: Ci::Unknown,
            merge_note: None,
        }
        .finish()
    }

    #[test]
    fn reads_every_way_of_writing_a_pull_request() {
        let input = json!("IAMichan/nook#12, IAMichan/nook/pull/13\nhttps://github.com/acme/app/pull/7#issuecomment-1; acme/app#7");
        let parsed = targets(Some(&input));
        assert_eq!(parsed.0, vec![t("IAMichan/nook", 12), t("IAMichan/nook", 13), t("acme/app", 7)]);
        assert!(parsed.1.is_empty());
        let list = json!(["acme/app#1", "acme/app#2"]);
        let refs: Vec<String> = targets(Some(&list)).0.into_iter().map(|x| x.reference()).collect();
        assert_eq!(refs, vec!["acme/app#1", "acme/app#2"]);
    }

    #[test]
    fn rejects_what_is_no_pull_request() {
        let parsed = targets(Some(&json!("acme/app#0, #12, ../etc#3, acme/app#4")));
        assert_eq!(parsed.0.iter().map(Target::reference).collect::<Vec<_>>(), vec!["acme/app#4"]);
        assert_eq!(parsed.1, vec!["acme/app#0", "#12", "../etc#3"]);
        assert!(problems(Some(&json!("acme/app#4"))).is_empty());
        assert!(!problems(Some(&json!(""))).is_empty());
        assert!(!problems(Some(&json!("acme/app#4, nonsense"))).is_empty());
        let many = (1..=31).map(|i| format!("acme/app#{i}")).collect::<Vec<_>>().join(",");
        assert!(!problems(Some(&json!(many))).is_empty());
    }

    #[test]
    fn the_plan_names_every_pull_request() {
        assert_eq!(
            summary(Some(&json!("acme/app#1, acme/app#2")), "squash"),
            "GitHub: merge 2 pull requests (squash): acme/app#1, acme/app#2"
        );
    }

    #[test]
    fn skips_what_is_not_ready() {
        assert_eq!(skip_reason(&detail(DetailState::Open, Some(true), "clean", vec![], Some(true))), None);
        assert_eq!(
            skip_reason(&detail(DetailState::Open, None, "unknown", vec![CheckOutcome::Passing, CheckOutcome::Skipped], Some(true))),
            None
        );
        assert_eq!(skip_reason(&detail(DetailState::Open, Some(true), "behind", vec![], Some(true))), None);
        assert_eq!(skip_reason(&detail(DetailState::Draft, Some(true), "clean", vec![], Some(true))), Some("draft"));
        assert_eq!(skip_reason(&detail(DetailState::Merged, Some(true), "clean", vec![], Some(true))), Some("already merged"));
        assert_eq!(skip_reason(&detail(DetailState::Closed, Some(true), "clean", vec![], Some(true))), Some("closed"));
        assert_eq!(skip_reason(&detail(DetailState::Open, Some(false), "dirty", vec![], Some(true))), Some("merge conflicts"));
        assert_eq!(
            skip_reason(&detail(DetailState::Open, Some(true), "clean", vec![CheckOutcome::Passing, CheckOutcome::Failing], Some(true))),
            Some("CI failing")
        );
        assert_eq!(
            skip_reason(&detail(DetailState::Open, Some(true), "clean", vec![CheckOutcome::Passing, CheckOutcome::Pending], Some(true))),
            None
        );
        assert_eq!(skip_reason(&detail(DetailState::Open, Some(true), "clean", vec![], Some(false))), Some("no write access"));
    }

    #[test]
    fn notes_a_merge_while_ci_is_still_running() {
        assert_eq!(
            merged_label("squash", &detail(DetailState::Open, Some(true), "clean", vec![CheckOutcome::Passing], Some(true))),
            "squash"
        );
        assert_eq!(
            merged_label("merge", &detail(DetailState::Open, Some(true), "clean", vec![CheckOutcome::Pending], Some(true))),
            "merge, CI still running"
        );
    }

    #[test]
    fn picks_a_method_the_repository_allows() {
        let m_s = vec!["merge".into(), "squash".into()];
        let s_only = vec!["squash".into()];
        let m_r = vec!["merge".into(), "rebase".into()];
        assert_eq!(pick_method(None, &m_s), Some("merge"));
        assert_eq!(pick_method(None, &s_only), Some("squash"));
        assert_eq!(pick_method(Some("rebase"), &m_r), Some("rebase"));
        assert_eq!(pick_method(Some("rebase"), &s_only), None);
    }

    #[test]
    fn reports_every_outcome() {
        let out = report(&[
            (t("acme/app", 1), Outcome::Merged("squash".into())),
            (t("acme/app", 2), Outcome::Skipped("draft".into())),
            (t("acme/app", 3), Outcome::Failed("GitHub refused the merge (422).".into())),
        ]);
        assert_eq!(
            out,
            "Merged 1 of 3 pull requests.\n✓ acme/app#1 merged (squash)\n– acme/app#2 skipped: draft\n✗ acme/app#3 failed: GitHub refused the merge (422)."
        );
    }
}
