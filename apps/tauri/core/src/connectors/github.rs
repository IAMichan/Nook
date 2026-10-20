//! GitHub: je pull requests, reviews en issues lezen; beoordelen, goedkeuren, samenvoegen, sluiten en issues bijwerken
//! alleen als actie, na Uitvoeren. Meer accounts mogen ("GitHub · Werk"); het token per account staat in de kluis
//! onder `connector.github.token` (hoofdaccount) of `connector.github.<account>.token`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::accounts::{self, ServiceAccount};
use super::hub::{Connector, Env, Scope};
use super::pulls::{self, PullRequestList};
use super::{
    dates, field, int, link, list, plural, short, with_query, CResult, ConnectorError, ConnectorItem, ConnectorStatus, ErrorKind, Tone,
};
use crate::brain::LoopTool;

pub const ID: &str = "github";
pub const TOKEN_ACCOUNT: &str = "connector.github.token";
pub const TOKEN_URL: &str = "https://github.com/settings/tokens/new?scopes=repo,read:user&description=Nook";

/// De OAuth-app voor "Koppel met GitHub" (device flow). Het client-id is openbaar, geen geheim. Zolang het leeg is,
/// biedt Nook alleen de GitHub CLI-login en een token plakken, net als op de Mac.
pub const CLIENT_ID: &str = "";

pub fn api() -> String {
    super::api_base("https://api.github.com", "NOOK_GITHUB_API_URL")
}

pub fn login_base() -> String {
    super::api_base("https://github.com", "NOOK_GITHUB_LOGIN_URL")
}

