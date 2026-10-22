//! Waar een repository woont en wat je ermee kunt (`SourceControlHost`, `GitQuickActions` en het aanmaken van een pull
//! request uit `CloudConnectors` op de Mac): de host herkennen aan de remote (zonder ooit inloggegevens in een link te
//! zetten), links naar vergelijken en een nieuwe pull request, de ene git-knop, en een pull request op
//! GitHub met je token uit de kluis.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::git::{Git, Result as GitResult};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "host")]
pub enum SourceControlHost {
    Github,
    Gitlab,
    Bitbucket,
    Gitea,
    Forgejo,
    AzureDevOps,
    Gitcafe,
    Unknown(String),
}

impl SourceControlHost {
    pub fn key(&self) -> String {
        match self {
            Self::Github => "github".into(),
            Self::Gitlab => "gitlab".into(),
            Self::Bitbucket => "bitbucket".into(),
            Self::Gitea => "gitea".into(),
            Self::Forgejo => "forgejo".into(),
            Self::AzureDevOps => "azure-devops".into(),
            Self::Gitcafe => "gitcafe".into(),
            Self::Unknown(h) => format!("unknown:{h}"),
        }
    }

    pub fn from_key(key: &str) -> Self {
        match key {
            "github" => Self::Github,
            "gitlab" => Self::Gitlab,
            "bitbucket" => Self::Bitbucket,
            "gitea" => Self::Gitea,
            "forgejo" => Self::Forgejo,
            "azure-devops" => Self::AzureDevOps,
            "gitcafe" => Self::Gitcafe,
            other => Self::Unknown(other.strip_prefix("unknown:").unwrap_or(other).into()),
        }
    }

    pub fn name(&self) -> String {
        match self {
            Self::Github => "GitHub".into(),
            Self::Gitlab => "GitLab".into(),
            Self::Bitbucket => "Bitbucket".into(),
            Self::Gitea => "Gitea".into(),
            Self::Forgejo => "Forgejo".into(),
            Self::AzureDevOps => "Azure DevOps".into(),
            Self::Gitcafe => "git.cafe".into(),
            Self::Unknown(h) => h.clone(),
        }
    }

    /// GitLab noemt het een merge request.
    pub fn uses_merge_requests(&self) -> bool {
        *self == Self::Gitlab
    }

    /// `host` in kleine letters, zonder poort.
    pub fn classify(host: &str) -> Self {
        let labels: Vec<&str> = host.split('.').collect();
        let label = |name: &str| labels.contains(&name) || host.contains(name);
        if host == "git.cafe" || host == "staging.git.cafe" {
            return Self::Gitcafe;
        }
        if host == "codeberg.org" || label("forgejo") {
            return Self::Forgejo;
        }
        if label("gitea") {
            return Self::Gitea;
        }
        if host == "github.com" || host.ends_with(".ghe.com") || label("github") {
            return Self::Github;
        }
        if host == "gitlab.com" || label("gitlab") {
            return Self::Gitlab;
        }
        if host == "dev.azure.com" || host.ends_with(".dev.azure.com") || host.ends_with(".visualstudio.com") {
            return Self::AzureDevOps;
        }
        if host == "bitbucket.org" || label("bitbucket") {
            return Self::Bitbucket;
        }
        Self::Unknown(host.into())
    }
}

/// Een repository bij een host, zonder inloggegevens: niets hier kan een token in een link lekken.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteRepository {
    pub host: SourceControlHost,
    /// Kleine letters, geen poort.
    pub host_name: String,
    /// "eigenaar/repo", "a/b/c" voor GitLab-subgroepen, "org/project/_git/repo" voor Azure DevOps.
    pub path: String,
    /// `schema://host[:poort]` van de webpagina's. SSH zegt niets over de webpoort, dus https.
    pub web_origin: String,
}

const REMOTE_SCHEMES: [&str; 6] = ["http", "https", "ssh", "git", "git+ssh", "ssh+git"];

impl RemoteRepository {
    pub fn segments(&self) -> Vec<&str> {
        self.path.split('/').collect()
    }

    pub fn name(&self) -> &str {
        self.path.rsplit('/').next().unwrap_or(&self.path)
    }

    /// "eigenaar/repo"; Azure laat `_git` weg.
    pub fn display_name(&self) -> String {
        self.segments().into_iter().filter(|s| *s != "_git").collect::<Vec<_>>().join("/")
    }

