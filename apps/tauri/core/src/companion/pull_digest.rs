//! Pull requests on the phone from a Windows or Linux computer (`PullDigest`, `PullDetailDigest`, `CompanionPullAction`
//! in `packages/protocol/Sources/CompanionPullRequests.swift`), built the way the Mac's
//! `CompanionServer+PullRequests.swift` builds them, from what Agents › Pull requests reads here
//! (`connectors::pulls`). This app reads pull requests from GitHub only; GitLab and the other forges have no pull
//! request page here yet. Pure, so it is tested on its own; the files the phone marked viewed are kept in
//! [`ViewedMarks`].

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::chat_digest::clip;
use super::models::CompanionPolicy;
use crate::connectors::github::Ci;
use crate::connectors::pulls::{
    CheckOutcome, DetailState, EventKind, PullRequestDetail, PullRequestFile, PullRequestItem, PullState, ReviewDecision,
};

/// The most a list answer carries (`PullDigest.maxList`).
pub const MAX_LIST: usize = 80;
/// `PullDetailDigest.maxBody`, `.maxPatch`, `.maxPatches`, `.maxFiles`, `.maxChecks`.
pub const MAX_BODY: usize = 8_000;
pub const MAX_PATCH: usize = 40 * 1024;
pub const MAX_PATCHES: usize = 150 * 1024;
pub const MAX_FILES: usize = 300;
pub const MAX_CHECKS: usize = 100;
/// `CompanionPullAction.maxComments`, `.maxBody`.
pub const MAX_COMMENTS: usize = 50;
/// How many pull requests keep their viewed marks; the oldest marked go first.
pub const MAX_MARKED: usize = 200;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullDigest {
    pub url: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub author: String,
    pub state: String,
    pub ci: String,
    pub review: String,
    pub conflict: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub additions: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deletions: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated: Option<f64>,
    pub group: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_branch: Option<String>,
}

impl PullDigest {
    fn is_open(&self) -> bool {
        self.state == "open" || self.state == "draft"
    }
}

/// Where a pull request in a list comes from (`PullDigest.Group`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    Linked,
    Mine,
    Review,
    Watched,
}

