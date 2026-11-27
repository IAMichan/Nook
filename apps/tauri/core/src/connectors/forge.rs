//! Personal tokens and REST adapters for non-GitHub code hosts: GitLab, Gitea / Forgejo / Codeberg,
//! GitCafe, Bitbucket Cloud, and Azure DevOps (`ForgeCredentials`, `SourceForge`, `PullRequestForge*` on macOS).
//!
//! Security invariants:
//! - Tokens are kept only in [`SecretStore`] (`forge.token.<host>` or `gitlab.token.<host>`) and never written to
//!   JSON config, URLs, or logs.
//! - Production requests go over `https://` only, and only to the host the token belongs to (Bitbucket Cloud tokens
//!   only go to `api.bitbucket.org`, Azure DevOps to `dev.azure.com`, GitCafe to `git.cafe` / `staging.git.cafe`).

use base64::Engine;
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{clean, gitlab, CResult, ConnectorError, ConnectorStore, Http};
use crate::i18n::tr;
use crate::secrets::SecretStore;
use crate::workspace::bridge::{PrCheckSummary, PrHost, PrReviewSummary, PullRequestRef, PullRequestSnapshot};
use crate::workspace::source_control::{RemoteRepository, SourceControlHost};

const BITBUCKET_API: &str = "https://api.bitbucket.org/2.0";
const AZURE_API_VERSION: &str = "api-version=7.1";
const GITCAFE_HOSTS: [&str; 2] = ["git.cafe", "staging.git.cafe"];

/// The kinds of code host Settings › Pull requests can store a token for.
/// Gitea, Forgejo, and Codeberg speak the same v1 API and share one choice (`Gitea`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CodeHostKind {
    Gitlab,
    Gitea,
    Gitcafe,
    Bitbucket,
    AzureDevOps,
}

impl CodeHostKind {
    /// Classifies a stored host name into its code host kind, matching `SourceControlHost::classify`.
    pub fn from_host(host: &str) -> Self {
        let bare = host.split(':').next().unwrap_or(host).to_ascii_lowercase();
        match SourceControlHost::classify(&bare) {
            SourceControlHost::Gitlab => Self::Gitlab,
            SourceControlHost::Gitcafe => Self::Gitcafe,
            SourceControlHost::Bitbucket => Self::Bitbucket,
            SourceControlHost::AzureDevOps => Self::AzureDevOps,
            SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Github | SourceControlHost::Unknown(_) => {
                Self::Gitea
            }
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Gitlab => "GitLab",
            Self::Gitea => "Gitea",
            Self::Gitcafe => "GitCafe",
            Self::Bitbucket => "Bitbucket",
            Self::AzureDevOps => "Azure DevOps",
        }
    }

    /// Whether the host has a `GET /user` check endpoint Nook can call to verify a token before saving.
    /// GitCafe and Azure DevOps tokens are saved without an upfront check and used on the first request.
    pub fn can_check_token(self) -> bool {
        matches!(self, Self::Gitlab | Self::Gitea | Self::Bitbucket)
    }

    /// Fixed host for single-domain services; `None` means the user provides the server host.
    pub fn fixed_host(self) -> Option<&'static str> {
        match self {
            Self::Gitlab => Some("gitlab.com"),
            Self::Gitcafe => Some("git.cafe"),
            Self::Bitbucket => Some("bitbucket.org"),
            Self::AzureDevOps => Some("dev.azure.com"),
            Self::Gitea => None,
        }
    }
}

/// What a code host said when Nook checked a token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ForgeTokenCheck {
    /// The host accepted the token; `account` is `None` when a valid token lacks user-read scope (HTTP 403).
    Valid {
        account: Option<String>,
    },
    Rejected,
    Unreachable,
}

impl ForgeTokenCheck {
    pub fn from_response(status: u16, body: &[u8]) -> Self {
        match status {
            401 => Self::Rejected,
            403 => Self::Valid { account: None },
            200 => {
                let json = serde_json::from_slice::<Value>(body).ok();
                let account = json.as_ref().and_then(|v| {
                    v["login"]
                        .as_str()
                        .or_else(|| v["username"].as_str())
                        .or_else(|| v["nickname"].as_str())
                        .or_else(|| v["display_name"].as_str())
                        .filter(|s| !s.is_empty())
                        .map(str::to_string)
                });
                Self::Valid { account }
            }
            _ => Self::Unreachable,
        }
    }
}

// MARK: Credentials

pub fn account(host: &str) -> String {
    format!("forge.token.{}", host.to_lowercase())
}

pub fn token(secrets: &dyn SecretStore, host: &str) -> Option<String> {
    secrets.read(&account(host)).map(|t| clean(&t)).filter(|t| !t.is_empty())
}

/// Stored non-GitHub/GitLab forge hosts that still have a token in the keychain.
pub fn hosts(store: &ConnectorStore, secrets: &dyn SecretStore) -> Vec<String> {
    store.read(|c| c.forge_hosts.clone()).into_iter().filter(|h| token(secrets, h).is_some()).collect()
}

pub fn save(store: &ConnectorStore, secrets: &dyn SecretStore, host: &str, value: &str) -> CResult<String> {
    let invalid =
        || ConnectorError::new(tr("Dat is geen geldige host of het token is leeg.", "That is not a valid host or the token is empty."));
    let host = gitlab::normalize(host).ok_or_else(invalid)?;
    let value = clean(value);
    if value.is_empty() {
        return Err(invalid());
    }
    secrets.write(&account(&host), &value).map_err(ConnectorError::new)?;
    store.update(|c| {
        if !c.forge_hosts.contains(&host) {
            c.forge_hosts.push(host.clone());
        }
    });
    Ok(host)
}

pub fn remove(store: &ConnectorStore, secrets: &dyn SecretStore, host: &str) {
    let _ = secrets.remove(&account(host));
    let host = host.to_lowercase();
    store.update(|c| c.forge_hosts.retain(|h| *h != host));
}

/// Checks a token against a code host (`GET /user`), over HTTPS only.
pub async fn check_token(http: &Http, kind: CodeHostKind, host: &str, value: &str) -> ForgeTokenCheck {
    check_token_with_base(http, kind, host, value, None).await
}

async fn check_token_with_base(http: &Http, kind: CodeHostKind, host: &str, value: &str, base_override: Option<&str>) -> ForgeTokenCheck {
    let clean_token = clean(value);
    if clean_token.is_empty() {
        return ForgeTokenCheck::Unreachable;
    }
    let Some(host) = gitlab::normalize(host) else {
        return ForgeTokenCheck::Unreachable;
    };
    match kind {
        CodeHostKind::Gitlab => match gitlab::check(http, &host, &clean_token).await {
            gitlab::TokenCheck::Valid { username } => ForgeTokenCheck::Valid { account: Some(username) },
            gitlab::TokenCheck::Rejected => ForgeTokenCheck::Rejected,
            gitlab::TokenCheck::Unreachable => ForgeTokenCheck::Unreachable,
        },
        CodeHostKind::Gitea => {
            let base = base_override.map(str::to_string).unwrap_or_else(|| format!("https://{host}/api/v1"));
            let headers = [("Authorization", format!("token {clean_token}")), ("Accept", "application/json".into())];
            match http.send("GET", &format!("{base}/user"), &headers, None, "Gitea").await {
                Ok((status, body)) => ForgeTokenCheck::from_response(status, &body),
                Err(_) => ForgeTokenCheck::Unreachable,
            }
        }
        CodeHostKind::Bitbucket => {
            let base = base_override.unwrap_or(BITBUCKET_API);
            let auth = format!("Basic {}", basic_encode(&clean_token));
            let headers = [("Authorization", auth), ("Accept", "application/json".into())];
            match http.send("GET", &format!("{base}/user"), &headers, None, "Bitbucket").await {
                Ok((status, body)) => ForgeTokenCheck::from_response(status, &body),
                Err(_) => ForgeTokenCheck::Unreachable,
            }
        }
        CodeHostKind::Gitcafe | CodeHostKind::AzureDevOps => ForgeTokenCheck::Unreachable,
    }
}

/// Verifies a token when the host supports it, refusing to store rejected tokens.
/// Unreachable hosts still store the token so offline/VPN setups work when later used.
pub async fn verify_and_save(
    http: &Http,
    store: &ConnectorStore,
    secrets: &dyn SecretStore,
    kind: CodeHostKind,
    host: &str,
    value: &str,
) -> CResult<(String, Option<ForgeTokenCheck>)> {
    verify_and_save_with_base(http, store, secrets, kind, host, value, None).await
}