    pub fn detect(remote_url: &str) -> Option<Self> {
        let text = remote_url.trim();
        if text.is_empty() {
            return None;
        }
        let mut scheme = "https".to_string();
        let mut port: Option<u16> = None;
        let host_raw: String;
        let raw_path: String;
        if let Some((s, rest)) = text.split_once("://") {
            let s = s.to_lowercase();
            if !REMOTE_SCHEMES.contains(&s.as_str()) {
                return None;
            }
            scheme = s;
            let (authority, path) = match rest.find('/') {
                Some(i) => (&rest[..i], &rest[i..]),
                None => (rest, ""),
            };
            let host_port = authority.rsplit('@').next().unwrap_or(authority);
            let (h, p) = match host_port.rsplit_once(':') {
                Some((h, p)) if !h.is_empty() && p.chars().all(|c| c.is_ascii_digit()) => (h, p.parse().ok()),
                _ => (host_port, None),
            };
            if h.is_empty() {
                return None;
            }
            host_raw = h.into();
            port = p;
            raw_path = path.split(['?', '#']).next().unwrap_or("").into();
        } else {
            // scp-stijl: [gebruiker@]host:pad. Een kale "C:\map" heeft geen gebruiker en geen punt: geen remote.
            let (left, right) = text.split_once(':')?;
            let has_user = left.contains('@');
            let h = if has_user { left.rsplit('@').next().unwrap_or("") } else { left };
            if h.is_empty()
                || left.contains('/')
                || !(has_user || h.contains('.'))
                || !h.chars().all(|c| c.is_alphanumeric() || "-._".contains(c))
            {
                return None;
            }
            host_raw = h.into();
            raw_path = right.into();
        }
        let host_name = host_raw.to_lowercase();
        let mut parts: Vec<String> = raw_path.split('/').filter(|p| !p.is_empty()).map(str::to_string).collect();
        if parts.is_empty() {
            return None;
        }
        if let Some(last) = parts.last_mut() {
            if last.to_lowercase().ends_with(".git") {
                last.truncate(last.len() - 4);
            }
        }
        if parts.iter().any(|p| p.is_empty() || p == "." || p == "..") {
            return None;
        }
        let host = SourceControlHost::classify(&host_name);
        let web = scheme == "http" || scheme == "https";
        let mut origin = format!("{}://{host_name}", if web { scheme.as_str() } else { "https" });
        if web {
            if let Some(p) = port {
                origin += &format!(":{p}");
            }
        }
        match host {
            SourceControlHost::AzureDevOps => {
                let normalized = azure_path(&host_name, &parts)?;
                return Some(Self {
                    host,
                    host_name: "dev.azure.com".into(),
                    path: normalized.join("/"),
                    web_origin: "https://dev.azure.com".into(),
                });
            }
            SourceControlHost::Gitlab | SourceControlHost::Unknown(_) => {
                if parts.len() < 2 {
                    return None;
                }
            }
            _ => {
                if parts.len() != 2 {
                    return None;
                }
            }
        }
        Some(Self { host, host_name, path: parts.join("/"), web_origin: origin })
    }

    fn repo_base(&self) -> String {
        format!("{}/{}", self.web_origin, encode_path(&self.path))
    }

    pub fn compare_url(&self, base: &str, head: &str) -> Option<String> {
        let (b, h, r) = (encode_path(base), encode_path(head), self.repo_base());
        Some(match self.host {
            SourceControlHost::Github | SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Gitcafe => {
                format!("{r}/compare/{b}...{h}")
            }
            SourceControlHost::Gitlab => format!("{r}/-/compare/{b}...{h}"),
            // Bitbucket Cloud scheidt bron en doel met een gecodeerde regelterugloop.
            SourceControlHost::Bitbucket => format!("{r}/branches/compare/{}%0D{}", encode(head), encode(base)),
            SourceControlHost::AzureDevOps => {
                format!(
                    "{r}/branchCompare{}",
                    query(&[("baseVersion", Some(&format!("GB{base}"))), ("targetVersion", Some(&format!("GB{head}")))])
                )
            }
            SourceControlHost::Unknown(_) => return None,
        })
    }

