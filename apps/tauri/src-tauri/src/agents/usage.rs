//! Keeps every subscription account's limits up to date while no session runs (`ClaudeUsage`, `CodexUsage`,
//! `AntigravityUsage`, `QuotaService` on the Mac). The background timer reads an account once an hour at most; a usage
//! view that opens, and the refresh button, read sooner. What `claude`, `codex app-server` and Antigravity answer is in
//! `nook_core::agents::usage`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use nook_core::agents::hub::normalize_home;
use nook_core::agents::usage::{
    self, AntigravityReading, CliProxyAccount, CliProxyHub, CliProxyHubSnapshot, CliProxyHubStore, CliProxyProblem, CodexUsage, QuotaLimit,
    ResetOutcome,
};
use nook_core::agents::AgentKind;
use tauri::{AppHandle, Emitter, Manager};

use super::{lock, AgentsState};
use crate::state::AppState;

const CLIPROXY_MIN_INTERVAL: Duration = Duration::from_secs(10);

#[derive(Default, Clone)]
struct CliProxyRawSnapshot {
    accounts: Vec<CliProxyAccount>,
    read_at: Option<DateTime<Utc>>,
    problem: Option<CliProxyProblem>,
}

pub struct UsageState {
    last: Mutex<HashMap<String, Instant>>,
    busy: Mutex<HashSet<String>>,
    /// Accounts whose reset credit is currently being redeemed (guards against double-click).
    redeeming: Mutex<HashSet<String>>,
    /// Codex limits per account (`AgentProfile.id`).
    codex: Mutex<BTreeMap<String, CodexUsage>>,
    /// Antigravity quota per account (`AgentProfile.id`).
    antigravity: Mutex<BTreeMap<String, AntigravityReading>>,
    /// Configured CLIProxyAPI hubs (`cliproxy-hubs.json` in support directory).
    cliproxy_hubs: Mutex<CliProxyHubStore>,
    /// Latest fetched accounts/problems per hub id.
    cliproxy_snapshots: Mutex<HashMap<String, CliProxyRawSnapshot>>,
    cliproxy_last: Mutex<HashMap<String, Instant>>,
    cliproxy_busy: Mutex<HashSet<String>>,
}

impl UsageState {
    fn new() -> Self {
        let hubs_path = nook_core::paths::support_directory().join("cliproxy-hubs.json");
        Self {
            last: Mutex::new(HashMap::new()),
            busy: Mutex::new(HashSet::new()),
            redeeming: Mutex::new(HashSet::new()),
            codex: Mutex::new(BTreeMap::new()),
            antigravity: Mutex::new(BTreeMap::new()),
            cliproxy_hubs: Mutex::new(CliProxyHubStore::load(Some(hubs_path))),
            cliproxy_snapshots: Mutex::new(HashMap::new()),
            cliproxy_last: Mutex::new(HashMap::new()),
            cliproxy_busy: Mutex::new(HashSet::new()),
        }
    }
}

pub fn manage(app: &AppHandle) {
    app.manage(UsageState::new());
}

/// The background timer, where agents run on this computer.
pub fn start(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        // The first reading starts a Node process for a few seconds: a little after launch, not during it.
        tokio::time::sleep(Duration::from_secs(20)).await;
        loop {
            let a = app.clone();
            let _ = tauri::async_runtime::spawn_blocking(move || refresh(&a, usage::BACKGROUND_INTERVAL)).await;
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
    });
}