async fn verify_and_save_with_base(
    http: &Http,
    store: &ConnectorStore,
    secrets: &dyn SecretStore,
    kind: CodeHostKind,
    host: &str,
    value: &str,
    base_override: Option<&str>,
) -> CResult<(String, Option<ForgeTokenCheck>)> {
    let target = kind.fixed_host().unwrap_or(host);
    if gitlab::normalize(target).is_none() || clean(value).is_empty() {
        return Err(ConnectorError::new(tr(
            "Dat is geen geldige host of het token is leeg.",
            "That is not a valid host or the token is empty.",
        )));
    }
    if kind == CodeHostKind::Gitlab {
        let (saved, check) = gitlab::verify_and_save(http, store, secrets, target, value).await?;
        let mapped = match check {
            gitlab::TokenCheck::Valid { username } => ForgeTokenCheck::Valid { account: Some(username) },
            gitlab::TokenCheck::Rejected => ForgeTokenCheck::Rejected,
            gitlab::TokenCheck::Unreachable => ForgeTokenCheck::Unreachable,
        };
        return Ok((saved, Some(mapped)));
    }
    let check = if kind.can_check_token() {
        let result = check_token_with_base(http, kind, target, value, base_override).await;
        if result == ForgeTokenCheck::Rejected {
            return Err(ConnectorError::new(tr(
                "De codehost weigert dit token. Controleer of het de juiste rechten heeft en niet verlopen is.",
                "The code host rejected this token. Check that it has the right scopes and has not expired.",
            )));
        }
        Some(result)
    } else {
        None
    };
    let saved = save(store, secrets, target, value)?;
    Ok((saved, check))
}

// MARK: Token & Host Resolution

fn repo_authority(repo: &RemoteRepository) -> String {
    if let Ok(url) = url::Url::parse(&repo.web_origin) {
        if let Some(host) = url.host_str() {
            return match url.port() {
                Some(port) => format!("{}:{port}", host.to_ascii_lowercase()),
                None => host.to_ascii_lowercase(),
            };
        }
    }
    repo.host_name.clone()
}

/// Looks up the stored token for a non-GitHub repository, matching `host:port` first then bare `host`.
pub fn token_for_repo(secrets: &dyn SecretStore, repo: &RemoteRepository) -> Option<String> {
    let authority = repo_authority(repo);
    match repo.host {
        SourceControlHost::Github => None,
        SourceControlHost::Gitlab => gitlab::token(secrets, &authority).or_else(|| gitlab::token(secrets, &repo.host_name)),
        SourceControlHost::Gitea
        | SourceControlHost::Forgejo
        | SourceControlHost::Gitcafe
        | SourceControlHost::Bitbucket
        | SourceControlHost::AzureDevOps
        | SourceControlHost::Unknown(_) => token(secrets, &authority).or_else(|| token(secrets, &repo.host_name)),
    }
}

/// Whether Nook can directly create a pull / merge request on this non-GitHub repository using its API.
pub fn can_create_pull_request(secrets: &dyn SecretStore, repo: &RemoteRepository) -> bool {
    if !repo.web_origin.starts_with("https://") {
        return false;
    }
    let Some(_) = token_for_repo(secrets, repo) else {
        return false;
    };
    match repo.host {
        SourceControlHost::Gitlab => true,
        SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Unknown(_) => repo.segments().len() == 2,
        SourceControlHost::Bitbucket => repo.host_name == "bitbucket.org" && repo.segments().len() == 2,
        SourceControlHost::AzureDevOps => repo.host_name == "dev.azure.com" && azure_location(&repo.path).is_some(),
        SourceControlHost::Github | SourceControlHost::Gitcafe => false,
    }
}

/// Whether Nook can query branch pull requests for this non-GitHub repository.
pub fn can_query_branch(secrets: &dyn SecretStore, repo: &RemoteRepository) -> bool {
    if !repo.web_origin.starts_with("https://") {
        return false;
    }
    let Some(_) = token_for_repo(secrets, repo) else {
        return false;
    };
    match repo.host {
        SourceControlHost::Gitlab => true,
        SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Unknown(_) => repo.segments().len() == 2,
        SourceControlHost::Gitcafe => GITCAFE_HOSTS.contains(&repo.host_name.as_str()) && repo.segments().len() == 2,
        SourceControlHost::Bitbucket => repo.host_name == "bitbucket.org" && repo.segments().len() == 2,
        SourceControlHost::AzureDevOps => repo.host_name == "dev.azure.com" && azure_location(&repo.path).is_some(),
        SourceControlHost::Github => false,
    }
}

// MARK: Branch Pull Requests & Creation

/// One pull / merge request discovered for a git branch on a forge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchPr {
    pub number: i64,
    pub url: String,
    pub title: String,
    /// `"open"`, `"draft"`, `"merged"`, or `"closed"`.
    pub state: String,
    pub head_branch: String,
    pub base_branch: String,
}

impl BranchPr {
    pub fn is_open(&self) -> bool {
        matches!(self.state.as_str(), "open" | "draft")
    }
}

/// Summary of pull / merge requests for one branch.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BranchPrSummary {
    pub open: Option<BranchPr>,
    pub landed: bool,
    pub all: Vec<BranchPr>,
}

impl BranchPrSummary {
    fn from_list(all: Vec<BranchPr>) -> Self {
        let open = all.iter().find(|pr| pr.is_open()).cloned();
        let landed = open.is_none() && !all.is_empty();
        Self { open, landed, all }
    }
}

/// Lists pull / merge requests for `branch` on a non-GitHub forge. Returns `None` if no token is saved or the forge could not be reached.
pub async fn branch_pull_requests(
    http: &Http,
    secrets: &dyn SecretStore,
    repo: &RemoteRepository,
    branch: &str,
) -> Option<BranchPrSummary> {
    if !can_query_branch(secrets, repo) {
        return None;
    }
    let tok = token_for_repo(secrets, repo)?;
    branch_pull_requests_with_base(http, repo, &tok, branch, None).await.ok()
}

async fn branch_pull_requests_with_base(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    branch: &str,
    base_override: Option<&str>,
) -> Result<BranchPrSummary, String> {
    match repo.host {
        SourceControlHost::Gitlab => gitlab_branch_mrs(http, repo, tok, branch, base_override).await,
        SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Unknown(_) => {
            gitea_branch_prs(http, repo, tok, branch, base_override).await
        }
        SourceControlHost::Gitcafe => gitcafe_branch_prs(http, repo, tok, branch, base_override).await,
        SourceControlHost::Bitbucket => bitbucket_branch_prs(http, repo, tok, branch, base_override).await,
        SourceControlHost::AzureDevOps => azure_branch_prs(http, repo, tok, branch, base_override).await,
        SourceControlHost::Github => Err("Use GitHub connector for GitHub repositories.".into()),
    }
}

/// Creates a pull / merge request on GitLab, Gitea / Forgejo / Codeberg, Bitbucket Cloud, or Azure DevOps.
#[allow(clippy::too_many_arguments)]
pub async fn create_pull_request(
    http: &Http,
    secrets: &dyn SecretStore,
    repo: &RemoteRepository,
    title: &str,
    body: &str,
    head: &str,
    base: &str,
    draft: bool,
) -> Result<String, String> {
    if !repo.web_origin.starts_with("https://") {
        return Err(format!("Nook only sends tokens over https (cannot send to {}).", repo.web_origin));
    }
    let tok = token_for_repo(secrets, repo)
        .ok_or_else(|| format!("No token is stored for {} (Settings › Pull requests › Code hosts).", repo.host_name))?;
    create_pull_request_with_base(http, repo, &tok, title, body, head, base, draft, None).await
}

#[allow(clippy::too_many_arguments)]
async fn create_pull_request_with_base(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    title: &str,
    body: &str,
    head: &str,
    base: &str,
    draft: bool,
    base_override: Option<&str>,
) -> Result<String, String> {
    match repo.host {
        SourceControlHost::Gitlab => gitlab_create_mr(http, repo, tok, title, body, head, base, draft, base_override).await,
        SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Unknown(_) => {
            gitea_create_pr(http, repo, tok, title, body, head, base, draft, base_override).await
        }
        SourceControlHost::Bitbucket => bitbucket_create_pr(http, repo, tok, title, body, head, base, draft, base_override).await,
        SourceControlHost::AzureDevOps => azure_create_pr(http, repo, tok, title, body, head, base, draft, base_override).await,
        SourceControlHost::Github | SourceControlHost::Gitcafe => {
            Err(format!("Nook cannot open a request directly on {}.", repo.host_name))
        }
    }
}

// MARK: Pull Request Snapshot (for `get_pull_request_status` & `watch_pull_request`)

/// Fetches a normalized [`PullRequestSnapshot`] from any non-GitHub forge.
pub async fn fetch_snapshot(http: &Http, secrets: &dyn SecretStore, reference: &PullRequestRef) -> Result<PullRequestSnapshot, String> {
    fetch_snapshot_with_base(http, secrets, reference, None).await
}

