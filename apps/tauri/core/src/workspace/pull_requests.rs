//! Linked pull requests, stacked PR chains, session branch tray, row badges, and persistent sync store
//! (`LinkedPullRequests`, `PullRequestLinks`, `SessionBranches`, `PullRequestSync` on macOS, AG-104).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use url::Url;

use super::source_control::{RemoteRepository, SourceControlHost};

// MARK: PullRequestState & PullRequestRef

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PullRequestState {
    Draft,
    Open,
    Merged,
    Closed,
}

impl PullRequestState {
    /// A draft is still unresolved work.
    pub fn is_open(self) -> bool {
        matches!(self, Self::Draft | Self::Open)
    }

    pub fn from_wire(raw: &str, draft: bool) -> Self {
        match raw.to_ascii_lowercase().as_str() {
            "merged" => Self::Merged,
            "closed" => Self::Closed,
            "draft" => Self::Draft,
            _ if draft => Self::Draft,
            _ => Self::Open,
        }
    }
}

/// A pull request named by a URL, `"owner/repo#12"`, or `"#12"` (no repository: this project's).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParsedPullRequestRef {
    pub host: Option<SourceControlHost>,
    pub host_name: Option<String>,
    /// Repository path (`"owner/repo"`); `None` for `"#12"`.
    pub repository: Option<String>,
    pub number: u64,
    pub url: Option<String>,
}

impl ParsedPullRequestRef {
    pub fn reference(&self) -> String {
        match &self.repository {
            Some(repo) => {
                let shown: Vec<&str> = repo.split('/').filter(|p| *p != "_git").collect();
                format!("{}#{}", shown.join("/"), self.number)
            }
            None => format!("#{}", self.number),
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        let t = text.trim();
        if t.is_empty() {
            return None;
        }
        if t.contains("://") {
            return Self::parse_url(t);
        }
        let hash = t.rfind('#')?;
        let number = parse_positive(&t[hash + 1..])?;
        let left = &t[..hash];
        if left.is_empty() {
            return Some(Self { host: None, host_name: None, repository: None, number, url: None });
        }
        let parts: Vec<&str> = left.split('/').collect();
        if parts.len() < 2
            || !parts.iter().all(|p| {
                !p.is_empty() && *p != "." && *p != ".." && p.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
            })
        {
            return None;
        }
        Some(Self { host: None, host_name: None, repository: Some(left.to_string()), number, url: None })
    }

    fn parse_url(text: &str) -> Option<Self> {
        let trimmed = text.trim_end_matches(|c: char| ".,;:!?)]}>'\"".contains(c));
        let parsed = Url::parse(trimmed).ok()?;
        let scheme = parsed.scheme().to_ascii_lowercase();
        if scheme != "http" && scheme != "https" {
            return None;
        }
        let mut host_raw = parsed.host_str()?.to_ascii_lowercase();
        if host_raw.is_empty() {
            return None;
        }
        if let Some(stripped) = host_raw.strip_prefix("www.") {
            host_raw = stripped.to_string();
        }
        let segments: Vec<&str> = parsed.path().split('/').filter(|s| !s.is_empty()).collect();
        let detected = SourceControlHost::classify(&host_raw);
        let mut kind = detected.clone();
        let mut found = match_url_shape(&detected, &segments);
        if matches!(detected, SourceControlHost::Unknown(_)) {
            for guess in [
                SourceControlHost::Gitlab,
                SourceControlHost::AzureDevOps,
                SourceControlHost::Bitbucket,
                SourceControlHost::Forgejo,
                SourceControlHost::Github,
            ] {
                if let Some(hit) = match_url_shape(&guess, &segments) {
                    kind = guess;
                    found = Some(hit);
                    break;
                }
            }
        }
        let (repo_parts, number) = found?;
        let mut origin = format!("{scheme}://{host_raw}");
        if let Some(port) = parsed.port() {
            origin.push_str(&format!(":{port}"));
        }
        let repo_url = format!("{origin}/{}", repo_parts.join("/"));
        let mut repo = RemoteRepository::detect(&repo_url)?;
        repo.host = kind.clone();
        let canonical = repo.pull_request_url(number);
        Some(Self {
            host: Some(kind),
            host_name: Some(repo.host_name),
            repository: Some(repo.path),
            number,
            url: canonical.or_else(|| Some(trimmed.to_string())),
        })
    }
}

fn parse_positive(s: &str) -> Option<u64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n: u64 = s.parse().ok()?;
    (n > 0).then_some(n)
}

fn match_url_shape<'a>(kind: &SourceControlHost, s: &[&'a str]) -> Option<(Vec<&'a str>, u64)> {
    match kind {
        SourceControlHost::Github => {
            if s.len() >= 4 && s[2] == "pull" {
                Some((s[..2].to_vec(), parse_positive(s[3])?))
            } else {
                None
            }
        }
        SourceControlHost::Bitbucket => {
            if s.len() >= 4 && s[2] == "pull-requests" {
                Some((s[..2].to_vec(), parse_positive(s[3])?))
            } else {
                None
            }
        }
        SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Gitcafe => {
            if s.len() >= 4 && s[2] == "pulls" {
                Some((s[..2].to_vec(), parse_positive(s[3])?))
            } else {
                None
            }
        }
        SourceControlHost::Gitlab => {
            let dash = s.iter().enumerate().position(|(i, &seg)| i >= 2 && seg == "-" && s.get(i + 1) == Some(&"merge_requests"))?;
            let n = parse_positive(s.get(dash + 2)?)?;
            Some((s[..dash].to_vec(), n))
        }
        SourceControlHost::AzureDevOps => {
            let git = s.iter().position(|&seg| seg == "_git")?;
            if s.get(git + 2) == Some(&"pullrequest") {
                let n = parse_positive(s.get(git + 3)?)?;
                Some((s[..git + 2].to_vec(), n))
            } else {
                None
            }
        }
        SourceControlHost::Unknown(_) => None,
    }
}