pub(super) fn headers(token: &str) -> Vec<(&'static str, String)> {
    vec![
        ("Authorization", format!("Bearer {token}")),
        ("Accept", "application/vnd.github+json".into()),
        ("X-GitHub-Api-Version", "2022-11-28".into()),
    ]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Ci {
    #[default]
    Unknown,
    Pending,
    Passing,
    Failing,
}

impl Ci {
    fn label(self) -> &'static str {
        match self {
            Ci::Failing => "CI failing",
            Ci::Pending => "CI running",
            Ci::Passing => "CI green",
            Ci::Unknown => "",
        }
    }

    fn tone(self) -> Tone {
        match self {
            Ci::Failing => Tone::Bad,
            Ci::Passing => Tone::Good,
            _ => Tone::Neutral,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
struct PullRequest {
    repo: String,
    number: i64,
    title: String,
    url: Option<String>,
    draft: bool,
    updated: Option<DateTime<Utc>>,
    ci: Ci,
}

impl PullRequest {
    fn reference(&self) -> String {
        format!("{}#{}", self.repo, self.number)
    }
}

#[derive(Debug, Clone)]
struct Snapshot {
    login: String,
    mine: Vec<PullRequest>,
    mine_total: i64,
    reviews: Vec<PullRequest>,
    review_total: i64,
}

/// "owner/naam", zoals een repository in een tool staat.
pub fn is_repository(text: &str) -> bool {
    let re = regex::Regex::new(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$").unwrap();
    re.is_match(text) && !text.contains("..")
}

fn target(input: &Value) -> CResult<(String, i64)> {
    let repo = super::text(input, "repo").trim().to_string();
    if !is_repository(&repo) {
        return Err(ConnectorError::new("The repository must be owner/name, for example IAMichan/nook."));
    }
    let number = int(&input["number"]).filter(|n| *n > 0).ok_or_else(|| ConnectorError::new("The pull request number is missing."))?;
    Ok((repo, number))
}

fn reference(input: &Value) -> String {
    target(input).map(|(r, n)| format!("{r}#{n}")).unwrap_or_else(|_| "pull request".into())
}

fn pr_schema(extra: Value, required: &[&str]) -> Value {
    let mut props = json!({
        "repo": {"type": "string", "description": "Repository as owner/name, for example IAMichan/nook."},
        "number": {"type": "integer", "description": "Pull request number."}
    });
    if let (Some(p), Some(e)) = (props.as_object_mut(), extra.as_object()) {
        for (k, v) in e {
            p.insert(k.clone(), v.clone());
        }
    }
    let mut req = vec![json!("repo"), json!("number")];
    req.extend(required.iter().map(|r| json!(r)));
    json!({"type": "object", "properties": props, "required": req})
}

fn labels(input: &Value) -> Vec<String> {
    super::text(input, "labels").split(',').map(|l| l.trim().to_string()).filter(|l| !l.is_empty()).collect()
}

pub struct GitHub {
    env: Arc<Env>,
    snapshots: Mutex<HashMap<String, Snapshot>>,
    status: Mutex<ConnectorStatus>,
}

impl GitHub {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { env, snapshots: Mutex::default(), status: Mutex::default() })
    }

    /// Accounts met een token, hoofdaccount eerst.
    pub fn accounts(&self) -> Vec<ServiceAccount> {
        accounts::accounts(&self.env.store, ID).into_iter().filter(|a| self.env.secret(&a.key("token")).is_some()).collect()
    }

    /// De tokens van alle accounts, hoofdaccount eerst (voor de werkruimte: een pull request openen).
    pub fn tokens(&self) -> Vec<String> {
        if !self.env.store.is_on(ID) {
            return vec![];
        }
        self.accounts().iter().filter_map(|a| self.env.secret(&a.key("token"))).collect()
    }

    /// Het account voor een tool-aanroep. Zonder `account` gebruikt lezen het hoofdaccount; een actie met meer
    /// accounts heeft `account` als verplicht veld, dus het plan draait nooit op een geraden account.
    fn credentials(&self, input: &Value) -> CResult<(ServiceAccount, String)> {
        if !self.env.store.is_on(ID) {
            return Err(ConnectorError::not_set_up("GitHub"));
        }
        let available = self.accounts();
        if available.is_empty() {
            return Err(ConnectorError::not_set_up("GitHub"));
        }
        let account = match field(input, "account") {
            Some(reference) => accounts::find(&reference, &available).cloned().ok_or_else(|| {
                ConnectorError::new(format!(
                    "There is no GitHub account \"{reference}\". Accounts: {}.",
                    available.iter().map(ServiceAccount::name).collect::<Vec<_>>().join(", ")
                ))
            })?,
            None => available[0].clone(),
        };
        let token = self.env.secret(&account.key("token")).ok_or_else(|| ConnectorError::not_set_up("GitHub"))?;
        Ok((account, token))
    }

    async fn get(&self, url: &str, token: &str) -> CResult<Value> {
        self.env.http.json("GET", url, &headers(token), None, "GitHub").await
    }

    async fn fetch(&self, token: &str) -> CResult<Snapshot> {
        let user = self.get(&format!("{}/user", api()), token).await?;
        let login = user["login"]
            .as_str()
            .filter(|l| !l.is_empty())
            .ok_or_else(|| ConnectorError::new("GitHub gaf geen gebruikersnaam."))?
            .to_string();
        let (mut mine, mine_total) = self.search(&format!("is:pr is:open archived:false author:{login}"), token).await?;
        let (reviews, review_total) = self.search(&format!("is:pr is:open archived:false review-requested:{login}"), token).await?;
        // CI alleen voor de nieuwste, om binnen de limieten van GitHub te blijven.
        for pr in mine.iter_mut().take(6) {
            pr.ci = self.ci_state(&pr.repo, pr.number, token).await;
        }
        Ok(Snapshot { login, mine, mine_total, reviews, review_total })
    }

    async fn search(&self, query: &str, token: &str) -> CResult<(Vec<PullRequest>, i64)> {
        let url = with_query(
            &format!("{}/search/issues", api()),
            &[("q", query.into()), ("sort", "updated".into()), ("order", "desc".into()), ("per_page", "20".into())],
        );
        let root = self.get(&url, token).await?;
        let prefix = format!("{}/repos/", api());
        let items: Vec<PullRequest> = list(&root["items"])
            .iter()
            .filter_map(|item| {
                let number = int(&item["number"])?;
                let repo_url = item["repository_url"].as_str()?;
                let repo = repo_url
                    .strip_prefix(&prefix)
                    .or_else(|| repo_url.strip_prefix("https://api.github.com/repos/"))
                    .unwrap_or(repo_url)
                    .to_string();
                Some(PullRequest {
                    repo,
                    number,
                    title: item["title"].as_str().unwrap_or("Untitled").into(),
                    url: link(item["html_url"].as_str()),
                    draft: item["draft"].as_bool().unwrap_or(false),
                    updated: super::date(&item["updated_at"]),
                    ci: Ci::Unknown,
                })
            })
            .collect();
        let total = int(&root["total_count"]).unwrap_or(items.len() as i64);
        Ok((items, total))
    }

    /// Check runs en de oude commit-statussen van de laatste commit van een PR.
    async fn ci_state(&self, repo: &str, number: i64, token: &str) -> Ci {
        let base = format!("{}/repos/{repo}", api());
        let Ok(pull) = self.get(&format!("{base}/pulls/{number}"), token).await else { return Ci::Unknown };
        let Some(sha) = pull["head"]["sha"].as_str() else { return Ci::Unknown };
        let (mut seen, mut pending, mut failing) = (false, false, false);
        let bad = ["failure", "timed_out", "action_required", "startup_failure"];
        if let Ok(runs) = self.get(&format!("{base}/commits/{sha}/check-runs?per_page=50"), token).await {
            for run in list(&runs["check_runs"]) {
                seen = true;
                if run["status"] != "completed" {
                    pending = true;
                } else if bad.contains(&run["conclusion"].as_str().unwrap_or("")) {
                    failing = true;
                }
            }
        }
        if let Ok(combined) = self.get(&format!("{base}/commits/{sha}/status"), token).await {
            if int(&combined["total_count"]).unwrap_or(0) > 0 {
                seen = true;
                match combined["state"].as_str().unwrap_or("") {
                    "failure" | "error" => failing = true,
                    "pending" => pending = true,
                    _ => {}
                }
            }
        }
        if failing {
            Ci::Failing
        } else if pending {
            Ci::Pending
        } else if seen {
            Ci::Passing
        } else {
            Ci::Unknown
        }
    }

    fn apply(&self, s: &Snapshot) {
        let failing: Vec<&PullRequest> = s.mine.iter().filter(|p| p.ci == Ci::Failing).collect();
        let mut headline = format!("{} open PR's", s.mine_total);
        if s.review_total > 0 {
            headline.push_str(&format!(" · {} reviews voor jou", s.review_total));
        }
        let detail = if !failing.is_empty() {
            format!("CI faalt bij {}", failing.iter().take(3).map(|p| p.reference()).collect::<Vec<_>>().join(", "))
        } else if s.mine.iter().any(|p| p.ci == Ci::Pending) {
            "CI draait nog".into()
        } else if s.mine.is_empty() {
            "Geen open PR's van jou".into()
        } else {
            "CI is groen".into()
        };
        let mut items: Vec<ConnectorItem> = s
            .reviews
            .iter()
            .take(4)
            .map(|p| {
                ConnectorItem::new(
                    format!("review-{}", p.reference()),
                    &p.title,
                    format!("Review gevraagd · {}", p.reference()),
                    Tone::Attention,
                    p.url.clone(),
                )
            })
            .collect();
        let room = 8usize.saturating_sub(items.len());
        for p in s.mine.iter().take(room) {
            let mut parts = vec![p.reference()];
            if p.draft {
                parts.push("concept".into());
            }
            if !p.ci.label().is_empty() {
                parts.push(p.ci.label().into());
            }
            items.push(ConnectorItem::new(format!("pr-{}", p.reference()), &p.title, parts.join(" · "), p.ci.tone(), p.url.clone()));
        }
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) =
            ConnectorStatus::ok(headline, detail, items, s.review_total > 0 || !failing.is_empty());
    }

    async fn overview(&self, input: &Value) -> CResult<String> {
        let (account, token) = self.credentials(input)?;
        let s = self.fetch(&token).await?;
        self.snapshots.lock().unwrap_or_else(|e| e.into_inner()).insert(account.id.clone(), s.clone());
        let several = self.accounts().len() > 1;
        if self.accounts().first().map(|a| a.id == account.id).unwrap_or(false) {
            self.apply(&s);
        }
        let label = if several { format!(" (account {})", account.name()) } else { String::new() };
        let mut out =
            vec![format!("GitHub account: @{}{label}", s.login), String::new(), format!("Open PRs authored by user ({}):", s.mine_total)];
        if s.mine.is_empty() {
            out.push("- none".into());
        }
        for p in &s.mine {
            let mut line = format!("- {} '{}'", p.reference(), p.title);
            if p.draft {
                line.push_str(" [draft]");
            }
            if !p.ci.label().is_empty() {
                line.push_str(&format!(" [{}]", p.ci.label()));
            }
            if let Some(u) = p.updated {
                line.push_str(&format!(" · updated {}", dates::ago(u)));
            }
            if let Some(url) = &p.url {
                line.push_str(&format!(" · {url}"));
            }
            out.push(line);
        }
        out.push(String::new());
        out.push(format!("Review requested from user ({}):", s.review_total));
        if s.reviews.is_empty() {
            out.push("- none".into());
        }
        for p in &s.reviews {
            let mut line = format!("- {} '{}'", p.reference(), p.title);
            if let Some(u) = p.updated {
                line.push_str(&format!(" · updated {}", dates::ago(u)));
            }
            if let Some(url) = &p.url {
                line.push_str(&format!(" · {url}"));
            }
            out.push(line);
        }
        Ok(out.join("\n"))
    }

    /// Een schrijfactie op GitHub, met de foutmelding van GitHub zelf zodat Nook kan uitleggen waarom het niet lukte.
    async fn send(&self, method: &str, path: &str, body: Value, input: &Value) -> CResult<Value> {
        let (_, token) = self.credentials(input)?;
        let (status, bytes) = self.env.http.send(method, &format!("{}{path}", api()), &headers(&token), Some(&body), "GitHub").await?;
        let object: Value = serde_json::from_slice(&bytes).unwrap_or(json!({}));
        if !(200..300).contains(&status) {
            let message = object["message"].as_str().map(str::to_string).unwrap_or_else(|| format!("GitHub returned an error ({status})."));
            return Err(match status {
                401 => ConnectorError::kind("GitHub weigerde de verbinding (401). Koppel opnieuw bij Instellingen › Accounts & koppelingen.", ErrorKind::Auth),
                403 | 404 => ConnectorError::kind(
                    format!("GitHub stond dit niet toe ({status}): {message} Heeft de koppeling schrijfrechten op pull requests? Koppel anders opnieuw."),
                    ErrorKind::Auth,
                ),
                _ => ConnectorError::new(format!("GitHub: {message}")),
            });
        }
        Ok(object)
    }

    /// De PR met alles wat nodig is om hem te beoordelen; ingekort zodat een grote diff het gesprek niet overspoelt.
    async fn pull_request_details(&self, repo: &str, number: i64, input: &Value) -> CResult<String> {
        let (_, token) = self.credentials(input)?;
        let base = format!("{}/repos/{repo}/pulls/{number}", api());
        let pull = self.get(&base, &token).await?;
        let files_value = self.get(&format!("{base}/files?per_page=30"), &token).await?;
        let files = list(&files_value);
        let reviews_value = self.get(&format!("{base}/reviews?per_page=30"), &token).await.unwrap_or(json!([]));
        let reviews = list(&reviews_value);
        let ci = self.ci_state(repo, number, &token).await;
        let state = if pull["merged"].as_bool().unwrap_or(false) {
            "merged"
        } else if pull["state"] == "open" {
            "open"
        } else {
            "closed"
        };
        let mut out = vec![format!(
            "{repo}#{number} '{}' by @{}",
            pull["title"].as_str().unwrap_or("Untitled"),
            pull["user"]["login"].as_str().unwrap_or("?")
        )];
        let mut facts = vec![format!("status: {state}")];
        if pull["draft"].as_bool().unwrap_or(false) {
            facts.push("draft".into());
        }
        if let Some(m) = pull["mergeable"].as_bool() {
            facts.push(if m { "no conflicts".into() } else { "conflicts".into() });
        }
        if let Some(ms) = pull["mergeable_state"].as_str().filter(|m| *m != "unknown") {
            facts.push(format!("mergeable_state: {ms}"));
        }
        if !ci.label().is_empty() {
            facts.push(ci.label().into());
        }
        out.push(facts.join(" · "));
        let changed = int(&pull["changed_files"]).unwrap_or(files.len() as i64);
        out.push(format!(
            "From {} to {} · +{} −{} in {}",
            pull["head"]["ref"].as_str().unwrap_or("?"),
            pull["base"]["ref"].as_str().unwrap_or("?"),
            int(&pull["additions"]).unwrap_or(0),
            int(&pull["deletions"]).unwrap_or(0),
            plural(changed as usize, "file", "files")
        ));
        if let Some(url) = pull["html_url"].as_str() {
            out.push(url.into());
        }
        if let Some(body) = pull["body"].as_str().map(str::trim).filter(|b| !b.is_empty()) {
            out.push(String::new());
            out.push("Description:".into());
            out.push(body.chars().take(1500).collect());
        }
        if !reviews.is_empty() {
            out.push(String::new());
            out.push("Reviews:".into());
            for r in reviews.iter().rev().take(10).collect::<Vec<_>>().into_iter().rev() {
                let mut line = format!("- @{}: {}", r["user"]["login"].as_str().unwrap_or("?"), r["state"].as_str().unwrap_or("?"));
                if let Some(t) = r["body"].as_str().map(str::trim).filter(|t| !t.is_empty()) {
                    line.push_str(&format!(" · {}", short(t, 160)));
                }
                out.push(line);
            }
        }
        out.push(String::new());
        out.push("Changed files:".into());
        let mut budget: usize = 12_000;
        for f in files {
            let mut block = format!(
                "### {} ({}, +{} −{})",
                f["filename"].as_str().unwrap_or("?"),
                f["status"].as_str().unwrap_or("modified"),
                int(&f["additions"]).unwrap_or(0),
                int(&f["deletions"]).unwrap_or(0)
            );
            match f["patch"].as_str() {
                Some(patch) if budget > 0 => {
                    let cut: String = patch.chars().take(1500.min(budget)).collect();
                    budget = budget.saturating_sub(cut.chars().count());
                    let truncated = cut.chars().count() < patch.chars().count();
                    block.push_str(&format!("\n{cut}{}", if truncated { "\n… (diff truncated)" } else { "" }));
                }
                None => block.push_str("\n(no diff available: binary or too large)"),
                _ => block.push_str("\n(diff omitted for brevity)"),
            }
            out.push(block);
        }
        if int(&pull["changed_files"]).unwrap_or(0) > files.len() as i64 {
            out.push(format!("… and more files (only the first {} were fetched)", files.len()));
        }
        Ok(out.join("\n"))
    }

    async fn search_issues(&self, query: &str, kind: &str, input: &Value) -> CResult<String> {
        let (_, token) = self.credentials(input)?;
        let mut q = query.to_string();
        if kind == "issue" && !q.contains("is:issue") {
            q.push_str(" is:issue");
        }
        if kind == "pr" && !q.contains("is:pr") {
            q.push_str(" is:pr");
        }
        let url = with_query(
            &format!("{}/search/issues", api()),
            &[("q", q), ("sort", "updated".into()), ("order", "desc".into()), ("per_page", "15".into())],
        );
        let root = self.get(&url, &token).await?;
        let items = list(&root["items"]);
        if items.is_empty() {
            return Ok(format!("No issues or pull requests found for \"{query}\"."));
        }
        let mut lines =
            vec![format!("{} results, {} most recently updated:", int(&root["total_count"]).unwrap_or(items.len() as i64), items.len())];
        let prefix = format!("{}/repos/", api());
        for item in items {
            let repo_url = item["repository_url"].as_str().unwrap_or("");
            let repo =
                repo_url.strip_prefix(&prefix).or_else(|| repo_url.strip_prefix("https://api.github.com/repos/")).unwrap_or(repo_url);
            let kind = if item.get("pull_request").is_some() { "PR" } else { "issue" };
            let labels: Vec<&str> = list(&item["labels"]).iter().filter_map(|l| l["name"].as_str()).collect();
            let mut line = format!(
                "- {repo}#{} [{kind}, {}] '{}'",
                int(&item["number"]).unwrap_or(0),
                item["state"].as_str().unwrap_or("?"),
                item["title"].as_str().unwrap_or("Untitled")
            );
            if !labels.is_empty() {
                line.push_str(&format!(" · labels: {}", labels.join(", ")));
            }
            if let Some(u) = super::date(&item["updated_at"]) {
                line.push_str(&format!(" · updated {}", dates::short(u)));
            }
            if let Some(a) = item["user"]["login"].as_str() {
                line.push_str(&format!(" · by @{a}"));
            }
            if let Some(url) = link(item["html_url"].as_str()) {
                line.push_str(&format!(" · {url}"));
            }
            lines.push(line);
        }
        Ok(lines.join("\n"))
    }

    async fn issue_details(&self, repo: &str, number: i64, input: &Value) -> CResult<String> {
        let (_, token) = self.credentials(input)?;
        let base = format!("{}/repos/{repo}/issues/{number}", api());
        let issue = self.get(&base, &token).await?;
        let comments_value = self.get(&format!("{base}/comments?per_page=30"), &token).await.unwrap_or(json!([]));
        let comments = list(&comments_value);
        let labels: Vec<&str> = list(&issue["labels"]).iter().filter_map(|l| l["name"].as_str()).collect();
        let mut out = vec![format!(
            "{repo}#{number} '{}' by @{}",
            issue["title"].as_str().unwrap_or("Untitled"),
            issue["user"]["login"].as_str().unwrap_or("?")
        )];
        let mut facts = vec![format!("status: {}", issue["state"].as_str().unwrap_or("?"))];
        if !labels.is_empty() {
            facts.push(format!("labels: {}", labels.join(", ")));
        }
        if let Some(c) = super::date(&issue["created_at"]) {
            facts.push(format!("opened {}", dates::short(c)));
        }
        if let Some(u) = super::date(&issue["updated_at"]) {
            facts.push(format!("updated {}", dates::short(u)));
        }
        let assignees: Vec<String> =
            list(&issue["assignees"]).iter().filter_map(|a| a["login"].as_str().map(|l| format!("@{l}"))).collect();
        if !assignees.is_empty() {
            facts.push(format!("assigned to: {}", assignees.join(", ")));
        }
        out.push(facts.join(" · "));
        if let Some(body) = issue["body"].as_str().map(str::trim).filter(|b| !b.is_empty()) {
            out.push(String::new());
            out.push("Description:".into());
            out.push(body.chars().take(4000).collect());
        }
        if !comments.is_empty() {
            out.push(String::new());
            out.push(format!("Comments (last {}):", comments.len().min(15)));
            for c in comments.iter().skip(comments.len().saturating_sub(15)) {
                let when = super::date(&c["created_at"]).map(dates::short).unwrap_or_default();
                out.push(format!(
                    "- @{} {when}: {}",
                    c["user"]["login"].as_str().unwrap_or("?"),
                    short(c["body"].as_str().unwrap_or(""), 600)
                ));
            }
        }
        if let Some(url) = link(issue["html_url"].as_str()) {
            out.push(url);
        }
        Ok(out.join("\n"))
    }

    fn specs(self: &Arc<Self>) -> Vec<LoopTool> {
        let read =
            |name: &str, description: &str, schema: Value, f: fn(Arc<GitHub>, Value) -> crate::brain::BoxFuture<crate::Result<String>>| {
                let me = self.clone();
                LoopTool::read(name, description, schema, move |input| f(me.clone(), input))
            };
        vec![
            read(
                "github_overview",
                "Freshly fetches the user's open pull requests on GitHub, pull requests requesting the user's review, and CI status per PR, with links.",
                super::schema(json!({})),
                |me, input| Box::pin(async move { me.overview(&input).await.map_err(Into::into) }),
            ),
            read(
                "github_pr_details",
                "Reads a single pull request completely: title, description, author, status, CI, existing reviews, and changed files with their diff. ALWAYS use this first when the user wants to review, approve, or merge a PR, and actually read the diff before rendering a verdict.",
                pr_schema(json!({}), &[]),
                |me, input| Box::pin(async move {
                    let (repo, number) = target(&input)?;
                    me.pull_request_details(&repo, number, &input).await.map_err(Into::into)
                }),
            ),
            LoopTool::action(
                "github_review_pr",
                "Submits a review on a pull request: approve (APPROVE), request changes (REQUEST_CHANGES), or comment only (COMMENT). Inspect the diff with github_pr_details first. A comment body is required for REQUEST_CHANGES and COMMENT. You cannot approve your own pull request.",
                pr_schema(json!({
                    "event": {"type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"], "description": "The review action."},
                    "body": {"type": "string", "description": "The review text. Required for REQUEST_CHANGES and COMMENT."}
                }), &["event"]),
            ),
            LoopTool::action("github_comment_pr", "Posts a regular comment on a pull request, without a review verdict.", pr_schema(json!({"body": {"type": "string", "description": "The comment text."}}), &["body"])),
            LoopTool::action(
                "github_merge_pr",
                "Merges a pull request. This is difficult to undo: only use when the user clearly asks, and check with github_pr_details first whether CI is green and the PR is not a draft. Choose the method requested by the user; default to 'merge'.",
                pr_schema(json!({"method": {"type": "string", "enum": ["merge", "squash", "rebase"], "description": "Merge method. Defaults to merge."}}), &[]),
            ),
            LoopTool::action("github_close_pr", "Closes a pull request without merging. Only use when explicitly requested by the user.", pr_schema(json!({}), &[])),
            read(
                "github_search",
                "Searches issues and pull requests on GitHub using a GitHub query, most recently updated first, with status, labels, and links. Example queries: \"launch repo:IAMichan/nook\", \"is:issue is:open label:bug\", \"involves:@me deadline\". Use this to find requirements, decisions, or outstanding work in issues.",
                json!({"type": "object", "properties": {
                    "query": {"type": "string", "description": "GitHub search query (same syntax as on github.com)."},
                    "type": {"type": "string", "enum": ["issue", "pr", "all"], "description": "Issues only, PRs only, or both (default)."}
                }, "required": ["query"]}),
                |me, input| Box::pin(async move {
                    let query = super::text(&input, "query").trim().to_string();
                    if query.is_empty() {
                        return Err(ConnectorError::new("Search query is missing.").into());
                    }
                    let kind = field(&input, "type").unwrap_or_else(|| "all".into());
                    me.search_issues(&query, &kind, &input).await.map_err(Into::into)
                }),
            ),
            read(
                "github_issue_details",
                "Reads a single issue (or the discussion on a pull request): title, status, labels, description, and recent comments.",
                pr_schema(json!({}), &[]),
                |me, input| Box::pin(async move {
                    let (repo, number) = target(&input)?;
                    me.issue_details(&repo, number, &input).await.map_err(Into::into)
                }),
            ),
            LoopTool::action(
                "github_create_issue",
                "Creates a new issue in a repository. Write a clear title and description (Markdown). Labels are optional, comma-separated, and must already exist in the repository.",
                json!({"type": "object", "properties": {
                    "repo": {"type": "string", "description": "Repository as owner/name."},
                    "title": {"type": "string", "description": "Issue title."},
                    "body": {"type": "string", "description": "Description (Markdown)."},
                    "labels": {"type": "string", "description": "Labels, comma-separated. Optional."}
                }, "required": ["repo", "title"]}),
            ),
            LoopTool::action("github_comment_issue", "Posts a comment on an issue (or the discussion of a pull request).", pr_schema(json!({"body": {"type": "string", "description": "The comment text."}}), &["body"])),
            LoopTool::action(
                "github_update_issue",
                "Updates an issue: close or reopen, change title, or add labels. Only provided fields are updated.",
                pr_schema(json!({
                    "state": {"type": "string", "enum": ["open", "closed"], "description": "open or closed. Optional."},
                    "title": {"type": "string", "description": "New title. Optional."},
                    "labels": {"type": "string", "description": "Labels to add, comma-separated. Optional."}
                }), &[]),
            ),
        ]
    }

    async fn run_action(&self, tool: &str, input: &Value) -> CResult<String> {
        match tool {
            "github_review_pr" => {
                let (repo, number) = target(input)?;
                let event = super::text(input, "event").to_uppercase();
                if !["APPROVE", "REQUEST_CHANGES", "COMMENT"].contains(&event.as_str()) {
                    return Err(ConnectorError::new("The review action must be APPROVE, REQUEST_CHANGES, or COMMENT."));
                }
                let body = field(input, "body");
                if event != "APPROVE" && body.is_none() {
                    return Err(ConnectorError::new("A comment body is required for this review action."));
                }
                let mut payload = json!({"event": event});
                if let Some(b) = body {
                    payload["body"] = json!(b);
                }
                self.send("POST", &format!("/repos/{repo}/pulls/{number}/reviews"), payload, input).await?;
                Ok(match event.as_str() {
                    "APPROVE" => format!("Goedgekeurd: {repo}#{number}"),
                    "REQUEST_CHANGES" => format!("Wijzigingen gevraagd op {repo}#{number}"),
                    _ => format!("Review geplaatst op {repo}#{number}"),
                })
            }
            "github_comment_pr" | "github_comment_issue" => {
                let (repo, number) = target(input)?;
                let body = field(input, "body").ok_or_else(|| ConnectorError::new("Comment text is missing."))?;
                let result = self.send("POST", &format!("/repos/{repo}/issues/{number}/comments"), json!({"body": body}), input).await?;
                Ok(format!(
                    "Reactie geplaatst op {repo}#{number}{}",
                    result["html_url"].as_str().map(|u| format!(" · {u}")).unwrap_or_default()
                ))
            }
            "github_merge_pr" => {
                let (repo, number) = target(input)?;
                let method = field(input, "method").unwrap_or_else(|| "merge".into()).to_lowercase();
                if !["merge", "squash", "rebase"].contains(&method.as_str()) {
                    return Err(ConnectorError::new("The method must be merge, squash, or rebase."));
                }
                // `sha` (set by the pull request view, not offered to the brain) merges only the head that was shown:
                // when someone pushed since, GitHub refuses instead of merging commits nobody looked at.
                let sha = field(input, "sha");
                let (_, token) = self.credentials(input)?;
                let body = pulls::merge_body(&method, sha.as_deref());
                let url = format!("{}/repos/{repo}/pulls/{number}/merge", api());
                let (status, bytes) = self.env.http.send("PUT", &url, &headers(&token), Some(&body), "GitHub").await?;
                let result: Value = serde_json::from_slice(&bytes).unwrap_or(json!({}));
                if !(200..300).contains(&status) || result["merged"] == json!(false) {
                    return Err(pulls::merge_error(status, &result));
                }
                let merged = result["sha"].as_str().map(|s| format!(" · {}", &s[..s.len().min(7)])).unwrap_or_default();
                Ok(format!("Samengevoegd ({method}): {repo}#{number}{merged}"))
            }
            "github_close_pr" => {
                let (repo, number) = target(input)?;
                self.send("PATCH", &format!("/repos/{repo}/pulls/{number}"), json!({"state": "closed"}), input).await?;
                Ok(format!("Gesloten: {repo}#{number}"))
            }
            "github_create_issue" => {
                let repo = super::text(input, "repo").trim().to_string();
                if !is_repository(&repo) {
                    return Err(ConnectorError::new("The repository must be owner/name."));
                }
                let title = field(input, "title").ok_or_else(|| ConnectorError::new("Title is missing."))?;
                let mut payload = json!({"title": title});
                if let Some(b) = field(input, "body") {
                    payload["body"] = json!(b);
                }
                let l = labels(input);
                if !l.is_empty() {
                    payload["labels"] = json!(l);
                }
                let result = self.send("POST", &format!("/repos/{repo}/issues"), payload, input).await?;
                Ok(format!(
                    "Issue aangemaakt: {repo}{}{}",
                    int(&result["number"]).map(|n| format!("#{n}")).unwrap_or_default(),
                    result["html_url"].as_str().map(|u| format!(" · {u}")).unwrap_or_default()
                ))
            }
            "github_update_issue" => {
                let (repo, number) = target(input)?;
                let mut payload = serde_json::Map::new();
                if let Some(state) = field(input, "state") {
                    if state != "open" && state != "closed" {
                        return Err(ConnectorError::new("Status must be open or closed."));
                    }
                    payload.insert("state".into(), json!(state));
                }
                if let Some(t) = field(input, "title") {
                    payload.insert("title".into(), json!(t));
                }
                let l = labels(input);
                if payload.is_empty() && l.is_empty() {
                    return Err(ConnectorError::new("There is nothing to update."));
                }
                if !payload.is_empty() {
                    self.send("PATCH", &format!("/repos/{repo}/issues/{number}"), Value::Object(payload), input).await?;
                }
                if !l.is_empty() {
                    self.send("POST", &format!("/repos/{repo}/issues/{number}/labels"), json!({"labels": l}), input).await?;
                }
                Ok(format!("Bijgewerkt: {repo}#{number}"))
            }
            _ => Err(ConnectorError::new(format!("Onbekende actie {tool}."))),
        }
    }

    // Voor de werkruimte

    /// Probeert de accounts op volgorde: het eerste met toegang tot de repository opent de pull request.
    pub async fn create_pull_request(&self, repo: &str, title: &str, body: &str, head: &str, base: &str, draft: bool) -> CResult<String> {
        let tokens = self.tokens();
        if tokens.is_empty() {
            return Err(ConnectorError::not_set_up("GitHub"));
        }
        let mut last = ConnectorError::not_set_up("GitHub");
        for token in tokens {
            let payload = json!({"title": title, "body": body, "head": head, "base": base, "draft": draft});
            match self.env.http.send("POST", &format!("{}/repos/{repo}/pulls", api()), &headers(&token), Some(&payload), "GitHub").await {
                Ok((status, bytes)) => {
                    let object: Value = serde_json::from_slice(&bytes).unwrap_or(json!({}));
                    if (200..300).contains(&status) {
                        if let Some(url) = object["html_url"].as_str() {
                            return Ok(url.to_string());
                        }
                    }
                    let mut message =
                        object["message"].as_str().map(str::to_string).unwrap_or_else(|| format!("GitHub returned an error ({status})."));
                    let details: Vec<&str> = list(&object["errors"]).iter().filter_map(|e| e["message"].as_str()).collect();
                    if !details.is_empty() {
                        message.push(' ');
                        message.push_str(&details.join(" "));
                    }
                    last = ConnectorError::new(format!("GitHub: {message}"));
                }
                Err(e) => last = e,
            }
        }
        Err(last)
    }

    /// The pull requests of every account (the list under Agents › Pull requests): one GraphQL request per account for
    /// yours and your reviews, and one for the watched organizations and repositories.
    pub async fn pull_request_list(&self, watching: &[String]) -> PullRequestList {
        let available = self.env.store.is_on(ID) && !self.accounts().is_empty();
        if !available {
            return PullRequestList { available, accounts: vec![] };
        }
        let targets: Vec<pulls::Target> = self
            .accounts()
            .into_iter()
            .filter_map(|account| {
                let token = self.env.secret(&account.key("token"))?;
                Some(pulls::Target {
                    id: account.id.clone(),
                    name: account.name(),
                    login: account.identity.clone().unwrap_or_default().trim_start_matches('@').to_string(),
                    token,
                })
            })
            .collect();
        PullRequestList { available, accounts: pulls::load(&self.env, &targets, watching).await }
    }

    /// The id and token of the account with this id; without one (or when it lost its token) the first account that
    /// has a token, so a pull request is read and merged with the account it was listed under.
    pub fn token_for(&self, account_id: Option<&str>) -> Option<(String, String)> {
        if !self.env.store.is_on(ID) {
            return None;
        }
        let available = self.accounts();
        let chosen = account_id.and_then(|id| available.iter().find(|a| a.id == id)).or(available.first())?;
        Some((chosen.id.clone(), self.env.secret(&chosen.key("token"))?))
    }
}

