//! Settings › Devices › Machines and the composer's "Runs on" (`RemoteMachinesSettings` on the Mac): the machines a
//! session can run on over SSH, kept in `machines.json` in Nook's folder, and the connection test that also finds
//! which agents are there. Every change tells the interface (`machines-changed`).

use nook_core::agents::AgentKind;
use nook_core::workspace::balance::{self, BalanceLevel, Candidate};
use nook_core::workspace::models::RunProvider;
use nook_core::workspace::remote::{self, RemoteMachine, RemoteMachines, RemoteTarget};
use nook_core::workspace::remote_passwords::RemotePasswords;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::workspace::WorkspaceState;

type Res<T> = Result<T, String>;

fn changed(app: &AppHandle) {
    let _ = app.emit("machines-changed", ());
}

/// The saved machines, in the order you added them.
#[tauri::command]
pub fn machines_list() -> Vec<RemoteMachine> {
    RemoteMachines::load(&RemoteMachines::file()).machines
}

/// Adds a machine, or changes the one with `id`. `Err` says what is wrong with what you typed.
#[tauri::command]
pub fn machines_save(
    app: AppHandle,
    id: Option<String>,
    name: String,
    host: String,
    port: Option<u16>,
    identity_file: Option<String>,
    password_login: Option<bool>,
) -> Res<RemoteMachine> {
    let mut machine = RemoteMachine::from_input(id, &name, &host, port, identity_file.as_deref().unwrap_or(""))?;
    let file = RemoteMachines::file();
    let mut list = RemoteMachines::load(&file);
    // Not given: as it was.
    machine.password_login = password_login.unwrap_or_else(|| list.find(&machine.id).is_some_and(|m| m.password_login));
    if !machine.password_login {
        let _ = RemotePasswords::shared().set(&machine.id, None, false);
    }
    list.upsert(machine.clone());
    list.save_to(&file).map_err(|e| e.to_string())?;
    changed(&app);
    Ok(list.find(&machine.id).cloned().unwrap_or(machine))
}