impl Group {
    pub fn name(self) -> &'static str {
        match self {
            Group::Linked => "linked",
            Group::Mine => "mine",
            Group::Review => "review",
            Group::Watched => "watched",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailCheck {
    pub name: String,
    pub outcome: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailFile {
    pub path: String,
    pub status: String,
    pub additions: i64,
    pub deletions: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub patch: Option<String>,
    pub truncated: bool,
    pub viewed: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Verdict {
    pub author: String,
    pub approved: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullDetailDigest {
    pub url: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub body: String,
    pub author: String,
    pub state: String,
    pub base_branch: String,
    pub head_branch: String,
    #[serde(rename = "headSHA")]
    pub head_sha: String,
    pub additions: i64,
    pub deletions: i64,
    pub changed_files: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated: Option<f64>,
    pub checks: Vec<DetailCheck>,
    pub files: Vec<DetailFile>,
    pub verdicts: Vec<Verdict>,
    pub methods: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocker: Option<String>,
    pub verdicts_allowed: bool,
    pub line_comments: bool,
    pub fetched: f64,
}

/// What the phone asks of a pull request (`CompanionPullAction`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionKind {
    Approve,
    RequestChanges,
    Comment,
    Merge,
    Viewed,
    Unviewed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineComment {
    pub path: String,
    pub line: i64,
    pub side: String,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_line: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullAction {
    pub kind: ActionKind,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub comments: Option<Vec<LineComment>>,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub head: Option<String>,
}

impl PullAction {
    /// The action as the phone wrote it, when it reads as one and is complete enough to go (`isValid`).
    pub fn parse(value: Option<&Value>) -> Option<Self> {
        let action: Self = serde_json::from_value(value?.clone()).ok()?;
        action.is_valid().then_some(action)
    }

    /// Words for a request for changes or a comment (without line comments), a path for the viewed marks, a head for a
    /// merge, and comments that are on a line and not empty.
    pub fn is_valid(&self) -> bool {
        let words = self.review_body();
        if words.chars().count() > MAX_BODY {
            return false;
        }
        let notes = self.comments.as_deref().unwrap_or_default();
        if notes.len() > MAX_COMMENTS {
            return false;
        }
        for note in notes {
            let text = note.body.trim();
            if note.path.is_empty()
                || note.line <= 0
                || text.is_empty()
                || text.chars().count() > MAX_BODY
                || !(note.side == "RIGHT" || note.side == "LEFT")
            {
                return false;
            }
            if note.start_line.is_some_and(|s| s <= 0 || s > note.line) {
                return false;
            }
        }
        match self.kind {
            ActionKind::Approve => true,
            ActionKind::RequestChanges => !words.is_empty(),
            ActionKind::Comment => !words.is_empty() || !notes.is_empty(),
            ActionKind::Merge => {
                self.head.as_deref().is_some_and(|h| !h.is_empty())
                    && self.method.as_deref().is_none_or(|m| ["merge", "squash", "rebase"].contains(&m))
            }
            ActionKind::Viewed | ActionKind::Unviewed => self.path.as_deref().is_some_and(|p| !p.is_empty()),
        }
    }

    pub fn review_body(&self) -> String {
        self.body.as_deref().unwrap_or("").trim().to_string()
    }

    /// GitHub's review event for a review action.
    pub fn event(&self) -> Option<&'static str> {
        match self.kind {
            ActionKind::Approve => Some("APPROVE"),
            ActionKind::RequestChanges => Some("REQUEST_CHANGES"),
            ActionKind::Comment => Some("COMMENT"),
            _ => None,
        }
    }
}

/// The comments on lines of a review in GitHub's shape (`POST /repos/{repo}/pulls/{number}/reviews`).
pub fn review_comments(comments: &[LineComment]) -> Vec<Value> {
    comments
        .iter()
        .map(|c| {
            let mut note = serde_json::json!({"path": c.path, "line": c.line, "side": c.side, "body": c.body.trim()});
            if let Some(start) = c.start_line.filter(|s| *s < c.line) {
                note["start_line"] = start.into();
                note["start_side"] = c.side.clone().into();
            }
            note
        })
        .collect()
}

fn seconds(date: Option<chrono::DateTime<chrono::Utc>>) -> Option<f64> {
    date.map(|d| d.timestamp_millis() as f64 / 1000.0)
}

fn ci(ci: Ci) -> &'static str {
    match ci {
        Ci::Unknown => "unknown",
        Ci::Pending => "pending",
        Ci::Passing => "passing",
        Ci::Failing => "failing",
    }
}

fn review(review: ReviewDecision) -> &'static str {
    match review {
        ReviewDecision::None => "none",
        ReviewDecision::Approved => "approved",
        ReviewDecision::ChangesRequested => "changesRequested",
        ReviewDecision::Required => "required",
    }
}

/// The web address of a pull request: what the phone reads and acts on it by.
pub fn url_of(repo: &str, number: i64, url: Option<&str>) -> String {
    url.map(str::to_string).unwrap_or_else(|| format!("https://github.com/{repo}/pull/{number}"))
}

/// One pull request of Agents › Pull requests.
pub fn item_digest(item: &PullRequestItem, group: Group) -> PullDigest {
    PullDigest {
        url: url_of(&item.repo, item.number, item.url.as_deref()),
        repo: item.repo.clone(),
        number: item.number,
        title: CompanionPolicy::excerpt(&item.title),
        author: item.author.clone(),
        state: match item.state {
            PullState::Open if item.draft => "draft",
            PullState::Open => "open",
            PullState::Closed => "closed",
            PullState::Merged => "merged",
        }
        .into(),
        ci: ci(item.ci).into(),
        review: review(item.review).into(),
        conflict: item.conflicting,
        additions: Some(item.additions),
        deletions: Some(item.deletions),
        updated: seconds(item.updated),
        group: group.name().into(),
        head_branch: None,
        base_branch: None,
    }
}

/// A pull request of a session's branch, from GitHub's list of pull requests (`GET /repos/{repo}/pulls?head=…`).
pub fn linked_digest(pull: &Value) -> Option<PullDigest> {
    let number = pull["number"].as_i64()?;
    let repo = pull["base"]["repo"]["full_name"].as_str()?.to_string();
    let state = if pull["merged_at"].is_string() {
        "merged"
    } else if pull["state"].as_str() != Some("open") {
        "closed"
    } else if pull["draft"].as_bool() == Some(true) {
        "draft"
    } else {
        "open"
    };
    let updated = pull["updated_at"].as_str().and_then(|d| chrono::DateTime::parse_from_rfc3339(d).ok()).map(|d| d.to_utc());
    Some(PullDigest {
        url: url_of(&repo, number, pull["html_url"].as_str()),
        repo,
        number,
        title: CompanionPolicy::excerpt(pull["title"].as_str().unwrap_or("")),
        author: pull["user"]["login"].as_str().unwrap_or("").to_string(),
        state: state.into(),
        ci: "unknown".into(),
        review: "none".into(),
        conflict: false,
        additions: None,
        deletions: None,
        updated: seconds(updated),
        group: Group::Linked.name().into(),
        head_branch: pull["head"]["ref"].as_str().map(str::to_string),
        base_branch: pull["base"]["ref"].as_str().map(str::to_string),
    })
}

/// What a list answer keeps (`PullDigest.trimmed`): open before closed, then the newest, at most `limit`, each address
/// once (the first group that lists it wins).
pub fn trimmed(pulls: Vec<PullDigest>, limit: usize) -> Vec<PullDigest> {
    let mut seen = HashSet::new();
    let mut unique: Vec<(usize, PullDigest)> = pulls.into_iter().filter(|p| seen.insert(p.url.to_lowercase())).enumerate().collect();
    unique.sort_by(|(ai, a), (bi, b)| {
        b.is_open().cmp(&a.is_open()).then_with(|| b.updated.unwrap_or(0.0).total_cmp(&a.updated.unwrap_or(0.0))).then_with(|| ai.cmp(bi))
    });
    unique.into_iter().take(limit).map(|(_, p)| p).collect()
}

/// The repository and number of a pull request on GitHub by its web address; nothing else is read or acted on.
pub fn parse_url(address: &str) -> Option<(String, i64)> {
    let url = url::Url::parse(address.trim()).ok()?;
    if url.scheme() != "https" || !url.host_str().is_some_and(|h| h.eq_ignore_ascii_case("github.com")) {
        return None;
    }
    let parts: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
    let [owner, name, "pull", number, ..] = parts.as_slice() else { return None };
    let repo = format!("{owner}/{name}");
    let number: i64 = number.parse().ok().filter(|n| *n > 0)?;
    crate::connectors::github::is_repository(&repo).then_some((repo, number))
}

/// Why it cannot be merged from the phone, by the quick merge's own rule (`PullRequestQuickRunner.blocker`): only what
/// certainly fails; failing checks are GitHub's call, since an admin may merge past them.
pub fn blocker(detail: &PullRequestDetail) -> Option<&'static str> {
    match detail.state {
        DetailState::Merged => return Some("merged"),
        DetailState::Closed => return Some("closed"),
        DetailState::Draft => return Some("draft"),
        DetailState::Open => {}
    }
    if detail.can_push == Some(false) {
        return Some("access");
    }
    if detail.mergeable == Some(false) || detail.merge_state == "dirty" {
        return Some("conflict");
    }
    None
}

/// The method a merge goes with: the one asked for when the repository allows it, else merge, else the first allowed.
pub fn merge_method(requested: Option<&str>, allowed: &[String]) -> Option<String> {
    if let Some(method) = requested.filter(|m| allowed.iter().any(|a| a == m)) {
        return Some(method.to_string());
    }
    allowed.iter().find(|m| *m == "merge").or(allowed.first()).cloned()
}

/// Each reviewer's last say: approved or changes requested (a comment says neither).
pub fn verdicts(detail: &PullRequestDetail) -> Vec<Verdict> {
    let mut last: BTreeMap<String, (Option<chrono::DateTime<chrono::Utc>>, bool)> = BTreeMap::new();
    for event in &detail.events {
        let EventKind::Review { state } = &event.kind else { continue };
        let approved = match state.as_str() {
            "APPROVED" => true,
            "CHANGES_REQUESTED" => false,
            _ => continue,
        };
        let newer = last.get(&event.author).is_none_or(|(date, _)| event.date >= *date);
        if newer {
            last.insert(event.author.clone(), (event.date, approved));
        }
    }
    last.into_iter().map(|(author, (_, approved))| Verdict { author, approved }).collect()
}

/// Files with their patches cut to fit one answer (`PullDetailDigest.budgeted`): each at `each` bytes on a whole line,
/// together at `total`; a file past the budget keeps its counts without a patch, and says it was cut.
pub fn budgeted(files: Vec<DetailFile>, each: usize, total: usize) -> Vec<DetailFile> {
    let mut used = 0;
    files
        .into_iter()
        .take(MAX_FILES)
        .map(|mut file| {
            let Some(patch) = file.patch.take() else { return file };
            let mut cut = patch;
            if cut.len() > each {
                let mut end = each;
                while !cut.is_char_boundary(end) {
                    end -= 1;
                }
                cut.truncate(end);
                // Whole lines only: a half line would read as a change that is not there.
                if let Some(newline) = cut.rfind('\n') {
                    cut.truncate(newline);
                }
                file.truncated = true;
            }
            if used + cut.len() > total {
                file.truncated = true;
                return file;
            }
            used += cut.len();
            file.patch = Some(cut);
            file
        })
        .collect()
}

fn check_outcome(outcome: CheckOutcome) -> &'static str {
    match outcome {
        CheckOutcome::Passing => "passing",
        CheckOutcome::Failing => "failing",
        CheckOutcome::Pending => "pending",
        CheckOutcome::Skipped => "skipped",
    }
}

fn state_name(state: DetailState) -> &'static str {
    match state {
        DetailState::Open => "open",
        DetailState::Draft => "draft",
        DetailState::Merged => "merged",
        DetailState::Closed => "closed",
    }
}