#[async_trait]
impl Connector for GitHub {
    fn id(&self) -> String {
        ID.into()
    }

    fn title(&self) -> String {
        "GitHub".into()
    }

    fn configured(&self) -> bool {
        !self.accounts().is_empty()
    }

    fn active(&self) -> bool {
        self.configured() && self.env.store.is_on(ID)
    }

    fn status(&self) -> ConnectorStatus {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn refresh_interval(&self) -> u64 {
        180
    }

    async fn refresh(&self) {
        let available = self.accounts();
        if !self.env.store.is_on(ID) || available.is_empty() {
            self.snapshots.lock().unwrap_or_else(|e| e.into_inner()).clear();
            *self.status.lock().unwrap_or_else(|e| e.into_inner()) = ConnectorStatus::default();
            return;
        }
        let mut fresh = HashMap::new();
        let mut failures = vec![];
        let mut kind = None;
        for account in &available {
            let Some(token) = self.env.secret(&account.key("token")) else { continue };
            match self.fetch(&token).await {
                Ok(s) => {
                    accounts::set_identity(&self.env.store, &account.id, Some(format!("@{}", s.login)));
                    fresh.insert(account.id.clone(), s);
                }
                Err(e) => {
                    kind.get_or_insert(e.kind);
                    failures.push(if available.len() > 1 { format!("{}: {}", account.name(), e.message) } else { e.message });
                }
            }
        }
        let first = available.iter().find_map(|a| fresh.get(&a.id).cloned());
        *self.snapshots.lock().unwrap_or_else(|e| e.into_inner()) = fresh;
        match first {
            Some(s) => {
                self.apply(&s);
                if !failures.is_empty() {
                    self.status.lock().unwrap_or_else(|e| e.into_inner()).detail = failures.join(" · ");
                }
            }
            None => {
                let error = ConnectorError::kind(failures.join(" · "), kind.unwrap_or_default());
                self.status.lock().unwrap_or_else(|e| e.into_inner()).fail(&error);
            }
        }
    }

    fn context_lines(&self) -> Vec<String> {
        if !self.status().is_ok() || !self.env.store.is_on(ID) {
            return vec![];
        }
        let available = self.accounts();
        let snapshots = self.snapshots.lock().unwrap_or_else(|e| e.into_inner());
        let mut lines = vec![];
        for account in &available {
            let Some(s) = snapshots.get(&account.id) else { continue };
            let who = if available.len() > 1 {
                format!("GitHub account \"{}\" (@{})", account.name(), s.login)
            } else {
                format!("GitHub (@{})", s.login)
            };
            lines.push(format!(
                "{who}: {} authored by you, {}.",
                plural(s.mine_total as usize, "open PR", "open PRs"),
                plural(s.review_total as usize, "review request", "review requests")
            ));
            lines.extend(s.reviews.iter().take(3).map(|p| format!("Review requested: {} '{}'", p.reference(), short(&p.title, 60))));
            lines.extend(
                s.mine
                    .iter()
                    .filter(|p| p.ci == Ci::Failing)
                    .take(3)
                    .map(|p| format!("CI failing on {} '{}'", p.reference(), short(&p.title, 60))),
            );
            let room = 8usize.saturating_sub(lines.len()).min(2);
            lines.extend(
                s.mine
                    .iter()
                    .filter(|p| p.ci != Ci::Failing)
                    .take(room)
                    .map(|p| format!("Open PR authored by you: {} '{}'", p.reference(), short(&p.title, 60))),
            );
        }
        lines.truncate(12);
        lines
    }

    /// Met meer accounts krijgt elke tool een veld `account`; de accounts die deze chat niet mag, vallen weg.
    fn tools(self: Arc<Self>, scope: &Scope) -> Vec<LoopTool> {
        if !self.active() {
            return vec![];
        }
        let all = self.accounts();
        let names: Vec<String> = all.iter().map(ServiceAccount::name).collect();
        let allowed = accounts::allowed_names(&all, &scope.excluded_accounts);
        self.specs()
            .into_iter()
            .filter_map(|mut tool| {
                tool.schema = accounts::with_account(&tool.schema, &names, tool.kind == crate::brain::ToolKind::Action, "GitHub");
                let (schema, only) = accounts::restrict_schema(&tool.schema, &allowed)?;
                tool.schema = schema;
                if let Some(only) = only {
                    // Eén account over voor deze chat: dat wordt ingevuld.
                    let run = tool.run.clone();
                    tool.run = Arc::new(move |mut input: Value| {
                        input["account"] = json!(only.clone());
                        run(input)
                    });
                }
                Some(tool)
            })
            .collect()
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        let line = match tool {
            "github_review_pr" => {
                let note = field(input, "body").map(|b| format!(" · {}", short(&b, 50))).unwrap_or_default();
                match super::text(input, "event").to_uppercase().as_str() {
                    "APPROVE" => format!("GitHub: keur {} goed{note}", reference(input)),
                    "REQUEST_CHANGES" => format!("GitHub: vraag wijzigingen op {}{note}", reference(input)),
                    _ => format!("GitHub: review op {}{note}", reference(input)),
                }
            }
            "github_comment_pr" | "github_comment_issue" => {
                format!("GitHub: reactie op {} · {}", reference(input), short(super::text(input, "body"), 50))
            }
            "github_merge_pr" => format!(
                "GitHub: voeg {} samen ({})",
                reference(input),
                field(input, "method").unwrap_or_else(|| "merge".into()).to_lowercase()
            ),
            "github_close_pr" => format!("GitHub: sluit {}", reference(input)),
            "github_create_issue" => {
                format!("GitHub: issue in {} · {}", super::text(input, "repo"), short(super::text(input, "title"), 60))
            }
            "github_update_issue" => {
                let mut parts = vec![];
                if let Some(state) = field(input, "state") {
                    parts.push(if state == "closed" { "sluiten".to_string() } else { "heropenen".to_string() });
                }
                if let Some(t) = field(input, "title") {
                    parts.push(format!("titel \"{}\"", short(&t, 40)));
                }
                if let Some(l) = field(input, "labels") {
                    parts.push(format!("labels {l}"));
                }
                format!("GitHub: {} {}", reference(input), if parts.is_empty() { "bijwerken".into() } else { parts.join(", ") })
            }
            _ => return None,
        };
        Some(match field(input, "account") {
            Some(account) => format!("{line} · {account}"),
            None => line,
        })
    }

    async fn execute(&self, tool: &str, input: &Value) -> Option<CResult<String>> {
        if !tool.starts_with("github_")
            || matches!(tool, "github_overview" | "github_pr_details" | "github_search" | "github_issue_details")
        {
            return None;
        }
        Some(self.run_action(tool, input).await)
    }
}

// Koppel met GitHub

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Poll {
    Token(String),
    Pending,
    SlowDown,
}

async fn post_form(env: &Env, url: &str, items: &[(&str, &str)]) -> CResult<Value> {
    let body = super::oauth::form_body(items);
    let response = env
        .http
        .client
        .post(url)
        .header("Accept", "application/json")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|e| super::network_error(e, "GitHub"))?;
    response.json().await.map_err(|_| ConnectorError::new("GitHub gaf een ongeldig antwoord."))
}

