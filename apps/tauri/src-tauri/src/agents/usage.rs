//! Keeps every subscription account's limits up to date while no session runs (`ClaudeUsage`, `CodexUsage`,
//! `QuotaService` on the Mac). The background timer reads an account once an hour at most; a usage view that opens, and
//! the refresh button, read sooner. What `claude` and `codex app-server` answer is in `nook_core::agents::usage`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use nook_core::agents::hub::normalize_home;
use nook_core::agents::AgentKind;
use nook_core::agents::usage::{self, CodexUsage, ResetOutcome};
use tauri::{AppHandle, Emitter, Manager};

use super::{lock, AgentsState};

#[derive(Default)]
pub struct UsageState {
    last: Mutex<HashMap<String, Instant>>,
    busy: Mutex<HashSet<String>>,
    /// Codex limits per account (`AgentProfile.id`).
    codex: Mutex<BTreeMap<String, CodexUsage>>,
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
        let executable = match profile.kind {
            AgentKind::Claude => claude.clone(),
            AgentKind::Codex => codex.clone(),
            _ => None,
        };
        let Some(executable) = executable else { continue };
        if lock(&state.last).get(&profile.id).is_some_and(|t| t.elapsed() < interval) {
            continue;
        }
        let home = profile.home.as_deref().map(normalize_home).unwrap_or_default();
        // Claude Code reported its numbers itself just now (status line, a session): nothing to ask.
        if profile.kind == AgentKind::Claude {
            let shown = if home.is_empty() { default_plan.as_ref() } else { plans.get(&home) };
            if shown.is_some_and(|u| (chrono::Utc::now() - u.updated).to_std().is_ok_and(|age| age < interval)) {
                continue;
            }
        }
        if !lock(&state.busy).insert(profile.id.clone()) {
            continue;
        }
        lock(&state.last).insert(profile.id.clone(), Instant::now());
        let app = app.clone();
        jobs.push(std::thread::spawn(move || {
            match profile.kind {
                AgentKind::Claude => {
                    // Not signed in with a subscription, or offline: keep what was shown and try again next time.
                    if let Some(reading) = usage::read_claude(&executable, &profile.environment()) {
                        if let Some(agents) = app.try_state::<AgentsState>() {
                            agents.hub.apply_fetched_usage(reading, &home);
                        }
                    }
                }
                _ => {
                    if let Some(reading) = usage::read_codex(&executable, profile.home.as_deref()) {
                        if let Some(state) = app.try_state::<UsageState>() {
                            lock(&state.codex).insert(profile.id.clone(), reading);
                        }
                        let _ = app.emit("codex-usage", ());
                    }
                }
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
    let a = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let outcome = usage::use_reset_credit(&codex, account.home.as_deref(), &key);
        if let Some(state) = a.try_state::<UsageState>() {
            lock(&state.last).remove(&account.id);
        }
        refresh(&a, usage::MANUAL_INTERVAL);
        outcome
    })
    .await
    .map_err(|e| e.to_string())
}

/// One subscription account's limits for the usage view (`UsageLimitSection` on the Mac).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountLimits {
    pub profile_id: String,
    pub kind: AgentKind,
    /// The account's own name (an e-mail address), else the profile's label, else empty.
    pub name: String,
    /// The plan as the agent names it ("max", "plus"), for weighing accounts in a pool; empty when unknown.
    pub plan: String,
    pub api_key: bool,
    pub usage: Option<nook_core::agents::models::PlanUsage>,
    pub codex: Option<CodexUsage>,
}

/// Every Claude Code and Codex account with what is known of its limits.
#[tauri::command]
pub fn agents_limits(app: AppHandle) -> Vec<AccountLimits> {
    let (Some(agents), Some(state)) = (app.try_state::<AgentsState>(), app.try_state::<UsageState>()) else { return vec![] };
    let profiles = lock(&agents.profiles).all();
    let (default_plan, plans) = agents.hub.plan_usage();
    let accounts = lock(&agents.last_history).accounts.clone();
    let codex = lock(&state.codex).clone();
    profiles
        .into_iter()
        .filter(|p| matches!(p.kind, AgentKind::Claude | AgentKind::Codex))
        .map(|p| {
            let home = p.home.as_deref().map(normalize_home).unwrap_or_default();
            let account = accounts.get(&p.id);
            let codex = codex.get(&p.id).cloned();
            let usage = match p.kind {
                AgentKind::Claude => if home.is_empty() { default_plan.clone() } else { plans.get(&home).cloned() },
                _ => codex.as_ref().map(CodexUsage::plan_usage),
            };
            AccountLimits {
                name: account.map(|a| a.name.clone()).filter(|n| !n.is_empty()).unwrap_or_else(|| p.label.clone()),
                plan: codex.as_ref().and_then(|c| c.plan_type.clone()).or_else(|| account.map(|a| a.plan.clone())).unwrap_or_default(),
                api_key: p.uses_api_key(),
                profile_id: p.id,
                kind: p.kind,
                usage,
                codex,
            }
        })
        .collect()
}