/// One pull request in full, as the phone's detail shows it, with the files marked viewed in `marks` and `now` as when
/// it was read.
pub fn detail_digest(detail: &PullRequestDetail, url: &str, marks: &ViewedMarks, now: f64) -> PullDetailDigest {
    let key = ViewedMarks::key(&detail.repo, detail.number);
    let files = detail
        .files
        .iter()
        .map(|f| DetailFile {
            path: f.path.clone(),
            status: f.status.clone(),
            additions: f.additions,
            deletions: f.deletions,
            patch: f.patch.clone(),
            truncated: false,
            viewed: marks.status(&key, f).into(),
        })
        .collect();
    PullDetailDigest {
        url: url.to_string(),
        repo: detail.repo.clone(),
        number: detail.number,
        title: clip(&detail.title, 300),
        body: clip(&detail.body, MAX_BODY),
        author: detail.author.clone(),
        state: state_name(detail.state).into(),
        base_branch: detail.base_branch.clone(),
        head_branch: detail.head_branch.clone(),
        head_sha: detail.head_sha.clone(),
        additions: detail.additions,
        deletions: detail.deletions,
        changed_files: detail.changed_files,
        updated: seconds(detail.updated),
        checks: detail
            .checks
            .iter()
            .take(MAX_CHECKS)
            .map(|c| DetailCheck { name: clip(&c.name, 200), outcome: check_outcome(c.outcome).into(), detail: clip(&c.detail, 200) })
            .collect(),
        files: budgeted(files, MAX_PATCH, MAX_PATCHES),
        verdicts: verdicts(detail),
        methods: {
            // The method this computer merges with by default (merge) first, as the Mac puts its preferred one first.
            let mut methods = detail.methods.clone();
            methods.sort_by_key(|m| m != "merge");
            methods
        },
        blocker: blocker(detail).map(str::to_string),
        // GitHub takes approve and request changes, and comments on lines with a review.
        verdicts_allowed: true,
        line_comments: true,
        fetched: now,
    }
}