fn message(json: &Value) -> String {
    json["error_description"].as_str().unwrap_or("GitHub gaf een fout.").to_string()
}

/// De "device flow": Nook vraagt een code, de gebruiker bevestigt hem op github.com. Geen geheim in de app nodig.
pub async fn request_code(env: &Env, client_id: &str) -> CResult<DeviceCode> {
    let json =
        post_form(env, &format!("{}/login/device/code", login_base()), &[("client_id", client_id), ("scope", "repo read:user")]).await?;
    let (Some(device_code), Some(user_code), Some(uri)) =
        (json["device_code"].as_str(), json["user_code"].as_str(), json["verification_uri"].as_str())
    else {
        return Err(ConnectorError::new(message(&json)));
    };
    Ok(DeviceCode {
        device_code: device_code.into(),
        user_code: user_code.into(),
        verification_uri: uri.into(),
        expires_in: int(&json["expires_in"]).unwrap_or(900) as u64,
        interval: int(&json["interval"]).unwrap_or(5) as u64,
    })
}

pub async fn poll(env: &Env, client_id: &str, device_code: &str) -> CResult<Poll> {
    let json = post_form(
        env,
        &format!("{}/login/oauth/access_token", login_base()),
        &[("client_id", client_id), ("device_code", device_code), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")],
    )
    .await?;
    if let Some(token) = json["access_token"].as_str().filter(|t| !t.is_empty()) {
        return Ok(Poll::Token(token.into()));
    }
    match json["error"].as_str() {
        Some("authorization_pending") => Ok(Poll::Pending),
        Some("slow_down") => Ok(Poll::SlowDown),
        Some("access_denied") => Err(ConnectorError::kind("Je hebt de toestemming op GitHub geweigerd.", ErrorKind::Auth)),
        Some("expired_token") => Err(ConnectorError::new("De code is verlopen. Probeer het opnieuw.")),
        _ => Err(ConnectorError::new(message(&json))),
    }
}

/// Wacht tot de gebruiker de code bevestigde en bewaart het token bij `account` (in de kluis).
pub async fn finish_device_flow(env: &Env, client_id: &str, code: &DeviceCode, account: &str) -> CResult<()> {
    let mut interval = code.interval.max(5);
    let deadline = std::time::Instant::now() + Duration::from_secs(code.expires_in);
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_secs(interval)).await;
        match poll(env, client_id, &code.device_code).await? {
            Poll::Token(token) => {
                return env
                    .secrets
                    .write(account, &token)
                    .map_err(|_| ConnectorError::new("De kluis weigerde de sleutel. Probeer het nog eens."));
            }
            Poll::Pending => continue,
            Poll::SlowDown => interval += 5,
        }
    }
    Err(ConnectorError::new("De code is verlopen. Probeer het opnieuw."))
}