/// Reads every subscription account not read within `interval`; returns once the readings are in.
pub fn refresh(app: &AppHandle, interval: Duration) {
    let (Some(agents), Some(state)) = (app.try_state::<AgentsState>(), app.try_state::<UsageState>()) else { return };
    let profiles = lock(&agents.profiles).all();
    let (default_plan, plans) = agents.hub.plan_usage();
    let claude = nook_core::agents::find_executable(AgentKind::Claude).map(|p| p.to_string_lossy().into_owned());
    let codex = nook_core::agents::find_executable(AgentKind::Codex).map(|p| p.to_string_lossy().into_owned());
    let mut jobs = Vec::new();
    for profile in profiles.into_iter().filter(|p| !p.uses_api_key()) {
        if !matches!(profile.kind, AgentKind::Claude | AgentKind::Codex | AgentKind::Antigravity) {
            continue;
        }
        let executable = match profile.kind {
            AgentKind::Claude => {
                let Some(exe) = claude.clone() else { continue };
                Some(exe)
            }
            // Codex can still fall back to session logs under CODEX_HOME even without the binary on PATH.
            AgentKind::Codex => codex.clone(),
            AgentKind::Antigravity => None,
            _ => continue,
        };
        if !interval.is_zero() && lock(&state.last).get(&profile.id).is_some_and(|t| t.elapsed() < interval) {
            continue;
        }
        let home = profile.home.as_deref().map(normalize_home).unwrap_or_default();
        // Claude Code reported its numbers itself just now (status line, a session): nothing to ask.
        if profile.kind == AgentKind::Claude && !interval.is_zero() {
            let shown = if home.is_empty() { default_plan.as_ref() } else { plans.get(&home) };
            if shown.is_some_and(|u| (Utc::now() - u.updated).to_std().is_ok_and(|age| age < interval)) {
                continue;
            }
        }
        if !lock(&state.busy).insert(profile.id.clone()) {
            continue;
        }
        lock(&state.last).insert(profile.id.clone(), Instant::now());
        let previous_codex = if profile.kind == AgentKind::Codex { lock(&state.codex).get(&profile.id).cloned() } else { None };
        let app = app.clone();
        jobs.push(std::thread::spawn(move || {
            match profile.kind {
                AgentKind::Claude => {
                    // Not signed in with a subscription, or offline: keep what was shown and try again next time.
                    if let Some(exe) = executable {
                        if let Some(reading) = usage::read_claude(&exe, &profile.environment()) {
                            if let Some(agents) = app.try_state::<AgentsState>() {
                                agents.hub.apply_fetched_usage(reading, &home);
                            }
                        }
                    }
                }
                AgentKind::Codex => {
                    if let Some(reading) =
                        usage::read_codex_with_fallback(executable.as_deref(), profile.home.as_deref(), previous_codex.as_ref())
                    {
                        if let Some(state) = app.try_state::<UsageState>() {
                            lock(&state.codex).insert(profile.id.clone(), reading);
                        }
                        let _ = app.emit("codex-usage", ());
                        let _ = app.emit("agent-usage", ());
                    }
                }
                AgentKind::Antigravity => {
                    let mut homes: Vec<PathBuf> = Vec::new();
                    let p_home = profile.home_path();
                    homes.push(p_home.clone());
                    let default_home = AgentKind::Antigravity.default_home();
                    if default_home != p_home {
                        homes.push(default_home);
                    }
                    let reading = tauri::async_runtime::handle().block_on(usage::read_antigravity(&homes));
                    if let Some(state) = app.try_state::<UsageState>() {
                        let mut map = lock(&state.antigravity);
                        if !reading.limits.is_empty() || reading.no_login {
                            map.insert(profile.id.clone(), reading);
                        }
                    }
                    let _ = app.emit("agent-usage", ());
                }
                _ => {}
            }
            if let Some(state) = app.try_state::<UsageState>() {
                lock(&state.busy).remove(&profile.id);
            }
        }));
    }
    for job in jobs {
        let _ = job.join();
    }
}

/// Reads the accounts now: `manual` for the refresh button (unless seconds ago), else for a usage view that opens.
#[tauri::command]
pub async fn agents_usage_refresh(app: AppHandle, manual: bool) -> Result<(), String> {
    let interval = if manual { usage::MANUAL_INTERVAL } else { usage::MINIMUM_INTERVAL };
    let app_for_accounts = app.clone();
    let accounts_job = tauri::async_runtime::spawn_blocking(move || refresh(&app_for_accounts, interval));
    let hubs_job = refresh_cliproxy_all(app, false);
    let (accounts_res, _) = tokio::join!(accounts_job, hubs_job);
    accounts_res.map_err(|e| e.to_string())
}

/// Codex limits per account, with plan and reset credits.
#[tauri::command]
pub fn agents_codex_usage(state: tauri::State<'_, UsageState>) -> BTreeMap<String, CodexUsage> {
    lock(&state.codex).clone()
}

