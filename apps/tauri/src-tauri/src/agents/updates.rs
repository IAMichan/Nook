//! Settings › Agents › Updates (`AgentUpdatesSection`, `AgentUpdater` on the Mac): each coding agent's installed
//! version, the newest one, and the command that updates it the way it was installed. Nook runs it only after you
//! click Update. What decides owner, command and versions is in `nook_core::agents::updates`.

use std::collections::BTreeMap;
use std::process::{Command, Stdio};
use std::time::Duration;

use nook_core::agents::updates::{self, InstallOwner};
use nook_core::agents::{find_executable, AgentKind};
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUpdateRow {
    pub kind: AgentKind,
    pub name: String,
    pub installed: Option<String>,
    pub latest: Option<String>,
    pub outdated: bool,
    /// Who installed it ("npm", "Scoop", "self"), "?" when Nook cannot tell.
    pub installer: String,
    /// The command Update runs, as the confirmation shows it; `None` when you update it yourself.
    pub command: Option<String>,
}

fn quiet(cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    #[cfg(not(windows))]
    let _ = cmd;
}

fn environment(executable: &str) -> BTreeMap<String, String> {
    let base: BTreeMap<String, String> = std::env::vars().collect();
    nook_core::workspace::command::environment(&base, executable, &BTreeMap::new())
}

/// `<agent> --version`, within ten seconds.
fn installed_version(executable: &str) -> Option<String> {
    let mut cmd = Command::new(executable);
    cmd.arg("--version").env_clear().envs(environment(executable)).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    quiet(&mut cmd);
    let child = cmd.spawn().ok()?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });
    let output = rx.recv_timeout(Duration::from_secs(10)).ok()?.ok()?;
    updates::Version::find(&String::from_utf8_lossy(&output.stdout)).map(|v| v.to_string())
}

async fn latest_version(kind: AgentKind, owner: &InstallOwner) -> Option<String> {
    let package = match owner {
        InstallOwner::Npm { package, .. } | InstallOwner::Pnpm { package } | InstallOwner::Bun { package, .. } | InstallOwner::Volta { package } => {
            package.clone()
        }
        _ => updates::npm_package(kind)?.to_string(),
    };
    let client = reqwest::Client::builder().timeout(Duration::from_secs(10)).build().ok()?;
    let body = client.get(updates::npm_dist_tags_url(&package)).send().await.ok()?.text().await.ok()?;
    updates::parse_npm_dist_tags(&body)
}

fn owner_of(kind: AgentKind) -> Option<(String, InstallOwner)> {
    let path = find_executable(kind)?;
    let resolved = std::fs::canonicalize(&path).unwrap_or(path.clone());
    let resolved = resolved.to_string_lossy().trim_start_matches(r"\\?\").to_string();
    let home = dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default();
    let owner = updates::owner(kind, &resolved, &home, |p| std::path::Path::new(p).exists());
    Some((path.to_string_lossy().into_owned(), owner))
}

/// The agents on this computer with their versions; `latest` asks the npm registry too.
#[tauri::command]
pub async fn agents_updates(latest: bool) -> Vec<AgentUpdateRow> {
    let mut rows = Vec::new();
    for kind in AgentKind::ALL.into_iter().filter(|k| updates::updatable(*k)) {
        let Some((executable, owner)) = tauri::async_runtime::spawn_blocking(move || owner_of(kind)).await.ok().flatten() else { continue };
        let exe = executable.clone();
        let installed = tauri::async_runtime::spawn_blocking(move || installed_version(&exe)).await.ok().flatten();
        let newest = if latest { latest_version(kind, &owner).await } else { None };
        rows.push(AgentUpdateRow {
            kind,
            name: kind.name().into(),
            outdated: updates::is_outdated(installed.as_deref(), newest.as_deref()),
            installed,
            latest: newest,
            installer: owner.name().into(),
            command: updates::command(&owner, &executable).map(|c| c.display()),
        });
    }
    rows
}

/// Updates one agent with the command its installer uses; returns the version it has after.
#[tauri::command]
pub async fn agents_update(kind: AgentKind) -> Result<Option<String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (executable, owner) = owner_of(kind).ok_or_else(|| {
            nook_core::i18n::trf("{agent} staat niet op deze computer.", "{agent} isn't installed on this computer.", &[("agent", &kind.name())])
        })?;
        let command = updates::command(&owner, &executable).ok_or_else(|| {
            nook_core::i18n::tr(
                "Nook weet niet hoe dit programma geïnstalleerd is. Werk het bij zoals je het installeerde.",
                "Nook can't tell how this program was installed. Update it the way you installed it.",
            )
            .to_string()
        })?;
        let program = nook_core::agents::which(&command.executable).map(|p| p.to_string_lossy().into_owned()).unwrap_or(command.executable.clone());
        let mut cmd = Command::new(&program);
        cmd.args(&command.arguments).env_clear().envs(environment(&program)).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        quiet(&mut cmd);
        let output = cmd.output().map_err(|e| e.to_string())?;
        if !output.status.success() {
            let text = String::from_utf8_lossy(&output.stderr);
            let last = text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string();
            return Err(if last.is_empty() { command.display() } else { last });
        }
        Ok(installed_version(&executable))
    })
    .await
    .map_err(|e| e.to_string())?
}