    /// Vooraf ingevuld waar de host dat kan. `draft` kan alleen als voorvoegsel van de titel (GitLab "Draft: ",
    /// Gitea/Forgejo "WIP: ").
    pub fn new_pull_request_url(&self, base: &str, head: &str, title: Option<&str>, body: Option<&str>, draft: bool) -> Option<String> {
        let (b, h, r) = (encode_path(base), encode_path(head), self.repo_base());
        Some(match self.host {
            SourceControlHost::Github => {
                format!("{r}/compare/{b}...{h}{}", query(&[("expand", Some("1")), ("title", title), ("body", body)]))
            }
            SourceControlHost::Gitlab => {
                let t = title.map(|t| if draft { format!("Draft: {t}") } else { t.to_string() });
                format!(
                    "{r}/-/merge_requests/new{}",
                    query(&[
                        ("merge_request[source_branch]", Some(head)),
                        ("merge_request[target_branch]", Some(base)),
                        ("merge_request[title]", t.as_deref()),
                        ("merge_request[description]", body),
                    ])
                )
            }
            SourceControlHost::Bitbucket => format!("{r}/pull-requests/new{}", query(&[("source", Some(head)), ("dest", Some(base))])),
            SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Gitcafe => {
                let t = title.map(|t| if draft { format!("WIP: {t}") } else { t.to_string() });
                format!("{r}/compare/{b}...{h}{}", query(&[("title", t.as_deref()), ("body", body)]))
            }
            SourceControlHost::AzureDevOps => {
                format!("{r}/pullrequestcreate{}", query(&[("sourceRef", Some(head)), ("targetRef", Some(base))]))
            }
            SourceControlHost::Unknown(_) => return None,
        })
    }

    pub fn pull_request_url(&self, number: u64) -> Option<String> {
        if number == 0 {
            return None;
        }
        let r = self.repo_base();
        Some(match self.host {
            SourceControlHost::Github => format!("{r}/pull/{number}"),
            SourceControlHost::Gitlab => format!("{r}/-/merge_requests/{number}"),
            SourceControlHost::Bitbucket => format!("{r}/pull-requests/{number}"),
            SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Gitcafe => format!("{r}/pulls/{number}"),
            SourceControlHost::AzureDevOps => format!("{r}/pullrequest/{number}"),
            SourceControlHost::Unknown(_) => return None,
        })
    }

    pub fn branch_url(&self, branch: &str) -> Option<String> {
        let (b, r) = (encode_path(branch), self.repo_base());
        Some(match self.host {
            SourceControlHost::Github => format!("{r}/tree/{b}"),
            SourceControlHost::Gitlab => format!("{r}/-/tree/{b}"),
            SourceControlHost::Bitbucket => format!("{r}/src/{b}"),
            SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Gitcafe => format!("{r}/src/branch/{b}"),
            SourceControlHost::AzureDevOps => format!("{r}{}", query(&[("version", Some(&format!("GB{branch}")))])),
            SourceControlHost::Unknown(_) => return None,
        })
    }
}

/// Elke Azure DevOps-schrijfwijze wordt `org/project/_git/repo` op dev.azure.com.
fn azure_path(host_name: &str, parts: &[String]) -> Option<Vec<String>> {
    if parts.first().map(String::as_str) == Some("v3")
        && parts.len() == 4
        && (host_name.starts_with("ssh.") || host_name.starts_with("vs-ssh."))
    {
        return Some(vec![parts[1].clone(), parts[2].clone(), "_git".into(), parts[3].clone()]);
    }
    let git = parts.iter().position(|p| p == "_git")?;
    if git + 2 != parts.len() || git < 1 {
        return None;
    }
    if host_name.ends_with(".visualstudio.com") {
        let org = host_name.split('.').next()?.to_string();
        let mut project: Vec<String> = parts[..git].to_vec();
        if project.first().is_some_and(|p| p.eq_ignore_ascii_case("defaultcollection")) {
            project.remove(0);
        }
        if project.is_empty() {
            return None;
        }
        let mut out = vec![org];
        out.extend(project);
        out.push("_git".into());
        out.push(parts[git + 1].clone());
        return Some(out);
    }
    Some(parts.to_vec())
}

/// Alles behalve de onbeschermde tekens wordt gecodeerd, zodat `#`, `&`, `?`, spaties en regeleinden in een titel of
/// branch nooit een parameter afbreken.
pub fn encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out += &format!("%{b:02X}");
        }
    }
    out
}

/// Een branchnaam in een pad houdt zijn schuine strepen.
fn encode_path(value: &str) -> String {
    value.split('/').map(encode).collect::<Vec<_>>().join("/")
}