/// Spends one of a Codex account's reset credits; the limits are read again after.
#[tauri::command]
pub async fn agents_use_reset_credit(app: AppHandle, profile: String, key: String) -> Result<ResetOutcome, String> {
    let account = app
        .try_state::<AgentsState>()
        .and_then(|a| lock(&a.profiles).profile(&profile))
        .ok_or_else(|| nook_core::i18n::tr("Dit account bestaat niet meer.", "This account no longer exists.").to_string())?;
    let codex = nook_core::agents::find_executable(AgentKind::Codex)
        .ok_or_else(|| nook_core::i18n::tr("Codex staat niet op deze computer.", "Codex isn't on this computer.").to_string())?
        .to_string_lossy()
        .into_owned();
    if let Some(state) = app.try_state::<UsageState>() {
        if !lock(&state.redeeming).insert(account.id.clone()) {
            return Ok(ResetOutcome::Failed);
        }
        let _ = app.emit("agent-usage", ());
    }
    let a = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let outcome = usage::use_reset_credit(&codex, account.home.as_deref(), &key);
        if let Some(state) = a.try_state::<UsageState>() {
            lock(&state.last).remove(&account.id);
        }
        refresh(&a, Duration::ZERO);
        if let Some(state) = a.try_state::<UsageState>() {
            lock(&state.redeeming).remove(&account.id);
        }
        let _ = a.emit("codex-usage", ());
        let _ = a.emit("agent-usage", ());
        outcome
    })
    .await
    .map_err(|e| e.to_string());
    if result.is_err() {
        if let Some(state) = app.try_state::<UsageState>() {
            lock(&state.redeeming).remove(&profile);
        }
    }
    result
}

/// One subscription account's limits for the usage view (`UsageLimitSection` on the Mac).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountLimits {
    pub profile_id: String,
    pub kind: AgentKind,
    /// The profile's label, else the account's name, else the agent's short name.
    pub name: String,
    /// The account's email address when known (shown redacted in segment details).
    pub email: Option<String>,
    /// The plan as the agent names it ("Max 5x", "Plus", "Pro"), for weighing accounts in a pool; empty when unknown.
    pub plan: String,
    pub api_key: bool,
    pub usage: Option<nook_core::agents::models::PlanUsage>,
    pub codex: Option<CodexUsage>,
    /// Settled Antigravity quota windows, when present.
    pub antigravity_limits: Vec<QuotaLimit>,
    /// True when no Antigravity Google sign-in file was found.
    pub antigravity_no_login: bool,
    /// True while a reset credit for this account is being redeemed.
    pub redeeming: bool,
}

