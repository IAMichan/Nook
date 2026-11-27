//! The sessions `nook-host` serves: its own workspace `Manager`, answered over the Companion protocol the way the
//! desktop app's `companion::backend` and `companion::remote` answer it. A paired Nook (or phone) may list, approve,
//! answer, send, stop, read a conversation, and start a session, but only in a folder the host's owner shared
//! (`nook-host project add`), never with "allow everything".

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use nook_core::agents::models::ApprovalDecision;
use nook_core::companion::remote_digest as rd;
use nook_core::companion::sessions;
use nook_core::companion::{
    feature, server, BackendSession, CompanionBackend, CompanionError, CompanionOp, CompanionPolicy, CompanionRequest, CompanionResponse,
};
use nook_core::workspace::manager::Manager;
use nook_core::workspace::models::{ExecutionMode, IsolationMode, NewRunConfig, RunProvider};
use nook_core::workspace::paths::{self, Verdict};
use nook_core::workspace::settings::WorkspaceSettings;
use uuid::Uuid;

/// The most sessions a client gets, as the desktop app sends.
const MAX_RUNS: usize = 25;

pub struct HostBackend {
    pub manager: Arc<Manager>,
    pub settings_file: PathBuf,
    pub images: PathBuf,
    /// Sessions started per request id, so a request sent again (from a client's outbox) gives the same session.
    started: Mutex<VecDeque<(String, String)>>,
}

impl HostBackend {
    pub fn new(manager: Arc<Manager>, settings_file: PathBuf, images: PathBuf) -> Self {
        Self { manager, settings_file, images, started: Mutex::new(VecDeque::new()) }
    }

    fn settings(&self) -> WorkspaceSettings {
        WorkspaceSettings::load_from(&self.settings_file)
    }

    fn run_id(session: &str) -> Result<Uuid, String> {
        Uuid::parse_str(session).map_err(|_| "This session no longer exists.".to_string())
    }
}

fn collect(manager: &Manager) -> Vec<BackendSession> {
    {
        let mut runs: Vec<_> = manager.runs().into_iter().filter(|r| !r.archived).collect();
        runs.sort_by_key(|r| std::cmp::Reverse(r.updated_at));
        runs.into_iter()
            .take(MAX_RUNS)
            .map(|run| {
                let answer = manager.last_answer(run.id);
                sessions::run_session(&run, &manager.permissions(run.id), &manager.questions(run.id), &answer)
            })
            .collect()
    }
}

impl HostBackend {
    async fn listed(&self) -> Vec<nook_core::companion::SessionDigest> {
        server::digests(self.sessions().await)
    }

