//! Settings › Devices › Machines and the composer's "Runs on" (`RemoteMachinesSettings` on the Mac): the machines a
//! session can run on over SSH, kept in `machines.json` in Nook's folder, and the connection test that also finds
//! which agents are there. Every change tells the interface (`machines-changed`).

use nook_core::agents::AgentKind;
use nook_core::workspace::remote::{self, RemoteMachine, RemoteMachines, RemoteTarget};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

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
) -> Res<RemoteMachine> {
    let machine = RemoteMachine::from_input(id, &name, &host, port, identity_file.as_deref().unwrap_or(""))?;
    let file = RemoteMachines::file();
    let mut list = RemoteMachines::load(&file);
    list.upsert(machine.clone());
    list.save_to(&file).map_err(|e| e.to_string())?;
    changed(&app);
    Ok(list.find(&machine.id).cloned().unwrap_or(machine))
}

#[tauri::command]
pub fn machines_remove(app: AppHandle, id: String) -> Res<()> {
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
        let output = remote::run_ssh(&remote::check_arguments(&target, &commands), std::time::Duration::from_secs(25))?;
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