/// Every relevant agent account with what is known of its limits.
#[tauri::command]
pub fn agents_limits(app: AppHandle) -> Vec<AccountLimits> {
    let (Some(agents), Some(state)) = (app.try_state::<AgentsState>(), app.try_state::<UsageState>()) else { return vec![] };
    let profiles = lock(&agents.profiles).all();
    let (default_plan, plans) = agents.hub.plan_usage();
    let history = lock(&agents.last_history).clone();
    let codex_map = lock(&state.codex).clone();
    let ag_map = lock(&state.antigravity).clone();
    let redeeming_set = lock(&state.redeeming).clone();
    let now = Utc::now();

    let mut installed_cache: HashMap<AgentKind, bool> = HashMap::new();
    let mut is_installed = |kind: AgentKind| -> bool {
        *installed_cache
            .entry(kind)
            .or_insert_with(|| history.installed.contains(&kind) || nook_core::agents::find_executable(kind).is_some())
    };

    let mut rows: Vec<AccountLimits> = profiles
        .into_iter()
        .filter_map(|p| {
            let home = p.home.as_deref().map(normalize_home).unwrap_or_default();
            let account = history.accounts.get(&p.id);
            let codex = codex_map.get(&p.id).cloned();
            let ag = ag_map.get(&p.id);
            let antigravity_limits: Vec<QuotaLimit> = if p.kind == AgentKind::Antigravity {
                ag.map(|r| r.limits.iter().map(|l| l.settled(now)).collect()).unwrap_or_default()
            } else {
                vec![]
            };
            let antigravity_no_login = p.kind == AgentKind::Antigravity && ag.is_none_or(|r| r.no_login);
            let usage = match p.kind {
                AgentKind::Claude => {
                    if home.is_empty() {
                        default_plan.clone()
                    } else {
                        plans.get(&home).cloned()
                    }
                }
                AgentKind::Codex => codex.as_ref().map(CodexUsage::plan_usage),
                _ => None,
            };
            let has_data = usage.is_some()
                || codex.is_some()
                || !antigravity_limits.is_empty()
                || account.is_some()
                || history.usage.contains_key(&p.id);
            let relevant = has_data || !p.is_default() || is_installed(p.kind);
            if !relevant {
                return None;
            }
            let email = account.map(|a| a.name.clone()).filter(|n| n.contains('@'));
            let name = if !p.label.is_empty() {
                p.label.clone()
            } else if let Some(acc) = account.filter(|a| !a.name.is_empty()) {
                acc.name.clone()
            } else {
                p.kind.short_name().to_string()
            };
            let plan = account
                .map(|a| a.plan.clone())
                .filter(|s| !s.is_empty())
                .or_else(|| codex.as_ref().and_then(CodexUsage::plan_display))
                .unwrap_or_default();
            let api_key = p.uses_api_key();
            Some(AccountLimits {
                redeeming: redeeming_set.contains(&p.id),
                profile_id: p.id,
                kind: p.kind,
                name,
                email,
                plan,
                api_key,
                usage,
                codex,
                antigravity_limits,
                antigravity_no_login,
            })
        })
        .collect();
    rows.sort_by_key(|r| (r.kind, r.profile_id.clone()));
    rows
}

// MARK: - CLIProxyAPI hubs (AG-48)

/// No cookies, no redirects: the management key must never leave the hub address it was given for.
fn cliproxy_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("Nook")
        .build()
        .unwrap_or_default()
}

