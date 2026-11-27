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
use crate::workspace::git::{self, Git};
use crate::workspace::models::*;
use crate::workspace::remote::{self, RemoteMachines, RemoteTarget};
use crate::workspace::rollback::ConversationMark;

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

        // Git runs there over ssh: the repository, the branch, and for a worktree a new folder there
        // (~/.nook/worktrees/<repository>/<branch>), as on this computer.
        let git = Git::on(target.clone());
        let repo_root = git.repository_root(&resolved);
        let mut working = resolved.clone();
        let mut branch = repo_root.as_ref().and_then(|_| git.current_branch(&resolved));
        let mut base_branch = None;
        let mut worktree = None;
        if config.isolation == IsolationMode::Worktree {
            let root = repo_root.clone().ok_or(tr("Deze map is geen git-repository.", "This folder is not a git repository."))?;
            let home = remote::run_ssh(
                &target,
                &remote::command_arguments(&target, "printenv", &["HOME".into()], None, &Default::default()),
                Duration::from_secs(20),
            )
            .ok()
            .map(|h| h.trim().to_string())
            .filter(|h| h.starts_with('/'))
            .ok_or(tr(
                "De thuismap op de andere machine is niet te vinden, dus er kan daar geen worktree komen.",
                "The home folder on the other machine cannot be found, so no worktree can be made there.",
            ))?;
            let name = config.branch_name.clone();
            let base = if config.base_branch.trim().is_empty() {
                branch.clone().unwrap_or_else(|| "HEAD".into())
            } else {
                config.base_branch.trim().to_string()
            };
            let path = remote_worktree_path(&home, &crate::agents::text::project_name(&root), &slug(&name.replace('/', "-"), 60), |p| {
                git_exists(&target, p)
            });
            git.add_worktree(&root, &path, &name, &base).map_err(|e| e.0)?;
            working = path.clone();
            worktree = Some(path);
            branch = Some(name);
            base_branch = Some(base);
        }
        target.directory = working.clone();

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
            isolation: config.isolation,
            project_path: repo_root.clone().unwrap_or_else(|| resolved.clone()),
            working_directory: working.clone(),
            repo_root: repo_root.clone(),
            branch: branch.clone(),
            base_branch,
            worktree_path: worktree.clone(),
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
        // The first snapshot, before the agent changes anything: HEAD of a new worktree, or the folder as it is.
        let first = git::checkpoint_ref(&id.to_string(), 0);
        let made = repo_root.is_some()
            && if worktree.is_some() { git.checkpoint_head(&working, &first).is_ok() } else { git.checkpoint(&working, &first).is_ok() };
        let mut run = run;
        if made {
            run.checkpoints.push(RunCheckpoint { r#ref: first, date: Utc::now(), conversation: Some(ConversationMark::empty()) });
        }
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
                        &[("name", &machine.name), ("host", &machine.host), ("folder", &working)],
                    ),
                ),
                &mut out,
            );
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        // There the agent is found by its own name, by the login shell, as in your terminal there.
        self.launch_turn(id, config.task.clone(), remote_program(config.provider), true);
        self.refresh_git(id);
        Ok(id)
    }
}

/// Where a session's worktree goes on the machine: `<home>/.nook/worktrees/<repository>/<branch>`, with a number added
/// while a folder of that name is there. Built with `/`, since the machine is not this computer (`worktree_path`).
pub(super) fn remote_worktree_path(home: &str, repo_name: &str, slug_text: &str, exists: impl Fn(&str) -> bool) -> String {
    let base = format!("{}/.nook/worktrees/{}", home.trim_end_matches('/'), slug(repo_name, 40));
    let mut candidate = format!("{base}/{slug_text}");
    let mut counter = 2;
    while exists(&candidate) {
        candidate = format!("{base}/{slug_text}-{counter}");
        counter += 1;
    }
    candidate
}

/// Whether `path` is there on the machine (`test -e`).
fn git_exists(target: &RemoteTarget, path: &str) -> bool {
    remote::run_ssh(
        target,
        &remote::command_arguments(target, "test", &["-e".into(), path.into()], None, &Default::default()),
        Duration::from_secs(20),
    )
    .is_ok()
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
        let taken = ["/home/me/.nook/worktrees/app/fix", "/home/me/.nook/worktrees/app/fix-2"];
        assert_eq!(remote_worktree_path("/home/me/", "App", "fix", |p| taken.contains(&p)), "/home/me/.nook/worktrees/app/fix-3");
        let _ = std::fs::remove_dir_all(&root);
    }
}