#[tauri::command]
pub fn machines_remove(app: AppHandle, id: String) -> Res<()> {
    let _ = RemotePasswords::shared().set(&id, None, false);
    let file = RemoteMachines::file();
    let mut list = RemoteMachines::load(&file);
    list.remove(&id);
    list.save_to(&file).map_err(|e| e.to_string())?;
    changed(&app);
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineCheck {
    /// The agents found on the machine's `PATH`, as `RunProvider` ids (`claude`, `codex`, …).
    agents: Vec<String>,
}

/// Logs in once and lists the agents found there; marks the machine as used when it answered.
#[tauri::command]
pub async fn machines_test(app: AppHandle, id: String) -> Res<MachineCheck> {
    let found = tauri::async_runtime::spawn_blocking(move || -> Res<Vec<String>> {
        let file = RemoteMachines::file();
        let mut list = RemoteMachines::load(&file);
        let machine = list.find(&id).cloned().ok_or_else(|| "Unknown machine.".to_string())?;
        let commands: Vec<&str> = AgentKind::ALL.iter().map(|k| k.command()).collect();
        let target = RemoteTarget::new(&machine, "~");
        let output = remote::run_ssh(&target, &remote::check_arguments(&target, &commands), std::time::Duration::from_secs(25))?;
        list.mark_used(&machine.id, chrono::Utc::now());
        let _ = list.save_to(&file);
        let found = remote::found_agents(&output, &commands);
        Ok(AgentKind::ALL.iter().filter(|k| found.iter().any(|c| c == k.command())).map(|k| k.id().to_string()).collect())
    })
    .await
    .map_err(|e| e.to_string())??;
    changed(&app);
    Ok(MachineCheck { agents: found })
}

/// Changes how often "Automatic" picks a machine.
#[tauri::command]
pub fn machines_set_balance(app: AppHandle, id: String, level: BalanceLevel) -> Res<()> {
    edit(&app, |list| {
        if let Some(m) = list.machines.iter_mut().find(|m| m.id == id) {
            m.balance = Some(level);
        }
    })
}

/// This computer's own level for "Automatic".
#[tauri::command]
pub fn machines_local_balance() -> BalanceLevel {
    RemoteMachines::load(&RemoteMachines::file()).local_balance.unwrap_or_default()
}

#[tauri::command]
pub fn machines_set_local_balance(app: AppHandle, level: BalanceLevel) -> Res<()> {
    edit(&app, |list| list.local_balance = Some(level))
}

/// Keeps `folder` as the folder of this computer's `project` on the machine: the project is then shared with it.
#[tauri::command]
pub fn machines_share_project(app: AppHandle, id: String, project: String, folder: String) -> Res<()> {
    edit(&app, |list| {
        if let Some(m) = list.machines.iter_mut().find(|m| m.id == id) {
            m.remember_folder(&project, &folder);
        }
    })
}

/// Stops sharing `project` with the machine.
#[tauri::command]
pub fn machines_forget_project(app: AppHandle, id: String, project: String) -> Res<()> {
    edit(&app, |list| {
        if let Some(m) = list.machines.iter_mut().find(|m| m.id == id) {
            m.project_folders.remove(&remote::project_key(&project));
        }
    })
}

fn edit(app: &AppHandle, change: impl FnOnce(&mut RemoteMachines)) -> Res<()> {
    let file = RemoteMachines::file();
    let mut list = RemoteMachines::load(&file);
    change(&mut list);
    list.save_to(&file).map_err(|e| e.to_string())?;
    changed(app);
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PickedPlace {
    machine_id: String,
    name: String,
    folder: String,
}

/// Where "Automatic" starts a session of `project` with `provider` (`balance::pick`): a machine the project is shared
/// with, or `None` for this computer. Asks those machines first, in parallel (at most about 25 seconds).
/// `local_available`: the agent is on this computer.
#[tauri::command]
pub async fn machines_pick(
    state: State<'_, WorkspaceState>,
    project: String,
    provider: RunProvider,
    local_available: bool,
) -> Res<Option<PickedPlace>> {
    let runs = state.manager.runs();
    tauri::async_runtime::spawn_blocking(move || {
        let list = RemoteMachines::load(&RemoteMachines::file());
        let shared: Vec<RemoteMachine> = list
            .machines
            .into_iter()
            .filter(|m| m.folder_for(&project).is_some() && m.balance_level() != BalanceLevel::ManualOnly)
            .collect();
        if shared.is_empty() {
            return None;
        }
        let command = provider.kind().command();
        let commands: Vec<&str> = AgentKind::ALL.iter().map(|k| k.command()).collect();
        let found: Vec<bool> = std::thread::scope(|scope| {
            let handles: Vec<_> = shared
                .iter()
                .map(|m| {
                    let commands = &commands;
                    scope.spawn(move || {
                        let target = RemoteTarget::new(m, "~");
                        remote::run_ssh(&target, &remote::check_arguments(&target, commands), std::time::Duration::from_secs(25))
                            .map(|out| remote::found_agents(&out, commands).iter().any(|c| c == command))
                            .unwrap_or(false)
                    })
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap_or(false)).collect()
        });
        let active = |id: Option<&str>| -> u32 {
            runs.iter().filter(|r| r.status.is_active() && r.remote.as_ref().map(|t| t.machine_id.as_str()) == id).count() as u32
        };
        let mut candidates = vec![Candidate {
            machine_id: None,
            level: list.local_balance.unwrap_or_default(),
            active: active(None),
            available: local_available,
        }];
        for (m, ok) in shared.iter().zip(&found) {
            candidates.push(Candidate {
                machine_id: Some(m.id.clone()),
                level: m.balance_level(),
                active: active(Some(&m.id)),
                available: *ok,
            });
        }
        let id = balance::pick(&candidates)?;
        let m = shared.iter().find(|m| m.id == id)?;
        Some(PickedPlace { machine_id: m.id.clone(), name: m.name.clone(), folder: m.folder_for(&project)?.to_string() })
    })
    .await
    .map_err(|e| e.to_string())
}

/// Machines this computer probably reaches (`~/.ssh/config`, `known_hosts`, the tailnet), without the ones added.
/// Nothing is contacted.
#[tauri::command]
pub async fn machines_discover() -> Res<Vec<nook_core::workspace::remote_discovery::Suggestion>> {
    tauri::async_runtime::spawn_blocking(|| {
        let existing = RemoteMachines::load(&RemoteMachines::file()).machines;
        nook_core::workspace::remote_discovery::discover(&existing)
    })
    .await
    .map_err(|e| e.to_string())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PasswordState {
    /// Nook has the password now (typed in this run, or kept).
    unlocked: bool,
    /// It is in the system's secret store.
    kept: bool,
}

/// Whether Nook has each password machine's password: the composer and Settings ask for it while it has not.
#[tauri::command]
pub fn machines_passwords() -> std::collections::BTreeMap<String, PasswordState> {
    let passwords = RemotePasswords::shared();
    RemoteMachines::load(&RemoteMachines::file())
        .machines
        .into_iter()
        .filter(|m| m.password_login)
        .map(|m| {
            let unlocked = passwords.password(&m.id).is_some();
            (m.id.clone(), PasswordState { unlocked, kept: unlocked && passwords.is_kept(&m.id) })
        })
        .collect()
}

/// Logs in once with `password` (and finds the agents there) before Nook keeps it: in memory, and in the system's
/// secret store when `keep`. A password that does not get in is forgotten again.
#[tauri::command]
pub async fn machines_unlock(app: AppHandle, id: String, password: String, keep: bool) -> Res<MachineCheck> {
    let passwords = RemotePasswords::shared();
    passwords.set(&id, Some(&password), false)?;
    match machines_test(app.clone(), id.clone()).await {
        Ok(check) => {
            if keep {
                passwords.set(&id, Some(&password), true)?;
            }
            Ok(check)
        }
        Err(e) => {
            let _ = passwords.set(&id, None, false);
            changed(&app);
            Err(e)
        }
    }
}

/// Forgets a machine's password, in memory and in the secret store.
#[tauri::command]
pub fn machines_lock(app: AppHandle, id: String) -> Res<()> {
    RemotePasswords::shared().set(&id, None, false)?;
    changed(&app);
    Ok(())
}
