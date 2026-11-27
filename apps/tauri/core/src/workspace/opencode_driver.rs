//! OpenCode 2 over its own server (`opencode serve`, `WorkspaceManager+OpenCodeServer` + `OpenCodeServerTurnDriver` on
//! the Mac): one shared server per `(executable, profile_id)` that stays up while sessions use it. A turn is an HTTP
//! prompt; the SSE stream delivers text, thinking, tools, permissions (with denial reasons), forms (questions), token
//! usage, compaction, and execution completion. Unsupported 1.x binaries or startup failures fall back to ACP.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use serde_json::{json, Value};
use uuid::Uuid;

use super::super::acp;
use super::super::bridge;
use super::super::handoff;
use super::super::models::*;
use super::super::opencode_protocol::{self, OpenCodeEvent, OpenCodeForm, OpenCodeOutcome, OpenCodePermission, Rule};
use super::super::opencode_server::{HostCallbacks, OpenCodeLink, OpenCodeServerError, OpenCodeServerHost, OpenCodeToolState};
use super::*;

const OPENCODE_IDLE_SECONDS: u64 = 10 * 60;
const OPENCODE_HOST_GRACE_SECONDS: u64 = 60;
const OPENCODE_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const OPENCODE_INTERRUPT_TIMEOUT: Duration = Duration::from_secs(10);
const OPENCODE_FORCE_STOP_TIMEOUT: Duration = Duration::from_secs(10);

impl Manager {
    /// Whether this session should run over OpenCode 2's own `opencode serve` rather than ACP.
    pub(super) fn uses_opencode_server(&self, id: Uuid, executable: &str) -> bool {
        let s = self.lock();
        let Some(run) = s.runs.iter().find(|r| r.id == id) else { return false };
        if run.provider != RunProvider::Opencode {
            return false;
        }
        if s.opencode_links.contains_key(&id) {
            return true;
        }
        drop(s);
        if !self.open_code_server_enabled() {
            return false;
        }
        !self.lock().opencode_fallback.contains(executable)
    }

    // MARK: - Turns