// MARK: PullRequestLink

/// One pull request linked to a session (`PullRequestLink` on macOS).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestLink {
    #[serde(default = "default_host")]
    pub host: SourceControlHost,
    #[serde(default)]
    pub repository: String,
    pub number: u64,
    #[serde(default)]
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default = "default_state")]
    pub state: PullRequestState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_branch: Option<String>,
    /// True when the forge reports a merge conflict with the base branch (only meaningful while open).
    #[serde(default)]
    pub conflicted: bool,
}

fn default_host() -> SourceControlHost {
    SourceControlHost::Unknown(String::new())
}

fn default_state() -> PullRequestState {
    PullRequestState::Open
}

impl PullRequestLink {
    pub fn from_url(url: &str) -> Option<Self> {
        let parsed = ParsedPullRequestRef::parse(url)?;
        let repository = parsed.repository?;
        let host = parsed.host.unwrap_or_else(|| SourceControlHost::Unknown(parsed.host_name.unwrap_or_default()));
        Some(Self {
            host,
            repository,
            number: parsed.number,
            url: parsed.url.unwrap_or_else(|| url.to_string()),
            title: None,
            state: PullRequestState::Open,
            updated_at: None,
            base_branch: None,
            head_branch: None,
            conflicted: false,
        })
    }

    pub fn has_conflict(&self) -> bool {
        self.state.is_open() && self.conflicted
    }

    pub fn id(&self) -> String {
        format!("{}/{}#{}", self.host.key(), self.repository.to_ascii_lowercase(), self.number)
    }

    /// Canonical place ID, resolving URL repository renames through `aliases`.
    pub fn place_id(&self, aliases: &BTreeMap<String, String>) -> String {
        let current = ParsedPullRequestRef::parse(&self.url).and_then(|r| r.repository).unwrap_or_else(|| self.repository.clone());
        let mut key = format!("{}/{}", self.host.key(), current.to_ascii_lowercase());
        let mut hops = 0;
        while let Some(next) = aliases.get(&key) {
            if next == &key || hops >= 4 {
                break;
            }
            key = next.clone();
            hops += 1;
        }
        format!("{key}#{}", self.number)
    }

    pub fn is_request(&self, repository: &str, number: u64) -> bool {
        if self.number != number {
            return false;
        }
        let wanted = repository.to_ascii_lowercase();
        if self.repository.to_ascii_lowercase() == wanted {
            return true;
        }
        ParsedPullRequestRef::parse(&self.url).and_then(|r| r.repository).is_some_and(|r| r.to_ascii_lowercase() == wanted)
    }

    /// The pull request the tray shows from a branch's list: open first, else newest merged/closed.
    pub fn shown(links: &[Self]) -> Option<String> {
        let usable: Vec<&Self> =
            links.iter().filter(|l| matches!(l.host, SourceControlHost::Github | SourceControlHost::Gitlab) && !l.url.is_empty()).collect();
        let pick =
            usable.iter().copied().find(|l| l.state.is_open()).or_else(|| usable.into_iter().max_by_key(|l| (l.updated_at, l.number)));
        pick.map(|l| l.url.clone())
    }
}

// MARK: PullRequestStack

pub struct PullRequestStack;

impl PullRequestStack {
    /// The pull request `link` is built on: the one in `links` whose `head_branch` equals `link.base_branch`.
    pub fn parent<'a>(link: &PullRequestLink, links: &'a [PullRequestLink]) -> Option<&'a PullRequestLink> {
        let base = link.base_branch.as_deref().filter(|b| !b.is_empty())?;
        let link_id = link.id();
        let link_repo = link.repository.to_ascii_lowercase();
        links
            .iter()
            .filter(|c| {
                c.id() != link_id
                    && c.head_branch.as_deref() == Some(base)
                    && c.host == link.host
                    && c.repository.to_ascii_lowercase() == link_repo
            })
            .max_by_key(|c| (u8::from(c.state.is_open()), c.number))
    }

    /// Layers from the top of the stack down to the PRs targeting an unlinked base branch.
    pub fn order(links: &[PullRequestLink]) -> Vec<Vec<PullRequestLink>> {
        let mut unique = Vec::new();
        let mut seen = HashSet::new();
        for link in links {
            if seen.insert(link.id()) {
                unique.push(link.clone());
            }
        }
        let mut grouped: BTreeMap<usize, Vec<PullRequestLink>> = BTreeMap::new();
        for link in &unique {
            let mut depth = 0usize;
            let mut visited = HashSet::from([link.id()]);
            let mut current = link;
            while let Some(up) = Self::parent(current, &unique) {
                if !visited.insert(up.id()) {
                    break;
                }
                depth += 1;
                current = up;
            }
            grouped.entry(depth).or_default().push(link.clone());
        }
        grouped
            .into_iter()
            .rev()
            .map(|(_, mut layer)| {
                layer.sort_by_key(|l| l.number);
                layer
            })
            .collect()
    }

    pub fn is_stack(links: &[PullRequestLink]) -> bool {
        Self::order(links).len() > 1
    }
}