    async fn options(&self, request: &CompanionRequest) -> CompanionResponse {
        let settings = self.settings();
        let agents: Vec<rd::LaunchAgent> = launchable()
            .into_iter()
            .map(|provider| rd::LaunchAgent {
                id: provider.id().into(),
                name: provider.display_name().into(),
                can_plan: provider.capabilities().plan_mode,
                models: Some(models(provider, &settings).iter().map(|m| rd::LaunchModel { id: m.clone(), name: model_name(m) }).collect()),
                default_model: Some(settings.model(provider)),
                can_main_thread: None,
            })
            .collect();
        let shared = shared_projects(&settings);
        let manager = self.manager.clone();
        let infos = tokio::task::spawn_blocking(move || {
            let can_git = manager.git_available();
            shared.iter().map(|p| (manager.inspect_project(p), can_git)).collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        let projects: Vec<rd::LaunchProject> = infos
            .into_iter()
            .filter(|(info, _)| info.verdict == Verdict::Ok)
            .map(|(info, can_git)| rd::LaunchProject {
                can_worktree: can_git && info.repo_root.is_some() && info.has_commits,
                path: info.path,
                name: info.name,
            })
            .collect();
        let default_agent = Some(settings.default_provider)
            .filter(|p| agents.iter().any(|a| a.id == p.id()))
            .map(|p| p.id().to_string())
            .or_else(|| agents.first().map(|a| a.id.clone()));
        let options = rd::LaunchOptions {
            default_plan: settings.default_mode == ExecutionMode::Plan,
            default_worktree: settings.default_isolation == IsolationMode::Worktree,
            default_project: projects.first().map(|p| p.path.clone()),
            agents,
            projects,
            default_agent,
        };
        CompanionResponse { launch: serde_json::to_value(&options).ok(), ..CompanionResponse::success(&request.id) }
    }

    async fn start(&self, request: &CompanionRequest) -> CompanionResponse {
        let known = self.started.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|(r, _)| *r == request.id).map(|(_, s)| s.clone());
        if let Some(created) = known {
            return CompanionResponse {
                sessions: Some(self.listed().await),
                created: Some(created),
                ..CompanionResponse::success(&request.id)
            };
        }
        let Some(launch) = &request.launch else { return fail(request, CompanionError::BadRequest) };
        let Some(provider) = RunProvider::ALL.into_iter().find(|p| p.id() == launch.agent).filter(|p| launchable().contains(p)) else {
            return fail(request, CompanionError::BadRequest);
        };
        let Some(words) = CompanionPolicy::clean_message(&launch.task) else { return fail(request, CompanionError::BadRequest) };
        let asked = CompanionRequest { text: Some(words), ..request.clone() };
        let Some(task) = rd::message(&asked, &self.images) else { return fail(request, CompanionError::BadRequest) };
        let settings = self.settings();
        let project = paths::normalize(&launch.project);
        // Only a folder the owner of this host shared: a client cannot point an agent at an arbitrary path.
        if !shared_projects(&settings).contains(&project) {
            return fail(request, CompanionError::NotAllowedFromPhone);
        }
        let capabilities = provider.capabilities();
        let plan = launch.plan && capabilities.plan_mode;
        let model = match &launch.model {
            Some(m) if models(provider, &settings).contains(m) => m.clone(),
            _ => settings.model(provider),
        };
        let title: String = launch.title.as_deref().unwrap_or_default().trim().chars().filter(|c| !c.is_control()).take(80).collect();
        let mut config = NewRunConfig {
            title,
            task: task.clone(),
            provider,
            profile_id: provider.id().into(),
            model,
            effort: settings.default_efforts.get(provider.id()).cloned(),
            mode: if plan { ExecutionMode::Plan } else { ExecutionMode::Agent },
            permission: rd::phone_permission(provider, settings.permission(provider), plan),
            project_path: project.clone(),
            worktree_root: settings.worktree_root.clone(),
            isolation: IsolationMode::Folder,
            ..Default::default()
        };
        let worktree = launch.worktree;
        let manager = self.manager.clone();
        let outcome = tokio::task::spawn_blocking(move || -> Result<Uuid, Option<String>> {
            if worktree {
                let info = manager.inspect_project(&project);
                if !manager.git_available() || info.repo_root.is_none() || !info.has_commits {
                    return Err(None);
                }
                config.isolation = IsolationMode::Worktree;
                config.base_branch = match info.default_base.filter(|b| info.branches.contains(b)) {
                    Some(base) => base,
                    None => info.current_branch.or_else(|| info.branches.first().cloned()).unwrap_or_default(),
                };
                config.branch_name = nook_core::workspace::models::branch_name(&task, Uuid::new_v4());
            }
            manager.start(config, false).map_err(Some)
        })
        .await
        .unwrap_or(Err(Some(String::new())));
        let id = match outcome {
            Ok(id) => id,
            Err(None) => return fail(request, CompanionError::BadRequest),
            Err(Some(message)) => {
                return CompanionResponse { message: Some(message), ..CompanionResponse::failure(&request.id, CompanionError::Failed) }
            }
        };
        {
            let mut list = self.started.lock().unwrap_or_else(|e| e.into_inner());
            list.push_back((request.id.clone(), id.to_string()));
            if list.len() > 64 {
                list.pop_front();
            }
        }
        CompanionResponse { sessions: Some(self.listed().await), created: Some(id.to_string()), ..CompanionResponse::success(&request.id) }
    }

    async fn timeline(&self, request: &CompanionRequest) -> CompanionResponse {
        let Some(session) = request.session.clone() else { return fail(request, CompanionError::UnknownSession) };
        let Some(id) = Uuid::parse_str(&session).ok().filter(|id| self.manager.run(*id).is_some()) else {
            return fail(request, CompanionError::UnknownSession);
        };
        let manager = self.manager.clone();
        let before = request.item.clone();
        let entries = tokio::task::spawn_blocking(move || rd::timeline_page(&manager.timeline(id), before.as_deref())).await.ok();
        let Some(entries) = entries else { return fail(request, CompanionError::UnknownSession) };
        CompanionResponse {
            timeline: serde_json::to_value(&entries).ok(),
            timeline_session: Some(session),
            timeline_before: request.item.clone(),
            ..CompanionResponse::success(&request.id)
        }
    }
}

fn fail(request: &CompanionRequest, error: CompanionError) -> CompanionResponse {
    CompanionResponse::failure(&request.id, error)
}

/// The folders this host lets a client start agents in: the ones its owner added (`nook-host project add`).
pub fn shared_projects(settings: &WorkspaceSettings) -> Vec<String> {
    nook_core::workspace::bridge_nook::projects(settings, &|p| Path::new(p).is_dir())
}

/// Agents installed on this host.
pub fn launchable() -> Vec<RunProvider> {
    RunProvider::ALL
        .into_iter()
        .filter(|p| {
            let found = nook_core::agents::find_executable(p.kind()).map(|e| e.to_string_lossy().into_owned());
            nook_core::workspace::driver::session_executable(*p, found).is_some()
        })
        .collect()
}

fn models(provider: RunProvider, settings: &WorkspaceSettings) -> Vec<String> {
    let mut list: Vec<String> = provider.suggested_models().into_iter().map(str::to_string).collect();
    let remembered = settings.model(provider);
    if !list.contains(&remembered) {
        list.push(remembered);
    }
    list.truncate(16);
    list
}

fn model_name(model: &str) -> String {
    if model.is_empty() {
        "Default".into()
    } else {
        CompanionPolicy::excerpt(model).chars().take(80).collect()
    }
}

#[async_trait]
impl CompanionBackend for HostBackend {
    async fn sessions(&self) -> Vec<BackendSession> {
        let manager = self.manager.clone();
        tokio::task::spawn_blocking(move || collect(&manager)).await.unwrap_or_default()
    }