fn query(items: &[(&str, Option<&str>)]) -> String {
    let pairs: Vec<String> = items
        .iter()
        .filter_map(|(k, v)| v.filter(|v| !v.is_empty() || *k == "expand").map(|v| format!("{}={}", encode(k), encode(v))))
        .collect();
    if pairs.is_empty() {
        String::new()
    } else {
        format!("?{}", pairs.join("&"))
    }
}

// MARK: De git-knop

/// De ene git-knop: wat hij doet hangt af van de stand van de branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuickAction {
    Commit,
    CommitPush,
    CommitPushPr,
    Push,
    PushPr,
    CreatePr,
    Pull,
}

impl QuickAction {
    pub fn commits(self) -> bool {
        matches!(self, Self::Commit | Self::CommitPush | Self::CommitPushPr)
    }

    pub fn pushes(self) -> bool {
        !matches!(self, Self::Commit | Self::Pull)
    }

    pub fn proposes(self) -> bool {
        matches!(self, Self::CommitPushPr | Self::PushPr | Self::CreatePr)
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Commit => "Commit",
            Self::CommitPush => "Commit & push",
            Self::CommitPushPr => "Commit, push & PR",
            Self::Push => "Push",
            Self::PushPr => "Push & maak PR",
            Self::CreatePr => "Maak PR",
            Self::Pull => "Pull",
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickState {
    pub has_changes: bool,
    pub branch: Option<String>,
    pub is_default_branch: bool,
    pub has_upstream: bool,
    pub has_remote: bool,
    pub ahead: u32,
    pub behind: u32,
    /// Commits op deze branch die de basis niet heeft (voor een branch die nooit gepusht is).
    pub ahead_of_base: u32,
    pub has_open_pull_request: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuickReason {
    Detached,
    Diverged,
    NoRemote,
    NothingToPush,
    UpToDate,
}

impl QuickReason {
    pub fn message(self) -> &'static str {
        match self {
            Self::Detached => "Niet op een branch (detached HEAD). Maak eerst een branch.",
            Self::Diverged => "De branch is uiteengelopen met de remote. Eerst rebasen of mergen.",
            Self::NoRemote => "Deze repository heeft geen remote om naar te pushen.",
            Self::NothingToPush => "Geen eigen commits om te pushen.",
            Self::UpToDate => "De branch is bij. Niets te doen.",
        }
    }
}

/// De actie, of waarom er niets te doen is (`resolveQuickAction`).
pub fn resolve(state: &QuickState) -> Result<QuickAction, QuickReason> {
    if state.branch.is_none() {
        return Err(QuickReason::Detached);
    }
    let finished = state.has_open_pull_request || state.is_default_branch;
    if state.has_changes {
        if !state.has_remote {
            return Ok(QuickAction::Commit);
        }
        return Ok(if finished { QuickAction::CommitPush } else { QuickAction::CommitPushPr });
    }
    if state.ahead > 0 && state.behind > 0 {
        return Err(QuickReason::Diverged);
    }
    if state.behind > 0 {
        return Ok(QuickAction::Pull);
    }
    if !state.has_remote {
        return Err(QuickReason::NoRemote);
    }
    if state.ahead > 0 || (!state.has_upstream && state.ahead_of_base > 0) {
        return Ok(if finished { QuickAction::Push } else { QuickAction::PushPr });
    }
    if !state.has_upstream {
        return Err(QuickReason::NothingToPush);
    }
    if !finished && state.ahead_of_base > 0 {
        return Ok(QuickAction::CreatePr);
    }
    Err(QuickReason::UpToDate)
}

impl Git {
    /// `git add -A` en een commit met onderwerp en optionele tekst. Geeft de korte hash.
    pub fn commit_all(&self, dir: &str, subject: &str, body: &str) -> GitResult<String> {
        self.run(&["add", "-A"], dir)?;
        let body = body.trim();
        let mut args = vec!["commit", "-m", subject];
        if !body.is_empty() {
            args.extend(["-m", body]);
        }
        self.run_with(&args, dir, std::time::Duration::from_secs(120), &[0], &Default::default())?;
        Ok(self.run(&["rev-parse", "--short", "HEAD"], dir)?.trim().to_string())
    }

    /// Alleen fast-forward: nooit een merge-commit of rebase achter je rug.
    pub fn pull_fast_forward(&self, dir: &str) -> GitResult<()> {
        self.run_with(&["pull", "--ff-only"], dir, std::time::Duration::from_secs(300), &[0], &Default::default()).map(|_| ())
    }

    /// Commits op HEAD die `base` niet heeft; `None` als de basis onbekend is.
    pub fn commits_ahead(&self, dir: &str, base: &str) -> Option<u32> {
        self.run(&["rev-list", "--count", &format!("{base}..HEAD")], dir).ok()?.trim().parse().ok()
    }

    /// De standaardbranch voor pull requests: waar HEAD van de remote naar wijst, anders `main` of `master`. Nooit de
    /// huidige branch.
    pub fn default_branch(&self, dir: &str, remote: &str) -> Option<String> {
        if let Ok(text) = self.run(&["symbolic-ref", "--quiet", "--short", &format!("refs/remotes/{remote}/HEAD")], dir) {
            let name = text.trim();
            if let Some(b) = name.strip_prefix(&format!("{remote}/")).filter(|b| !b.is_empty()) {
                return Some(b.into());
            }
        }
        ["main", "master"]
            .into_iter()
            .find(|b| self.ref_exists(&format!("refs/heads/{b}"), dir) || self.ref_exists(&format!("refs/remotes/{remote}/{b}"), dir))
            .map(str::to_string)
    }

    /// Waartegen vergeleken wordt: de remote-branch als die er is (`origin/main`), anders de lokale.
    pub fn comparison_base(&self, dir: &str, base: &str, remote: &str) -> String {
        if self.ref_exists(&format!("refs/remotes/{remote}/{base}"), dir) {
            format!("{remote}/{base}")
        } else {
            base.into()
        }
    }

    pub fn upstream(&self, dir: &str) -> Option<String> {
        self.run(&["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], dir)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
}

/// De pull-request-sjabloon van de repository, als die er is.
pub fn pull_request_template(root: &str) -> Option<String> {
    const CANDIDATES: [&str; 6] = [
        ".github/pull_request_template.md",
        ".github/PULL_REQUEST_TEMPLATE.md",
        "PULL_REQUEST_TEMPLATE.md",
        "pull_request_template.md",
        "docs/PULL_REQUEST_TEMPLATE.md",
        "docs/pull_request_template.md",
    ];
    CANDIDATES.iter().find_map(|name| std::fs::read_to_string(std::path::Path::new(root).join(name)).ok().filter(|t| !t.trim().is_empty()))
}

// MARK: GitHub

fn github(request: reqwest::RequestBuilder, token: &str) -> reqwest::RequestBuilder {
    request
        .bearer_auth(token)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .header("User-Agent", "Nook")
}

/// Maakt een pull request op GitHub; geeft de link. Probeert de tokens op volgorde: het eerste account met toegang.
pub async fn create_github_pull_request(
    tokens: &[String],
    repo: &str,
    title: &str,
    body: &str,
    head: &str,
    base: &str,
    draft: bool,
) -> Result<String, String> {
    if tokens.is_empty() {
        return Err("GitHub is niet gekoppeld. Koppel het bij Instellingen › Koppelingen.".into());
    }
    let client = github_client();
    let mut last = String::new();
    for token in tokens {
        let request = github(client.post(format!("https://api.github.com/repos/{repo}/pulls")), token)
            .json(&json!({"title": title, "body": body, "head": head, "base": base, "draft": draft}));
        let response = match request.send().await {
            Ok(r) => r,
            Err(e) => {
                last = format!("GitHub is niet bereikbaar: {e}");
                continue;
            }
        };
        let status = response.status().as_u16();
        let object: Value = response.json().await.unwrap_or(Value::Null);
        if (200..300).contains(&status) {
            if let Some(link) = object.get("html_url").and_then(Value::as_str) {
                return Ok(link.into());
            }
        }
        let mut message =
            object.get("message").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| format!("GitHub gaf een fout ({status})."));
        if let Some(errors) = object.get("errors").and_then(Value::as_array) {
            let details: Vec<&str> = errors.iter().filter_map(|e| e.get("message").and_then(Value::as_str)).collect();
            if !details.is_empty() {
                message += &format!(" {}", details.join(" "));
            }
        }
        last = format!("GitHub: {message}");
    }
    Err(last)
}

/// A client with timeouts: `Client::new()` has none, so a stalled connection would hang the command that waits on it.
fn github_client() -> reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(10))
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_default()
        })
        .clone()
}

