//! A new session on another machine (`WorkspaceManager.startRemote` on the Mac): the same agents and turns, started
//! over SSH in a folder there. Nook checks the folder first (one login, `cd … && pwd`), so a wrong folder or a machine
//! that does not let you in says so before a session exists.
//!
//! Not yet here (the Mac has them, AG-132): a new worktree on the machine, git over ssh (the diff, snapshots per turn),
//! machines that log in with a password, and Nook's tools for the agent there.

use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use uuid::Uuid;

use super::{Manager, ManagerEvent, Out};
use crate::i18n::{tr, trf};
use crate::workspace::models::*;
use crate::workspace::remote::{self, RemoteMachines, RemoteTarget};

impl Manager {
    /// Starts `config` on the machine it names (`config.machine_id`), in the folder `config.project_path` there. Blocks
    /// for the folder check (at most 25 seconds): call it off the interface's thread, as `start` is.
    pub(super) fn start_remote(self: &Arc<Self>, config: NewRunConfig) -> Result<Uuid, String> {
        let file = RemoteMachines::file();
        let mut machines = RemoteMachines::load(&file);
        let machine = machines.find(config.machine_id.trim()).cloned().ok_or_else(|| {
            tr("Deze machine staat niet meer in Nook. Kies er een andere.", "This machine is no longer in Nook. Choose another one.")
        })?;
        let folder = config.project_path.trim();
        if !remote::is_valid_directory(folder) {
            return Err(tr(
                "Typ de map op de machine: vanaf / of vanaf je thuismap (~/code/app).",
                "Type the folder on the machine: from / or from your home folder (~/code/app).",
            )
            .into());
        }
        if config.isolation == IsolationMode::Worktree {
            return Err(tr(
                "Een nieuwe worktree op een andere machine kan hier nog niet. Kies de map zelf.",
                "A new worktree on another machine is not available here yet. Choose the folder itself.",
            )
            .into());
        }
        self.check_supported(config.provider)?;
        // A machine that logs in with a password needs it typed once in this run of Nook (or kept) before it starts.
        if machine.password_login && super::super::remote_passwords::RemotePasswords::shared().password(&machine.id).is_none() {
            return Err(trf(
                "Typ eerst het wachtwoord van {machine} bij Instellingen › Apparaten › Machines.",
                "Type the password for {machine} in Settings › Devices › Machines first.",
                &[("machine", &machine.name)],
            ));
        }
        let mut target = RemoteTarget::new(&machine, folder);
        // The folder's full path there: Codex's app-server and ACP agents need one, and a missing folder fails here.
        let resolved = remote::run_ssh(&target, &remote::folder_arguments(&target), Duration::from_secs(25))?;
        let resolved = resolved.lines().map(str::trim).rfind(|l| l.starts_with('/')).unwrap_or(folder).to_string();
        target.directory = resolved.clone();
        machines.mark_used(&machine.id, Utc::now());
        let _ = machines.save_to(&file);

        let id = Uuid::new_v4();
        let now = Utc::now();
        let title = config.title.trim();
        let run = WorkspaceRun {
            id,
            title: if title.is_empty() { title_from(&config.task, 60) } else { title.into() },
            task: config.task.clone(),
            provider: config.provider,
            profile_id: config.profile_id.clone(),
            model: config.model.trim().into(),
            resolved_model: None,
            mode: config.mode,
            permission: config.permission,
            isolation: IsolationMode::Folder,
            project_path: resolved.clone(),
            working_directory: resolved.clone(),
            repo_root: None,
            branch: None,
            base_branch: None,
            worktree_path: None,
            instructions: config.instructions.clone(),
            status: RunStatus::Preparing,
            status_detail: None,
            provider_session_id: None,
            created_at: now,
            updated_at: now,
            archived: false,
            usage: RunUsage::default(),
            turn_started_at: Some(now),
            reviewed_at: None,
            last_change_at: None,
            changed_files: None,
            lines_added: None,
            lines_removed: None,
            checkpoints: vec![],
            limited_at: None,
            limit_reset_at: None,
            auto_resume: false,
            effort: config.effort.clone(),
            pending_handoff: None,
            conversation: None,
            pending_rollback: None,
            goal: None,
            compacting: false,
            tasks: None,
            restart: Default::default(),
            prompt_cache: None,
            other_projects: vec![],
            remote: Some(target),
        };
        let mut out = Out::default();
        {
            let mut s = self.lock();
            s.runs.insert(0, run);
            s.events.insert(id, vec![]);
            s.dirty_runs = true;
            Self::append(
                &mut s,
                id,
                RunEvent::new(
                    EventKind::System,
                    trf(
                        "Draait op {name} ({host}) in {folder}",
                        "Runs on {name} ({host}) in {folder}",
                        &[("name", &machine.name), ("host", &machine.host), ("folder", &resolved)],
                    ),
                ),
                &mut out,
            );
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        // There the agent is found by its own name, by the login shell, as in your terminal there.
        self.launch_turn(id, config.task.clone(), remote_program(config.provider), true);
        Ok(id)
    }
}

/// The agent's program on the other machine: its command, found there on `PATH` (`AgentKind.command`).
pub(super) fn remote_program(provider: RunProvider) -> String {
    provider.kind().command().to_string()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::super::Hooks;
    use super::*;

    #[tokio::test]
    async fn an_unknown_machine_starts_nothing_here() {
        let root = std::env::temp_dir().join(format!("nook-manager-remote-{}", Uuid::new_v4()));
        let hooks = Hooks {
            executable: Box::new(|_| None),
            account_environment: Box::new(|_| BTreeMap::new()),
            bridge: Box::new(|| None),
            worktree_root: Box::new(|| "/tmp".into()),
            auto_resume_limited: Box::new(|| false),
        };
        let manager = Manager::new(root.join("store"), hooks, tokio::runtime::Handle::current(), |_| {});
        let config = NewRunConfig {
            task: "Build it there".into(),
            project_path: "~/code/app".into(),
            machine_id: Uuid::new_v4().to_string(),
            ..Default::default()
        };
        // The folder is a path on the machine: it is never checked here, and no agent here is needed.
        let error = manager.start(config, false).unwrap_err();
        assert!(error.contains("machine"), "{error}");
        assert!(manager.runs().is_empty());
        assert_eq!(remote_program(RunProvider::Cursor), "cursor-agent");
        let _ = std::fs::remove_dir_all(&root);
    }
}