    async fn decide(&self, session: &str, item: &str, allow: bool) -> Result<(), String> {
        self.decide_with_reason(session, item, allow, None).await
    }

    async fn decide_with_reason(&self, session: &str, item: &str, allow: bool, reason: Option<&str>) -> Result<(), String> {
        let decision = if allow { ApprovalDecision::Allow } else { ApprovalDecision::Deny };
        self.manager.decide_with_reason(Self::run_id(session)?, item, decision, reason)
    }

    async fn answer(&self, session: &str, item: &str, text: &str) -> Result<(), String> {
        self.manager.answer_question(Self::run_id(session)?, item, &[vec![text.to_string()]])
    }

    async fn send(&self, session: &str, text: &str) -> Result<(), String> {
        self.manager.send(Self::run_id(session)?, text)
    }

    async fn stop(&self, session: &str) -> Result<(), String> {
        let run = Self::run_id(session)?;
        if self.manager.run(run).is_none() {
            return Err("This session no longer exists.".into());
        }
        self.manager.stop(run);
        Ok(())
    }

    fn features(&self) -> Vec<&'static str> {
        vec![feature::START, feature::TIMELINE]
    }

    async fn extra(&self, request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
        Some(match request.op {
            CompanionOp::Options => self.options(request).await,
            CompanionOp::Start => self.start(request).await,
            CompanionOp::Timeline => self.timeline(request).await,
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_existing_shared_folders_are_offered() {
        let dir = std::env::temp_dir().join(format!("nook-host-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut settings = WorkspaceSettings::default();
        settings.remember_project(&dir.to_string_lossy());
        settings.remember_project("/definitely/not/here/nook-host");
        let shared = shared_projects(&settings);
        assert_eq!(shared, vec![paths::normalize(&dir.to_string_lossy())]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
