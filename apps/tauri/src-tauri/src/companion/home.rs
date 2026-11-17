//! The companion's `home` area on Windows and Linux: what the Mac's `CompanionServer+Home.swift` answers for `home`,
//! `usage`, `music` and `requestUpdate`, from this app's own state. The shapes and rules are in
//! `nook_core::companion::home_digest`; this file only reads the app.

use std::time::Duration;

use chrono::Utc;
use nook_core::companion::home_digest::{self as digest, HomeDigest, LineRank, MusicButton, UsageAccount};
use nook_core::companion::server::digests;
use nook_core::companion::{feature, CompanionError, CompanionOp, CompanionRequest, CompanionResponse, SessionDigest};
use nook_core::platform::MediaCommand;
use nook_core::workspace::store::UsageFilter;
use tauri::{AppHandle, Manager as _};

use super::Companion;
use crate::agents::{lock, AgentsState};
use crate::connectors::Connectors;
use crate::services::Services;
use crate::state::AppState;
use crate::workspace::WorkspaceState;

/// The `feature` names this area can answer. `requestUpdate` is left out: this build has no updater of its own (the
/// newest version is on the releases page), so the phone would only ever hear "unavailable".
pub fn features(_app: &AppHandle) -> Vec<&'static str> {
    let mut list = vec![feature::HOME, feature::USAGE];
    if crate::platform::capabilities().media {
        list.push(feature::MUSIC);
    }
    list
}

/// The answer to one of this area's ops; `None` when it cannot.
pub async fn handle(app: &AppHandle, request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
    match request.op {
        CompanionOp::Home => Some(home(app, &request.id).await),
        CompanionOp::Usage => Some(usage(app, request).await),
        CompanionOp::Music => Some(music(app, request).await),
        // As the Mac answers when it cannot look for updates: nothing is shown, nothing is installed.
        CompanionOp::RequestUpdate => {
            Some(CompanionResponse { message: Some("unavailable".into()), ..CompanionResponse::success(&request.id) })
        }
        _ => None,
    }
}

async fn blocking<T: Send + 'static>(app: &AppHandle, work: impl FnOnce(&AppHandle) -> T + Send + 'static) -> Option<T> {
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || work(&app)).await.ok()
}

async fn sessions(app: &AppHandle) -> Vec<SessionDigest> {
    match app.try_state::<Companion>() {
        Some(companion) => digests(companion.server.sessions().await),
        None => Vec::new(),
    }
}

// MARK: Home

async fn home(app: &AppHandle, id: &str) -> CompanionResponse {
    let sessions = sessions(app).await;
    let accounts = accounts(app).await;
    let rows = sessions.clone();
    let built = blocking(app, move |app| {
        let now = Utc::now();
        let upcoming = digest::upcoming(&agenda(app), now);
        let mut lines = digest::agent_lines(&rows);
        lines.extend(connector_lines(app).into_iter().map(|l| (LineRank::Failure, l)));
        if let Some(line) = digest::next_event_line(&upcoming, now, digest::time_of_day) {
            lines.push((LineRank::Soon, line));
        }
        if let Some(line) = nudge_line(app, now) {
            lines.push((LineRank::Info, line));
        }
        let track = app.try_state::<Services>().and_then(|s| s.platform.media.now_playing()).map(|n| digest::track(&n));
        let suggestions = digest::suggestions(&crate::commands::brain::start_suggestions(app.clone()));
        HomeDigest { lines: digest::rank_lines(lines), events: digest::events(&upcoming), suggestions, track, accounts: vec![] }
    })
    .await
    .unwrap_or_default();
    let home = HomeDigest { accounts, ..built };
    CompanionResponse { sessions: Some(sessions), home: serde_json::to_value(home).ok(), ..CompanionResponse::success(id) }
}

/// Every active calendar's events from its cache (no network), as Home's inbox reads them.
fn agenda(app: &AppHandle) -> Vec<nook_core::connectors::agenda::AgendaEntry> {
    let Some(c) = app.try_state::<Connectors>() else { return Vec::new() };
    c.hub.active().iter().flat_map(|calendar| calendar.cached_agenda()).collect()
}