async fn fetch_snapshot_with_base(
    http: &Http,
    secrets: &dyn SecretStore,
    reference: &PullRequestRef,
    base_override: Option<&str>,
) -> Result<PullRequestSnapshot, String> {
    match &reference.host {
        PrHost::Github => Err("Use GitHub connector for GitHub pull requests.".into()),
        PrHost::GitLab(host) => {
            let tok = gitlab::token(secrets, host)
                .ok_or_else(|| format!("No GitLab token is connected for {host} (Settings › Pull requests › Code hosts)."))?;
            gitlab_snapshot(http, host, &tok, reference, base_override).await
        }
        PrHost::Gitea(host) => {
            let tok =
                token(secrets, host).ok_or_else(|| format!("No token is connected for {host} (Settings › Pull requests › Code hosts)."))?;
            gitea_snapshot(http, host, &tok, reference, base_override).await
        }
        PrHost::GitCafe(host) => {
            if !GITCAFE_HOSTS.contains(&host.as_str()) {
                return Err(format!("Unsupported GitCafe host {host}."));
            }
            let tok = token(secrets, host)
                .ok_or_else(|| format!("No GitCafe token is connected for {host} (Settings › Pull requests › Code hosts)."))?;
            gitcafe_snapshot(http, host, &tok, reference, base_override).await
        }
        PrHost::Bitbucket(host) => {
            if host != "bitbucket.org" {
                return Err(format!("Unsupported Bitbucket host {host}."));
            }
            let tok = token(secrets, host)
                .ok_or_else(|| "No Bitbucket token is connected (Settings › Pull requests › Code hosts).".to_string())?;
            bitbucket_snapshot(http, &tok, reference, base_override).await
        }
        PrHost::AzureDevOps(host) => {
            if host != "dev.azure.com" {
                return Err(format!("Unsupported Azure DevOps host {host}."));
            }
            let tok = token(secrets, host)
                .ok_or_else(|| "No Azure DevOps token is connected (Settings › Pull requests › Code hosts).".to_string())?;
            azure_snapshot(http, &tok, reference, base_override).await
        }
    }
}

// MARK: GitLab

fn gitlab_project_id(path: &str) -> String {
    encode_segment(path)
}

fn gitlab_state(item: &Value) -> &'static str {
    match item["state"].as_str().unwrap_or("").to_ascii_lowercase().as_str() {
        "merged" => "merged",
        "closed" | "locked" => "closed",
        _ => {
            if item["draft"].as_bool() == Some(true) || item["work_in_progress"].as_bool() == Some(true) {
                "draft"
            } else {
                "open"
            }
        }
    }
}

async fn gitlab_branch_mrs(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    branch: &str,
    base_override: Option<&str>,
) -> Result<BranchPrSummary, String> {
    let base = base_override.map(str::to_string).unwrap_or_else(|| format!("{}/api/v4", repo.web_origin));
    let url = format!(
        "{base}/projects/{}/merge_requests?source_branch={}&state=all&per_page=10&order_by=updated_at",
        gitlab_project_id(&repo.path),
        encode_segment(branch)
    );
    let headers = [("PRIVATE-TOKEN", tok.to_string())];
    let val = send_json(http, "GET", &url, &headers, None, "GitLab").await?;
    let list = val.as_array().ok_or_else(|| "GitLab returned an unexpected merge request list.".to_string())?;
    let mut items = Vec::new();
    for item in list {
        let Some(number) = item["iid"].as_i64() else { continue };
        let web_url = item["web_url"].as_str().map(str::to_string).or_else(|| repo.pull_request_url(number as u64)).unwrap_or_default();
        items.push(BranchPr {
            number,
            url: web_url,
            title: item["title"].as_str().unwrap_or("").to_string(),
            state: gitlab_state(item).to_string(),
            head_branch: item["source_branch"].as_str().unwrap_or(branch).to_string(),
            base_branch: item["target_branch"].as_str().unwrap_or("").to_string(),
        });
    }
    Ok(BranchPrSummary::from_list(items))
}

#[allow(clippy::too_many_arguments)]
async fn gitlab_create_mr(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    title: &str,
    body: &str,
    head: &str,
    base_branch: &str,
    draft: bool,
    base_override: Option<&str>,
) -> Result<String, String> {
    let api = base_override.map(str::to_string).unwrap_or_else(|| format!("{}/api/v4", repo.web_origin));
    let url = format!("{api}/projects/{}/merge_requests", gitlab_project_id(&repo.path));
    let clean_title = title.trim();
    let final_title = if draft && !clean_title.to_ascii_lowercase().starts_with("draft:") {
        format!("Draft: {clean_title}")
    } else {
        clean_title.to_string()
    };
    let payload = json!({
        "title": final_title,
        "description": body,
        "source_branch": head,
        "target_branch": base_branch,
        "remove_source_branch": false,
    });
    let headers = [("PRIVATE-TOKEN", tok.to_string())];
    let obj = send_json(http, "POST", &url, &headers, Some(&payload), "GitLab").await?;
    obj["web_url"].as_str().map(str::to_string).ok_or_else(|| "GitLab created the merge request without returning its URL.".to_string())
}

async fn gitlab_snapshot(
    http: &Http,
    host: &str,
    tok: &str,
    reference: &PullRequestRef,
    base_override: Option<&str>,
) -> Result<PullRequestSnapshot, String> {
    let api = base_override.map(str::to_string).unwrap_or_else(|| format!("https://{host}/api/v4"));
    let project = gitlab_project_id(&reference.repo);
    let base = format!("{api}/projects/{project}/merge_requests/{}", reference.number);
    let headers = [("PRIVATE-TOKEN", tok.to_string())];
    let mr = send_json(http, "GET", &base, &headers, None, "GitLab").await?;
    let notes =
        send_json(http, "GET", &format!("{base}/notes?per_page=100&sort=asc"), &headers, None, "GitLab").await.unwrap_or(Value::Null);
    let approvals = send_json(http, "GET", &format!("{base}/approvals"), &headers, None, "GitLab").await.ok();

    let state = gitlab_state(&mr).to_string();
    let conflicted = mr["has_conflicts"].as_bool().unwrap_or(false);
    let merge_state = mr["detailed_merge_status"].as_str().or_else(|| mr["merge_status"].as_str()).unwrap_or("unknown").to_string();

    let mut checks = Vec::new();
    if let Some(pipeline) = mr.get("head_pipeline").filter(|v| v.is_object()) {
        let p_status = pipeline["status"].as_str().unwrap_or("unknown");
        let outcome = match p_status {
            "success" => "passing",
            "failed" | "canceled" => "failing",
            "skipped" | "manual" => "skipped",
            _ => "pending",
        };
        if p_status == "failed" {
            if let Some(pid) = pipeline["id"].as_i64() {
                let jobs_url = format!("{api}/projects/{project}/pipelines/{pid}/jobs?scope%5B%5D=failed&per_page=50");
                if let Ok(jobs) = send_json(http, "GET", &jobs_url, &headers, None, "GitLab").await {
                    if let Some(arr) = jobs.as_array() {
                        for job in arr {
                            if let Some(name) = job["name"].as_str() {
                                checks.push(PrCheckSummary {
                                    name: name.to_string(),
                                    outcome: "failing".into(),
                                    detail: job["stage"].as_str().unwrap_or("failed").to_string(),
                                });
                            }
                        }
                    }
                }
            }
        }
        if checks.is_empty() {
            checks.push(PrCheckSummary { name: "GitLab pipeline".into(), outcome: outcome.into(), detail: p_status.into() });
        }
    }

    let mut reviews = Vec::new();
    if let Some(approved_by) = approvals.as_ref().and_then(|a| a["approved_by"].as_array()) {
        for entry in approved_by {
            let user = entry.get("user").unwrap_or(entry);
            let author = user["username"].as_str().or_else(|| user["name"].as_str()).unwrap_or("?").to_string();
            reviews.push(PrReviewSummary { id: format!("gl-approval-{author}"), author, state: "APPROVED".into(), body: String::new() });
        }
    }

    let mut comment_ids = Vec::new();
    if let Some(arr) = notes.as_array() {
        for note in arr {
            if note["system"].as_bool().unwrap_or(false) {
                continue;
            }
            if let Some(id) = note["id"].as_i64() {
                comment_ids.push(format!("gl-note-{id}"));
            }
        }
    }

    Ok(PullRequestSnapshot {
        repo: reference.repo.clone(),
        number: reference.number,
        title: mr["title"].as_str().unwrap_or("Untitled").to_string(),
        url: mr["web_url"].as_str().map(str::to_string).unwrap_or_else(|| reference.url.clone()),
        state,
        head_branch: mr["source_branch"].as_str().unwrap_or("").to_string(),
        base_branch: mr["target_branch"].as_str().unwrap_or("").to_string(),
        head_sha: mr["sha"].as_str().or_else(|| mr["diff_refs"]["head_sha"].as_str()).unwrap_or("").to_string(),
        conflicted,
        merge_state,
        checks,
        reviews,
        comment_ids,
    })
}

// MARK: Gitea / Forgejo / Codeberg

fn gitea_repo_path(path: &str) -> Result<String, String> {
    let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if parts.len() != 2 {
        return Err(format!("Expected owner/repo path, got \"{path}\"."));
    }
    Ok(format!("/repos/{}/{}", encode_segment(parts[0]), encode_segment(parts[1])))
}

fn gitea_state(item: &Value) -> &'static str {
    if item["merged"].as_bool() == Some(true) || item["merged_at"].as_str().is_some_and(|s| !s.is_empty()) {
        return "merged";
    }
    if item["state"].as_str().map(|s| s.eq_ignore_ascii_case("closed")).unwrap_or(false) {
        return "closed";
    }
    let title = item["title"].as_str().unwrap_or("").trim().to_ascii_lowercase();
    if item["draft"].as_bool() == Some(true) || title.starts_with("wip:") || title.starts_with("draft:") {
        return "draft";
    }
    "open"
}