    pub(super) fn launch_opencode_turn(self: &Arc<Self>, id: Uuid, prompt: String, executable: String, show_prompt: bool) {
        let mut out = Out::default();
        let ready_action = {
            let mut s = self.lock();
            if s.processes.contains_key(&id) || (s.opencode_links.contains_key(&id) && s.turns.contains_key(&id)) {
                return;
            }
            if let Some(timer) = s.opencode_idle_close.remove(&id) {
                timer.abort();
            }
            Self::clear_usage_limit(&mut s, id);
            Self::drop_finished_setup(&mut s, id);
            Self::load_timeline(&self.store, &mut s, id);
            let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return };
            if show_prompt {
                s.idle_compacting.remove(&id);
                Self::append(&mut s, id, RunEvent::new(EventKind::User, prompt.clone()), &mut out);
            }
            let now = Utc::now();
            s.turns.insert(id, TurnState { started: Some(now), ..Default::default() });
            if let Some(link) = s.opencode_links.get_mut(&id) {
                link.prompt_sent = false;
                link.usage = TurnUsage::default();
                link.tools.clear();
                link.replied = false;
                link.unprompted = false;
                link.text_items.clear();
                link.thinking_items.clear();
            }
            if let Some(r) = s.runs.iter_mut().find(|r| r.id == id) {
                if matches!(r.status, RunStatus::Completed | RunStatus::Failed | RunStatus::Stopped) {
                    r.move_to(RunStatus::Preparing, None, now);
                }
                r.move_to(RunStatus::Running, None, now);
                r.turn_started_at = Some(now);
                crate::services::nook_telemetry::shared().turn_started(id, &r.usage, now);
                if r.tasks.as_ref().is_some_and(|t| {
                    t.iter().all(|x| matches!(x.status, super::super::tasks::StepStatus::Done | super::super::tasks::StepStatus::Cancelled))
                }) {
                    r.tasks = None;
                }
            }
            s.dirty_runs = true;
            let (project, agent) = (run.project_name(), run.provider.display_name());
            self.recap.note(|r, now| r.prompt(&format!("run-{id}"), &project, agent, now));
            out.push(ManagerEvent::Changed);

            let linked_ready = s.opencode_links.get(&id).and_then(|link| {
                let host_up = s.opencode_hosts.get(&link.host).is_some_and(|h| h.is_running());
                host_up.then_some(!link.opening && link.session_id.is_some())
            });
            match linked_ready {
                Some(true) => Some(true),
                Some(false) => {
                    s.opencode_warm_prompts.insert(id, prompt.clone());
                    Some(false)
                }
                None => None,
            }
        };
        self.emit(out);
        match ready_action {
            Some(true) => self.send_opencode_prompt(id, prompt),
            Some(false) => {}
            None => self.connect_opencode(id, executable, Some(prompt)),
        }
    }

    /// Starts (or reuses) the account's `opencode serve` host and opens the session on it.
    fn connect_opencode(self: &Arc<Self>, id: Uuid, executable: String, prompt: Option<String>) {
        let Some(run) = self.run(id) else { return };
        let host = self.opencode_host(&run, &executable);
        let host_key = host.key.clone();
        let mut out = Out::default();
        {
            let mut s = self.lock();
            s.opencode_links.insert(id, OpenCodeLink::new(host_key.clone(), run.working_directory.clone()));
            if let Some(p) = prompt {
                s.opencode_warm_prompts.insert(id, p);
                let program =
                    Path::new(&executable).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| executable.clone());
                let cmd_line = std::iter::once(program)
                    .chain(opencode_protocol::ARGUMENTS.iter().map(|a| (*a).to_string()))
                    .collect::<Vec<_>>()
                    .join(" ");
                let mut launch = RunEvent::new(EventKind::System, cmd_line);
                launch.tool = Some("launch".into());
                Self::append(&mut s, id, launch, &mut out);
            }
        }
        self.emit(out);

        let manager = Arc::clone(self);
        self.runtime.spawn(async move {
            let result = host.wait_ready().await;
            let still_same_host = manager.lock().opencode_links.get(&id).is_some_and(|l| l.host == host_key);
            if !still_same_host {
                return;
            }
            match result {
                Ok(()) => manager.open_opencode_session(id),
                Err(err) => manager.opencode_start_failed(id, err, executable),
            }
        });
    }

    /// Returns the running host for `(executable, profile_id)` or spawns a new one.
    fn opencode_host(self: &Arc<Self>, run: &WorkspaceRun, executable: &str) -> Arc<OpenCodeServerHost> {
        let key = format!("{executable}|{}", run.profile_id);
        {
            let mut s = self.lock();
            if let Some(stop_timer) = s.opencode_host_stops.remove(&key) {
                stop_timer.abort();
            }
            if let Some(existing) = s.opencode_hosts.get(&key) {
                if existing.is_running() {
                    return Arc::clone(existing);
                }
            }
        }

        let m_events = Arc::clone(self);
        let k_events = key.clone();
        let m_reconn = Arc::clone(self);
        let k_reconn = key.clone();
        let m_gone = Arc::clone(self);
        let k_gone = key.clone();

        let callbacks = HostCallbacks {
            on_events: Arc::new(move |events| m_events.handle_opencode_events(&k_events, events)),
            on_reconnected: Arc::new(move || m_reconn.opencode_reconnected(&k_reconn)),
            on_gone: Arc::new(move |msg| m_gone.opencode_host_gone(&k_gone, msg)),
        };
        let host = OpenCodeServerHost::new(key.clone(), executable.to_string(), self.runtime.clone(), callbacks);
        self.lock().opencode_hosts.insert(key, Arc::clone(&host));

        let account_env = (self.hooks.account_environment)(&run.profile_id);
        let home = dirs::home_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|| run.working_directory.clone());
        host.start(account_env, home);
        host
    }

    /// The server could not be used: remember the executable for ACP fallback (until Nook restarts) and launch the
    /// waiting prompt over ACP.
    fn opencode_start_failed(self: &Arc<Self>, id: Uuid, error: OpenCodeServerError, executable: String) {
        let mut out = Out::default();
        let fallback_prompt = {
            let mut s = self.lock();
            if let Some(link) = s.opencode_links.remove(&id) {
                if s.opencode_hosts.get(&link.host).is_some_and(|h| !h.is_running()) {
                    s.opencode_hosts.remove(&link.host);
                }
            }
            s.opencode_fallback.insert(executable.clone());
            let waiting = s.opencode_warm_prompts.remove(&id);
            if s.turns.get(&id).is_some_and(|t| t.stopping) {
                drop(s);
                self.opencode_stopped(id);
                return;
            }
            let active_turn = s.turns.contains_key(&id);
            if !active_turn {
                return;
            }
            let Some(waiting) = waiting else { return };
            s.turns.remove(&id);
            let reason = match error {
                OpenCodeServerError::Unsupported(_) => tr(
                    "Deze OpenCode heeft geen server die Nook kan gebruiken (OpenCode 2.0.18 of nieuwer); Nook gebruikt ACP.",
                    "This OpenCode has no server Nook can use (OpenCode 2.0.18 or newer); Nook uses ACP.",
                )
                .to_string(),
                OpenCodeServerError::Launch(_) | OpenCodeServerError::Timeout | OpenCodeServerError::Exited(_) => trf(
                    "De server van OpenCode startte niet ({error}); Nook gebruikt ACP.",
                    "OpenCode's server did not start ({error}); Nook uses ACP.",
                    &[("error", &error)],
                ),
            };
            Self::append(&mut s, id, RunEvent::new(EventKind::System, reason), &mut out);
            waiting
        };
        self.emit(out);
        self.launch_turn(id, fallback_prompt, executable, false);
    }

    fn open_opencode_session(self: &Arc<Self>, id: Uuid) {
        let Some((run, host_key, host)) = ({
            let s = self.lock();
            let run = s.runs.iter().find(|r| r.id == id).cloned();
            let link = s.opencode_links.get(&id).cloned();
            let host = link.as_ref().and_then(|l| s.opencode_hosts.get(&l.host).cloned());
            run.zip(link).zip(host).map(|((r, l), h)| (r, l.host, h))
        }) else {
            return;
        };

        let manager = Arc::clone(self);
        self.runtime.spawn(async move {
            let mut session_id: Option<String> = None;

            if let Some(known) = run.provider_session_id.as_deref().filter(|s| !s.is_empty()) {
                let reply = host.send("GET", &format!("/api/session/{known}"), &[], None, OPENCODE_REQUEST_TIMEOUT).await;
                if !manager.same_opencode_host(id, &host_key) {
                    return;
                }
                if reply.ok() {
                    if let Some(info) = reply.json.as_ref().and_then(opencode_protocol::parse_session) {
                        session_id = Some(info.id);
                        if let Some(link) = manager.lock().opencode_links.get_mut(&id) {
                            link.current_model = info.model;
                        }
                    }
                } else if reply.not_found() {
                    let mut out = Out::default();
                    {
                        let mut s = manager.lock();
                        let agent = run.provider.display_name();
                        Self::append(
                            &mut s,
                            id,
                            RunEvent::new(
                                EventKind::System,
                                trf(
                                    "{agent} kan een eerder gesprek niet laden; dit wordt een nieuw gesprek.",
                                    "{agent} cannot load an earlier conversation; this becomes a new one.",
                                    &[("agent", &agent)],
                                ),
                            ),
                            &mut out,
                        );
                        Self::update(&mut s, id, |r| r.provider_session_id = None);
                        if let Some(waiting) = s.opencode_warm_prompts.get(&id).cloned() {
                            let events = s.events.get(&id).cloned().unwrap_or_default();
                            if let Some(rendered) = handoff::render(&events, 0, run.provider.display_name(), handoff::TOKEN_BUDGET) {
                                s.opencode_warm_prompts.insert(id, format!("{}\n\n{waiting}", rendered.text));
                            }
                        }
                    }
                    manager.emit(out);
                } else {
                    manager.opencode_open_failed(id, reply.error);
                    return;
                }
            }

            if session_id.is_none() {
                let rules = manager.opencode_rules(id);
                let model = opencode_protocol::model_ref(&run.model, run.effort.as_deref());
                let agent = opencode_protocol::agent_for_mode(run.mode);
                let body = opencode_protocol::new_session_body(&run.working_directory, model.clone(), agent, &rules);
                let reply = host.send("POST", "/api/session", &[], Some(body), OPENCODE_REQUEST_TIMEOUT).await;
                if !manager.same_opencode_host(id, &host_key) {
                    return;
                }
                let Some(info) = reply.ok().then_some(reply.json.as_ref()).flatten().and_then(opencode_protocol::parse_session) else {
                    manager.opencode_open_failed(id, reply.error);
                    return;
                };
                session_id = Some(info.id);
                let mut s = manager.lock();
                if let Some(link) = s.opencode_links.get_mut(&id) {
                    link.fresh = true;
                    link.applied_rules = Some(rules);
                    link.applied_agent = Some(agent.to_string());
                    link.current_model = info.model;
                    if model.is_some() {
                        link.applied_model = Some(opencode_model_key(&run));
                    }
                }
            }

            let Some(session_id) = session_id else { return };
            {
                let mut s = manager.lock();
                if let Some(link) = s.opencode_links.get_mut(&id) {
                    link.session_id = Some(session_id.clone());
                }
                Self::update(&mut s, id, |r| {
                    r.provider_session_id = Some(session_id.clone());
                });
            }

            manager.prepare_opencode_session(id).await;
            if !manager.same_opencode_host(id, &host_key) {
                return;
            }
            let next_action = {
                let mut s = manager.lock();
                if let Some(link) = s.opencode_links.get_mut(&id) {
                    link.opening = false;
                }
                if s.turns.get(&id).is_some_and(|t| t.stopping) {
                    s.opencode_warm_prompts.remove(&id);
                    Some(Err(()))
                } else if s.turns.contains_key(&id) {
                    s.opencode_warm_prompts.remove(&id).map(Ok)
                } else {
                    None
                }
            };
            match next_action {
                Some(Err(())) => manager.opencode_stopped(id),
                Some(Ok(next)) => manager.send_opencode_prompt(id, next),
                None => manager.schedule_opencode_idle_close(id),
            }
        });
    }

    fn same_opencode_host(&self, id: Uuid, host_key: &str) -> bool {
        self.lock().opencode_links.get(&id).is_some_and(|l| l.host == host_key)
    }

    fn opencode_open_failed(self: &Arc<Self>, id: Uuid, message: Option<String>) {
        let (waiting, stopping, active) = {
            let mut s = self.lock();
            let waiting = s.opencode_warm_prompts.remove(&id);
            let stopping = s.turns.get(&id).is_some_and(|t| t.stopping);
            let active = s.turns.contains_key(&id);
            (waiting, stopping, active)
        };
        self.close_opencode_session(id);
        if stopping {
            self.opencode_stopped(id);
            return;
        }
        if waiting.is_some() && active {
            let msg = message
                .filter(|m| !m.is_empty())
                .unwrap_or_else(|| tr("De agent opende geen sessie.", "The agent opened no session.").to_string());
            self.fail_opencode_turn(id, msg);
        }
    }

    /// Once per open session: fetches OpenCode's models and `/` commands for this folder and registers Nook's MCP
    /// bridge server scoped exclusively to this session.
    async fn prepare_opencode_session(self: &Arc<Self>, id: Uuid) {
        let Some((run, directory, host)) = ({
            let mut s = self.lock();
            let already = s.opencode_links.get(&id).is_none_or(|l| l.prepared);
            if already {
                return;
            }
            let Some(link) = s.opencode_links.get_mut(&id) else { return };
            link.prepared = true;
            let directory = link.directory.clone();
            let host_key = link.host.clone();
            let host = s.opencode_hosts.get(&host_key).cloned();
            let run = s.runs.iter().find(|r| r.id == id).cloned();
            run.zip(host).map(|(r, h)| (r, directory, h))
        }) else {
            return;
        };

        let location = opencode_protocol::location_query(&directory);
        let (models_reply, _default_reply, commands_reply) = tokio::join!(
            host.send("GET", "/api/model", &location, None, OPENCODE_REQUEST_TIMEOUT),
            host.send("GET", "/api/model/default", &location, None, OPENCODE_REQUEST_TIMEOUT),
            host.send("GET", "/api/command", &location, None, OPENCODE_REQUEST_TIMEOUT),
        );

        let offered = models_reply.json.as_ref().map(opencode_protocol::parse_models).unwrap_or_default();
        let listed = commands_reply.json.as_ref().map(opencode_protocol::parse_commands).unwrap_or_default();
        {
            let mut s = self.lock();
            if let Some(link) = s.opencode_links.get_mut(&id) {
                link.models = offered;
                link.commands = listed.clone();
                let active_model = if run.model.is_empty() { link.current_model.as_deref() } else { Some(run.model.as_str()) };
                if let Some(win) = active_model.and_then(|m| link.models.iter().find(|x| x.id == m)).and_then(|m| m.context_window) {
                    link.context_window = Some(win);
                }
            }
            if !listed.is_empty() {
                s.commands.insert(id, listed);
            }
        }

        if let Some(launch) = (self.hooks.bridge)() {
            let name = opencode_protocol::bridge_server(id);
            let mut env = BTreeMap::new();
            env.insert("NOOK_RUN_ID".into(), id.to_string());
            let config = opencode_protocol::bridge_config(&launch.script, &["--agent".into(), run.provider.id().into()], &env);
            let reply = host.send("PUT", &format!("/api/experimental/mcp/{name}"), &location, Some(config), OPENCODE_REQUEST_TIMEOUT).await;
            if reply.ok() {
                if let Some(link) = self.lock().opencode_links.get_mut(&id) {
                    link.bridge_server = Some(name);
                }
            }
        }
    }

    fn opencode_rules(&self, id: Uuid) -> Vec<Rule> {
        let s = self.lock();
        let Some(run) = s.runs.iter().find(|r| r.id == id) else { return vec![] };
        let link = s.opencode_links.get(&id);
        let grants = link.map(|l| l.grants.as_slice()).unwrap_or(&[]);
        let bridge = link.and_then(|l| l.bridge_server.as_deref());
        opencode_protocol::rules(run.permission, run.mode, grants, bridge)
    }

    /// Applies the run's model (with effort as variant), agent (`build`/`plan`), and permission rules to the session,
    /// sending only fields that changed since the last update.
    pub(super) async fn apply_opencode_settings(self: &Arc<Self>, id: Uuid) {
        let Some((run, session, host, applied_model, applied_agent, applied_rules, current_model)) = ({
            let s = self.lock();
            let run = s.runs.iter().find(|r| r.id == id).cloned();
            let link = s.opencode_links.get(&id).cloned();
            let host = link.as_ref().and_then(|l| s.opencode_hosts.get(&l.host).cloned());
            run.zip(link).zip(host).and_then(|((r, l), h)| {
                let session = l.session_id?;
                Some((r, session, h, l.applied_model, l.applied_agent, l.applied_rules, l.current_model))
            })
        }) else {
            return;
        };

        let model = if run.model.is_empty() { current_model.as_deref() } else { Some(run.model.as_str()) };
        let key = opencode_model_key(&run);
        if applied_model.as_deref() != Some(key.as_str()) && (!run.model.is_empty() || run.effort.is_some() || applied_model.is_some()) {
            if let Some(m) = model {
                if let Some(model_ref) = opencode_protocol::model_ref(m, run.effort.as_deref()) {
                    if let Some(link) = self.lock().opencode_links.get_mut(&id) {
                        link.applied_model = Some(key);
                    }
                    let reply = host
                        .send(
                            "POST",
                            &format!("/api/session/{session}/model"),
                            &[],
                            Some(json!({ "model": model_ref })),
                            OPENCODE_REQUEST_TIMEOUT,
                        )
                        .await;
                    if !reply.ok() {
                        let mut out = Out::default();
                        let agent = run.provider.display_name();
                        let note = trf(
                            "{agent} kon niet wisselen naar {model}.",
                            "{agent} could not switch to {model}.",
                            &[("agent", &agent), ("model", &m)],
                        );
                        Self::append(&mut self.lock(), id, RunEvent::new(EventKind::System, note), &mut out);
                        self.emit(out);
                    }
                }
            }
        }

        let agent = opencode_protocol::agent_for_mode(run.mode);
        if applied_agent.as_deref() != Some(agent) {
            if let Some(link) = self.lock().opencode_links.get_mut(&id) {
                link.applied_agent = Some(agent.to_string());
            }
            let _ = host
                .send("POST", &format!("/api/session/{session}/agent"), &[], Some(json!({ "agent": agent })), OPENCODE_REQUEST_TIMEOUT)
                .await;
        }

        let rules = self.opencode_rules(id);
        if applied_rules.as_deref() != Some(rules.as_slice()) {
            if let Some(link) = self.lock().opencode_links.get_mut(&id) {
                link.applied_rules = Some(rules.clone());
            }
            let rules_json: Vec<Value> = rules.iter().map(Rule::json).collect();
            let _ = host
                .send(
                    "PATCH",
                    &format!("/api/session/{session}"),
                    &[],
                    Some(json!({ "permissions": rules_json })),
                    OPENCODE_REQUEST_TIMEOUT,
                )
                .await;
        }

        // Refresh context window from learned model metadata.
        {
            let mut s = self.lock();
            if let Some(link) = s.opencode_links.get_mut(&id) {
                let active_model = if run.model.is_empty() { link.current_model.as_deref() } else { Some(run.model.as_str()) };
                if let Some(win) = active_model.and_then(|m| link.models.iter().find(|x| x.id == m)).and_then(|m| m.context_window) {
                    link.context_window = Some(win);
                }
            }
        }
    }

    fn send_opencode_prompt(self: &Arc<Self>, id: Uuid, prompt: String) {
        let manager = Arc::clone(self);
        self.runtime.spawn(async move {
            manager.apply_opencode_settings(id).await;
            let Some((run, session, host, fresh, commands)) = ({
                let mut s = manager.lock();
                if !s.turns.contains_key(&id) {
                    return;
                }
                if s.turns.get(&id).is_some_and(|t| t.stopping) {
                    drop(s);
                    manager.opencode_stopped(id);
                    return;
                }
                let run = s.runs.iter().find(|r| r.id == id).cloned();
                let (session, host_key, fresh, commands) = match s.opencode_links.get_mut(&id) {
                    Some(link) => {
                        let Some(sid) = link.session_id.clone() else { return };
                        link.prompt_sent = true;
                        let fresh = link.fresh;
                        link.fresh = false;
                        (sid, link.host.clone(), fresh, link.commands.clone())
                    }
                    None => return,
                };
                let host = s.opencode_hosts.get(&host_key).cloned();
                run.zip(host).map(|(r, h)| (r, session, h, fresh, commands))
            }) else {
                return;
            };

            let reply = if let Some((name, text)) = opencode_protocol::parse_slash_command(&prompt, &commands) {
                if name == "compact" {
                    host.send("POST", &format!("/api/session/{session}/compact"), &[], Some(json!({})), OPENCODE_REQUEST_TIMEOUT).await
                } else {
                    host.send(
                        "POST",
                        &format!("/api/session/{session}/command"),
                        &[],
                        Some(json!({ "name": name, "text": text })),
                        OPENCODE_REQUEST_TIMEOUT,
                    )
                    .await
                }
            } else {
                let mut text = prompt.clone();
                if fresh {
                    let has_bridge = (manager.hooks.bridge)().is_some();
                    let instructions = {
                        let own = run.instructions.trim().to_string();
                        if has_bridge {
                            [own, bridge::INSTRUCTIONS.to_string()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n\n")
                        } else {
                            own
                        }
                    };
                    if !instructions.is_empty() {
                        text = format!("{instructions}\n\n{text}");
                    }
                }
                let pictures: Vec<String> = acp::picture_paths(&prompt).into_iter().filter(|p| Path::new(p).exists()).collect();
                host.send(
                    "POST",
                    &format!("/api/session/{session}/prompt"),
                    &[],
                    Some(opencode_protocol::prompt_body(&text, &pictures)),
                    OPENCODE_REQUEST_TIMEOUT,
                )
                .await
            };

            if reply.ok() {
                return;
            }
            let (still_turn, stopping) = {
                let s = manager.lock();
                let same = s.opencode_links.get(&id).and_then(|l| l.session_id.as_deref()) == Some(session.as_str());
                (same && s.turns.contains_key(&id), s.turns.get(&id).is_some_and(|t| t.stopping))
            };
            if !still_turn {
                return;
            }
            if stopping {
                manager.opencode_stopped(id);
            } else {
                let err = reply.error.unwrap_or_else(|| format!("HTTP {}", reply.status));
                manager.fail_opencode_turn(id, err);
            }
        });
    }

    // MARK: - Stop

    /// Stops an active OpenCode server turn via `POST /api/session/{id}/interrupt`. Returns `true` if handled.
    pub(super) fn stop_opencode_turn(self: &Arc<Self>, id: Uuid) -> bool {
        let mut out = Out::default();
        let target = {
            let mut s = self.lock();
            if !s.opencode_links.contains_key(&id) {
                return false;
            }
            let active = s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.status.is_active());
            if !active {
                return false;
            }
            if s.turns.get(&id).is_some_and(|t| t.stopping) {
                return true;
            }
            if let Some(t) = s.turns.get_mut(&id) {
                t.stopping = true;
            }
            Self::cancel_opencode_requests_locked(&mut s, id);
            Self::expire_approvals(&mut s, id, &mut out);
            Self::drop_opencode_questions_locked(&mut s, id, &mut out);
            Self::append(&mut s, id, RunEvent::new(EventKind::System, tr("Stoppen…", "Stopping…")), &mut out);
            let link = s.opencode_links.get(&id).cloned();
            let host = link.as_ref().and_then(|l| s.opencode_hosts.get(&l.host).cloned());
            (link, host)
        };
        self.emit(out);

        let (Some(link), Some(host)) = target else { return true };
        if link.opening || link.session_id.is_none() {
            return true;
        }
        if !link.prompt_sent {
            self.opencode_stopped(id);
            return true;
        }
        let session = link.session_id.unwrap();
        let manager = Arc::clone(self);
        let host_interrupt = Arc::clone(&host);
        let session_interrupt = session.clone();
        self.runtime.spawn(async move {
            let reply = host_interrupt
                .send("POST", &format!("/api/session/{session_interrupt}/interrupt"), &[], None, OPENCODE_INTERRUPT_TIMEOUT)
                .await;
            let still_stopping = {
                let s = manager.lock();
                s.turns.get(&id).is_some_and(|t| t.stopping)
                    && s.opencode_links.get(&id).and_then(|l| l.session_id.as_deref()) == Some(session_interrupt.as_str())
            };
            if still_stopping && reply.ok() && reply.json.as_ref().and_then(opencode_protocol::parse_interrupted) == Some(false) {
                manager.finish_opencode_turn(id, OpenCodeOutcome::Interrupted { reason: "user".into() });
            }
        });

        // Force-stop fallback clock if the server never emits `execution.interrupted`.
        let manager_force = Arc::clone(self);
        self.runtime.spawn(async move {
            tokio::time::sleep(OPENCODE_FORCE_STOP_TIMEOUT).await;
            let still_stopping = {
                let s = manager_force.lock();
                s.turns.get(&id).is_some_and(|t| t.stopping)
                    && s.opencode_links.get(&id).and_then(|l| l.session_id.as_deref()) == Some(session.as_str())
            };
            if still_stopping {
                let _ = host.send("POST", &format!("/api/session/{session}/interrupt"), &[], None, OPENCODE_INTERRUPT_TIMEOUT).await;
                manager_force.close_opencode_session(id);
                manager_force.opencode_stopped(id);
            }
        });

        true
    }

    fn opencode_stopped(self: &Arc<Self>, id: Uuid) {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            Self::finish_live_text(&mut s, id);
            Self::close_thinking(&mut s, id, &mut out);
            Self::expire_approvals(&mut s, id, &mut out);
            Self::drop_opencode_questions_locked(&mut s, id, &mut out);
            s.turns.remove(&id);
            if let Some(link) = s.opencode_links.get_mut(&id) {
                link.prompt_sent = false;
                link.tools.clear();
                link.text_items.clear();
                link.thinking_items.clear();
            }
            Self::settle_open_work(&mut s, id, true, &mut out);
            Self::update(&mut s, id, |r| {
                r.move_to(RunStatus::Stopped, None, Utc::now());
            });
            Self::append(&mut s, id, RunEvent::new(EventKind::System, tr("Gestopt.", "Stopped.")), &mut out);
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        self.start_waiting_turns();
        self.schedule_opencode_idle_close(id);
    }

    // MARK: - Approvals and Questions

    /// Answers an OpenCode permission request. Returns `true` if `request_id` belonged to an OpenCode server session.
    pub(super) fn decide_opencode(
        self: &Arc<Self>,
        run_id: Uuid,
        request_id: &str,
        decision: ApprovalDecision,
        reason: Option<&str>,
    ) -> bool {
        let mut out = Out::default();
        let allow = decision != ApprovalDecision::Deny && decision != ApprovalDecision::Terminal;
        let reason_text = reason.map(str::trim).filter(|r| !r.is_empty() && !allow).map(str::to_string).unwrap_or_default();

        let (perm, host) = {
            let mut s = self.lock();
            let Some((owner, perm)) = s.opencode_requests.remove(request_id) else { return false };
            if owner != run_id {
                s.opencode_requests.insert(request_id.to_string(), (owner, perm));
                return false;
            }
            let pending = s.approvals.get(&run_id).and_then(|l| l.iter().find(|p| p.id == request_id)).cloned();
            if let Some(l) = s.approvals.get_mut(&run_id) {
                l.retain(|p| p.id != request_id);
            }
            self.recap.note(|r, now| r.decision(allow, now));
            if let Some(p) = pending {
                Self::mutate(&mut s, run_id, p.event_id, &mut out, |e| {
                    e.state = Some(if allow { EventState::Allowed } else { EventState::Denied });
                });
            }
            if s.approvals.get(&run_id).is_none_or(Vec::is_empty) && s.questions.get(&run_id).is_none_or(Vec::is_empty) {
                Self::update(&mut s, run_id, |r| {
                    r.move_to(RunStatus::Running, None, Utc::now());
                });
            }
            out.push(ManagerEvent::ApprovalGone(format!("run-{request_id}")));
            if !allow && !reason_text.is_empty() {
                Self::append(
                    &mut s,
                    run_id,
                    RunEvent::new(EventKind::System, trf("Geweigerd: {reason}", "Denied: {reason}", &[("reason", &reason_text)])),
                    &mut out,
                );
            }
            out.push(ManagerEvent::Changed);
            let host = s.opencode_links.get(&run_id).and_then(|l| s.opencode_hosts.get(&l.host).cloned());
            (perm, host)
        };
        self.emit(out);

        let Some(host) = host else { return true };
        let manager = Arc::clone(self);
        self.runtime.spawn(async move {
            if decision == ApprovalDecision::Always {
                let new_grants = opencode_protocol::grants(&perm.action, &perm.save);
                {
                    let mut s = manager.lock();
                    if let Some(link) = s.opencode_links.get_mut(&run_id) {
                        for grant in new_grants {
                            if !link.grants.contains(&grant) {
                                link.grants.push(grant);
                            }
                        }
                    }
                }
                manager.apply_opencode_settings(run_id).await;
            }
            let reply = host
                .send(
                    "POST",
                    &format!("/api/session/{}/permission/{}/reply", perm.session_id, perm.id),
                    &[],
                    Some(opencode_protocol::permission_reply(allow, &reason_text)),
                    OPENCODE_REQUEST_TIMEOUT,
                )
                .await;
            if !reply.ok() && !reply.not_found() {
                let err = reply.error.unwrap_or_else(|| format!("HTTP {}", reply.status));
                let mut out = Out::default();
                Self::append(
                    &mut manager.lock(),
                    run_id,
                    RunEvent::new(
                        EventKind::Error,
                        trf(
                            "Je antwoord kwam niet aan bij OpenCode: {error}",
                            "Your answer did not reach OpenCode: {error}",
                            &[("error", &err)],
                        ),
                    ),
                    &mut out,
                );
                manager.emit(out);
            }
        });
        true
    }

    /// Answers an OpenCode form question. Returns `true` if `request_id` belonged to an OpenCode form.
    pub(super) fn answer_opencode_question(self: &Arc<Self>, run_id: Uuid, request_id: &str, selections: &[Vec<String>]) -> bool {
        let mut out = Out::default();
        let (form, host) = {
            let mut s = self.lock();
            let Some((owner, form)) = s.opencode_forms.remove(request_id) else { return false };
            if owner != run_id {
                s.opencode_forms.insert(request_id.to_string(), (owner, form));
                return false;
            }
            if let Some(l) = s.questions.get_mut(&run_id) {
                l.retain(|q| q.id != request_id);
            }
            Self::sync_waiting(&mut s, run_id);
            let event = s
                .events
                .get(&run_id)
                .and_then(|l| l.iter().rev().find(|e| e.kind == EventKind::Approval && e.call_id.as_deref() == Some(request_id)))
                .map(|e| e.id);
            let summary = selections.iter().flatten().cloned().collect::<Vec<_>>().join(", ");
            if let Some(ev_id) = event {
                Self::mutate(&mut s, run_id, ev_id, &mut out, |e| {
                    e.state = Some(EventState::Allowed);
                    e.output = Some(format!("Je koos: {summary}"));
                });
            }
            if s.approvals.get(&run_id).is_none_or(Vec::is_empty) && s.questions.get(&run_id).is_none_or(Vec::is_empty) {
                Self::update(&mut s, run_id, |r| {
                    r.move_to(RunStatus::Running, None, Utc::now());
                });
            }
            out.push(ManagerEvent::QuestionGone(format!("runq:{run_id}:{request_id}")));
            out.push(ManagerEvent::Changed);
            let host = s.opencode_links.get(&run_id).and_then(|l| s.opencode_hosts.get(&l.host).cloned());
            (form, host)
        };
        self.emit(out);

        let Some(host) = host else { return true };
        let mut answers: HashMap<String, Vec<String>> = HashMap::new();
        for (field, sel) in form.fields.iter().zip(selections.iter()) {
            answers.insert(field.key.clone(), sel.clone());
        }
        let body = opencode_protocol::form_answer(&form, &answers);
        let manager = Arc::clone(self);
        self.runtime.spawn(async move {
            let reply = host
                .send(
                    "POST",
                    &format!("/api/session/{}/form/{}/reply", form.session_id, form.id),
                    &[],
                    Some(body),
                    OPENCODE_REQUEST_TIMEOUT,
                )
                .await;
            if !reply.ok() && !reply.not_found() {
                let err = reply.error.unwrap_or_else(|| format!("HTTP {}", reply.status));
                let mut out = Out::default();
                Self::append(
                    &mut manager.lock(),
                    run_id,
                    RunEvent::new(
                        EventKind::Error,
                        trf(
                            "Je antwoord kwam niet aan bij OpenCode: {error}",
                            "Your answer did not reach OpenCode: {error}",
                            &[("error", &err)],
                        ),
                    ),
                    &mut out,
                );
                manager.emit(out);
            }
        });
        true
    }

    fn cancel_opencode_requests_locked(s: &mut Inner, id: Uuid) {
        s.opencode_requests.retain(|_, (owner, _)| *owner != id);
    }

    fn drop_opencode_questions_locked(s: &mut Inner, id: Uuid, out: &mut Out) {
        let removed_ids: Vec<String> = s.opencode_forms.iter().filter_map(|(k, (owner, _))| (*owner == id).then_some(k.clone())).collect();
        for k in &removed_ids {
            s.opencode_forms.remove(k);
        }
        if let Some(list) = s.questions.get_mut(&id) {
            list.retain(|q| !q.id.starts_with("ocform-"));
            if list.is_empty() {
                s.questions.remove(&id);
            }
        }
        for k in removed_ids {
            out.push(ManagerEvent::QuestionGone(format!("runq:{id}:{k}")));
        }
        Self::sync_waiting(s, id);
    }

    fn present_opencode_permission(s: &mut Inner, id: Uuid, permission: OpenCodePermission, out: &mut Out) {
        let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return };
        Self::finish_live_text(s, id);
        let request_id = format!("oc-{}", permission.id);
        if s.opencode_requests.contains_key(&request_id) {
            return;
        }
        let subject = permission.resources.join(", ");
        let mut input_map = serde_json::Map::new();
        input_map.insert("action".into(), Value::String(permission.action.clone()));
        match permission.action.as_str() {
            "shell" => {
                input_map.insert("command".into(), Value::String(subject.clone()));
            }
            "edit" | "read" | "external_directory" => {
                input_map.insert("path".into(), Value::String(permission.resources.first().cloned().unwrap_or_default()));
            }
            _ => {
                input_map.insert("resources".into(), Value::Array(permission.resources.iter().cloned().map(Value::String).collect()));
            }
        }
        let input = Value::Object(input_map);
        let tool = if permission.action == "edit" { "Edit".to_string() } else { permission.action.clone() };
        let summary = if subject.is_empty() {
            permission.action.clone()
        } else {
            format!("{} · {}", permission.action, tool_summary::one_line(&subject, 200))
        };
        let event = RunEvent::new(EventKind::Approval, summary.clone())
            .with_tool(&tool)
            .with_call(&request_id)
            .with_detail(tool_summary::json(&input))
            .with_state(EventState::Pending);
        let pending = PendingPermission {
            id: request_id.clone(),
            run_id: id,
            tool,
            summary,
            input,
            suggestions: Some(json!(["always"])),
            event_id: event.id,
            created: Utc::now(),
        };
        Self::append(s, id, event, out);
        s.opencode_requests.insert(request_id, (id, permission));
        s.approvals.entry(id).or_default().push(pending.clone());
        Self::update(s, id, |r| {
            r.move_to(RunStatus::WaitingApproval, None, Utc::now());
        });
        out.push(ManagerEvent::Approval(Self::approval_view(&run, &pending)));
        out.push(ManagerEvent::Changed);
    }

    fn present_opencode_form(self: &Arc<Self>, id: Uuid, form: OpenCodeForm) {
        if form.unsupported.is_some() {
            let mut out = Out::default();
            let host = {
                let mut s = self.lock();
                Self::append(
                    &mut s,
                    id,
                    RunEvent::new(
                        EventKind::System,
                        tr(
                            "OpenCode stelde een vraag die Nook nog niet kan tonen; die is overgeslagen.",
                            "OpenCode asked a question Nook cannot show yet; it was skipped.",
                        ),
                    ),
                    &mut out,
                );
                s.opencode_links.get(&id).and_then(|l| s.opencode_hosts.get(&l.host).cloned())
            };
            self.emit(out);
            if let Some(host) = host {
                self.runtime.spawn(async move {
                    let _ = host
                        .send("DELETE", &format!("/api/session/{}/form/{}", form.session_id, form.id), &[], None, OPENCODE_REQUEST_TIMEOUT)
                        .await;
                });
            }
            return;
        }
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return };
            Self::finish_live_text(&mut s, id);
            let form_req_id = format!("ocform-{}", form.id);
            if s.questions.get(&id).is_some_and(|l| l.iter().any(|q| q.id == form_req_id)) {
                return;
            }
            let items = form.question_items();
            let q = PendingQuestion {
                id: form_req_id.clone(),
                run_id: id,
                items: items.clone(),
                input: json!({ "formId": form.id, "title": form.title }),
                created: Utc::now(),
                restored: false,
            };
            let mut e = RunEvent::new(EventKind::Approval, tr("Wacht op je antwoord…", "Waiting for your answer…"))
                .with_tool("AskUserQuestion")
                .with_call(&form_req_id)
                .with_state(EventState::Pending);
            e.detail = Some(items.iter().map(|i| i.question.clone()).collect::<Vec<_>>().join("\n"));
            Self::append(&mut s, id, e, &mut out);
            s.opencode_forms.insert(form_req_id, (id, form));
            s.questions.entry(id).or_default().push(q.clone());
            Self::sync_waiting(&mut s, id);
            Self::update(&mut s, id, |r| {
                r.move_to(RunStatus::WaitingApproval, None, Utc::now());
            });
            out.push(ManagerEvent::Question(Self::question_view(&run, &q)));
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
    }

    // MARK: - Events

    fn handle_opencode_events(self: &Arc<Self>, key: &str, events: Vec<OpenCodeEvent>) {
        for event in events {
            let Some(session) = event.session_id().map(str::to_string) else { continue };
            let found = {
                let s = self.lock();
                Self::find_opencode_run(&s, key, &session)
            };
            if let Some((id, is_child)) = found {
                if is_child {
                    self.apply_opencode_child(id, event);
                } else {
                    self.apply_opencode_event(id, event);
                }
                continue;
            }
            if matches!(event, OpenCodeEvent::Permission(_) | OpenCodeEvent::Form(_)) {
                self.adopt_opencode_child(key.to_string(), session, event);
            }
        }
    }

    fn find_opencode_run(s: &Inner, key: &str, session: &str) -> Option<(Uuid, bool)> {
        for (&id, link) in &s.opencode_links {
            if link.host != key {
                continue;
            }
            if link.session_id.as_deref() == Some(session) {
                return Some((id, false));
            }
            if link.children.contains(session) {
                return Some((id, true));
            }
        }
        None
    }

    fn adopt_opencode_child(self: &Arc<Self>, key: String, session: String, event: OpenCodeEvent) {
        let Some(host) = self.lock().opencode_hosts.get(&key).cloned() else { return };
        let manager = Arc::clone(self);
        self.runtime.spawn(async move {
            let reply = host.send("GET", &format!("/api/session/{session}"), &[], None, OPENCODE_REQUEST_TIMEOUT).await;
            let Some(parent) = reply.json.as_ref().and_then(opencode_protocol::parse_session).and_then(|s| s.parent_id) else {
                return;
            };
            let parent_run = {
                let mut s = manager.lock();
                let found = Self::find_opencode_run(&s, &key, &parent).map(|(id, _)| id);
                if let Some(id) = found {
                    if let Some(link) = s.opencode_links.get_mut(&id) {
                        link.children.insert(session);
                    }
                }
                found
            };
            if let Some(id) = parent_run {
                manager.apply_opencode_child(id, event);
            }
        });
    }

    fn apply_opencode_child(self: &Arc<Self>, id: Uuid, event: OpenCodeEvent) {
        if matches!(
            event,
            OpenCodeEvent::Permission(_)
                | OpenCodeEvent::Form(_)
                | OpenCodeEvent::PermissionSettled { .. }
                | OpenCodeEvent::FormSettled { .. }
        ) {
            self.apply_opencode_event(id, event);
        }
    }

    fn apply_opencode_event(self: &Arc<Self>, id: Uuid, event: OpenCodeEvent) {
        match event {
            OpenCodeEvent::ExecutionStarted { .. } => {
                let should_wake = {
                    let s = self.lock();
                    !s.turns.contains_key(&id) && s.runs.iter().find(|r| r.id == id).is_some_and(|r| !r.status.is_active())
                };
                if should_wake {
                    self.wake_opencode(id);
                }
                return;
            }
            OpenCodeEvent::ExecutionEnded { outcome, .. } => {
                let should_finish = {
                    let s = self.lock();
                    s.turns.get(&id).is_some_and(|t| t.stopping || s.opencode_links.get(&id).is_some_and(|l| l.prompt_sent || l.unprompted))
                };
                if should_finish {
                    self.finish_opencode_turn(id, outcome);
                }
                return;
            }
            OpenCodeEvent::Permission(perm) => {
                let active_not_stopping = {
                    let s = self.lock();
                    s.turns.get(&id).is_some_and(|t| !t.stopping)
                };
                if !active_not_stopping {
                    if let Some(host) = self.lock().opencode_links.get(&id).and_then(|l| self.lock_host(&l.host)) {
                        self.runtime.spawn(async move {
                            let _ = host
                                .send(
                                    "POST",
                                    &format!("/api/session/{}/permission/{}/reply", perm.session_id, perm.id),
                                    &[],
                                    Some(json!({ "decision": "reject" })),
                                    OPENCODE_REQUEST_TIMEOUT,
                                )
                                .await;
                        });
                    }
                    return;
                }
                let mut out = Out::default();
                Self::present_opencode_permission(&mut self.lock(), id, perm, &mut out);
                self.emit(out);
                return;
            }
            OpenCodeEvent::PermissionSettled { request, .. } => {
                let request_id = format!("oc-{request}");
                let mut out = Out::default();
                {
                    let mut s = self.lock();
                    if s.opencode_requests.remove(&request_id).is_some() {
                        Self::expire_approval(&mut s, id, &request_id, &mut out);
                        if s.approvals.get(&id).is_none_or(Vec::is_empty)
                            && s.questions.get(&id).is_none_or(Vec::is_empty)
                            && s.turns.contains_key(&id)
                        {
                            Self::update(&mut s, id, |r| {
                                r.move_to(RunStatus::Running, None, Utc::now());
                            });
                            out.push(ManagerEvent::Changed);
                        }
                    }
                }
                self.emit(out);
                return;
            }
            OpenCodeEvent::Form(form) => {
                let active_not_stopping = self.lock().turns.get(&id).is_some_and(|t| !t.stopping);
                if !active_not_stopping {
                    let host = {
                        let s = self.lock();
                        s.opencode_links.get(&id).and_then(|l| s.opencode_hosts.get(&l.host).cloned())
                    };
                    if let Some(host) = host {
                        self.runtime.spawn(async move {
                            let _ = host
                                .send(
                                    "DELETE",
                                    &format!("/api/session/{}/form/{}", form.session_id, form.id),
                                    &[],
                                    None,
                                    OPENCODE_REQUEST_TIMEOUT,
                                )
                                .await;
                        });
                    }
                    return;
                }
                self.present_opencode_form(id, form);
                return;
            }
            OpenCodeEvent::FormSettled { form, .. } => {
                let form_req_id = format!("ocform-{form}");
                let mut out = Out::default();
                {
                    let mut s = self.lock();
                    s.opencode_forms.remove(&form_req_id);
                    if let Some(list) = s.questions.get_mut(&id) {
                        let before = list.len();
                        list.retain(|q| q.id != form_req_id);
                        if list.len() != before {
                            if list.is_empty() {
                                s.questions.remove(&id);
                            }
                            Self::sync_waiting(&mut s, id);
                            out.push(ManagerEvent::QuestionGone(format!("runq:{id}:{form_req_id}")));
                            if s.approvals.get(&id).is_none_or(Vec::is_empty)
                                && s.questions.get(&id).is_none_or(Vec::is_empty)
                                && s.turns.contains_key(&id)
                            {
                                Self::update(&mut s, id, |r| {
                                    r.move_to(RunStatus::Running, None, Utc::now());
                                });
                            }
                            out.push(ManagerEvent::Changed);
                        }
                    }
                }
                self.emit(out);
                return;
            }
            OpenCodeEvent::ModelSelected { model, .. } => {
                let mut out = Out::default();
                {
                    let mut s = self.lock();
                    if let Some(link) = s.opencode_links.get_mut(&id) {
                        link.current_model = Some(model.clone());
                    }
                    if s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.resolved_model.as_deref() != Some(model.as_str())) {
                        Self::update(&mut s, id, |r| r.resolved_model = Some(model));
                        out.push(ManagerEvent::Changed);
                    }
                }
                self.emit(out);
                return;
            }
            _ => {}
        }

        // Everything below belongs to an active turn.
        let mut out = Out::default();
        let mut recorded_tool: Option<String> = None;
        {
            let mut s = self.lock();
            if !s.turns.contains_key(&id) {
                return;
            }
            match event {
                OpenCodeEvent::TextDelta { item, thinking, text, .. } => {
                    if thinking {
                        let existing = s.opencode_links.get(&id).and_then(|l| l.thinking_items.get(&item).copied());
                        match existing {
                            Some(ev_id) => Self::mutate(&mut s, id, ev_id, &mut out, |e| e.text.push_str(&text)),
                            None => {
                                let e = RunEvent::new(EventKind::Thinking, text).with_state(EventState::Running);
                                let ev_id = e.id;
                                if let Some(link) = s.opencode_links.get_mut(&id) {
                                    link.thinking_items.insert(item, ev_id);
                                }
                                Self::append(&mut s, id, e, &mut out);
                            }
                        }
                    } else {
                        if !text.trim().is_empty() {
                            if let Some(link) = s.opencode_links.get_mut(&id) {
                                link.replied = true;
                            }
                        }
                        let existing = s.opencode_links.get(&id).and_then(|l| l.text_items.get(&item).copied());
                        match existing {
                            Some(ev_id) => Self::mutate(&mut s, id, ev_id, &mut out, |e| e.text.push_str(&text)),
                            None => {
                                let e = RunEvent::new(EventKind::Assistant, text).with_state(EventState::Running);
                                let ev_id = e.id;
                                if let Some(link) = s.opencode_links.get_mut(&id) {
                                    link.text_items.insert(item, ev_id);
                                }
                                Self::append(&mut s, id, e, &mut out);
                            }
                        }
                    }
                }
                OpenCodeEvent::TextDone { item, thinking, text, .. } => {
                    if thinking {
                        let existing = s.opencode_links.get_mut(&id).and_then(|l| l.thinking_items.remove(&item));
                        match existing {
                            Some(ev_id) => Self::mutate(&mut s, id, ev_id, &mut out, |e| {
                                if !text.is_empty() {
                                    e.text = text;
                                }
                                e.state = Some(EventState::Done);
                            }),
                            None if !text.is_empty() => {
                                Self::append(&mut s, id, RunEvent::new(EventKind::Thinking, text).with_state(EventState::Done), &mut out);
                            }
                            None => {}
                        }
                    } else {
                        if !text.trim().is_empty() {
                            if let Some(link) = s.opencode_links.get_mut(&id) {
                                link.replied = true;
                            }
                        }
                        let existing = s.opencode_links.get_mut(&id).and_then(|l| l.text_items.remove(&item));
                        match existing {
                            Some(ev_id) => Self::mutate(&mut s, id, ev_id, &mut out, |e| {
                                e.text = text;
                                e.state = Some(EventState::Done);
                            }),
                            None => {
                                Self::append(&mut s, id, RunEvent::new(EventKind::Assistant, text).with_state(EventState::Done), &mut out);
                            }
                        }
                    }
                }
                OpenCodeEvent::ToolStarted { call, name, .. } => {
                    // `question` is shown through the form panel, not as a tool step.
                    if name == "question" {
                        return;
                    }
                    let canonical = opencode_protocol::tools::canonical_name(&name);
                    if let Some(link) = s.opencode_links.get_mut(&id) {
                        link.tools.insert(call.clone(), OpenCodeToolState { name: name.clone(), input: json!({}) });
                    }
                    let e = RunEvent::new(EventKind::Tool, name).with_tool(&canonical).with_call(&call).with_state(EventState::Running);
                    if let Some(t) = s.turns.get_mut(&id) {
                        t.tool_events.insert(call.clone(), e.id);
                        t.tool_names.insert(call, canonical.clone());
                    }
                    recorded_tool = Some(canonical);
                    Self::append(&mut s, id, e, &mut out);
                }
                OpenCodeEvent::ToolCalled { call, input, .. } => {
                    let Some((raw_name, directory)) = s.opencode_links.get_mut(&id).and_then(|link| {
                        let tool = link.tools.get_mut(&call)?;
                        tool.input = input.clone();
                        Some((tool.name.clone(), link.directory.clone()))
                    }) else {
                        return;
                    };
                    let canonical = opencode_protocol::tools::canonical_name(&raw_name);
                    let mapped = opencode_protocol::tools::map_input(&raw_name, &input, &directory);
                    if super::super::tasks::is_todo_tool(&canonical) {
                        if let Some(steps) = super::super::tasks::claude(&mapped) {
                            Self::update(&mut s, id, |r| r.tasks = Some(steps));
                        }
                    }
                    let summary = tool_summary::describe(&raw_name, &mapped);
                    let detail = tool_summary::json(&input);
                    let existing = s.turns.get(&id).and_then(|t| t.tool_events.get(&call)).copied();
                    if let Some(t) = s.turns.get_mut(&id) {
                        t.tool_inputs.insert(call.clone(), mapped);
                    }
                    match existing {
                        Some(ev_id) => Self::mutate(&mut s, id, ev_id, &mut out, |e| {
                            e.text = summary;
                            e.tool = Some(canonical);
                            e.detail = Some(detail);
                        }),
                        None => {
                            let e = RunEvent::new(EventKind::Tool, summary)
                                .with_tool(&canonical)
                                .with_call(&call)
                                .with_detail(detail)
                                .with_state(EventState::Running);
                            if let Some(t) = s.turns.get_mut(&id) {
                                t.tool_events.insert(call, e.id);
                            }
                            Self::append(&mut s, id, e, &mut out);
                        }
                    }
                }
                OpenCodeEvent::ToolSucceeded { call, output, metadata, .. } => {
                    let Some((raw_name, raw_input, directory)) = s.opencode_links.get(&id).and_then(|link| {
                        let tool = link.tools.get(&call)?;
                        Some((tool.name.clone(), tool.input.clone(), link.directory.clone()))
                    }) else {
                        return;
                    };
                    let running = metadata.get("status").and_then(Value::as_str) == Some("running");
                    let ev_id = s.turns.get(&id).and_then(|t| t.tool_events.get(&call)).copied();
                    if let Some(ev_id) = ev_id {
                        Self::mutate(&mut s, id, ev_id, &mut out, |e| {
                            if !output.is_empty() {
                                e.output = Some(RunEvent::clip(&output));
                            }
                            e.state = Some(if running { EventState::Running } else { EventState::Done });
                        });
                    }
                    let kind = if raw_name == "write" { "written" } else { "modified" };
                    for path in opencode_protocol::tools::changed_paths(&raw_name, &raw_input, &metadata, &directory) {
                        Self::record_file_change(&mut s, id, &path, kind, &mut out);
                    }
                }
                OpenCodeEvent::ToolFailed { call, message, .. } => {
                    if !s.opencode_links.get(&id).is_some_and(|l| l.tools.contains_key(&call)) {
                        return;
                    }
                    let ev_id = s.turns.get(&id).and_then(|t| t.tool_events.get(&call)).copied();
                    if let Some(ev_id) = ev_id {
                        Self::mutate(&mut s, id, ev_id, &mut out, |e| {
                            if !message.is_empty() {
                                e.output = Some(RunEvent::clip(&message));
                            }
                            e.state = Some(EventState::Failed);
                        });
                    }
                }
                OpenCodeEvent::StepEnded { tokens, cost, .. } => {
                    if let Some(tokens) = tokens {
                        if let Some(link) = s.opencode_links.get_mut(&id) {
                            link.usage.input_tokens = Some(link.usage.input_tokens.unwrap_or(0) + tokens.input);
                            link.usage.output_tokens = Some(link.usage.output_tokens.unwrap_or(0) + tokens.output + tokens.reasoning);
                            link.usage.cache_read_tokens = Some(link.usage.cache_read_tokens.unwrap_or(0) + tokens.cache_read);
                            link.usage.cache_write_tokens = Some(link.usage.cache_write_tokens.unwrap_or(0) + tokens.cache_write);
                        }
                        if let Some(t) = s.turns.get_mut(&id) {
                            t.last_context = Some(tokens.context());
                        }
                    }
                    if let Some(c) = cost {
                        if let Some(link) = s.opencode_links.get_mut(&id) {
                            link.usage.reported_cost_usd = Some(link.usage.reported_cost_usd.unwrap_or(0.0) + c);
                        }
                    }
                }
                OpenCodeEvent::Retrying { message, .. } => {
                    let prefix = tr("Opnieuw proberen…", "Retrying…");
                    let text = if message.is_empty() { prefix.to_string() } else { format!("{prefix} {message}") };
                    Self::append(&mut s, id, RunEvent::new(EventKind::System, text), &mut out);
                }
                OpenCodeEvent::CompactionStarted { .. } => {
                    Self::compaction_started(&mut s, id, &mut out);
                }
                OpenCodeEvent::CompactionEnded { failed, .. } => match failed {
                    Some(msg) => Self::compaction_failed(&mut s, id, (!msg.is_empty()).then_some(msg.as_str()), &mut out),
                    None => Self::compaction_finished(&mut s, id, &mut out),
                },
                _ => {}
            }
        }
        if let Some(tool) = recorded_tool {
            self.recap.note(|r, now| r.tool_use(&tool, now));
        }
        self.emit(out);
    }

    fn lock_host(&self, key: &str) -> Option<Arc<OpenCodeServerHost>> {
        self.lock().opencode_hosts.get(key).cloned()
    }

    /// Background wake: the session started an execution on the OpenCode server without a prompt from Nook.
    fn wake_opencode(&self, id: Uuid) {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            if let Some(timer) = s.opencode_idle_close.remove(&id) {
                timer.abort();
            }
            let now = Utc::now();
            s.turns.insert(id, TurnState { started: Some(now), ..Default::default() });
            if let Some(link) = s.opencode_links.get_mut(&id) {
                link.usage = TurnUsage::default();
                link.unprompted = true;
                link.replied = false;
                link.tools.clear();
                link.text_items.clear();
                link.thinking_items.clear();
            }
            let mut wake_ev =
                RunEvent::new(EventKind::System, tr("De sessie ging op de achtergrond verder.", "The session resumed in the background."));
            wake_ev.tool = Some("wake".into());
            Self::append(&mut s, id, wake_ev, &mut out);
            Self::update(&mut s, id, |r| {
                if matches!(r.status, RunStatus::Completed | RunStatus::Failed | RunStatus::Stopped) {
                    r.move_to(RunStatus::Preparing, None, now);
                }
                r.move_to(RunStatus::Running, None, now);
                r.turn_started_at = Some(now);
            });
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
    }

    fn finish_opencode_turn(self: &Arc<Self>, id: Uuid, outcome: OpenCodeOutcome) {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let Some(state) = s.turns.remove(&id) else { return };
            // Mark any still-open streamed items as done.
            if let Some(link) = s.opencode_links.get_mut(&id) {
                let text_ids: Vec<Uuid> = link.text_items.drain().map(|(_, v)| v).collect();
                let think_ids: Vec<Uuid> = link.thinking_items.drain().map(|(_, v)| v).collect();
                for ev_id in text_ids.into_iter().chain(think_ids) {
                    Self::mutate(&mut s, id, ev_id, &mut out, |e| e.state = Some(EventState::Done));
                }
            }
            let (mut usage, replied, unprompted) = match s.opencode_links.get_mut(&id) {
                Some(link) => {
                    let mut u = std::mem::take(&mut link.usage);
                    u.context_window = link.context_window;
                    link.prompt_sent = false;
                    link.tools.clear();
                    let replied = link.replied;
                    let unprompted = link.unprompted;
                    link.replied = false;
                    link.unprompted = false;
                    (u, replied, unprompted)
                }
                None => (TurnUsage::default(), false, false),
            };
            usage.context_tokens = state.last_context;
            if let Some(started) = state.started {
                usage.duration_seconds = Some((Utc::now() - started).num_milliseconds() as f64 / 1000.0);
            }
            Self::cancel_opencode_requests_locked(&mut s, id);
            Self::drop_opencode_questions_locked(&mut s, id, &mut out);

            let (stopped, failure) = match outcome {
                OpenCodeOutcome::Succeeded => (state.stopping, None),
                OpenCodeOutcome::Interrupted { .. } => (true, None),
                OpenCodeOutcome::Failed { kind, message } => {
                    if state.stopping {
                        (true, None)
                    } else {
                        (false, Some((kind, message)))
                    }
                }
            };

            let detail = failure.as_ref().map(|(kind, msg)| if msg.is_empty() { kind.clone() } else { msg.clone() });
            let provider_name = s.runs.iter().find(|r| r.id == id).map(|r| r.provider.display_name()).unwrap_or("OpenCode");
            Self::update(&mut s, id, |r| {
                r.usage.add(&usage);
                let now = Utc::now();
                if stopped {
                    r.move_to(RunStatus::Stopped, None, now);
                } else if let Some(d) = detail.clone() {
                    r.move_to(RunStatus::Failed, Some(d), now);
                } else {
                    r.move_to(RunStatus::Completed, None, now);
                }
            });
            if stopped {
                Self::append(&mut s, id, RunEvent::new(EventKind::System, tr("Gestopt.", "Stopped.")), &mut out);
            }
            if let Some(d) = &detail {
                Self::append(&mut s, id, RunEvent::new(EventKind::Error, d.clone()), &mut out);
            }
            if !stopped && detail.is_none() && !replied && !unprompted {
                Self::append(
                    &mut s,
                    id,
                    RunEvent::new(
                        EventKind::System,
                        trf("{agent} stopte zonder te antwoorden.", "{agent} stopped without replying.", &[("agent", &provider_name)]),
                    ),
                    &mut out,
                );
            }
            Self::append(
                &mut s,
                id,
                RunEvent::new(EventKind::Result, result_line(&usage, 0)).with_state(if detail.is_some() {
                    EventState::Failed
                } else {
                    EventState::Done
                }),
                &mut out,
            );
            Self::expire_approvals(&mut s, id, &mut out);
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        self.turn_did_finish(id);
        self.schedule_opencode_idle_close(id);
    }

    fn fail_opencode_turn(self: &Arc<Self>, id: Uuid, message: String) {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            Self::finish_live_text(&mut s, id);
            Self::close_thinking(&mut s, id, &mut out);
            Self::cancel_opencode_requests_locked(&mut s, id);
            Self::expire_approvals(&mut s, id, &mut out);
            Self::drop_opencode_questions_locked(&mut s, id, &mut out);
            s.turns.remove(&id);
            if let Some(link) = s.opencode_links.get_mut(&id) {
                link.prompt_sent = false;
                link.tools.clear();
                link.text_items.clear();
                link.thinking_items.clear();
            }
            Self::update(&mut s, id, |r| {
                r.move_to(RunStatus::Failed, Some(message.clone()), Utc::now());
            });
            Self::append(&mut s, id, RunEvent::new(EventKind::Error, message), &mut out);
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        self.turn_did_finish(id);
    }

    // MARK: - Connection & Lifecycle

    /// After an SSE drop and reconnect: catches up on missed execution completion and any pending permissions.
    fn opencode_reconnected(self: &Arc<Self>, key: &str) {
        let targets: Vec<(Uuid, String, Arc<OpenCodeServerHost>)> = {
            let s = self.lock();
            let Some(host) = s.opencode_hosts.get(key).cloned() else { return };
            s.opencode_links
                .iter()
                .filter_map(|(&id, link)| {
                    if link.host != key || !s.turns.contains_key(&id) {
                        return None;
                    }
                    let session = link.session_id.clone()?;
                    Some((id, session, Arc::clone(&host)))
                })
                .collect()
        };
        for (id, session, host) in targets {
            let manager = Arc::clone(self);
            self.runtime.spawn(async move {
                let info = host.send("GET", &format!("/api/session/{session}"), &[], None, OPENCODE_REQUEST_TIMEOUT).await;
                if let Some(state) = info.json.as_ref().and_then(opencode_protocol::parse_session) {
                    let active_prompted = {
                        let s = manager.lock();
                        s.turns.contains_key(&id) && s.opencode_links.get(&id).is_some_and(|l| l.prompt_sent)
                    };
                    if !state.busy && active_prompted {
                        let outcome = match state.outcome.as_deref() {
                            Some("interrupted") => OpenCodeOutcome::Interrupted { reason: "user".into() },
                            Some("failed") => OpenCodeOutcome::Failed {
                                kind: String::new(),
                                message: tr(
                                    "De verbinding met OpenCode viel even weg; de beurt is mislukt.",
                                    "The connection to OpenCode dropped for a moment; the turn failed.",
                                )
                                .to_string(),
                            },
                            _ => OpenCodeOutcome::Succeeded,
                        };
                        manager.finish_opencode_turn(id, outcome);
                        return;
                    }
                }
                let pending = host.send("GET", &format!("/api/session/{session}/permission"), &[], None, OPENCODE_REQUEST_TIMEOUT).await;
                if let Some(items) = pending.json.as_ref().and_then(|j| j.get("data")).and_then(Value::as_array) {
                    let mut out = Out::default();
                    {
                        let mut s = manager.lock();
                        if !s.turns.contains_key(&id) {
                            return;
                        }
                        for item in items {
                            if let Some(perm) = OpenCodePermission::parse(item) {
                                Self::present_opencode_permission(&mut s, id, perm, &mut out);
                            }
                        }
                    }
                    manager.emit(out);
                }
            });
        }
    }

    fn opencode_host_gone(self: &Arc<Self>, key: &str, message: String) {
        let affected: Vec<(Uuid, bool, bool)> = {
            let mut s = self.lock();
            s.opencode_hosts.remove(key);
            s.opencode_links
                .iter()
                .filter(|(_, link)| link.host == key)
                .map(|(&id, _)| (id, s.turns.contains_key(&id), s.turns.get(&id).is_some_and(|t| t.stopping)))
                .collect()
        };
        for (id, active, stopping) in affected {
            self.close_opencode_session(id);
            if stopping {
                self.opencode_stopped(id);
            } else if active {
                let text = if message.is_empty() {
                    tr("De server van OpenCode is gestopt.", "The OpenCode server stopped.").to_string()
                } else {
                    message.clone()
                };
                self.fail_opencode_turn(id, text);
            }
        }
    }

    fn schedule_opencode_idle_close(self: &Arc<Self>, id: Uuid) {
        let manager = Arc::clone(self);
        let handle = self.runtime.spawn(async move {
            tokio::time::sleep(Duration::from_secs(OPENCODE_IDLE_SECONDS)).await;
            let active = manager.run(id).is_some_and(|r| r.status.is_active());
            if !active {
                manager.close_opencode_session(id);
            }
        });
        let mut s = self.lock();
        if let Some(prev) = s.opencode_idle_close.insert(id, handle.abort_handle()) {
            prev.abort();
        }
    }

    /// Drops this session's link to its OpenCode server, removes its scoped MCP bridge, and stops the shared server
    /// after a grace period if no other session uses it.
    pub(super) fn close_opencode_session(&self, id: Uuid) {
        let cleanup = {
            let mut s = self.lock();
            if let Some(timer) = s.opencode_idle_close.remove(&id) {
                timer.abort();
            }
            s.opencode_warm_prompts.remove(&id);
            Self::cancel_opencode_requests_locked(&mut s, id);
            let mut out = Out::default();
            Self::drop_opencode_questions_locked(&mut s, id, &mut out);
            let Some(link) = s.opencode_links.remove(&id) else { return };
            let host = s.opencode_hosts.get(&link.host).cloned();
            let host_unused = !s.opencode_links.values().any(|l| l.host == link.host);
            (link, host, host_unused)
        };
        let (link, host, host_unused) = cleanup;
        if let (Some(bridge_name), Some(host_ref)) = (link.bridge_server, host.clone()) {
            let location = opencode_protocol::location_query(&link.directory);
            self.runtime.spawn(async move {
                let _ = host_ref
                    .send("DELETE", &format!("/api/experimental/mcp/{bridge_name}"), &location, None, OPENCODE_REQUEST_TIMEOUT)
                    .await;
            });
        }
        if host_unused {
            if let Some(host_ref) = host {
                let host_key = link.host;
                let handle = self.runtime.spawn(async move {
                    tokio::time::sleep(Duration::from_secs(OPENCODE_HOST_GRACE_SECONDS)).await;
                    host_ref.stop();
                });
                let mut s = self.lock();
                if let Some(prev) = s.opencode_host_stops.insert(host_key, handle.abort_handle()) {
                    prev.abort();
                }
            }
        }
    }

    /// Stops every shared `opencode serve` host during Nook shutdown.
    pub(super) fn shutdown_opencode_hosts(&self) {
        let hosts: Vec<Arc<OpenCodeServerHost>> = {
            let mut s = self.lock();
            for (_, timer) in s.opencode_idle_close.drain() {
                timer.abort();
            }
            for (_, timer) in s.opencode_host_stops.drain() {
                timer.abort();
            }
            s.opencode_links.clear();
            s.opencode_requests.clear();
            s.opencode_forms.clear();
            s.opencode_warm_prompts.clear();
            s.opencode_hosts.drain().map(|(_, h)| h).collect()
        };
        for host in hosts {
            host.stop();
        }
    }
}

fn opencode_model_key(run: &WorkspaceRun) -> String {
    format!("{}|{}", run.model, run.effort.as_deref().unwrap_or(""))
}