/// Connections that need you (failing checks, a review asked of you), the first two, as on the Mac.
fn connector_lines(app: &AppHandle) -> Vec<digest::HomeLine> {
    let Some(c) = app.try_state::<Connectors>() else { return Vec::new() };
    c.hub
        .active()
        .iter()
        .filter_map(|source| {
            let status = source.status();
            status.needs_attention.then(|| {
                let first = status.items.first().map(|i| i.title.as_str());
                digest::connector_line(&source.id(), &source.title(), &status.headline, &status.detail, first)
            })
        })
        .take(2)
        .collect()
}

/// Nook's offer from thinking along, while it is fresh.
fn nudge_line(app: &AppHandle, now: chrono::DateTime<Utc>) -> Option<digest::HomeLine> {
    let services = app.try_state::<Services>()?;
    let nudge = services.nudge.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
    if !nudge.still_fresh(now.timestamp()) {
        return None;
    }
    let time = chrono::DateTime::from_timestamp(nudge.date, 0).map(digest::time_of_day).unwrap_or_default();
    Some(digest::nudge_line(&nudge.id, &nudge.line, &nudge.app, &time))
}

/// Every signed-in account of an installed agent with the limits it reported, as Settings › Coding agents lists them.
async fn accounts(app: &AppHandle) -> Vec<UsageAccount> {
    let Some(agents) = app.try_state::<AgentsState>() else { return Vec::new() };
    // Who is signed in comes from the agents' own folders; read them once when nothing has looked yet.
    let empty = {
        let last = lock(&agents.last_history);
        last.accounts.is_empty() && last.installed.is_empty()
    };
    if empty {
        crate::agents::refresh_history(app).await;
    }
    let history = lock(&agents.last_history).clone();
    let (main, by_home) = agents.hub.plan_usage();
    let now = Utc::now();
    let profiles = lock(&agents.profiles).all();
    profiles
        .into_iter()
        .filter_map(|profile| {
            let account = history.accounts.get(&profile.id)?;
            let installed = history.installed.contains(&profile.kind) || history.executables.contains_key(profile.kind.id());
            if !installed {
                return None;
            }
            let limits = match profile.kind {
                nook_core::agents::AgentKind::Claude => {
                    digest::claude_limits(digest::plan_usage_for(main.as_ref(), &by_home, &profile.id, profile.home.as_deref()), now)
                }
                // The others report no plan windows to this app (yet).
                _ => Vec::new(),
            };
            Some(UsageAccount {
                id: profile.id.clone(),
                agent: profile.kind.short_name().into(),
                account: digest::account_name(&profile.label, Some(&account.organization)),
                limits,
            })
        })
        .collect()
}

// MARK: Music

/// The player's buttons; only what the main window's player offers. Answered with the home, after a moment so the
/// player says what changed.
async fn music(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let id = request.id.as_str();
    let Some(button) = MusicButton::parse(request.text.as_deref()) else {
        return CompanionResponse::failure(id, CompanionError::BadRequest);
    };
    let command = match button {
        MusicButton::PlayPause => MediaCommand::PlayPause,
        MusicButton::Next => MediaCommand::Next,
        MusicButton::Previous => MediaCommand::Previous,
    };
    let sent = blocking(app, move |app| {
        let services = app.try_state::<Services>()?;
        services.platform.media.now_playing()?;
        Some(services.platform.media.send(command))
    })
    .await
    .flatten();
    match sent {
        None => return CompanionResponse::failure(id, CompanionError::UnknownItem),
        Some(Err(e)) => {
            log::debug!("Companion: music control failed: {e}");
            return CompanionResponse::failure(id, CompanionError::Failed);
        }
        Some(Ok(())) => {}
    }
    if let Some(state) = app.try_state::<AppState>() {
        state.store.audit("companion_music", request.text.as_deref().unwrap_or_default(), "ok");
    }
    crate::services::media::refresh_soon(app);
    tokio::time::sleep(Duration::from_millis(350)).await;
    home(app, id).await
}

// MARK: Usage

async fn usage(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let range = digest::range(request.item.as_deref());
    let accounts = accounts(app).await;
    let report = blocking(app, move |app| {
        app.try_state::<WorkspaceState>().map(|ws| ws.manager.usage_report(&UsageFilter { range, ..Default::default() }))
    })
    .await
    .flatten()
    .unwrap_or_default();
    let usage = digest::usage(&report, range, accounts);
    CompanionResponse { usage: serde_json::to_value(usage).ok(), ..CompanionResponse::success(&request.id) }
}