async fn fetch_cliproxy_hub(address: &str, key: &str) -> Result<Vec<CliProxyAccount>, CliProxyProblem> {
    let base = CliProxyHub::base(address).map_err(CliProxyProblem::from)?;
    let url = CliProxyHub::management_url(&base, "auth-files").ok_or(CliProxyProblem::BadAddress)?;
    let response = cliproxy_client()
        .get(url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {key}"))
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .await
        .map_err(|_| CliProxyProblem::Unreachable)?;
    let status = response.status().as_u16();
    if status == 401 || status == 403 {
        return Err(CliProxyProblem::RejectedKey);
    }
    if !(200..300).contains(&status) {
        return Err(CliProxyProblem::NotAHub);
    }
    let bytes = response.bytes().await.map_err(|_| CliProxyProblem::Unreachable)?;
    usage::cliproxy_accounts(&bytes).ok_or(CliProxyProblem::NotAHub)
}

async fn refresh_cliproxy_one(app: AppHandle, hub: CliProxyHub, force: bool) {
    let Some(state) = app.try_state::<UsageState>() else { return };
    if !force && lock(&state.cliproxy_last).get(&hub.id).is_some_and(|t| t.elapsed() < CLIPROXY_MIN_INTERVAL) {
        return;
    }
    if !lock(&state.cliproxy_busy).insert(hub.id.clone()) {
        return;
    }
    lock(&state.cliproxy_last).insert(hub.id.clone(), Instant::now());

    let key = app.try_state::<AppState>().and_then(|s| s.secrets.read(&hub.secret_account()));
    let result = match key.map(|k| k.trim().to_string()).filter(|k| !k.is_empty()) {
        Some(k) => fetch_cliproxy_hub(&hub.url, &k).await,
        None => Err(CliProxyProblem::NoKey),
    };

    if let Some(state) = app.try_state::<UsageState>() {
        lock(&state.cliproxy_busy).remove(&hub.id);
        if lock(&state.cliproxy_hubs).contains(&hub.id) {
            let mut snaps = lock(&state.cliproxy_snapshots);
            let entry = snaps.entry(hub.id.clone()).or_default();
            match result {
                Ok(accounts) => {
                    entry.accounts = accounts;
                    entry.read_at = Some(Utc::now());
                    entry.problem = None;
                }
                Err(problem) => {
                    entry.problem = Some(problem);
                }
            }
        }
    }
    let _ = app.emit("cliproxy-usage", ());
    let _ = app.emit("agent-usage", ());
}

pub async fn refresh_cliproxy_all(app: AppHandle, force: bool) {
    let hubs = app.try_state::<UsageState>().map(|s| lock(&s.cliproxy_hubs).all()).unwrap_or_default();
    if hubs.is_empty() {
        return;
    }
    let mut handles = Vec::with_capacity(hubs.len());
    for hub in hubs {
        let a = app.clone();
        handles.push(tauri::async_runtime::spawn(async move {
            refresh_cliproxy_one(a, hub, force).await;
        }));
    }
    for h in handles {
        let _ = h.await;
    }
}

/// Every configured CLIProxyAPI hub with its latest settled accounts and any read problem.
#[tauri::command]
pub fn agents_cliproxy_hubs(state: tauri::State<'_, UsageState>) -> Vec<CliProxyHubSnapshot> {
    let hubs = lock(&state.cliproxy_hubs).all();
    let snaps = lock(&state.cliproxy_snapshots);
    let now = Utc::now();
    hubs.into_iter()
        .map(|hub| {
            let snap = snaps.get(&hub.id);
            let name = hub.name();
            CliProxyHubSnapshot {
                hub,
                name,
                accounts: snap.map(|s| s.accounts.iter().map(|a| a.to_view(now)).collect()).unwrap_or_default(),
                read_at: snap.and_then(|s| s.read_at),
                problem: snap.and_then(|s| s.problem),
            }
        })
        .collect()
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyAddResult {
    pub problem: Option<CliProxyProblem>,
}

/// Adds a CLIProxyAPI hub, stores its management key in the secret store, and fetches its accounts immediately.
#[tauri::command]
pub async fn agents_cliproxy_add(app: AppHandle, label: String, address: String, key: String) -> Result<CliProxyAddResult, String> {
    let trimmed_key = key.trim().to_string();
    if trimmed_key.is_empty() {
        return Ok(CliProxyAddResult { problem: Some(CliProxyProblem::NoKey) });
    }
    if let Err(err) = CliProxyHub::base(&address) {
        return Ok(CliProxyAddResult { problem: Some(CliProxyProblem::from(err)) });
    }
    let hub = CliProxyHub { id: uuid::Uuid::new_v4().to_string(), label: label.trim().to_string(), url: address.trim().to_string() };
    if app.state::<AppState>().secrets.write(&hub.secret_account(), &trimmed_key).is_err() {
        return Ok(CliProxyAddResult { problem: Some(CliProxyProblem::NoKey) });
    }
    if let Some(state) = app.try_state::<UsageState>() {
        lock(&state.cliproxy_hubs).add(hub.clone());
    }
    let _ = app.emit("cliproxy-usage", ());
    let a = app.clone();
    tauri::async_runtime::spawn(async move {
        refresh_cliproxy_one(a, hub, true).await;
    });
    Ok(CliProxyAddResult { problem: None })
}

/// Removes a CLIProxyAPI hub and deletes its management key from the secret store.
#[tauri::command]
pub fn agents_cliproxy_remove(app: AppHandle, id: String) -> Result<(), String> {
    let removed = app.try_state::<UsageState>().and_then(|state| {
        let hub = lock(&state.cliproxy_hubs).remove(&id);
        lock(&state.cliproxy_snapshots).remove(&id);
        lock(&state.cliproxy_last).remove(&id);
        hub
    });
    if let Some(hub) = removed {
        let _ = app.state::<AppState>().secrets.remove(&hub.secret_account());
    }
    let _ = app.emit("cliproxy-usage", ());
    Ok(())
}

/// Refreshes all configured CLIProxyAPI hubs (`force: true` bypasses the 10 s per-hub throttle).
#[tauri::command]
pub async fn agents_cliproxy_refresh(app: AppHandle, force: Option<bool>) -> Result<(), String> {
    refresh_cliproxy_all(app, force.unwrap_or(false)).await;
    Ok(())
}