/// Neemt de login van de GitHub CLI over (`gh auth token`): geen OAuth-app nodig. Alleen op de desktop.
pub fn cli_token() -> CResult<String> {
    if cfg!(any(target_os = "android", target_os = "ios")) {
        return Err(ConnectorError::new("De GitHub CLI bestaat niet op dit apparaat. Plak een token."));
    }
    let home = dirs::home_dir().unwrap_or_default();
    let mut dirs_list: Vec<std::path::PathBuf> =
        vec!["/opt/homebrew/bin".into(), "/usr/local/bin".into(), "/usr/bin".into(), "/bin".into(), home.join(".local/bin")];
    if cfg!(target_os = "windows") {
        dirs_list = vec![
            std::path::PathBuf::from(std::env::var("ProgramFiles").unwrap_or_else(|_| "C:\\Program Files".into())).join("GitHub CLI"),
            home.join("AppData\\Local\\Programs\\GitHub CLI"),
            home.join("scoop\\shims"),
        ];
    }
    let exe = if cfg!(target_os = "windows") { "gh.exe" } else { "gh" };
    let path_dirs: Vec<std::path::PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    let gh = dirs_list.iter().chain(path_dirs.iter()).map(|d| d.join(exe)).find(|p| p.is_file()).ok_or_else(|| {
        ConnectorError::new("GitHub CLI (gh) niet gevonden. Installeer hem (cli.github.com) en voer `gh auth login` uit.")
    })?;
    let mut cmd = std::process::Command::new(gh);
    cmd.args(["auth", "token"]).env("GH_PROMPT_DISABLED", "1").stdin(std::process::Stdio::null());
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let output = cmd
        .output()
        .map_err(|_| ConnectorError::new("Je bent nog niet ingelogd in gh. Voer `gh auth login` uit en probeer het opnieuw."))?;
    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !output.status.success() || token.is_empty() {
        return Err(ConnectorError::new("Je bent nog niet ingelogd in gh. Voer `gh auth login` uit en probeer het opnieuw."));
    }
    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;
    use crate::connectors::ConnectorStore;
    use crate::secrets::{MemorySecrets, SecretStore};

    fn pr_item(repo: &str, number: i64, title: &str) -> Value {
        json!({"number": number, "title": title, "repository_url": format!("https://api.github.com/repos/{repo}"), "html_url": format!("https://github.com/{repo}/pull/{number}"), "updated_at": "2026-10-18T12:00:00Z"})
    }

    async fn fake() -> TestServer {
        TestServer::start(vec![
            ("GET /user", 200, r#"{"login":"michan"}"#.into()),
            ("GET /search/issues", 200, json!({"total_count": 1, "items": [pr_item("IAMichan/nook", 23, "Tauri-app")]}).to_string()),
            ("GET /repos/IAMichan/nook/pulls/23", 200, r#"{"number":23,"title":"Tauri-app","user":{"login":"michan"},"state":"open","head":{"sha":"abc","ref":"tauri"},"base":{"ref":"main"},"additions":10,"deletions":2,"changed_files":1,"mergeable":true,"html_url":"https://github.com/IAMichan/nook/pull/23","body":"Nieuwe app"}"#.into()),
            ("GET /repos/IAMichan/nook/pulls/23/files", 200, r#"[{"filename":"a.rs","status":"added","additions":10,"deletions":2,"patch":"+fn main() {}"}]"#.into()),
            ("GET /repos/IAMichan/nook/pulls/23/reviews", 200, "[]".into()),
            ("GET /repos/IAMichan/nook/commits/abc/check-runs", 200, r#"{"check_runs":[{"status":"completed","conclusion":"failure"}]}"#.into()),
            ("GET /repos/IAMichan/nook/commits/abc/status", 200, r#"{"total_count":0}"#.into()),
            ("PUT /repos/IAMichan/nook/pulls/23/merge", 200, r#"{"merged":true}"#.into()),
            ("POST /repos/IAMichan/nook/pulls/23/reviews", 422, r#"{"message":"Can not approve your own pull request"}"#.into()),
            ("POST /login/device/code", 200, r#"{"device_code":"d1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.into()),
            ("POST /login/oauth/access_token", 200, r#"{"error":"authorization_pending"}"#.into()),
            // One answer for both GraphQL requests: the list's aliases and the watched ones ("w0" for acme; "w1", for
            // the entry GitHub could not search, is missing).
            ("POST /graphql", 200, r#"{"data":{"viewer":{"login":"michan"},"mine":{"nodes":[{"number":23,"title":"Tauri-app","url":"https://github.com/IAMichan/nook/pull/23","isDraft":false,"updatedAt":"2026-10-18T12:00:00Z","state":"OPEN","author":{"login":"michan"},"repository":{"nameWithOwner":"IAMichan/nook"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}]},"mineClosed":{"nodes":[{"number":20,"title":"Oud","isDraft":false,"updatedAt":"2026-10-10T12:00:00Z","state":"MERGED","author":{"login":"michan"},"repository":{"nameWithOwner":"IAMichan/nook"},"commits":{"nodes":[]}}]},"reviews":{"nodes":[]},"w0":{"nodes":[{"number":5,"title":"Web","isDraft":false,"updatedAt":"2026-10-18T12:00:00Z","state":"OPEN","author":{"login":"ada"},"repository":{"nameWithOwner":"acme/web"},"commits":{"nodes":[]}}]},"w0Closed":{"nodes":[]}}}"#.into()),
        ])
        .await
    }

    // De omgevingsvariabele geldt voor het hele testproces: alle GitHub-tests in één test.
    #[tokio::test]
    async fn github_against_a_fake_api() {
        let server = fake().await;
        std::env::set_var("NOOK_GITHUB_API_URL", server.url(""));
        std::env::set_var("NOOK_GITHUB_LOGIN_URL", server.url(""));
        let secrets = Arc::new(MemorySecrets::default());
        let env = Env::new(secrets.clone(), Arc::new(ConnectorStore::in_memory()));
        let github = GitHub::new(env.clone());
        assert!(!github.configured());
        secrets.write(TOKEN_ACCOUNT, "ghp_nep").unwrap();
        assert!(github.active());

        github.refresh().await;
        let status = github.status();
        assert!(status.is_ok(), "{status:?}");
        assert_eq!(status.headline, "1 open PR's · 1 reviews voor jou");
        assert_eq!(status.detail, "CI faalt bij IAMichan/nook#23");
        assert!(status.needs_attention);
        assert_eq!(accounts::accounts(&env.store, ID)[0].identity.as_deref(), Some("@michan"));
        let context = github.context_lines();
        assert_eq!(context[0], "GitHub (@michan): 1 open PR authored by you, 1 review request.");
        let sent = server.requests();
        assert_eq!(sent[0].header("authorization"), Some("Bearer ghp_nep"));
        assert_eq!(sent[0].header("x-github-api-version"), Some("2022-11-28"));

        let details = github.pull_request_details("IAMichan/nook", 23, &json!({})).await.unwrap();
        assert!(details.contains("status: open · no conflicts · CI failing"), "{details}");
        assert!(details.contains("+fn main() {}"));

        // Acties lopen alleen via execute (na Uitvoeren), met GitHubs eigen foutmelding.
        let tools = github.clone().tools(&Scope::default());
        let merge = tools.iter().find(|t| t.name == "github_merge_pr").unwrap();
        assert_eq!(merge.kind, crate::brain::ToolKind::Action);
        assert_eq!(
            github.execute("github_merge_pr", &json!({"repo": "IAMichan/nook", "number": 23, "method": "squash"})).await.unwrap().unwrap(),
            "Samengevoegd (squash): IAMichan/nook#23"
        );
        let refused = github
            .execute("github_review_pr", &json!({"repo": "IAMichan/nook", "number": 23, "event": "APPROVE"}))
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(refused.message, "GitHub: Can not approve your own pull request");
        assert!(github.execute("github_review_pr", &json!({"repo": "x/../y", "number": 1, "event": "APPROVE"})).await.unwrap().is_err());
        assert_eq!(
            github.summarize("github_merge_pr", &json!({"repo": "IAMichan/nook", "number": 23})).as_deref(),
            Some("GitHub: voeg IAMichan/nook#23 samen (merge)")
        );

        // Een tweede account: tools krijgen een veld account, acties maken het verplicht.
        let work = accounts::add(&env.store, ID, "Werk");
        secrets.write(&work.key("token"), "ghp_werk").unwrap();
        let tools = github.clone().tools(&Scope::default());
        let merge = tools.iter().find(|t| t.name == "github_merge_pr").unwrap();
        assert_eq!(merge.schema["properties"]["account"]["enum"], json!(["@michan", "Werk"]));
        assert!(merge.schema["required"].as_array().unwrap().contains(&json!("account")));
        // Deze chat mag Werk niet: het veld verdwijnt, het hoofdaccount wordt ingevuld.
        let scope = Scope { excluded_accounts: [work.id.clone()].into() };
        let tools = github.clone().tools(&scope);
        let overview = tools.iter().find(|t| t.name == "github_overview").unwrap();
        assert!(overview.schema.pointer("/properties/account").is_none());
        let unknown = github
            .execute("github_close_pr", &json!({"repo": "IAMichan/nook", "number": 23, "account": "Privé"}))
            .await
            .unwrap()
            .unwrap_err();
        assert!(unknown.message.starts_with("There is no GitHub account \"Privé\""));

        // The pull request list for all accounts, with a watched organization; GitHub could not search "typo".
        let watching = vec!["acme".to_string(), "typo".to_string()];
        let list = github.pull_request_list(&watching).await;
        assert!(list.available);
        assert_eq!(list.accounts.len(), 2);
        let first = &list.accounts[0];
        assert_eq!((first.login.as_str(), first.mine[0].ci, first.mine[1].state), ("michan", Ci::Failing, pulls::PullState::Merged));
        assert_eq!(first.watched.iter().map(|i| i.id()).collect::<Vec<_>>(), vec!["acme/web#5"]);
        assert_eq!(first.unreadable, vec!["typo"]);
        // Both accounts see the same watched pull request: it shows once, under the first.
        assert!(list.accounts[1].watched.is_empty());
        let watched_request = server.requests().into_iter().find(|r| r.body.contains("NookWatchedPullRequests")).unwrap();
        assert!(watched_request.body.contains("org:acme"), "{}", watched_request.body);

        // One pull request in full, with the token of the account it was listed under.
        assert_eq!(github.token_for(Some(&work.id)), Some((work.id.clone(), "ghp_werk".to_string())));
        assert_eq!(github.token_for(Some("github.gone")).map(|t| t.0), Some(ID.to_string()));
        let detail = pulls::load_detail(&env, "ghp_werk", "IAMichan/nook", 23).await.unwrap();
        assert_eq!((detail.head_sha.as_str(), detail.check_summary, detail.merge_note.as_deref()), ("abc", Ci::Failing, Some("unstable")));
        assert_eq!(detail.files[0].patch.as_deref(), Some("+fn main() {}"));
        assert_eq!(detail.body, "Nieuwe app");
        assert!(server.requests().iter().any(|r| r.path.starts_with("/repos/IAMichan/nook/pulls/23/files?per_page=100&page=1")
            && r.header("authorization") == Some("Bearer ghp_werk")));

        // Merging from the view sends the head it showed, so GitHub refuses when someone pushed since.
        let merged = github
            .execute(
                "github_merge_pr",
                &json!({"repo": "IAMichan/nook", "number": 23, "method": "merge", "sha": "abc", "account": work.id}),
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(merged, "Samengevoegd (merge): IAMichan/nook#23");
        let put = server.requests().into_iter().rev().find(|r| r.method == "PUT").unwrap();
        assert_eq!(serde_json::from_str::<Value>(&put.body).unwrap(), json!({"merge_method": "merge", "sha": "abc"}));
        assert_eq!(put.header("authorization"), Some("Bearer ghp_werk"));

        // Koppel met GitHub: de code komt, het wachten gaat door tot GitHub ja zegt.
        let code = request_code(&env, "client").await.unwrap();
        assert_eq!(code.user_code, "ABCD-1234");
        assert_eq!(poll(&env, "client", &code.device_code).await.unwrap(), Poll::Pending);
        std::env::remove_var("NOOK_GITHUB_API_URL");
        std::env::remove_var("NOOK_GITHUB_LOGIN_URL");
    }

    #[test]
    fn repositories() {
        assert!(is_repository("IAMichan/nook"));
        assert!(!is_repository("nook"));
        assert!(!is_repository("a/b/c"));
        assert!(!is_repository("../etc"));
    }
}