async fn gitea_branch_prs(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    branch: &str,
    base_override: Option<&str>,
) -> Result<BranchPrSummary, String> {
    let api = base_override.map(str::to_string).unwrap_or_else(|| format!("{}/api/v1", repo.web_origin));
    let repo_path = gitea_repo_path(&repo.path)?;
    let headers = [("Authorization", format!("token {tok}")), ("Accept", "application/json".into())];
    let mut items = Vec::new();
    for page in 1..=3 {
        let url = format!("{api}{repo_path}/pulls?state=all&sort=recentupdate&limit=50&page={page}");
        let val = send_json(http, "GET", &url, &headers, None, &repo.host.name()).await?;
        let Some(list) = val.as_array() else { break };
        for item in list {
            let head_ref = item["head"]["ref"].as_str().unwrap_or("");
            if head_ref != branch {
                continue;
            }
            let Some(number) = item["number"].as_i64() else { continue };
            let web_url =
                item["html_url"].as_str().map(str::to_string).or_else(|| repo.pull_request_url(number as u64)).unwrap_or_default();
            items.push(BranchPr {
                number,
                url: web_url,
                title: item["title"].as_str().unwrap_or("").to_string(),
                state: gitea_state(item).to_string(),
                head_branch: head_ref.to_string(),
                base_branch: item["base"]["ref"].as_str().unwrap_or("").to_string(),
            });
        }
        if list.len() < 50 {
            break;
        }
    }
    Ok(BranchPrSummary::from_list(items))
}

#[allow(clippy::too_many_arguments)]
async fn gitea_create_pr(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    title: &str,
    body: &str,
    head: &str,
    base_branch: &str,
    draft: bool,
    base_override: Option<&str>,
) -> Result<String, String> {
    let api = base_override.map(str::to_string).unwrap_or_else(|| format!("{}/api/v1", repo.web_origin));
    let repo_path = gitea_repo_path(&repo.path)?;
    let url = format!("{api}{repo_path}/pulls");
    let clean_title = title.trim();
    let lower = clean_title.to_ascii_lowercase();
    let final_title = if draft && !lower.starts_with("wip:") && !lower.starts_with("draft:") {
        format!("WIP: {clean_title}")
    } else {
        clean_title.to_string()
    };
    let payload = json!({
        "title": final_title,
        "body": body,
        "head": head,
        "base": base_branch,
    });
    let headers = [("Authorization", format!("token {tok}")), ("Accept", "application/json".into())];
    let obj = send_json(http, "POST", &url, &headers, Some(&payload), &repo.host.name()).await?;
    obj["html_url"]
        .as_str()
        .or_else(|| obj["url"].as_str())
        .map(str::to_string)
        .ok_or_else(|| format!("{} created the pull request without returning its URL.", repo.host.name()))
}

async fn gitea_snapshot(
    http: &Http,
    host: &str,
    tok: &str,
    reference: &PullRequestRef,
    base_override: Option<&str>,
) -> Result<PullRequestSnapshot, String> {
    let api = base_override.map(str::to_string).unwrap_or_else(|| format!("https://{host}/api/v1"));
    let repo_path = gitea_repo_path(&reference.repo)?;
    let headers = [("Authorization", format!("token {tok}")), ("Accept", "application/json".into())];
    let pr_url = format!("{api}{repo_path}/pulls/{}", reference.number);
    let pr = send_json(http, "GET", &pr_url, &headers, None, "Gitea").await?;

    let head_sha = pr["head"]["sha"].as_str().unwrap_or("").to_string();
    let mut checks = Vec::new();
    if !head_sha.is_empty() {
        let status_url = format!("{api}{repo_path}/commits/{}/status", encode_segment(&head_sha));
        if let Ok(combined) = send_json(http, "GET", &status_url, &headers, None, "Gitea").await {
            if let Some(statuses) = combined["statuses"].as_array() {
                for st in statuses {
                    let name = st["context"].as_str().filter(|s| !s.is_empty()).unwrap_or("status").to_string();
                    let raw = st["status"].as_str().or_else(|| st["state"].as_str()).unwrap_or("pending");
                    let outcome = match raw {
                        "success" => "passing",
                        "failure" | "error" => "failing",
                        _ => "pending",
                    };
                    checks.push(PrCheckSummary {
                        name,
                        outcome: outcome.into(),
                        detail: st["description"].as_str().unwrap_or(raw).to_string(),
                    });
                }
            }
        }
    }

    let mut reviews = Vec::new();
    if let Ok(rev_val) = send_json(http, "GET", &format!("{pr_url}/reviews?limit=50"), &headers, None, "Gitea").await {
        if let Some(arr) = rev_val.as_array() {
            for r in arr {
                let state = r["state"].as_str().unwrap_or("");
                if state.is_empty() || state.eq_ignore_ascii_case("PENDING") {
                    continue;
                }
                let id = r["id"].as_i64().map(|i| format!("gitea-rev-{i}")).unwrap_or_else(|| format!("gitea-rev-{state}"));
                let author = r["user"]["login"].as_str().or_else(|| r["user"]["username"].as_str()).unwrap_or("?").to_string();
                let normalized_state = match state.to_ascii_uppercase().as_str() {
                    "APPROVED" => "APPROVED",
                    "REQUEST_CHANGES" | "CHANGES_REQUESTED" => "CHANGES_REQUESTED",
                    _ => "COMMENTED",
                };
                reviews.push(PrReviewSummary {
                    id,
                    author,
                    state: normalized_state.into(),
                    body: r["body"].as_str().unwrap_or("").to_string(),
                });
            }
        }
    }

    let mut comment_ids = Vec::new();
    let comments_url = format!("{api}{repo_path}/issues/{}/comments?limit=50", reference.number);
    if let Ok(c_val) = send_json(http, "GET", &comments_url, &headers, None, "Gitea").await {
        if let Some(arr) = c_val.as_array() {
            for c in arr {
                if let Some(id) = c["id"].as_i64() {
                    comment_ids.push(format!("gitea-comment-{id}"));
                }
            }
        }
    }

    let mergeable = pr["mergeable"].as_bool();
    let conflicted = mergeable == Some(false);
    let merge_state = match mergeable {
        Some(true) => "clean",
        Some(false) => "dirty",
        None => "unknown",
    }
    .to_string();

    Ok(PullRequestSnapshot {
        repo: reference.repo.clone(),
        number: reference.number,
        title: pr["title"].as_str().unwrap_or("Untitled").to_string(),
        url: pr["html_url"].as_str().map(str::to_string).unwrap_or_else(|| reference.url.clone()),
        state: gitea_state(&pr).to_string(),
        head_branch: pr["head"]["ref"].as_str().unwrap_or("").to_string(),
        base_branch: pr["base"]["ref"].as_str().unwrap_or("").to_string(),
        head_sha,
        conflicted,
        merge_state,
        checks,
        reviews,
        comment_ids,
    })
}

// MARK: GitCafe

fn gitcafe_state(item: &Value) -> &'static str {
    match item["state"].as_str().unwrap_or("").to_ascii_lowercase().as_str() {
        "merged" => "merged",
        "closed" => "closed",
        _ => {
            if item["draft"].as_bool() == Some(true) || item["isDraft"].as_bool() == Some(true) {
                "draft"
            } else {
                "open"
            }
        }
    }
}

async fn gitcafe_branch_prs(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    branch: &str,
    base_override: Option<&str>,
) -> Result<BranchPrSummary, String> {
    let api = base_override.map(str::to_string).unwrap_or_else(|| format!("https://{}/api", repo.host_name));
    let repo_path = gitea_repo_path(&repo.path)?;
    let headers = [("Authorization", format!("Bearer {tok}")), ("Accept", "application/json".into())];
    let url = format!("{api}{repo_path}/pulls?sort=newest");
    let val = send_json(http, "GET", &url, &headers, None, "GitCafe").await?;
    let rows = val.as_array().or_else(|| val["items"].as_array()).map(Vec::as_slice).unwrap_or(&[]);
    let mut items = Vec::new();
    for item in rows {
        let head =
            item["headBranch"].as_str().or_else(|| item["sourceBranch"].as_str()).or_else(|| item["head"]["ref"].as_str()).unwrap_or("");
        if head != branch {
            continue;
        }
        let Some(number) = item["number"].as_i64() else { continue };
        let web_url = item["url"]
            .as_str()
            .or_else(|| item["htmlUrl"].as_str())
            .map(str::to_string)
            .or_else(|| repo.pull_request_url(number as u64))
            .unwrap_or_default();
        items.push(BranchPr {
            number,
            url: web_url,
            title: item["title"].as_str().unwrap_or("").to_string(),
            state: gitcafe_state(item).to_string(),
            head_branch: head.to_string(),
            base_branch: item["baseBranch"]
                .as_str()
                .or_else(|| item["targetBranch"].as_str())
                .or_else(|| item["base"]["ref"].as_str())
                .unwrap_or("")
                .to_string(),
        });
    }
    Ok(BranchPrSummary::from_list(items))
}