// MARK: LinkedPullRequests

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkedSource {
    Branch,
    EarlierBranch,
    You,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkedPullRequest {
    pub link: PullRequestLink,
    pub source: LinkedSource,
    /// 0 for standalone or bottom of chain; +1 per PR it is built on.
    pub depth: usize,
    /// Total pull requests in this chain (1 when standalone).
    pub stack_size: usize,
}

pub struct LinkedPullRequests;

impl LinkedPullRequests {
    /// Ordered list for a session: each chain from its bottom up, indented by depth, open chains first
    /// and newest of those on top. A PR found twice keeps the source closest to the session.
    pub fn lines(
        branch: &[PullRequestLink],
        earlier: &[PullRequestLink],
        yours: &[PullRequestLink],
        dismissed: &BTreeSet<String>,
        aliases: &BTreeMap<String, String>,
    ) -> Vec<LinkedPullRequest> {
        let mut sources: HashMap<String, LinkedSource> = HashMap::new();
        let mut unique: Vec<PullRequestLink> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();

        let gone: HashSet<String> = branch
            .iter()
            .chain(yours.iter())
            .chain(earlier.iter())
            .filter(|l| dismissed.contains(&l.id()) || dismissed.contains(&l.place_id(aliases)))
            .map(|l| l.place_id(aliases))
            .collect();

        for (links, source) in [(branch, LinkedSource::Branch), (yours, LinkedSource::You), (earlier, LinkedSource::EarlierBranch)] {
            for link in links {
                let place = link.place_id(aliases);
                let id = link.id();
                if gone.contains(&place) || sources.contains_key(&id) || !seen.insert(place) {
                    continue;
                }
                sources.insert(id, source);
                unique.push(link.clone());
            }
        }

        let mut children: HashMap<String, Vec<PullRequestLink>> = HashMap::new();
        let mut roots: Vec<PullRequestLink> = Vec::new();
        for link in &unique {
            if let Some(parent) = PullRequestStack::parent(link, &unique) {
                children.entry(parent.id()).or_default().push(link.clone());
            } else {
                roots.push(link.clone());
            }
        }

        let mut placed: HashSet<String> = HashSet::new();
        fn walk(
            link: &PullRequestLink,
            depth: usize,
            children: &HashMap<String, Vec<PullRequestLink>>,
            placed: &mut HashSet<String>,
            chain: &mut Vec<PullRequestLink>,
            depths: &mut HashMap<String, usize>,
        ) {
            let id = link.id();
            if !placed.insert(id.clone()) {
                return;
            }
            chain.push(link.clone());
            depths.insert(id.clone(), depth);
            let mut kids = children.get(&id).cloned().unwrap_or_default();
            kids.sort_by_key(|c| c.number);
            for child in kids {
                walk(&child, depth + 1, children, placed, chain, depths);
            }
        }

        let mut chains: Vec<(Vec<PullRequestLink>, HashMap<String, usize>)> = Vec::new();
        for root in &roots {
            let mut chain = Vec::new();
            let mut depths = HashMap::new();
            walk(root, 0, &children, &mut placed, &mut chain, &mut depths);
            if !chain.is_empty() {
                chains.push((chain, depths));
            }
        }
        // Cycles have no root: each still gets a line.
        for link in &unique {
            if placed.contains(&link.id()) {
                continue;
            }
            let mut chain = Vec::new();
            let mut depths = HashMap::new();
            walk(link, 0, &children, &mut placed, &mut chain, &mut depths);
            if !chain.is_empty() {
                chains.push((chain, depths));
            }
        }

        chains.sort_by(|left, right| {
            let left_open = left.0.iter().any(|l| l.state.is_open());
            let right_open = right.0.iter().any(|l| l.state.is_open());
            right_open.cmp(&left_open).then_with(|| {
                let left_max = left.0.iter().map(|l| l.number).max().unwrap_or(0);
                let right_max = right.0.iter().map(|l| l.number).max().unwrap_or(0);
                right_max.cmp(&left_max)
            })
        });

        let mut out = Vec::new();
        for (chain, depths) in chains {
            let stack_size = chain.len();
            for link in chain {
                let id = link.id();
                out.push(LinkedPullRequest {
                    source: *sources.get(&id).unwrap_or(&LinkedSource::Branch),
                    depth: *depths.get(&id).unwrap_or(&0),
                    stack_size,
                    link,
                });
            }
        }
        out
    }

    pub fn open_count(lines: &[LinkedPullRequest]) -> usize {
        lines.iter().filter(|l| l.link.state.is_open()).count()
    }
}

// MARK: PullRequestBadge

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BadgeGlyph {
    Draft,
    Open,
    Conflict,
    Merged,
    Closed,
    Stack,
}

impl BadgeGlyph {
    pub fn from_link(link: &PullRequestLink) -> Self {
        if link.has_conflict() {
            return Self::Conflict;
        }
        match link.state {
            PullRequestState::Draft => Self::Draft,
            PullRequestState::Open => Self::Open,
            PullRequestState::Merged => Self::Merged,
            PullRequestState::Closed => Self::Closed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum BadgeLabel {
    Number { number: u64 },
    NumberPlus { number: u64, extra: usize },
    Stack { count: usize, merged: usize },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestBadge {
    pub glyph: BadgeGlyph,
    pub label: BadgeLabel,
}

impl PullRequestBadge {
    pub fn from_links(links: &[PullRequestLink]) -> Option<Self> {
        if links.is_empty() {
            return None;
        }
        if links.len() > 1 && PullRequestStack::is_stack(links) {
            let merged = links.iter().filter(|l| l.state == PullRequestState::Merged).count();
            let glyph = if links.iter().any(|l| l.state.is_open()) {
                BadgeGlyph::Stack
            } else if merged > 0 {
                BadgeGlyph::Merged
            } else {
                BadgeGlyph::Closed
            };
            return Some(Self { glyph, label: BadgeLabel::Stack { count: links.len(), merged } });
        }
        let primary = links.iter().max_by_key(|l| (u8::from(l.state.is_open()), l.number, l.updated_at))?;
        let glyph = BadgeGlyph::from_link(primary);
        let label = if links.len() == 1 {
            BadgeLabel::Number { number: primary.number }
        } else {
            BadgeLabel::NumberPlus { number: primary.number, extra: links.len() - 1 }
        };
        Some(Self { glyph, label })
    }
}

// MARK: SessionBranches & RunBranchTray rows

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionBranchRow {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<PullRequestLink>,
    pub is_current: bool,
}

pub struct SessionBranches;

impl SessionBranches {
    /// How many rows stay open when folded (`SessionBranches.shownWhenFolded` on macOS).
    pub const SHOWN_WHEN_FOLDED: usize = 3;

    pub fn is_default_branch(name: &str, detected_default: Option<&str>) -> bool {
        let short = Self::normalize_branch(name);
        if matches!(short.to_ascii_lowercase().as_str(), "main" | "master" | "trunk" | "develop") {
            return true;
        }
        detected_default.filter(|d| !d.is_empty()).is_some_and(|d| short == Self::normalize_branch(d))
    }

    fn normalize_branch(name: &str) -> &str {
        let mut n = name.trim();
        for prefix in ["refs/heads/", "refs/remotes/origin/", "origin/"] {
            if let Some(rest) = n.strip_prefix(prefix) {
                n = rest;
            }
        }
        n
    }

    /// The session left `old` for `current`: appends `old` to earlier branches unless it is the default branch.
    pub fn leaving(old: Option<&str>, current: &str, earlier: &[String], base: Option<&str>) -> Vec<String> {
        let mut list: Vec<String> = earlier.iter().filter(|b| b.as_str() != current).cloned().collect();
        if let Some(old) = old {
            if !old.is_empty() && old != current && !Self::is_default_branch(old, base) {
                list.retain(|b| b != old);
                list.push(old.to_string());
            }
        }
        list
    }

    /// Merges pull requests of a branch the session left into its earlier-branch list (newer replaces older).
    pub fn keeping(left: &[PullRequestLink], earlier: &[PullRequestLink], aliases: &BTreeMap<String, String>) -> Vec<PullRequestLink> {
        let mut list = earlier.to_vec();
        for link in left {
            if link.url.is_empty() {
                continue;
            }
            let target = Self::place(&link.url, aliases);
            if let Some(pos) = list.iter().position(|e| Self::place(&e.url, aliases) == target) {
                list[pos] = link.clone();
            } else {
                list.push(link.clone());
            }
        }
        list
    }

    pub fn place(url: &str, aliases: &BTreeMap<String, String>) -> String {
        PullRequestLink::from_url(url).map(|l| l.place_id(aliases)).unwrap_or_else(|| url.to_string())
    }

    /// Builds the branch tray rows (oldest first, current last), matching `SessionBranches.rows` on macOS.
    pub fn rows(
        earlier: &[String],
        earlier_links: &[PullRequestLink],
        current: Option<&str>,
        current_links: &[PullRequestLink],
        aliases: &BTreeMap<String, String>,
    ) -> Vec<SessionBranchRow> {
        let newest = |branch: &str| -> Option<PullRequestLink> {
            earlier_links.iter().filter(|l| l.head_branch.as_deref() == Some(branch)).max_by_key(|l| (l.updated_at, l.number)).cloned()
        };

        let own: Vec<&PullRequestLink> =
            current_links.iter().filter(|l| l.head_branch.as_deref().is_none_or(|h| Some(h) == current)).collect();
        let picked = own
            .iter()
            .copied()
            .find(|l| l.state.is_open())
            .or_else(|| own.iter().copied().max_by_key(|l| (l.updated_at, l.number)))
            .cloned();
        let picked_key = picked.as_ref().map(|l| Self::place(&l.url, aliases));

        let names: Vec<String> = earlier.iter().filter(|b| Some(b.as_str()) != current).cloned().collect();
        let mut rows: Vec<SessionBranchRow> =
            names.iter().map(|b| SessionBranchRow { branch: Some(b.clone()), pull_request: newest(b), is_current: false }).collect();
        let mut seen: HashSet<String> = rows.iter().filter_map(|r| r.pull_request.as_ref().map(|p| Self::place(&p.url, aliases))).collect();

        for link in earlier_links {
            if link.url.is_empty() {
                continue;
            }
            let covered_by_name = link.head_branch.as_ref().is_some_and(|h| names.contains(h) || Some(h.as_str()) == current);
            if covered_by_name {
                continue;
            }
            let target = Self::place(&link.url, aliases);
            if picked_key.as_deref() == Some(target.as_str()) || !seen.insert(target) {
                continue;
            }
            rows.push(SessionBranchRow { branch: link.head_branch.clone(), pull_request: Some(link.clone()), is_current: false });
        }

        let mut own_sorted: Vec<&PullRequestLink> = own;
        own_sorted.sort_by_key(|l| l.number);
        for link in own_sorted {
            if link.url.is_empty() {
                continue;
            }
            let target = Self::place(&link.url, aliases);
            if picked_key.as_deref() == Some(target.as_str()) || !seen.insert(target) {
                continue;
            }
            rows.push(SessionBranchRow { branch: current.map(ToString::to_string), pull_request: Some(link.clone()), is_current: true });
        }

        // If the session has earlier branches/PRs OR has a current PR, include the current branch row at the bottom.
        let mine = picked.or_else(|| current.and_then(newest)).filter(|l| !seen.contains(&Self::place(&l.url, aliases)));
        if !rows.is_empty() || mine.is_some() {
            rows.push(SessionBranchRow { branch: current.map(ToString::to_string), pull_request: mine, is_current: true });
        }
        rows
    }

    /// Folds older rows when more than `SHOWN_WHEN_FOLDED + 1` exist and `open` is false.
    pub fn folded(rows: &[SessionBranchRow], open: bool) -> (Vec<SessionBranchRow>, usize, usize) {
        if open || rows.len() <= Self::SHOWN_WHEN_FOLDED + 1 {
            return (rows.to_vec(), 0, 0);
        }
        let split = rows.len() - Self::SHOWN_WHEN_FOLDED;
        let hidden = &rows[..split];
        let hidden_prs = hidden.iter().filter(|r| r.pull_request.is_some()).count();
        (rows[split..].to_vec(), hidden.len(), hidden_prs)
    }
}

// MARK: PullRequestSettlement

pub struct PullRequestSettlement;

impl PullRequestSettlement {
    pub const QUIET_AFTER_SECS: i64 = 30 * 60;
    pub const SETTLED_AFTER_SECS: i64 = 24 * 60 * 60;

    pub fn any_open(links: &[PullRequestLink]) -> bool {
        links.iter().any(|l| l.state.is_open())
    }

    pub fn all_merged(links: &[PullRequestLink]) -> bool {
        !links.is_empty() && links.iter().all(|l| l.state == PullRequestState::Merged)
    }

    pub fn should_settle(links: &[PullRequestLink], settle_on_merge: bool) -> bool {
        if links.is_empty() || Self::any_open(links) {
            return false;
        }
        let Some(latest) = links.iter().max_by_key(|l| (l.updated_at, l.number)) else {
            return false;
        };
        latest.state == PullRequestState::Closed || (latest.state == PullRequestState::Merged && settle_on_merge)
    }

    pub fn sync_interval_secs(
        links: &[PullRequestLink],
        quiet_since: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
        sees_creation: bool,
    ) -> i64 {
        if Self::any_open(links) {
            let quiet = links
                .iter()
                .filter(|l| l.state.is_open())
                .all(|l| l.updated_at.is_some_and(|u| (now - u).num_seconds() >= Self::QUIET_AFTER_SECS));
            return if quiet { 300 } else { 30 };
        }
        let is_settled = |dt: Option<DateTime<Utc>>| dt.is_some_and(|d| (now - d).num_seconds() >= Self::SETTLED_AFTER_SECS);
        if links.is_empty() {
            return if is_settled(quiet_since) || sees_creation { 900 } else { 60 };
        }
        let newest = links.iter().filter_map(|l| l.updated_at).chain(quiet_since).max();
        if is_settled(newest) {
            6 * 60 * 60
        } else {
            900
        }
    }
}

// MARK: PullRequestSyncStore (persisted JSON store)

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestSyncSnapshot {
    #[serde(default)]
    pub links: BTreeMap<String, Vec<PullRequestLink>>,
    #[serde(default)]
    pub folder_links: BTreeMap<String, Vec<PullRequestLink>>,
    #[serde(default)]
    pub earlier: BTreeMap<String, Vec<PullRequestLink>>,
    #[serde(default)]
    pub earlier_branches: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub added: BTreeMap<String, Vec<PullRequestLink>>,
    #[serde(default)]
    pub dismissed: BTreeMap<String, BTreeSet<String>>,
    #[serde(default)]
    pub synced_at: BTreeMap<String, DateTime<Utc>>,
}

#[derive(Debug, Clone)]
pub struct PullRequestSyncStore {
    path: PathBuf,
    pub data: PullRequestSyncSnapshot,
}

impl PullRequestSyncStore {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("workspace").join("pull-request-links.json")
    }

    pub fn load() -> Self {
        Self::load_from(Self::file())
    }

    pub fn load_from(path: PathBuf) -> Self {
        let data =
            std::fs::read(&path).ok().and_then(|bytes| serde_json::from_slice::<PullRequestSyncSnapshot>(&bytes).ok()).unwrap_or_default();
        Self { path, data }
    }

    pub fn save(&self) -> Result<(), String> {
        Self::save_to(&self.path, &self.data)
    }

    fn save_to(path: &Path, data: &PullRequestSyncSnapshot) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(data).map_err(|e| e.to_string())?;
        crate::paths::write_atomic(path, &bytes).map_err(|e| e.to_string())
    }

    pub fn session_key(run_id: Option<&str>, directory: &str) -> String {
        run_id.filter(|id| !id.is_empty()).unwrap_or(directory).to_string()
    }

    pub fn folder_key(path: &str, branch: &str) -> String {
        format!("{path}\n{branch}")
    }

    /// Everything linked to a session, sorted and stacked via [`LinkedPullRequests::lines`].
    pub fn linked(&self, run_id: Option<&str>, directory: &str, branch: Option<&str>) -> Vec<LinkedPullRequest> {
        let key = Self::session_key(run_id, directory);
        let current = run_id
            .and_then(|id| self.data.links.get(id))
            .or_else(|| branch.and_then(|b| self.data.folder_links.get(&Self::folder_key(directory, b))))
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        let earlier = run_id.and_then(|id| self.data.earlier.get(id)).map(Vec::as_slice).unwrap_or(&[]);
        let yours = self.data.added.get(&key).map(Vec::as_slice).unwrap_or(&[]);
        let dismissed = self.data.dismissed.get(&key).cloned().unwrap_or_default();
        LinkedPullRequests::lines(current, earlier, yours, &dismissed, &BTreeMap::new())
    }

    /// Manually links a pull request to a session; if it was dismissed earlier, restores it.
    pub fn add_link(&mut self, session_key: &str, link: PullRequestLink) {
        let aliases = BTreeMap::new();
        let target = link.place_id(&aliases);
        let id = link.id();
        if let Some(gone) = self.data.dismissed.get_mut(session_key) {
            gone.remove(&id);
            gone.remove(&target);
        }
        let list = self.data.added.entry(session_key.to_string()).or_default();
        list.retain(|existing| existing.id() != id && existing.place_id(&aliases) != target);
        list.push(link);
        let _ = self.save();
    }

    /// Adds a PR discovered in the session's timeline; respects prior dismissals and avoids duplicates.
    pub fn mention_link(&mut self, session_key: &str, link: PullRequestLink) {
        let aliases = BTreeMap::new();
        let target = link.place_id(&aliases);
        let id = link.id();
        if self.data.dismissed.get(session_key).is_some_and(|g| g.contains(&id) || g.contains(&target)) {
            return;
        }
        let list = self.data.added.entry(session_key.to_string()).or_default();
        if list.iter().any(|existing| existing.id() == id || existing.place_id(&aliases) == target) {
            return;
        }
        list.push(link);
        let _ = self.save();
    }

    /// Unlinks/dismisses a pull request from a session so branch sync won't re-add it.
    pub fn remove_link(&mut self, session_key: &str, link_id: &str, url: &str) {
        let aliases = BTreeMap::new();
        let place = SessionBranches::place(url, &aliases);
        if let Some(list) = self.data.added.get_mut(session_key) {
            list.retain(|existing| existing.id() != link_id && existing.place_id(&aliases) != place);
        }
        let gone = self.data.dismissed.entry(session_key.to_string()).or_default();
        if !link_id.is_empty() {
            gone.insert(link_id.to_string());
        }
        if !place.is_empty() {
            gone.insert(place);
        }
        let _ = self.save();
    }

    /// Updates branch pull requests for a Nook-managed session.
    pub fn record_run_links(&mut self, run_id: &str, links: Vec<PullRequestLink>, now: DateTime<Utc>) {
        if links.is_empty() {
            self.data.links.remove(run_id);
        } else {
            self.data.links.insert(run_id.to_string(), links);
        }
        self.data.synced_at.insert(run_id.to_string(), now);
        let _ = self.save();
    }

    /// Updates branch pull requests for a folder+branch (external / terminal / past session).
    pub fn record_folder_links(&mut self, path: &str, branch: &str, links: Vec<PullRequestLink>, now: DateTime<Utc>) {
        let key = Self::folder_key(path, branch);
        if links.is_empty() {
            self.data.folder_links.remove(&key);
        } else {
            self.data.folder_links.insert(key.clone(), links);
        }
        self.data.synced_at.insert(key, now);
        let _ = self.save();
    }

    /// Records that a session opened a pull request on its current branch.
    pub fn record_opened(&mut self, run_id: &str, url: &str, branch: Option<&str>, title: Option<String>, now: DateTime<Utc>) {
        let Some(mut link) = PullRequestLink::from_url(url) else {
            return;
        };
        link.head_branch = branch.map(ToString::to_string);
        link.title = title;
        link.updated_at = Some(now);
        let aliases = BTreeMap::new();
        let target = link.place_id(&aliases);
        let list = self.data.links.entry(run_id.to_string()).or_default();
        if let Some(pos) = list.iter().position(|e| e.place_id(&aliases) == target) {
            list[pos] = link;
        } else {
            list.push(link);
        }
        self.data.synced_at.insert(run_id.to_string(), now);
        let _ = self.save();
    }

    /// Records that a session moved from `old_branch` to `new_branch`, retiring old links to `earlier`.
    pub fn record_branch_change(&mut self, run_id: &str, old_branch: Option<&str>, new_branch: &str, base_branch: Option<&str>) {
        let aliases = BTreeMap::new();
        let current_earlier = self.data.earlier_branches.get(run_id).cloned().unwrap_or_default();
        let updated_branches = SessionBranches::leaving(old_branch, new_branch, &current_earlier, base_branch);
        if updated_branches.is_empty() {
            self.data.earlier_branches.remove(run_id);
        } else {
            self.data.earlier_branches.insert(run_id.to_string(), updated_branches);
        }
        if let Some(left) = self.data.links.remove(run_id) {
            let kept = SessionBranches::keeping(&left, self.data.earlier.get(run_id).map(Vec::as_slice).unwrap_or(&[]), &aliases);
            if !kept.is_empty() {
                self.data.earlier.insert(run_id.to_string(), kept);
            }
        }
        let _ = self.save();
    }

    /// Updates state (e.g. merged/closed) across every stored link matching `repository` + `number`.
    pub fn mark_state(&mut self, repository: &str, number: u64, state: PullRequestState, now: DateTime<Utc>) {
        let mut changed = false;
        let update_list = |list: &mut Vec<PullRequestLink>, changed: &mut bool| {
            for link in list.iter_mut() {
                if link.is_request(repository, number) && link.state != state {
                    link.state = state;
                    link.updated_at = Some(now);
                    if !state.is_open() {
                        link.conflicted = false;
                    }
                    *changed = true;
                }
            }
        };
        for list in self.data.links.values_mut() {
            update_list(list, &mut changed);
        }
        for list in self.data.folder_links.values_mut() {
            update_list(list, &mut changed);
        }
        for list in self.data.earlier.values_mut() {
            update_list(list, &mut changed);
        }
        for list in self.data.added.values_mut() {
            update_list(list, &mut changed);
        }
        if changed {
            let _ = self.save();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_link(number: u64, head: Option<&str>, base: Option<&str>, state: PullRequestState) -> PullRequestLink {
        PullRequestLink {
            host: SourceControlHost::Github,
            repository: "acme/app".into(),
            number,
            url: format!("https://github.com/acme/app/pull/{number}"),
            title: Some(format!("PR #{number}")),
            state,
            updated_at: None,
            base_branch: base.map(ToString::to_string),
            head_branch: head.map(ToString::to_string),
            conflicted: false,
        }
    }

    #[test]
    fn parses_urls_and_shorthand_references() {
        let gh = ParsedPullRequestRef::parse("https://github.com/acme/app/pull/42.").unwrap();
        assert_eq!(gh.host, Some(SourceControlHost::Github));
        assert_eq!(gh.repository.as_deref(), Some("acme/app"));
        assert_eq!(gh.number, 42);
        assert_eq!(gh.url.as_deref(), Some("https://github.com/acme/app/pull/42"));

        let gl = ParsedPullRequestRef::parse("https://gitlab.com/org/sub/repo/-/merge_requests/9").unwrap();
        assert_eq!(gl.host, Some(SourceControlHost::Gitlab));
        assert_eq!(gl.repository.as_deref(), Some("org/sub/repo"));
        assert_eq!(gl.number, 9);

        let short = ParsedPullRequestRef::parse("acme/app#17").unwrap();
        assert_eq!(short.repository.as_deref(), Some("acme/app"));
        assert_eq!(short.number, 17);

        let num = ParsedPullRequestRef::parse("#99").unwrap();
        assert_eq!(num.repository, None);
        assert_eq!(num.number, 99);
        assert_eq!(num.reference(), "#99");

        assert!(ParsedPullRequestRef::parse("https://github.com/acme/app").is_none());
        assert!(ParsedPullRequestRef::parse("#0").is_none());
    }

    #[test]
    fn linked_pull_requests_orders_stacks_dedupes_and_respects_dismissed() {
        let aliases = BTreeMap::new();
        let dismissed = BTreeSet::new();

        // Stacked chain: #1 (main <- a), #2 (a <- b), #3 (b <- c)
        let lines = LinkedPullRequests::lines(
            &[mk_link(3, Some("c"), Some("b"), PullRequestState::Open)],
            &[mk_link(1, Some("a"), Some("main"), PullRequestState::Open), mk_link(2, Some("b"), Some("a"), PullRequestState::Open)],
            &[],
            &dismissed,
            &aliases,
        );
        assert_eq!(lines.iter().map(|l| (l.link.number, l.depth, l.stack_size)).collect::<Vec<_>>(), vec![(1, 0, 3), (2, 1, 3), (3, 2, 3)]);
        assert_eq!(LinkedPullRequests::open_count(&lines), 3);

        // Open chains come before merged ones even with lower PR numbers
        let mixed = LinkedPullRequests::lines(
            &[mk_link(9, Some("old"), Some("main"), PullRequestState::Merged), mk_link(4, Some("x"), Some("main"), PullRequestState::Open)],
            &[],
            &[],
            &dismissed,
            &aliases,
        );
        assert_eq!(mixed.iter().map(|l| l.link.number).collect::<Vec<_>>(), vec![4, 9]);

        // Duplicate across sources keeps closest source (branch > you > earlier)
        let dup = LinkedPullRequests::lines(
            &[mk_link(1, None, None, PullRequestState::Open)],
            &[mk_link(1, None, None, PullRequestState::Open)],
            &[mk_link(1, None, None, PullRequestState::Open), mk_link(2, None, None, PullRequestState::Draft)],
            &dismissed,
            &aliases,
        );
        assert_eq!(dup.len(), 2);
        assert_eq!(dup.iter().find(|l| l.link.number == 1).unwrap().source, LinkedSource::Branch);
        assert_eq!(dup.iter().find(|l| l.link.number == 2).unwrap().source, LinkedSource::You);

        // Dismissed PR is omitted
        let gone = mk_link(1, None, None, PullRequestState::Open);
        let gone_set = BTreeSet::from([gone.id()]);
        let kept = LinkedPullRequests::lines(&[gone, mk_link(2, None, None, PullRequestState::Open)], &[], &[], &gone_set, &aliases);
        assert_eq!(kept.iter().map(|l| l.link.number).collect::<Vec<_>>(), vec![2]);

        // Cyclic stack still outputs every PR without looping forever
        let cyc = LinkedPullRequests::lines(
            &[mk_link(1, Some("a"), Some("b"), PullRequestState::Open), mk_link(2, Some("b"), Some("a"), PullRequestState::Open)],
            &[],
            &[],
            &dismissed,
            &aliases,
        );
        assert_eq!(cyc.len(), 2);
    }

    #[test]
    fn pull_request_badge_handles_single_multi_conflict_and_stacks() {
        assert_eq!(PullRequestBadge::from_links(&[]), None);

        let draft = PullRequestBadge::from_links(&[mk_link(12, None, None, PullRequestState::Draft)]).unwrap();
        assert_eq!(draft, PullRequestBadge { glyph: BadgeGlyph::Draft, label: BadgeLabel::Number { number: 12 } });

        let multi = PullRequestBadge::from_links(&[
            mk_link(12, Some("a"), None, PullRequestState::Open),
            mk_link(13, Some("b"), None, PullRequestState::Merged),
            mk_link(14, Some("c"), None, PullRequestState::Closed),
        ])
        .unwrap();
        assert_eq!(multi, PullRequestBadge { glyph: BadgeGlyph::Open, label: BadgeLabel::NumberPlus { number: 12, extra: 2 } });

        let mut conflicted = mk_link(5, None, None, PullRequestState::Open);
        conflicted.conflicted = true;
        assert_eq!(PullRequestBadge::from_links(&[conflicted]).unwrap().glyph, BadgeGlyph::Conflict);

        let stack = PullRequestBadge::from_links(&[
            mk_link(1, Some("a"), Some("main"), PullRequestState::Merged),
            mk_link(2, Some("b"), Some("a"), PullRequestState::Open),
            mk_link(3, Some("c"), Some("b"), PullRequestState::Open),
        ])
        .unwrap();
        assert_eq!(stack, PullRequestBadge { glyph: BadgeGlyph::Stack, label: BadgeLabel::Stack { count: 3, merged: 1 } });

        let all_merged = PullRequestBadge::from_links(&[
            mk_link(1, Some("a"), Some("main"), PullRequestState::Merged),
            mk_link(2, Some("b"), Some("a"), PullRequestState::Merged),
        ])
        .unwrap();
        assert_eq!(all_merged, PullRequestBadge { glyph: BadgeGlyph::Merged, label: BadgeLabel::Stack { count: 2, merged: 2 } });
    }

    #[test]
    fn session_branches_rows_and_folding() {
        let aliases = BTreeMap::new();
        let earlier = vec!["feat/a".into(), "feat/b".into(), "feat/c".into(), "feat/d".into()];
        let earlier_links = vec![
            mk_link(1, Some("feat/a"), Some("main"), PullRequestState::Merged),
            mk_link(2, Some("feat/b"), Some("main"), PullRequestState::Merged),
        ];
        let current_links = vec![mk_link(5, Some("feat/e"), Some("main"), PullRequestState::Open)];
        let rows = SessionBranches::rows(&earlier, &earlier_links, Some("feat/e"), &current_links, &aliases);
        assert_eq!(rows.len(), 5);
        assert!(rows.last().unwrap().is_current);
        assert_eq!(rows.last().unwrap().pull_request.as_ref().map(|p| p.number), Some(5));

        let (shown, hidden, hidden_prs) = SessionBranches::folded(&rows, false);
        assert_eq!(shown.len(), 3);
        assert_eq!(hidden, 2);
        assert_eq!(hidden_prs, 2);

        let (expanded, hidden2, _) = SessionBranches::folded(&rows, true);
        assert_eq!(expanded.len(), 5);
        assert_eq!(hidden2, 0);
    }

    #[test]
    fn sync_store_persists_adds_dismissals_and_branch_retirements() {
        let dir = std::env::temp_dir().join(format!("nook-pr-sync-{}", uuid::Uuid::new_v4()));
        let path = dir.join("pull-request-links.json");
        let now = Utc::now();

        let mut store = PullRequestSyncStore::load_from(path.clone());
        store.record_opened("run-1", "https://github.com/acme/app/pull/10", Some("feat/first"), Some("First".into()), now);
        store.record_branch_change("run-1", Some("feat/first"), "feat/second", Some("main"));
        store.add_link("run-1", mk_link(20, Some("other"), Some("main"), PullRequestState::Open));

        let reloaded = PullRequestSyncStore::load_from(path.clone());
        let linked = reloaded.linked(Some("run-1"), "/repo", Some("feat/second"));
        assert_eq!(linked.len(), 2);
        assert_eq!(reloaded.data.earlier_branches.get("run-1").cloned(), Some(vec!["feat/first".to_string()]));

        let mut store2 = reloaded;
        store2.mark_state("acme/app", 20, PullRequestState::Merged, now);
        let after_merge = store2.linked(Some("run-1"), "/repo", Some("feat/second"));
        assert_eq!(after_merge.iter().find(|l| l.link.number == 20).unwrap().link.state, PullRequestState::Merged);

        let link10 = mk_link(10, Some("feat/first"), Some("main"), PullRequestState::Open);
        store2.remove_link("run-1", &link10.id(), &link10.url);
        assert_eq!(store2.linked(Some("run-1"), "/repo", Some("feat/second")).len(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
