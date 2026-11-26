//! Keeps every subscription account's limits up to date while no session runs (`ClaudeUsage`, `CodexUsage`,
//! `AntigravityUsage`, `QuotaService` on the Mac). The background timer reads an account once an hour at most; a usage
//! view that opens, and the refresh button, read sooner. What `claude`, `codex app-server` and Antigravity answer is in
//! `nook_core::agents::usage`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::Utc;
use nook_core::agents::hub::normalize_home;
use nook_core::agents::usage::{self, AntigravityReading, CodexUsage, QuotaLimit, ResetOutcome};
use nook_core::agents::AgentKind;
use tauri::{AppHandle, Emitter, Manager};

use super::{lock, AgentsState};

#[derive(Default)]
pub struct UsageState {
    last: Mutex<HashMap<String, Instant>>,
    busy: Mutex<HashSet<String>>,
    /// Accounts whose reset credit is currently being redeemed (guards against double-click).
    redeeming: Mutex<HashSet<String>>,
    /// Codex limits per account (`AgentProfile.id`).
    codex: Mutex<BTreeMap<String, CodexUsage>>,
    /// Antigravity quota per account (`AgentProfile.id`).
    antigravity: Mutex<BTreeMap<String, AntigravityReading>>,
}

pub fn manage(app: &AppHandle) {
    app.manage(UsageState::default());
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
    tauri::async_runtime::spawn_blocking(move || refresh(&app, interval)).await.map_err(|e| e.to_string())
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
#[tauri::command(async)]
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