async fn gitcafe_snapshot(
    http: &Http,
    host: &str,
    tok: &str,
    reference: &PullRequestRef,
    base_override: Option<&str>,
) -> Result<PullRequestSnapshot, String> {
    let api = base_override.map(str::to_string).unwrap_or_else(|| format!("https://{host}/api"));
    let repo_path = gitea_repo_path(&reference.repo)?;
    let headers = [("Authorization", format!("Bearer {tok}")), ("Accept", "application/json".into())];
    let pr_url = format!("{api}{repo_path}/pulls/{}", reference.number);
    let pr = send_json(http, "GET", &pr_url, &headers, None, "GitCafe").await?;
    let status = send_json(http, "GET", &format!("{pr_url}/status"), &headers, None, "GitCafe").await.ok();
    let reviews_val = send_json(http, "GET", &format!("{pr_url}/reviews"), &headers, None, "GitCafe").await.ok();
    let comments_val = send_json(http, "GET", &format!("{pr_url}/comments"), &headers, None, "GitCafe").await.ok();

    let conflicted = status.as_ref().and_then(|s| s["hasConflicts"].as_bool().or_else(|| s["conflicted"].as_bool())).unwrap_or(false);
    let merge_state = status
        .as_ref()
        .and_then(|s| s["mergeState"].as_str().or_else(|| s["state"].as_str()))
        .unwrap_or(if conflicted { "dirty" } else { "unknown" })
        .to_string();

    let mut reviews = Vec::new();
    if let Some(arr) = reviews_val.as_ref().and_then(|v| v.as_array().or_else(|| v["items"].as_array())) {
        for (idx, r) in arr.iter().enumerate() {
            let author = r["author"]["login"].as_str().or_else(|| r["author"]["username"].as_str()).unwrap_or("?").to_string();
            let raw_state = r["verdict"].as_str().or_else(|| r["state"].as_str()).unwrap_or("COMMENTED");
            let state = match raw_state.to_ascii_uppercase().as_str() {
                "APPROVE" | "APPROVED" => "APPROVED",
                "REQUEST_CHANGES" | "CHANGES_REQUESTED" => "CHANGES_REQUESTED",
                _ => "COMMENTED",
            };
            let id = r["id"].as_str().map(str::to_string).unwrap_or_else(|| format!("gitcafe-rev-{idx}"));
            reviews.push(PrReviewSummary { id, author, state: state.into(), body: r["body"].as_str().unwrap_or("").to_string() });
        }
    }

    let mut comment_ids = Vec::new();
    if let Some(arr) = comments_val.as_ref().and_then(|v| v.as_array().or_else(|| v["items"].as_array())) {
        for (idx, c) in arr.iter().enumerate() {
            let id = c["id"]
                .as_str()
                .map(|s| format!("gitcafe-c-{s}"))
                .or_else(|| c["id"].as_i64().map(|n| format!("gitcafe-c-{n}")))
                .unwrap_or_else(|| format!("gitcafe-c-{idx}"));
            comment_ids.push(id);
        }
    }

    Ok(PullRequestSnapshot {
        repo: reference.repo.clone(),
        number: reference.number,
        title: pr["title"].as_str().unwrap_or("Untitled").to_string(),
        url: pr["url"].as_str().map(str::to_string).unwrap_or_else(|| reference.url.clone()),
        state: gitcafe_state(&pr).to_string(),
        head_branch: pr["headBranch"].as_str().or_else(|| pr["head"]["ref"].as_str()).unwrap_or("").to_string(),
        base_branch: pr["baseBranch"].as_str().or_else(|| pr["base"]["ref"].as_str()).unwrap_or("").to_string(),
        head_sha: pr["headOid"].as_str().or_else(|| pr["head"]["sha"].as_str()).unwrap_or("").to_string(),
        conflicted,
        merge_state,
        checks: vec![],
        reviews,
        comment_ids,
    })
}

// MARK: Bitbucket Cloud

fn bitbucket_repo_path(path: &str) -> Result<String, String> {
    let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if parts.len() != 2 {
        return Err(format!("Expected workspace/repo path for Bitbucket, got \"{path}\"."));
    }
    Ok(format!("/repositories/{}/{}", encode_segment(parts[0]), encode_segment(parts[1])))
}

fn bitbucket_state(item: &Value) -> &'static str {
    match item["state"].as_str().unwrap_or("").to_ascii_uppercase().as_str() {
        "MERGED" => "merged",
        "DECLINED" | "SUPERSEDED" => "closed",
        _ => {
            if item["draft"].as_bool() == Some(true) {
                "draft"
            } else {
                "open"
            }
        }
    }
}

async fn bitbucket_branch_prs(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    branch: &str,
    base_override: Option<&str>,
) -> Result<BranchPrSummary, String> {
    let api = base_override.unwrap_or(BITBUCKET_API);
    let repo_path = bitbucket_repo_path(&repo.path)?;
    let escaped = branch.replace('\\', "\\\\").replace('"', "\\\"");
    let query_val = encode_segment(&format!("source.branch.name=\"{escaped}\""));
    let url = format!("{api}{repo_path}/pullrequests?q={query_val}&state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&pagelen=50");
    let headers = [("Authorization", format!("Basic {}", basic_encode(tok))), ("Accept", "application/json".into())];
    let val = send_json(http, "GET", &url, &headers, None, "Bitbucket").await?;
    let list = val["values"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    let mut items = Vec::new();
    for item in list {
        let Some(number) = item["id"].as_i64() else { continue };
        let web_url =
            item["links"]["html"]["href"].as_str().map(str::to_string).or_else(|| repo.pull_request_url(number as u64)).unwrap_or_default();
        items.push(BranchPr {
            number,
            url: web_url,
            title: item["title"].as_str().unwrap_or("").to_string(),
            state: bitbucket_state(item).to_string(),
            head_branch: item["source"]["branch"]["name"].as_str().unwrap_or(branch).to_string(),
            base_branch: item["destination"]["branch"]["name"].as_str().unwrap_or("").to_string(),
        });
    }
    Ok(BranchPrSummary::from_list(items))
}

#[allow(clippy::too_many_arguments)]
async fn bitbucket_create_pr(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    title: &str,
    body: &str,
    head: &str,
    base_branch: &str,
    draft: bool,
    base_override: Option<&str>,
) -> Result<String, String> {
    let api = base_override.unwrap_or(BITBUCKET_API);
    let repo_path = bitbucket_repo_path(&repo.path)?;
    let url = format!("{api}{repo_path}/pullrequests");
    let payload = json!({
        "title": title.trim(),
        "description": body,
        "source": { "branch": { "name": head } },
        "destination": { "branch": { "name": base_branch } },
        "draft": draft,
    });
    let headers = [("Authorization", format!("Basic {}", basic_encode(tok))), ("Accept", "application/json".into())];
    let obj = send_json(http, "POST", &url, &headers, Some(&payload), "Bitbucket").await?;
    if let Some(link) = obj["links"]["html"]["href"].as_str() {
        return Ok(link.to_string());
    }
    if let Some(id) = obj["id"].as_i64() {
        if let Some(link) = repo.pull_request_url(id as u64) {
            return Ok(link);
        }
    }
    Err("Bitbucket created the pull request without returning its URL.".into())
}

async fn bitbucket_snapshot(
    http: &Http,
    tok: &str,
    reference: &PullRequestRef,
    base_override: Option<&str>,
) -> Result<PullRequestSnapshot, String> {
    let api = base_override.unwrap_or(BITBUCKET_API);
    let repo_path = bitbucket_repo_path(&reference.repo)?;
    let headers = [("Authorization", format!("Basic {}", basic_encode(tok))), ("Accept", "application/json".into())];
    let pr_url = format!("{api}{repo_path}/pullrequests/{}", reference.number);
    let pr = send_json(http, "GET", &pr_url, &headers, None, "Bitbucket").await?;

    let statuses_val = send_json(http, "GET", &format!("{pr_url}/statuses?pagelen=100"), &headers, None, "Bitbucket").await.ok();
    let comments_val = send_json(http, "GET", &format!("{pr_url}/comments?pagelen=100"), &headers, None, "Bitbucket").await.ok();
    let conflicts_val = send_json(http, "GET", &format!("{pr_url}/conflicts"), &headers, None, "Bitbucket").await.ok();

    let mut checks = Vec::new();
    if let Some(arr) = statuses_val.as_ref().and_then(|v| v["values"].as_array()) {
        for st in arr {
            let name = st["name"].as_str().or_else(|| st["key"].as_str()).unwrap_or("build").to_string();
            let raw = st["state"].as_str().unwrap_or("INPROGRESS");
            let outcome = match raw {
                "SUCCESSFUL" => "passing",
                "FAILED" | "STOPPED" => "failing",
                _ => "pending",
            };
            checks.push(PrCheckSummary { name, outcome: outcome.into(), detail: st["description"].as_str().unwrap_or(raw).to_string() });
        }
    }

    let mut reviews = Vec::new();
    if let Some(participants) = pr["participants"].as_array() {
        for p in participants {
            let state_raw = p["state"].as_str().unwrap_or("");
            let approved = p["approved"].as_bool() == Some(true) || state_raw.eq_ignore_ascii_case("approved");
            let changes = state_raw.eq_ignore_ascii_case("changes_requested");
            if !approved && !changes {
                continue;
            }
            let user = &p["user"];
            let author = user["nickname"]
                .as_str()
                .or_else(|| user["display_name"].as_str())
                .or_else(|| user["username"].as_str())
                .unwrap_or("?")
                .to_string();
            reviews.push(PrReviewSummary {
                id: format!("bb-part-{author}"),
                author,
                state: if changes { "CHANGES_REQUESTED" } else { "APPROVED" }.into(),
                body: String::new(),
            });
        }
    }

    let mut comment_ids = Vec::new();
    if let Some(arr) = comments_val.as_ref().and_then(|v| v["values"].as_array()) {
        for c in arr {
            if c["deleted"].as_bool() == Some(true) {
                continue;
            }
            if let Some(id) = c["id"].as_i64() {
                comment_ids.push(format!("bb-comment-{id}"));
            }
        }
    }

    let conflicted =
        conflicts_val.as_ref().and_then(|v| v.as_array().or_else(|| v["values"].as_array())).is_some_and(|arr| !arr.is_empty());

    Ok(PullRequestSnapshot {
        repo: reference.repo.clone(),
        number: reference.number,
        title: pr["title"].as_str().unwrap_or("Untitled").to_string(),
        url: pr["links"]["html"]["href"].as_str().map(str::to_string).unwrap_or_else(|| reference.url.clone()),
        state: bitbucket_state(&pr).to_string(),
        head_branch: pr["source"]["branch"]["name"].as_str().unwrap_or("").to_string(),
        base_branch: pr["destination"]["branch"]["name"].as_str().unwrap_or("").to_string(),
        head_sha: pr["source"]["commit"]["hash"].as_str().unwrap_or("").to_string(),
        conflicted,
        merge_state: if conflicted { "dirty" } else { "clean" }.to_string(),
        checks,
        reviews,
        comment_ids,
    })
}

// MARK: Azure DevOps

#[derive(Debug, Clone, PartialEq, Eq)]
struct AzureLocation<'a> {
    organization: &'a str,
    project: &'a str,
    repository: &'a str,
}