/// De open pull request met `branch` als bron, of `None` (niet gekoppeld, niet gevonden, offline).
pub async fn open_github_pull_request(tokens: &[String], repo: &str, branch: &str) -> Option<String> {
    let owner = repo.split('/').next()?;
    let client = github_client();
    for token in tokens {
        let request = github(client.get(format!("https://api.github.com/repos/{repo}/pulls")), token).query(&[
            ("state", "open"),
            ("head", &format!("{owner}:{branch}")),
            ("per_page", "1"),
        ]);
        let Ok(response) = request.send().await else { continue };
        if response.status().as_u16() != 200 {
            continue;
        }
        let Ok(list) = response.json::<Vec<Value>>().await else { continue };
        return list.first().and_then(|p| p.get("html_url")).and_then(Value::as_str).map(str::to_string);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo(url: &str) -> RemoteRepository {
        RemoteRepository::detect(url).unwrap_or_else(|| panic!("{url}"))
    }

    #[test]
    fn github_remotes() {
        for url in [
            "https://github.com/acme/app.git",
            "git@github.com:acme/app.git",
            "ssh://git@github.com/acme/app.git",
            "https://GitHub.com/acme/app/",
            "https://user:token@github.com/acme/app",
            "github.com:acme/app",
        ] {
            let r = repo(url);
            assert_eq!(r.host, SourceControlHost::Github, "{url}");
            assert_eq!(r.path, "acme/app", "{url}");
            assert_eq!(r.host_name, "github.com");
            assert_eq!(r.display_name(), "acme/app");
        }
    }

    #[test]
    fn credentials_and_ports() {
        let r = repo("https://user:secret@github.com/acme/app.git");
        assert!(!r.web_origin.contains("secret"));
        assert!(!r.compare_url("main", "x").unwrap().contains("secret"));
        let r = repo("ssh://git@git.example.com:2222/team/app.git");
        assert_eq!(r.web_origin, "https://git.example.com");
        assert_eq!(r.host, SourceControlHost::Unknown("git.example.com".into()));
        let r = repo("https://gitlab.corp.io:8443/a/b.git");
        assert_eq!(r.web_origin, "https://gitlab.corp.io:8443");
        assert_eq!(r.host_name, "gitlab.corp.io");
    }

    #[test]
    fn hosts() {
        assert_eq!(repo("git@gitlab.com:group/sub/deep/project.git").path, "group/sub/deep/project");
        assert_eq!(repo("https://gitlab.mycorp.nl/a/b").host, SourceControlHost::Gitlab);
        assert_eq!(repo("https://gitea.mycorp.nl/a/b").host, SourceControlHost::Gitea);
        assert_eq!(repo("https://forgejo.mycorp.nl/a/b").host, SourceControlHost::Forgejo);
        assert_eq!(repo("https://codeberg.org/a/b").host, SourceControlHost::Forgejo);
        assert_eq!(repo("https://bitbucket.mycorp.nl/a/b").host, SourceControlHost::Bitbucket);
        assert_eq!(repo("https://bitbucket.org/a/b").host, SourceControlHost::Bitbucket);
        assert_eq!(repo("https://git.cafe/a/b").host, SourceControlHost::Gitcafe);
        assert_eq!(repo("https://acme.ghe.com/a/b").host, SourceControlHost::Github);
        let unknown = repo("https://git.example.org/a/b");
        assert_eq!(unknown.host, SourceControlHost::Unknown("git.example.org".into()));
        assert!(unknown.pull_request_url(1).is_none());
        assert!(unknown.new_pull_request_url("main", "x", None, None, false).is_none());
        for h in [SourceControlHost::Github, SourceControlHost::AzureDevOps, SourceControlHost::Unknown("x.org".into())] {
            assert_eq!(SourceControlHost::from_key(&h.key()), h);
        }
        assert_eq!(SourceControlHost::from_key("mystery"), SourceControlHost::Unknown("mystery".into()));
    }

    #[test]
    fn azure_spellings() {
        for url in [
            "https://dev.azure.com/org/proj/_git/repo",
            "https://org@dev.azure.com/org/proj/_git/repo",
            "git@ssh.dev.azure.com:v3/org/proj/repo",
            "https://org.visualstudio.com/proj/_git/repo",
            "https://org.visualstudio.com/DefaultCollection/proj/_git/repo",
            "org@vs-ssh.visualstudio.com:v3/org/proj/repo",
        ] {
            let r = repo(url);
            assert_eq!(r.host, SourceControlHost::AzureDevOps, "{url}");
            assert_eq!(r.path, "org/proj/_git/repo", "{url}");
            assert_eq!(r.host_name, "dev.azure.com");
            assert_eq!(r.display_name(), "org/proj/repo");
        }
        assert!(RemoteRepository::detect("https://dev.azure.com/org/proj").is_none());
    }

    #[test]
    fn rejects_non_remotes() {
        for url in [
            "",
            "   ",
            "/Users/me/repo",
            "C:\\work\\repo",
            "https://github.com/onlyowner",
            "https://github.com/a/b/c",
            "file:///tmp/x",
            "https://github.com/a/../b",
            "ftp://github.com/a/b",
        ] {
            assert!(RemoteRepository::detect(url).is_none(), "{url}");
        }
    }

    #[test]
    fn github_urls() {
        let r = repo("git@github.com:acme/app.git");
        assert_eq!(r.compare_url("main", "feature/x").unwrap(), "https://github.com/acme/app/compare/main...feature/x");
        assert_eq!(
            r.new_pull_request_url("main", "feature/x", None, None, false).unwrap(),
            "https://github.com/acme/app/compare/main...feature/x?expand=1"
        );
        assert_eq!(r.pull_request_url(12).unwrap(), "https://github.com/acme/app/pull/12");
        assert_eq!(r.branch_url("feature/x").unwrap(), "https://github.com/acme/app/tree/feature/x");
        assert!(r.pull_request_url(0).is_none());
        let r = repo("https://github.com/acme/app");
        assert_eq!(
            r.new_pull_request_url("main", "x", Some("Fix #12 & more: één"), Some("line1\nline2 100%"), false).unwrap(),
            "https://github.com/acme/app/compare/main...x?expand=1&title=Fix%20%2312%20%26%20more%3A%20%C3%A9%C3%A9n&body=line1%0Aline2%20100%25"
        );
        assert_eq!(r.compare_url("main", "fix#1 a").unwrap(), "https://github.com/acme/app/compare/main...fix%231%20a");
    }

    #[test]
    fn other_hosts_urls() {
        let r = repo("https://gitlab.com/g/sub/p.git");
        assert_eq!(r.compare_url("main", "x").unwrap(), "https://gitlab.com/g/sub/p/-/compare/main...x");
        assert_eq!(
            r.new_pull_request_url("main", "feat/x", Some("T t"), Some("B"), false).unwrap(),
            "https://gitlab.com/g/sub/p/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat%2Fx&merge_request%5Btarget_branch%5D=main&merge_request%5Btitle%5D=T%20t&merge_request%5Bdescription%5D=B"
        );
        assert!(r.new_pull_request_url("main", "x", Some("T"), None, true).unwrap().contains("Draft%3A%20T"));
        assert_eq!(r.pull_request_url(3).unwrap(), "https://gitlab.com/g/sub/p/-/merge_requests/3");
        let b = repo("git@bitbucket.org:ws/repo.git");
        assert_eq!(
            b.new_pull_request_url("main", "feat/x", None, None, false).unwrap(),
            "https://bitbucket.org/ws/repo/pull-requests/new?source=feat%2Fx&dest=main"
        );
        assert_eq!(b.compare_url("main", "x").unwrap(), "https://bitbucket.org/ws/repo/branches/compare/x%0Dmain");
        assert_eq!(b.branch_url("a/b").unwrap(), "https://bitbucket.org/ws/repo/src/a/b");
        let g = repo("https://codeberg.org/o/r");
        assert_eq!(
            g.new_pull_request_url("main", "x", Some("A B"), Some("c"), false).unwrap(),
            "https://codeberg.org/o/r/compare/main...x?title=A%20B&body=c"
        );
        assert_eq!(
            g.new_pull_request_url("main", "x", Some("A"), None, true).unwrap(),
            "https://codeberg.org/o/r/compare/main...x?title=WIP%3A%20A"
        );
        assert_eq!(g.pull_request_url(9).unwrap(), "https://codeberg.org/o/r/pulls/9");
        assert_eq!(g.branch_url("x").unwrap(), "https://codeberg.org/o/r/src/branch/x");
        let a = repo("git@ssh.dev.azure.com:v3/org/my%20proj/repo");
        assert_eq!(
            a.new_pull_request_url("main", "feat/x", None, None, false).unwrap(),
            "https://dev.azure.com/org/my%2520proj/_git/repo/pullrequestcreate?sourceRef=feat%2Fx&targetRef=main"
        );
        let plain = repo("https://dev.azure.com/org/proj/_git/repo");
        assert_eq!(
            plain.compare_url("main", "x").unwrap(),
            "https://dev.azure.com/org/proj/_git/repo/branchCompare?baseVersion=GBmain&targetVersion=GBx"
        );
        assert_eq!(plain.branch_url("x").unwrap(), "https://dev.azure.com/org/proj/_git/repo?version=GBx");
    }

    fn state(f: impl FnOnce(&mut QuickState)) -> QuickState {
        let mut s = QuickState { branch: Some("feat".into()), has_upstream: true, has_remote: true, ..Default::default() };
        f(&mut s);
        s
    }

    #[test]
    fn quick_action_with_changes() {
        assert_eq!(resolve(&state(|s| s.has_changes = true)), Ok(QuickAction::CommitPushPr));
        assert_eq!(
            resolve(&state(|s| {
                s.has_changes = true;
                s.has_open_pull_request = true;
            })),
            Ok(QuickAction::CommitPush)
        );
        assert_eq!(
            resolve(&state(|s| {
                s.has_changes = true;
                s.is_default_branch = true;
            })),
            Ok(QuickAction::CommitPush)
        );
        assert_eq!(
            resolve(&state(|s| {
                s.has_changes = true;
                s.has_upstream = false;
                s.has_remote = false;
            })),
            Ok(QuickAction::Commit)
        );
        assert_eq!(
            resolve(&state(|s| {
                s.has_changes = true;
                s.branch = None;
            })),
            Err(QuickReason::Detached)
        );
    }

    #[test]
    fn quick_action_on_clean_branch() {
        assert_eq!(resolve(&state(|s| s.ahead = 2)), Ok(QuickAction::PushPr));
        assert_eq!(
            resolve(&state(|s| {
                s.ahead = 2;
                s.has_open_pull_request = true;
            })),
            Ok(QuickAction::Push)
        );
        assert_eq!(
            resolve(&state(|s| {
                s.has_upstream = false;
                s.ahead_of_base = 3;
            })),
            Ok(QuickAction::PushPr)
        );
        assert_eq!(resolve(&state(|s| s.behind = 1)), Ok(QuickAction::Pull));
        assert_eq!(
            resolve(&state(|s| {
                s.ahead = 1;
                s.behind = 1;
            })),
            Err(QuickReason::Diverged)
        );
        assert_eq!(resolve(&state(|s| s.ahead_of_base = 2)), Ok(QuickAction::CreatePr));
        assert_eq!(
            resolve(&state(|s| {
                s.ahead_of_base = 2;
                s.has_open_pull_request = true;
            })),
            Err(QuickReason::UpToDate)
        );
        assert_eq!(resolve(&state(|s| s.has_upstream = false)), Err(QuickReason::NothingToPush));
        assert_eq!(resolve(&state(|s| s.has_remote = false)), Err(QuickReason::NoRemote));
        assert!(QuickAction::CommitPushPr.commits() && QuickAction::CommitPushPr.pushes() && QuickAction::CommitPushPr.proposes());
        assert!(!QuickAction::Pull.pushes());
    }

    #[test]
    fn commit_all_and_branches() {
        let Some(git) = Git::locate() else { return };
        let dir = std::env::temp_dir().join(format!("nook-quick-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let d = dir.to_string_lossy().to_string();
        git.run(&["init", "-q", "-b", "main"], &d).unwrap();
        git.run(&["config", "user.email", "t@example.com"], &d).unwrap();
        git.run(&["config", "user.name", "Test"], &d).unwrap();
        std::fs::write(dir.join("a.txt"), "a").unwrap();
        let hash = git.commit_all(&d, "Eerste", "met tekst").unwrap();
        assert!(!hash.is_empty());
        assert_eq!(git.default_branch(&d, "origin").as_deref(), Some("main"));
        assert_eq!(git.comparison_base(&d, "main", "origin"), "main");
        git.run(&["checkout", "-q", "-b", "feat"], &d).unwrap();
        std::fs::write(dir.join("b.txt"), "b").unwrap();
        git.commit_all(&d, "Tweede", "").unwrap();
        assert_eq!(git.commits_ahead(&d, "main"), Some(1));
        assert!(git.upstream(&d).is_none());
        std::fs::create_dir_all(dir.join(".github")).unwrap();
        std::fs::write(dir.join(".github/pull_request_template.md"), "## Wat\n").unwrap();
        assert_eq!(pull_request_template(&d).as_deref(), Some("## Wat\n"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