/// The files the phone marked viewed, per pull request (`PullRequestViewedFiles` on the Mac): each with a fingerprint of
/// its patch then, so a file pushed to since shows as changed.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ViewedMarks {
    /// By `key`: the marked files' fingerprints by path.
    pub pulls: BTreeMap<String, BTreeMap<String, String>>,
    /// The keys, the most recently marked last.
    pub order: Vec<String>,
}

impl ViewedMarks {
    pub fn key(repo: &str, number: i64) -> String {
        format!("{}#{number}", repo.to_lowercase())
    }

    /// What the file looked like: its patch, or its counts when GitHub sends none.
    pub fn fingerprint(file: &PullRequestFile) -> String {
        let mut hash = Sha256::new();
        match &file.patch {
            Some(patch) => hash.update(patch.as_bytes()),
            None => hash.update(format!("{}|{}|{}", file.status, file.additions, file.deletions).as_bytes()),
        }
        hash.finalize()[..8].iter().map(|b| format!("{b:02x}")).collect()
    }

    /// viewed, changed (viewed, then pushed to) or unviewed.
    pub fn status(&self, key: &str, file: &PullRequestFile) -> &'static str {
        match self.pulls.get(key).and_then(|files| files.get(&file.path)) {
            Some(mark) if *mark == Self::fingerprint(file) => "viewed",
            Some(_) => "changed",
            None => "unviewed",
        }
    }

    pub fn set(&mut self, key: &str, file: &PullRequestFile, viewed: bool) {
        if viewed {
            self.pulls.entry(key.to_string()).or_default().insert(file.path.clone(), Self::fingerprint(file));
        } else if let Some(files) = self.pulls.get_mut(key) {
            files.remove(&file.path);
            if files.is_empty() {
                self.pulls.remove(key);
            }
        }
        self.order.retain(|k| k != key);
        if self.pulls.contains_key(key) {
            self.order.push(key.to_string());
        }
        while self.order.len() > MAX_MARKED {
            let oldest = self.order.remove(0);
            self.pulls.remove(&oldest);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::pulls::{PullRequestCheck, PullRequestEvent};
    use chrono::{TimeZone, Utc};
    use serde_json::json;

    fn item() -> PullRequestItem {
        PullRequestItem {
            repo: "acme/app".into(),
            number: 7,
            title: "Fix it".into(),
            url: None,
            draft: true,
            updated: Some(Utc.timestamp_opt(1_700_000_000, 0).unwrap()),
            author: "lisa".into(),
            ci: Ci::Failing,
            state: PullState::Open,
            review: ReviewDecision::ChangesRequested,
            comments: 0,
            additions: 3,
            deletions: 1,
            conflicting: true,
        }
    }

    fn detail() -> PullRequestDetail {
        let pull = json!({
            "number": 7, "title": "Fix it", "body": "Why", "html_url": "https://github.com/acme/app/pull/7",
            "user": {"login": "lisa"}, "state": "open", "draft": false, "mergeable": true, "mergeable_state": "clean",
            "base": {"ref": "main", "repo": {"full_name": "acme/app"}}, "head": {"ref": "fix", "sha": "abc123"},
            "additions": 3, "deletions": 1, "changed_files": 1, "updated_at": "2026-11-01T10:00:00Z"
        });
        let repository = json!({"full_name": "acme/app", "permissions": {"push": true}, "allow_merge_commit": false});
        let mut d = crate::connectors::pulls::parse_detail(&pull, Some(&repository)).unwrap();
        d.files = vec![PullRequestFile {
            path: "a.rs".into(),
            status: "modified".into(),
            additions: 3,
            deletions: 1,
            patch: Some("@@ -1 +1 @@\n-a\n+b".into()),
            previous_path: None,
        }];
        d
    }

    #[test]
    fn a_list_item_has_the_macs_words() {
        let json = serde_json::to_value(item_digest(&item(), Group::Review)).unwrap();
        assert_eq!(json["url"], "https://github.com/acme/app/pull/7");
        assert_eq!(json["state"], "draft");
        assert_eq!(json["ci"], "failing");
        assert_eq!(json["review"], "changesRequested");
        assert_eq!(json["conflict"], true);
        assert_eq!(json["group"], "review");
        assert_eq!(json["updated"], 1_700_000_000.0);
        assert!(json.get("headBranch").is_none());
    }

    #[test]
    fn a_linked_pull_request_comes_from_githubs_list() {
        let pull = json!({
            "number": 9, "title": "Add", "html_url": "https://github.com/acme/app/pull/9", "state": "closed",
            "merged_at": "2026-11-01T10:00:00Z", "user": {"login": "bo"},
            "base": {"ref": "main", "repo": {"full_name": "acme/app"}}, "head": {"ref": "add"}
        });
        let d = linked_digest(&pull).unwrap();
        assert_eq!((d.state.as_str(), d.group.as_str()), ("merged", "linked"));
        assert_eq!(d.head_branch.as_deref(), Some("add"));
        assert!(linked_digest(&json!({"number": 1})).is_none());
    }

    #[test]
    fn a_list_keeps_open_first_then_newest_and_each_address_once() {
        let mut a = item_digest(&item(), Group::Mine);
        a.state = "closed".into();
        a.updated = Some(5.0);
        let mut b = a.clone();
        b.url = "https://github.com/acme/app/pull/8".into();
        b.state = "open".into();
        b.updated = Some(1.0);
        let mut c = b.clone();
        c.url = "https://github.com/acme/app/pull/9".into();
        c.updated = Some(3.0);
        let mut dup = c.clone();
        dup.url = dup.url.to_uppercase();
        dup.group = "watched".into();
        let out = trimmed(vec![a, b, c, dup], 10);
        let numbers: Vec<&str> = out.iter().map(|p| p.url.rsplit('/').next().unwrap()).collect();
        assert_eq!(numbers, ["9", "8", "7"]);
        assert_eq!(out[0].group, "mine");
        assert_eq!(trimmed(out, 1).len(), 1);
    }

    #[test]
    fn only_github_pull_request_addresses_are_read() {
        assert_eq!(parse_url("https://github.com/acme/app/pull/7"), Some(("acme/app".into(), 7)));
        assert_eq!(parse_url("https://github.com/acme/app/pull/7/files#diff"), Some(("acme/app".into(), 7)));
        assert_eq!(parse_url("http://github.com/acme/app/pull/7"), None);
        assert_eq!(parse_url("https://evil.com/acme/app/pull/7"), None);
        assert_eq!(parse_url("https://github.com/acme/app/issues/7"), None);
        assert_eq!(parse_url("https://github.com/acme/app/pull/0"), None);
        assert_eq!(parse_url("https://github.com/../app/pull/1"), None);
    }

    #[test]
    fn a_detail_has_the_macs_keys_and_merges_only_what_can_go() {
        let d = detail();
        let digest = detail_digest(&d, "https://github.com/acme/app/pull/7", &ViewedMarks::default(), 42.0);
        let json = serde_json::to_value(&digest).unwrap();
        assert_eq!(json["headSHA"], "abc123");
        assert_eq!(json["state"], "open");
        assert_eq!(json["methods"], json!(["squash", "rebase"]));
        assert!(json.get("blocker").is_none());
        assert_eq!(json["files"][0]["viewed"], "unviewed");
        assert_eq!(json["fetched"], 42.0);
        assert_eq!(json["verdictsAllowed"], true);

        let mut draft = d.clone();
        draft.state = DetailState::Draft;
        assert_eq!(blocker(&draft), Some("draft"));
        let mut conflict = d.clone();
        conflict.merge_state = "dirty".into();
        assert_eq!(blocker(&conflict), Some("conflict"));
        let mut reader = d;
        reader.can_push = Some(false);
        assert_eq!(blocker(&reader), Some("access"));
    }

    #[test]
    fn a_merge_takes_the_method_asked_for_when_allowed() {
        let allowed = vec!["squash".to_string(), "merge".to_string()];
        assert_eq!(merge_method(Some("squash"), &allowed).as_deref(), Some("squash"));
        assert_eq!(merge_method(Some("rebase"), &allowed).as_deref(), Some("merge"));
        assert_eq!(merge_method(None, &["rebase".to_string()]).as_deref(), Some("rebase"));
        assert_eq!(merge_method(None, &[]), None);
    }

    #[test]
    fn verdicts_are_each_reviewers_last_say() {
        let mut d = detail();
        let review = |author: &str, state: &str, at: i64| PullRequestEvent {
            id: format!("{author}{at}"),
            kind: EventKind::Review { state: state.into() },
            author: author.into(),
            body: String::new(),
            date: Some(Utc.timestamp_opt(at, 0).unwrap()),
            url: None,
        };
        d.events = vec![
            review("bo", "CHANGES_REQUESTED", 1),
            review("bo", "APPROVED", 2),
            review("al", "COMMENTED", 3),
            review("cy", "CHANGES_REQUESTED", 4),
        ];
        let v = verdicts(&d);
        assert_eq!(v, vec![Verdict { author: "bo".into(), approved: true }, Verdict { author: "cy".into(), approved: false }]);
    }

    #[test]
    fn patches_are_cut_on_whole_lines_within_the_budget() {
        let file = |patch: &str| DetailFile {
            path: "x".into(),
            status: "modified".into(),
            additions: 1,
            deletions: 0,
            patch: Some(patch.into()),
            truncated: false,
            viewed: "unviewed".into(),
        };
        let out = budgeted(vec![file("line one\nline two\nline three"), file("12345"), file("abc")], 15, 15);
        assert_eq!(out[0].patch.as_deref(), Some("line one"));
        assert!(out[0].truncated);
        assert_eq!(out[1].patch.as_deref(), Some("12345"));
        assert!(!out[1].truncated);
        assert_eq!(out[2].patch, None);
        assert!(out[2].truncated);
    }

    #[test]
    fn viewed_marks_notice_a_push() {
        let mut d = detail();
        let key = ViewedMarks::key(&d.repo, d.number);
        let mut marks = ViewedMarks::default();
        marks.set(&key, &d.files[0], true);
        assert_eq!(marks.status(&key, &d.files[0]), "viewed");
        d.files[0].patch = Some("@@ -1 +1 @@\n-a\n+c".into());
        assert_eq!(marks.status(&key, &d.files[0]), "changed");
        marks.set(&key, &d.files[0], false);
        assert_eq!(marks.status(&key, &d.files[0]), "unviewed");
        assert!(marks.pulls.is_empty() && marks.order.is_empty());
    }

    #[test]
    fn actions_are_checked_as_on_the_mac() {
        let parse = |v: Value| PullAction::parse(Some(&v));
        assert!(parse(json!({"kind": "approve"})).is_some());
        assert!(parse(json!({"kind": "requestChanges"})).is_none());
        assert!(parse(json!({"kind": "requestChanges", "body": "Please"})).is_some());
        assert!(parse(json!({"kind": "comment", "comments": [{"path": "a", "line": 2, "side": "RIGHT", "body": "x"}]})).is_some());
        assert!(parse(json!({"kind": "comment", "comments": [{"path": "a", "line": 2, "side": "UP", "body": "x"}]})).is_none());
        assert!(parse(json!({"kind": "comment", "comments": [{"path": "a", "line": 2, "side": "LEFT", "body": "x", "startLine": 3}]}))
            .is_none());
        assert!(parse(json!({"kind": "merge"})).is_none());
        assert!(parse(json!({"kind": "merge", "head": "abc", "method": "octopus"})).is_none());
        assert!(parse(json!({"kind": "merge", "head": "abc", "method": "squash"})).is_some());
        assert!(parse(json!({"kind": "viewed"})).is_none());
        assert!(parse(json!({"kind": "viewed", "path": "a.rs"})).is_some());
        assert!(parse(json!({"kind": "launch"})).is_none());
        assert!(PullAction::parse(None).is_none());
    }

    #[test]
    fn line_comments_go_in_githubs_shape() {
        let notes = vec![
            LineComment { path: "a".into(), line: 5, side: "RIGHT".into(), body: " fix ".into(), start_line: Some(3) },
            LineComment { path: "b".into(), line: 1, side: "LEFT".into(), body: "x".into(), start_line: None },
        ];
        let out = review_comments(&notes);
        assert_eq!(out[0], json!({"path": "a", "line": 5, "side": "RIGHT", "body": "fix", "start_line": 3, "start_side": "RIGHT"}));
        assert!(out[1].get("start_line").is_none());
    }

    #[test]
    fn a_check_keeps_its_outcome() {
        let mut d = detail();
        d.checks = vec![PullRequestCheck {
            name: "ci".into(),
            outcome: CheckOutcome::Failing,
            detail: "2 failed".into(),
            url: None,
            check_run: true,
            running: false,
            started: None,
            finished: None,
        }];
        let digest = detail_digest(&d, "u", &ViewedMarks::default(), 0.0);
        assert_eq!(digest.checks, vec![DetailCheck { name: "ci".into(), outcome: "failing".into(), detail: "2 failed".into() }]);
    }
}