fn azure_location(path: &str) -> Option<AzureLocation<'_>> {
    let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if parts.len() == 4 && parts[2] == "_git" {
        Some(AzureLocation { organization: parts[0], project: parts[1], repository: parts[3] })
    } else if parts.len() == 3 {
        Some(AzureLocation { organization: parts[0], project: parts[1], repository: parts[2] })
    } else {
        None
    }
}

/// Azure DevOps PATs use HTTP Basic auth where an empty username (`:token`) is valid.
/// If the user pasted a bare token without a colon, prefix `:` automatically.
fn azure_credential(token: &str) -> String {
    let clean_token = clean(token);
    let raw = if clean_token.contains(':') { clean_token } else { format!(":{clean_token}") };
    basic_encode(&raw)
}

fn azure_repo_api_base(loc: &AzureLocation<'_>, base_override: Option<&str>) -> String {
    if let Some(override_base) = base_override {
        return override_base.to_string();
    }
    format!(
        "https://dev.azure.com/{}/{}/_apis/git/repositories/{}",
        encode_segment(loc.organization),
        encode_segment(loc.project),
        encode_segment(loc.repository),
    )
}

fn azure_state(item: &Value) -> &'static str {
    match item["status"].as_str().unwrap_or("").to_ascii_lowercase().as_str() {
        "completed" => "merged",
        "abandoned" => "closed",
        _ => {
            if item["isDraft"].as_bool() == Some(true) {
                "draft"
            } else {
                "open"
            }
        }
    }
}

fn strip_heads_ref(r: &str) -> String {
    r.strip_prefix("refs/heads/").unwrap_or(r).to_string()
}

async fn azure_branch_prs(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    branch: &str,
    base_override: Option<&str>,
) -> Result<BranchPrSummary, String> {
    let loc = azure_location(&repo.path).ok_or_else(|| format!("Invalid Azure DevOps repository path \"{}\".", repo.path))?;
    let api = azure_repo_api_base(&loc, base_override);
    let source_ref = encode_segment(&format!("refs/heads/{branch}"));
    let url = format!("{api}/pullrequests?searchCriteria.sourceRefName={source_ref}&searchCriteria.status=all&{AZURE_API_VERSION}");
    let headers = [("Authorization", format!("Basic {}", azure_credential(tok))), ("Accept", "application/json".into())];
    let val = send_json(http, "GET", &url, &headers, None, "Azure DevOps").await?;
    let list = val["value"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    let mut items = Vec::new();
    for item in list {
        let Some(number) = item["pullRequestId"].as_i64() else { continue };
        let web_url = format!(
            "https://dev.azure.com/{}/{}/_git/{}/pullrequest/{number}",
            encode_segment(loc.organization),
            encode_segment(loc.project),
            encode_segment(loc.repository),
        );
        items.push(BranchPr {
            number,
            url: web_url,
            title: item["title"].as_str().unwrap_or("").to_string(),
            state: azure_state(item).to_string(),
            head_branch: item["sourceRefName"].as_str().map(strip_heads_ref).unwrap_or_else(|| branch.to_string()),
            base_branch: item["targetRefName"].as_str().map(strip_heads_ref).unwrap_or_default(),
        });
    }
    Ok(BranchPrSummary::from_list(items))
}

#[allow(clippy::too_many_arguments)]
async fn azure_create_pr(
    http: &Http,
    repo: &RemoteRepository,
    tok: &str,
    title: &str,
    body: &str,
    head: &str,
    base_branch: &str,
    draft: bool,
    base_override: Option<&str>,
) -> Result<String, String> {
    let loc = azure_location(&repo.path).ok_or_else(|| format!("Invalid Azure DevOps repository path \"{}\".", repo.path))?;
    let api = azure_repo_api_base(&loc, base_override);
    let url = format!("{api}/pullrequests?{AZURE_API_VERSION}");
    let payload = json!({
        "sourceRefName": format!("refs/heads/{head}"),
        "targetRefName": format!("refs/heads/{base_branch}"),
        "title": title.trim(),
        "description": body,
        "isDraft": draft,
    });
    let headers = [("Authorization", format!("Basic {}", azure_credential(tok))), ("Accept", "application/json".into())];
    let obj = send_json(http, "POST", &url, &headers, Some(&payload), "Azure DevOps").await?;
    let number =
        obj["pullRequestId"].as_i64().ok_or_else(|| "Azure DevOps created the pull request without returning its id.".to_string())?;
    Ok(format!(
        "https://dev.azure.com/{}/{}/_git/{}/pullrequest/{number}",
        encode_segment(loc.organization),
        encode_segment(loc.project),
        encode_segment(loc.repository),
    ))
}

async fn azure_snapshot(
    http: &Http,
    tok: &str,
    reference: &PullRequestRef,
    base_override: Option<&str>,
) -> Result<PullRequestSnapshot, String> {
    let loc = azure_location(&reference.repo).ok_or_else(|| format!("Invalid Azure DevOps repository path \"{}\".", reference.repo))?;
    let api = azure_repo_api_base(&loc, base_override);
    let headers = [("Authorization", format!("Basic {}", azure_credential(tok))), ("Accept", "application/json".into())];
    let pr_url = format!("{api}/pullrequests/{}?{AZURE_API_VERSION}", reference.number);
    let pr = send_json(http, "GET", &pr_url, &headers, None, "Azure DevOps").await?;

    let statuses_url = format!("{api}/pullrequests/{}/statuses?{AZURE_API_VERSION}", reference.number);
    let threads_url = format!("{api}/pullrequests/{}/threads?{AZURE_API_VERSION}", reference.number);
    let statuses_val = send_json(http, "GET", &statuses_url, &headers, None, "Azure DevOps").await.ok();
    let threads_val = send_json(http, "GET", &threads_url, &headers, None, "Azure DevOps").await.ok();

    let mut checks = Vec::new();
    if let Some(arr) = statuses_val.as_ref().and_then(|v| v["value"].as_array()) {
        for st in arr {
            let ctx = &st["context"];
            let name = ctx["name"].as_str().or_else(|| ctx["genre"].as_str()).unwrap_or("status").to_string();
            let raw = st["state"].as_str().unwrap_or("pending");
            let outcome = match raw.to_ascii_lowercase().as_str() {
                "succeeded" => "passing",
                "failed" | "error" => "failing",
                "notapplicable" => "skipped",
                _ => "pending",
            };
            checks.push(PrCheckSummary { name, outcome: outcome.into(), detail: st["description"].as_str().unwrap_or(raw).to_string() });
        }
    }

    let mut reviews = Vec::new();
    if let Some(reviewers) = pr["reviewers"].as_array() {
        for rev in reviewers {
            let vote = rev["vote"].as_i64().unwrap_or(0);
            let state = match vote {
                10 | 5 => "APPROVED",
                -10 | -5 => "CHANGES_REQUESTED",
                _ => continue,
            };
            let author = rev["displayName"].as_str().or_else(|| rev["uniqueName"].as_str()).unwrap_or("?").to_string();
            let id = rev["id"].as_str().map(|s| format!("az-rev-{s}")).unwrap_or_else(|| format!("az-rev-{author}"));
            reviews.push(PrReviewSummary { id, author, state: state.into(), body: String::new() });
        }
    }

    let mut comment_ids = Vec::new();
    if let Some(threads) = threads_val.as_ref().and_then(|v| v["value"].as_array()) {
        for thread in threads {
            if thread["isDeleted"].as_bool() == Some(true) {
                continue;
            }
            let tid = thread["id"].as_i64().unwrap_or(0);
            if let Some(comments) = thread["comments"].as_array() {
                for c in comments {
                    if c["isDeleted"].as_bool() == Some(true) {
                        continue;
                    }
                    let ctype = c["commentType"].as_str().unwrap_or("text");
                    if ctype.eq_ignore_ascii_case("system") {
                        continue;
                    }
                    if let Some(cid) = c["id"].as_i64() {
                        comment_ids.push(format!("az-t{tid}-c{cid}"));
                    }
                }
            }
        }
    }

    let merge_status = pr["mergeStatus"].as_str().unwrap_or("unknown");
    let conflicted = merge_status.eq_ignore_ascii_case("conflicts");
    let head_sha = pr["lastMergeSourceCommit"]["commitId"].as_str().unwrap_or("").to_string();

    Ok(PullRequestSnapshot {
        repo: reference.repo.clone(),
        number: reference.number,
        title: pr["title"].as_str().unwrap_or("Untitled").to_string(),
        url: reference.url.clone(),
        state: azure_state(&pr).to_string(),
        head_branch: pr["sourceRefName"].as_str().map(strip_heads_ref).unwrap_or_default(),
        base_branch: pr["targetRefName"].as_str().map(strip_heads_ref).unwrap_or_default(),
        head_sha,
        conflicted,
        merge_state: merge_status.to_ascii_lowercase(),
        checks,
        reviews,
        comment_ids,
    })
}

// MARK: Helpers

fn encode_segment(s: &str) -> String {
    utf8_percent_encode(s, NON_ALPHANUMERIC).to_string()
}

fn basic_encode(raw: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(raw.as_bytes())
}

async fn send_json(
    http: &Http,
    method: &str,
    url: &str,
    headers: &[(&str, String)],
    body: Option<&Value>,
    forge_name: &str,
) -> Result<Value, String> {
    let (status, bytes) = http.send(method, url, headers, body, forge_name).await.map_err(|e| e.message)?;
    if !(200..300).contains(&status) {
        return Err(refusal_message(forge_name, status, &bytes));
    }
    if bytes.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_slice(&bytes).map_err(|_| format!("{forge_name} sent a response Nook could not read."))
}

/// Extracts a human-readable refusal message from a forge error body, matching `ForgeHTTP.refusal` / `GitLabAPI.errorMessage`.
pub fn refusal_message(forge_name: &str, status: u16, body: &[u8]) -> String {
    let obj = serde_json::from_slice::<Value>(body).ok();
    let detail = obj.as_ref().and_then(|v| {
        if let Some(msg) = v.get("error").and_then(|e| e.get("message")).and_then(Value::as_str) {
            return Some(msg.to_string());
        }
        if let Some(msg) = v.get("message").and_then(Value::as_str) {
            return Some(msg.to_string());
        }
        if let Some(fields) = v.get("message").and_then(Value::as_object) {
            let mut parts: Vec<String> = fields
                .iter()
                .map(|(k, val)| {
                    let text = val
                        .as_array()
                        .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "))
                        .unwrap_or_else(|| val.to_string());
                    format!("{k} {text}")
                })
                .collect();
            parts.sort();
            if !parts.is_empty() {
                return Some(parts.join("; "));
            }
        }
        if let Some(err) = v.get("error").and_then(Value::as_str) {
            return Some(err.to_string());
        }
        None
    });
    match detail.filter(|d| !d.trim().is_empty()) {
        Some(msg) => format!("{forge_name} refused this ({status}). {msg}"),
        None => format!("{forge_name} refused this ({status})."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;
    use crate::secrets::MemorySecrets;

    fn repo(url: &str) -> RemoteRepository {
        RemoteRepository::detect(url).unwrap_or_else(|| panic!("failed to detect {url}"))
    }

    #[test]
    fn code_host_kind_classification_and_credentials() {
        assert_eq!(CodeHostKind::from_host("gitlab.com"), CodeHostKind::Gitlab);
        assert_eq!(CodeHostKind::from_host("codeberg.org"), CodeHostKind::Gitea);
        assert_eq!(CodeHostKind::from_host("git.example.com"), CodeHostKind::Gitea);
        assert_eq!(CodeHostKind::from_host("git.cafe"), CodeHostKind::Gitcafe);
        assert_eq!(CodeHostKind::from_host("bitbucket.org"), CodeHostKind::Bitbucket);
        assert_eq!(CodeHostKind::from_host("dev.azure.com"), CodeHostKind::AzureDevOps);

        let store = ConnectorStore::in_memory();
        let secrets = MemorySecrets::default();
        assert!(save(&store, &secrets, "codeberg.org", "  ").is_err());
        assert_eq!(save(&store, &secrets, "https://Codeberg.org/org/repo", "tok-123").unwrap(), "codeberg.org");
        assert_eq!(secrets.read("forge.token.codeberg.org").as_deref(), Some("tok-123"));
        assert_eq!(hosts(&store, &secrets), ["codeberg.org"]);
        assert!(can_create_pull_request(&secrets, &repo("https://codeberg.org/acme/app.git")));
        remove(&store, &secrets, "codeberg.org");
        assert!(hosts(&store, &secrets).is_empty());
        assert!(!can_create_pull_request(&secrets, &repo("https://codeberg.org/acme/app.git")));
    }

    #[test]
    fn token_check_response_parsing() {
        assert_eq!(ForgeTokenCheck::from_response(200, br#"{"login":"alice"}"#), ForgeTokenCheck::Valid { account: Some("alice".into()) });
        assert_eq!(
            ForgeTokenCheck::from_response(200, br#"{"display_name":"Bob"}"#),
            ForgeTokenCheck::Valid { account: Some("Bob".into()) }
        );
        assert_eq!(ForgeTokenCheck::from_response(403, b""), ForgeTokenCheck::Valid { account: None });
        assert_eq!(ForgeTokenCheck::from_response(401, b""), ForgeTokenCheck::Rejected);
        assert_eq!(ForgeTokenCheck::from_response(502, b""), ForgeTokenCheck::Unreachable);
    }

    #[test]
    fn refusal_parses_nested_and_field_errors() {
        assert_eq!(
            refusal_message("GitLab", 422, br#"{"message":{"source_branch":["does not exist"]}}"#),
            "GitLab refused this (422). source_branch does not exist"
        );
        assert_eq!(
            refusal_message("Bitbucket", 400, br#"{"error":{"message":"Invalid branch"}}"#),
            "Bitbucket refused this (400). Invalid branch"
        );
        assert_eq!(
            refusal_message("Gitea", 409, br#"{"message":"pull request already exists"}"#),
            "Gitea refused this (409). pull request already exists"
        );
    }

    #[tokio::test]
    async fn gitea_token_check_create_branch_and_snapshot() {
        let server = TestServer::start(vec![
            ("GET /user", 200, r#"{"login":"michan"}"#.into()),
            (
                "POST /repos/acme/app/pulls",
                201,
                r#"{"number":7,"html_url":"https://codeberg.org/acme/app/pulls/7"}"#.into(),
            ),
            (
                "GET /repos/acme/app/pulls",
                200,
                r#"[{"number":7,"html_url":"https://codeberg.org/acme/app/pulls/7","title":"WIP: Fix","state":"open","draft":true,"head":{"ref":"feat/x"},"base":{"ref":"main"}}]"#.into(),
            ),
            (
                "GET /repos/acme/app/pulls/7",
                200,
                r#"{"number":7,"html_url":"https://codeberg.org/acme/app/pulls/7","title":"Fix","state":"open","draft":false,"mergeable":true,"head":{"ref":"feat/x","sha":"abc123"},"base":{"ref":"main"}}"#.into(),
            ),
            (
                "GET /repos/acme/app/commits/abc123/status",
                200,
                r#"{"statuses":[{"context":"ci/build","status":"success","description":"passed"}]}"#.into(),
            ),
            (
                "GET /repos/acme/app/pulls/7/reviews",
                200,
                r#"[{"id":11,"state":"APPROVED","body":"lgtm","user":{"login":"sara"}}]"#.into(),
            ),
            (
                "GET /repos/acme/app/issues/7/comments",
                200,
                r#"[{"id":22,"body":"nice"}]"#.into(),
            ),
        ])
        .await;
        let http = Http::new();
        let store = ConnectorStore::in_memory();
        let secrets = MemorySecrets::default();
        let base = server.url("");

        let (saved_host, check) =
            verify_and_save_with_base(&http, &store, &secrets, CodeHostKind::Gitea, "codeberg.org", "gt-secret", Some(&base))
                .await
                .unwrap();
        assert_eq!(saved_host, "codeberg.org");
        assert_eq!(check, Some(ForgeTokenCheck::Valid { account: Some("michan".into()) }));

        let r = repo("https://codeberg.org/acme/app.git");
        let created =
            create_pull_request_with_base(&http, &r, "gt-secret", "Fix bug", "details", "feat/x", "main", true, Some(&base)).await.unwrap();
        assert_eq!(created, "https://codeberg.org/acme/app/pulls/7");

        let reqs = server.requests();
        let post = reqs.iter().find(|req| req.method == "POST").unwrap();
        assert_eq!(post.header("authorization"), Some("token gt-secret"));
        assert!(post.body.contains("\"title\":\"WIP: Fix bug\""), "body was {}", post.body);

        let branch = branch_pull_requests_with_base(&http, &r, "gt-secret", "feat/x", Some(&base)).await.unwrap();
        assert_eq!(branch.open.as_ref().map(|p| p.number), Some(7));
        assert!(!branch.landed);

        let pr_ref = PullRequestRef {
            host: PrHost::Gitea("codeberg.org".into()),
            repo: "acme/app".into(),
            number: 7,
            url: "https://codeberg.org/acme/app/pulls/7".into(),
        };
        let snap = fetch_snapshot_with_base(&http, &secrets, &pr_ref, Some(&base)).await.unwrap();
        assert_eq!(snap.state, "open");
        assert_eq!(snap.checks.len(), 1);
        assert_eq!(snap.checks[0].outcome, "passing");
        assert_eq!(snap.reviews.len(), 1);
        assert_eq!(snap.reviews[0].state, "APPROVED");
        assert_eq!(snap.comment_ids, vec!["gitea-comment-22"]);
    }

    #[tokio::test]
    async fn gitlab_create_branch_and_snapshot() {
        let server = TestServer::start(vec![
            (
                "POST /projects/group%2Fsub%2Fapp/merge_requests",
                201,
                r#"{"iid":4,"web_url":"https://gitlab.com/group/sub/app/-/merge_requests/4"}"#.into(),
            ),
            (
                "GET /projects/group%2Fsub%2Fapp/merge_requests",
                200,
                r#"[{"iid":4,"web_url":"https://gitlab.com/group/sub/app/-/merge_requests/4","title":"Draft: Work","state":"opened","draft":true,"source_branch":"feat/y","target_branch":"main"}]"#.into(),
            ),
            (
                "GET /projects/group%2Fsub%2Fapp/merge_requests/4",
                200,
                r#"{"iid":4,"web_url":"https://gitlab.com/group/sub/app/-/merge_requests/4","title":"Work","state":"opened","draft":false,"has_conflicts":false,"detailed_merge_status":"mergeable","source_branch":"feat/y","target_branch":"main","sha":"def456","head_pipeline":{"id":99,"status":"failed"}}"#.into(),
            ),
            (
                "GET /projects/group%2Fsub%2Fapp/pipelines/99/jobs",
                200,
                r#"[{"name":"unit-tests","stage":"test"}]"#.into(),
            ),
            (
                "GET /projects/group%2Fsub%2Fapp/merge_requests/4/approvals",
                200,
                r#"{"approved_by":[{"user":{"username":"lena"}}]}"#.into(),
            ),
            (
                "GET /projects/group%2Fsub%2Fapp/merge_requests/4/notes",
                200,
                r#"[{"id":1,"system":true},{"id":2,"system":false,"body":"looks good"}]"#.into(),
            ),
        ])
        .await;
        let http = Http::new();
        let store = ConnectorStore::in_memory();
        let secrets = MemorySecrets::default();
        gitlab::save(&store, &secrets, "gitlab.com", "glpat-1").unwrap();
        let base = server.url("");
        let r = repo("git@gitlab.com:group/sub/app.git");

        let url = create_pull_request_with_base(&http, &r, "glpat-1", "Work", "body", "feat/y", "main", true, Some(&base)).await.unwrap();
        assert_eq!(url, "https://gitlab.com/group/sub/app/-/merge_requests/4");
        let post = server.requests().into_iter().find(|req| req.method == "POST").unwrap();
        assert_eq!(post.header("private-token"), Some("glpat-1"));
        assert!(post.body.contains("\"title\":\"Draft: Work\""), "body was {}", post.body);

        let branch = branch_pull_requests_with_base(&http, &r, "glpat-1", "feat/y", Some(&base)).await.unwrap();
        assert_eq!(branch.open.as_ref().map(|p| p.state.as_str()), Some("draft"));

        let pr_ref = PullRequestRef {
            host: PrHost::GitLab("gitlab.com".into()),
            repo: "group/sub/app".into(),
            number: 4,
            url: "https://gitlab.com/group/sub/app/-/merge_requests/4".into(),
        };
        let snap = fetch_snapshot_with_base(&http, &secrets, &pr_ref, Some(&base)).await.unwrap();
        assert_eq!(snap.checks.len(), 1);
        assert_eq!(snap.checks[0].name, "unit-tests");
        assert_eq!(snap.checks[0].outcome, "failing");
        assert_eq!(snap.reviews.len(), 1);
        assert_eq!(snap.reviews[0].author, "lena");
        assert_eq!(snap.comment_ids, vec!["gl-note-2"]);
    }

    #[tokio::test]
    async fn bitbucket_and_azure_create_and_snapshot() {
        let server = TestServer::start(vec![
            (
                "POST /repositories/team/web/pullrequests",
                201,
                r#"{"id":15,"links":{"html":{"href":"https://bitbucket.org/team/web/pull-requests/15"}}}"#.into(),
            ),
            (
                "GET /repositories/team/web/pullrequests/15",
                200,
                r#"{"id":15,"title":"BB PR","state":"OPEN","draft":false,"links":{"html":{"href":"https://bitbucket.org/team/web/pull-requests/15"}},"source":{"branch":{"name":"feat/b"},"commit":{"hash":"111"}},"destination":{"branch":{"name":"main"}},"participants":[{"approved":true,"state":"approved","user":{"nickname":"alex"}}]}"#.into(),
            ),
            (
                "GET /repositories/team/web/pullrequests/15/statuses",
                200,
                r#"{"values":[{"name":"pipelines","state":"SUCCESSFUL","description":"ok"}]}"#.into(),
            ),
            ("GET /repositories/team/web/pullrequests/15/comments", 200, r#"{"values":[{"id":55,"deleted":false}]}"#.into()),
            ("GET /repositories/team/web/pullrequests/15/conflicts", 200, r#"[]"#.into()),
            ("POST /pullrequests", 201, r#"{"pullRequestId":42}"#.into()),
            (
                "GET /pullrequests/42",
                200,
                r#"{"pullRequestId":42,"title":"Az PR","status":"active","isDraft":false,"mergeStatus":"conflicts","sourceRefName":"refs/heads/feat/a","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"222"},"reviewers":[{"id":"u1","displayName":"Sam","vote":-10}]}"#.into(),
            ),
            (
                "GET /pullrequests/42/statuses",
                200,
                r#"{"value":[{"state":"succeeded","context":{"name":"build"},"description":"green"}]}"#.into(),
            ),
            (
                "GET /pullrequests/42/threads",
                200,
                r#"{"value":[{"id":3,"comments":[{"id":1,"commentType":"text"},{"id":2,"commentType":"system"}]}]}"#.into(),
            ),
        ])
        .await;
        let http = Http::new();
        let store = ConnectorStore::in_memory();
        let secrets = MemorySecrets::default();
        save(&store, &secrets, "bitbucket.org", "me@example.com:bbtok").unwrap();
        save(&store, &secrets, "dev.azure.com", "azpat").unwrap();
        let base = server.url("");

        let bb_repo = repo("https://bitbucket.org/team/web.git");
        let bb_url =
            create_pull_request_with_base(&http, &bb_repo, "me@example.com:bbtok", "BB PR", "desc", "feat/b", "main", false, Some(&base))
                .await
                .unwrap();
        assert_eq!(bb_url, "https://bitbucket.org/team/web/pull-requests/15");
        let bb_snap = fetch_snapshot_with_base(
            &http,
            &secrets,
            &PullRequestRef { host: PrHost::Bitbucket("bitbucket.org".into()), repo: "team/web".into(), number: 15, url: bb_url },
            Some(&base),
        )
        .await
        .unwrap();
        assert_eq!(bb_snap.reviews[0].author, "alex");
        assert_eq!(bb_snap.checks[0].outcome, "passing");
        assert_eq!(bb_snap.comment_ids, vec!["bb-comment-55"]);

        let az_repo = repo("https://dev.azure.com/org/proj/_git/web");
        let az_url =
            create_pull_request_with_base(&http, &az_repo, "azpat", "Az PR", "desc", "feat/a", "main", true, Some(&base)).await.unwrap();
        assert_eq!(az_url, "https://dev.azure.com/org/proj/_git/web/pullrequest/42");
        let az_snap = fetch_snapshot_with_base(
            &http,
            &secrets,
            &PullRequestRef {
                host: PrHost::AzureDevOps("dev.azure.com".into()),
                repo: "org/proj/_git/web".into(),
                number: 42,
                url: az_url,
            },
            Some(&base),
        )
        .await
        .unwrap();
        assert!(az_snap.conflicted);
        assert_eq!(az_snap.reviews[0].state, "CHANGES_REQUESTED");
        assert_eq!(az_snap.comment_ids, vec!["az-t3-c1"]);
    }
}
