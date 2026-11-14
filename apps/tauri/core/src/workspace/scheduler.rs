//! Scheduled tasks as Nook runs them (`ScheduledTaskStore.swift` and `WebhookListener.handle` on the Mac): the list on
//! disk (`scheduled-tasks.json` in Nook's data folder), what the 30-second tick starts, and the webhook deliveries that
//! wait for their turn. The decisions (when, missed, overlap, duplicates) are in [`super::schedule`]; this owns the
//! state and talks to sessions through [`SessionHost`], so it is tested with a fake.
//!
//! Safety: nothing runs by itself until the user turns scheduled tasks on ([`AutomationSettings::enabled`]). A run is
//! an ordinary session with the rights stored on the task ("ask" by default, never full rights unattended), so every
//! edit and command follows the usual approvals; a run a webhook starts always asks, because its payload comes from
//! outside. Webhook signing secrets live in the secret store, never in the file.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::manager::Manager;
use super::models::{ExecutionMode, IsolationMode, NewRunConfig, PermissionPolicy, RunProvider, RunStatus};
use super::schedule::{
    self, effective_permission, reason, FireLedger, RunGate, ScheduleTrigger, ScheduledRunStatus, ScheduledTask, ScheduledTaskTarget,
    WebhookQueue,
};
use super::webhook::{self, Delivery, DeliveryLog, RateWindow, Request};
use crate::secrets::SecretStore;

/// The seconds between two checks for due tasks.
pub const TICK_SECONDS: u64 = 30;

/// The switches for automation, in `automation-settings.json` next to Nook's other data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AutomationSettings {
    /// Scheduled tasks may run. Off by default: until it is on, nothing runs by itself.
    pub scheduled_tasks: bool,
    /// The port of the local webhook listener (127.0.0.1 only); 0 = no webhooks.
    pub webhook_port: u16,
    /// A new session gets a short title from its first message, written by the chosen brain.
    pub auto_titles: bool,
}

impl Default for AutomationSettings {
    fn default() -> Self {
        Self { scheduled_tasks: false, webhook_port: 0, auto_titles: true }
    }
}

impl AutomationSettings {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("automation-settings.json")
    }

    pub fn load_from(file: &Path) -> Self {
        std::fs::read(file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save_to(&self, file: &Path) {
        if let Ok(bytes) = serde_json::to_vec_pretty(self) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    /// The webhook port in use: only an unprivileged one.
    pub fn listening_port(&self) -> Option<u16> {
        (self.scheduled_tasks && self.webhook_port >= 1024).then_some(self.webhook_port)
    }
}

/// What the scheduler needs from the sessions. [`Manager`] is the real one.
pub trait SessionHost: Send + Sync {
    fn start_session(&self, config: NewRunConfig) -> Result<Uuid, String>;
    /// Status, the detail of a failure, and the session's rights; `None` when it is gone.
    fn session(&self, id: Uuid) -> Option<(RunStatus, Option<String>, PermissionPolicy)>;
    /// Starts the next turn in an existing session with a new conversation (`fresh`) or as a follow-up.
    fn send_to(&self, id: Uuid, text: &str, fresh: bool, note: &str) -> Result<(), String>;
}

impl SessionHost for Arc<Manager> {
    fn start_session(&self, config: NewRunConfig) -> Result<Uuid, String> {
        self.start(config, false)
    }

    fn session(&self, id: Uuid) -> Option<(RunStatus, Option<String>, PermissionPolicy)> {
        self.run(id).map(|r| (r.status, r.status_detail, r.permission))
    }

    fn send_to(&self, id: Uuid, text: &str, fresh: bool, note: &str) -> Result<(), String> {
        if fresh && self.update_between_turns(id, |r| r.provider_session_id = None) {
            self.note(id, note);
        }
        self.send(id, text)
    }
}

/// The webhook account of a task in the secret store.
pub fn secret_account(task: Uuid) -> String {
    format!("scheduled-task-webhook.{task}")
}

#[derive(Default)]
struct State {
    tasks: Vec<ScheduledTask>,
    ledger: FireLedger,
    gate: RunGate,
    queue: WebhookQueue,
    /// Webhook deliveries that wait for their task to be free, oldest first.
    pending: HashMap<Uuid, VecDeque<Delivery>>,
    /// Task → the session it started and what started it, for runs going on now.
    running: HashMap<Uuid, (Option<Uuid>, ScheduleTrigger)>,
    logs: HashMap<Uuid, DeliveryLog>,
    rates: HashMap<Uuid, RateWindow>,
}

pub struct Scheduler {
    file: PathBuf,
    secrets: Arc<dyn SecretStore>,
    state: Mutex<State>,
}

/// Who a new session belongs to when the task names no account: the user's account for that agent.
pub type DefaultProfile<'a> = &'a dyn Fn(RunProvider) -> String;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunNow {
    Started,
    Busy,
    NotAvailable,
}

impl Scheduler {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("scheduled-tasks.json")
    }

    /// Loads the list. A run a restart cut off becomes failed and is planned again.
    pub fn new<Tz: TimeZone>(file: PathBuf, secrets: Arc<dyn SecretStore>, now: DateTime<Utc>, tz: &Tz) -> Self {
        let rows: Vec<Value> = std::fs::read(&file)
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| v.get("tasks").and_then(Value::as_array).cloned())
            .unwrap_or_default();
        // A row that does not read is skipped, the others still load.
        let loaded: Vec<ScheduledTask> = rows.into_iter().filter_map(|r| serde_json::from_value(r).ok()).collect();
        let mut tasks = ScheduledTask::recover_interrupted(loaded.clone(), now, tz);
        for t in &mut tasks {
            if !t.enabled {
                t.next_run = None;
            } else if t.next_run.is_none() && !t.rule.is_webhook() {
                t.next_run = t.planned_run(now, true, tz);
            }
        }
        let changed = tasks != loaded;
        let scheduler = Self { file, secrets, state: Mutex::new(State { tasks, ..Default::default() }) };
        if changed {
            scheduler.save(&scheduler.lock());
        }
        scheduler
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn save(&self, s: &State) {
        let file = serde_json::json!({ "version": 1, "tasks": s.tasks });
        if let Ok(bytes) = serde_json::to_vec_pretty(&file) {
            let _ = crate::paths::write_atomic(&self.file, &bytes);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&self.file, std::fs::Permissions::from_mode(0o600));
            }
        }
    }

    pub fn tasks(&self) -> Vec<ScheduledTask> {
        self.lock().tasks.clone()
    }

    pub fn task(&self, id: Uuid) -> Option<ScheduledTask> {
        self.lock().tasks.iter().find(|t| t.id == id).cloned()
    }

    pub fn is_running(&self, id: Uuid) -> bool {
        self.lock().gate.is_running(id)
    }

    // MARK: Editing

    /// Adds a task, or replaces the one with the same id. A changed schedule counts from now, so editing never fires a
    /// task at once because its old schedule was overdue; a once-task that ran stays done until its moment changes.
    pub fn save_task<Tz: TimeZone>(&self, task: ScheduledTask, now: DateTime<Utc>, tz: &Tz) -> ScheduledTask {
        let mut s = self.lock();
        let mut row = task;
        let old = s.tasks.iter().find(|t| t.id == row.id).cloned();
        if let Some(old) = &old {
            row.last_run = old.last_run;
            row.last_status = old.last_status;
            row.last_error = old.last_error.clone();
            row.last_session = old.last_session;
            row.created_at = old.created_at;
            if old.rule.is_webhook() && !row.rule.is_webhook() {
                let _ = self.secrets.remove(&secret_account(row.id));
            }
        }
        if row.permission == PermissionPolicy::Bypass {
            row.permission = PermissionPolicy::Ask;
        }
        row.next_run = row.planned_run(now, old.as_ref().is_some_and(|o| o.rule == row.rule), tz);
        if s.gate.is_running(row.id) {
            row.last_status = Some(ScheduledRunStatus::Running);
            row.next_run = None;
        }
        match s.tasks.iter_mut().find(|t| t.id == row.id) {
            Some(slot) => *slot = row.clone(),
            None => s.tasks.push(row.clone()),
        }
        self.save(&s);
        drop(s);
        if row.rule.is_webhook() {
            let _ = self.webhook_secret(row.id, true);
        }
        row
    }

    pub fn delete(&self, id: Uuid) {
        let mut s = self.lock();
        s.tasks.retain(|t| t.id != id);
        s.pending.remove(&id);
        s.queue.forget(id);
        s.logs.remove(&id);
        s.rates.remove(&id);
        self.save(&s);
        let _ = self.secrets.remove(&secret_account(id));
    }

    pub fn set_enabled<Tz: TimeZone>(&self, id: Uuid, enabled: bool, now: DateTime<Utc>, tz: &Tz) {
        let mut s = self.lock();
        let running = s.gate.is_running(id);
        let Some(index) = s.tasks.iter().position(|t| t.id == id) else { return };
        s.tasks[index].enabled = enabled;
        if enabled {
            if !running {
                s.tasks[index].next_run = s.tasks[index].planned_run(now, true, tz);
            }
        } else {
            s.tasks[index].next_run = None;
            // Deliveries that waited for a paused task are dropped.
            for _ in s.pending.remove(&id).unwrap_or_default() {
                s.queue.release(id);
            }
        }
        self.save(&s);
    }

    // MARK: Webhook secrets (secret store only)

    pub fn webhook_secret(&self, id: Uuid, create: bool) -> Option<String> {
        if let Some(secret) = self.secrets.read(&secret_account(id)) {
            return Some(secret);
        }
        create.then(|| self.rotate_secret(id)).flatten()
    }

    /// A new random secret; the old one stops working at once and deliveries waiting for it are dropped.
    pub fn rotate_secret(&self, id: Uuid) -> Option<String> {
        let secret = webhook::new_secret();
        self.secrets.write(&secret_account(id), &secret).ok()?;
        let mut s = self.lock();
        for _ in s.pending.remove(&id).unwrap_or_default() {
            s.queue.release(id);
        }
        Some(secret)
    }

    // MARK: The tick

    /// Ends runs whose session finished, then starts what is due. A fixed-time run more than ten minutes late (the
    /// computer slept) is skipped and the next one planned; an overdue interval runs once; a once-task runs as soon as
    /// Nook is awake again.
    pub fn tick<Tz: TimeZone>(&self, host: &dyn SessionHost, enabled: bool, profile: DefaultProfile<'_>, now: DateTime<Utc>, tz: &Tz) {
        self.check_runs(host, now, tz);
        if !enabled {
            return;
        }
        let due: Vec<(Uuid, DateTime<Utc>, String)> = {
            let mut s = self.lock();
            let mut due = vec![];
            let mut changed = false;
            for i in 0..s.tasks.len() {
                let t = s.tasks[i].clone();
                if !t.enabled || t.rule.is_webhook() || s.gate.is_running(t.id) || t.is_done() {
                    continue;
                }
                let Some(at) = t.next_run else {
                    s.tasks[i].next_run = schedule::next_run(&t.rule, t.last_run, now, tz);
                    changed = true;
                    continue;
                };
                if at > now {
                    continue;
                }
                if schedule::should_skip(&t.rule, at, now) {
                    let mut row = t.finishing(ScheduledRunStatus::Skipped, Some(reason::MISSED.into()), now, tz);
                    row.last_run = t.last_run;
                    s.tasks[i] = row;
                    changed = true;
                    continue;
                }
                due.push((t.id, at, t.prompt.clone()));
            }
            if changed {
                self.save(&s);
            }
            due
        };
        for (id, at, prompt) in due {
            self.fire(
                host,
                id,
                &ScheduledTask::fire_key(id, at, ScheduleTrigger::Schedule),
                ScheduleTrigger::Schedule,
                &prompt,
                profile,
                now,
                tz,
            );
        }
    }

    /// "Run now" from the list: the task's own prompt, once, if it is free.
    pub fn run_now<Tz: TimeZone>(
        &self,
        host: &dyn SessionHost,
        enabled: bool,
        id: Uuid,
        profile: DefaultProfile<'_>,
        now: DateTime<Utc>,
        tz: &Tz,
    ) -> RunNow {
        let Some(task) = self.task(id).filter(|_| enabled) else { return RunNow::NotAvailable };
        if self.is_running(id) {
            return RunNow::Busy;
        }
        let key = ScheduledTask::fire_key(id, now, ScheduleTrigger::Manual);
        if self.fire(host, id, &key, ScheduleTrigger::Manual, &task.prompt, profile, now, tz) {
            RunNow::Started
        } else {
            RunNow::Busy
        }
    }

    /// The one way a run starts. False when nothing started: the same firing was seen already, or the task is busy.
    #[allow(clippy::too_many_arguments)]
    fn fire<Tz: TimeZone>(
        &self,
        host: &dyn SessionHost,
        id: Uuid,
        key: &str,
        trigger: ScheduleTrigger,
        prompt: &str,
        profile: DefaultProfile<'_>,
        now: DateTime<Utc>,
        tz: &Tz,
    ) -> bool {
        let task = {
            let mut s = self.lock();
            let Some(index) = s.tasks.iter().position(|t| t.id == id) else { return false };
            if !s.ledger.claim(key) {
                return false;
            }
            if !s.gate.begin(id) {
                return false;
            }
            let row = &mut s.tasks[index];
            row.last_run = Some(now);
            row.last_status = Some(ScheduledRunStatus::Running);
            row.last_error = None;
            row.next_run = None;
            let task = row.clone();
            s.running.insert(id, (None, trigger));
            self.save(&s);
            task
        };
        match &task.target {
            ScheduledTaskTarget::NewSession { project_path, provider, profile_id } => {
                if project_path.trim().is_empty() {
                    self.finish(id, ScheduledRunStatus::Failed, Some(reason::BAD_TARGET.into()), now, tz);
                    return true;
                }
                let config = NewRunConfig {
                    title: task.title.clone(),
                    task: prompt.to_string(),
                    provider: *provider,
                    profile_id: profile_id.clone().filter(|p| !p.is_empty()).unwrap_or_else(|| profile(*provider)),
                    mode: ExecutionMode::Agent,
                    permission: effective_permission(task.permission, *provider, trigger),
                    isolation: IsolationMode::Folder,
                    project_path: project_path.clone(),
                    ..NewRunConfig::default()
                };
                match host.start_session(config) {
                    Ok(session) => {
                        let mut s = self.lock();
                        s.running.insert(id, (Some(session), trigger));
                        if let Some(row) = s.tasks.iter_mut().find(|t| t.id == id) {
                            row.last_session = Some(session);
                        }
                        self.save(&s);
                    }
                    Err(e) => self.finish(id, ScheduledRunStatus::Failed, Some(e), now, tz),
                }
            }
            ScheduledTaskTarget::ExistingSession { id: session, fresh } => {
                let Some((status, _, permission)) = host.session(*session) else {
                    self.finish(id, ScheduledRunStatus::Failed, Some(reason::NO_SESSION.into()), now, tz);
                    return true;
                };
                // Never interrupts a session that is working: that is the overlap rule for sessions.
                if status.is_active() {
                    self.finish(id, ScheduledRunStatus::Skipped, Some(reason::OVERLAP.into()), now, tz);
                    return true;
                }
                // What comes from outside must not work with rights you gave that session for yourself.
                if trigger == ScheduleTrigger::Webhook && permission != PermissionPolicy::Ask {
                    self.finish(id, ScheduledRunStatus::Failed, Some(reason::WEBHOOK_RIGHTS.into()), now, tz);
                    return true;
                }
                let note = crate::i18n::trf(
                    "Nieuw gesprek voor de geplande taak ‘{title}’: de agent ziet eerdere runs niet.",
                    "Fresh conversation for the scheduled task “{title}”: the agent does not see earlier runs.",
                    &[("title", &task.title)],
                );
                let result = host.send_to(*session, prompt, *fresh, &note);
                if let Some(row) = self.lock().tasks.iter_mut().find(|t| t.id == id) {
                    row.last_session = Some(*session);
                }
                match result {
                    Ok(()) => self.finish(id, ScheduledRunStatus::Succeeded, None, now, tz),
                    Err(e) => self.finish(id, ScheduledRunStatus::Failed, Some(e), now, tz),
                }
            }
        }
        true
    }

    /// A started session that is no longer active ends the run of its task.
    pub fn check_runs<Tz: TimeZone>(&self, host: &dyn SessionHost, now: DateTime<Utc>, tz: &Tz) {
        let running: Vec<(Uuid, Uuid)> =
            self.lock().running.iter().filter_map(|(task, (session, _))| session.map(|s| (*task, s))).collect();
        for (task, session) in running {
            match host.session(session) {
                None => self.finish(task, ScheduledRunStatus::Failed, Some(reason::NO_SESSION.into()), now, tz),
                Some((status, _, _)) if status.is_active() => {}
                Some((RunStatus::Completed, _, _)) => self.finish(task, ScheduledRunStatus::Succeeded, None, now, tz),
                Some((status, detail, _)) => {
                    let detail = detail.unwrap_or_else(|| format!("{status:?}").to_lowercase());
                    self.finish(task, ScheduledRunStatus::Failed, Some(detail), now, tz)
                }
            }
        }
    }

    fn finish<Tz: TimeZone>(&self, id: Uuid, status: ScheduledRunStatus, error: Option<String>, now: DateTime<Utc>, tz: &Tz) {
        let mut s = self.lock();
        let trigger = s.running.remove(&id).map(|(_, t)| t);
        s.gate.finish(id);
        if trigger == Some(ScheduleTrigger::Webhook) {
            s.queue.release(id);
        }
        if let Some(index) = s.tasks.iter().position(|t| t.id == id) {
            let started = s.tasks[index].last_run;
            let mut row = s.tasks[index].finishing(status, error, now, tz);
            if row.rule.is_webhook() {
                row.next_run = None;
            }
            // `finishing` stamps the end time; the list shows when the run started.
            row.last_run = started.or(Some(now));
            s.tasks[index] = row;
        }
        self.save(&s);
    }

    /// Starts the next webhook delivery of every free task. Called after each tick and each accepted delivery.
    pub fn drain_webhooks<Tz: TimeZone>(&self, host: &dyn SessionHost, profile: DefaultProfile<'_>, now: DateTime<Utc>, tz: &Tz) {
        loop {
            let next = {
                let mut s = self.lock();
                let free: Vec<Uuid> = s.pending.keys().copied().filter(|id| !s.gate.is_running(*id)).collect();
                let mut found = None;
                for id in free {
                    let enabled = s.tasks.iter().find(|t| t.id == id).map(|t| (t.enabled, t.prompt.clone()));
                    let Some(queue) = s.pending.get_mut(&id) else { continue };
                    let Some(delivery) = queue.pop_front() else { continue };
                    if queue.is_empty() {
                        s.pending.remove(&id);
                    }
                    match enabled {
                        Some((true, prompt)) => {
                            found = Some((id, delivery, prompt));
                            break;
                        }
                        _ => s.queue.release(id),
                    }
                }
                found
            };
            let Some((id, delivery, prompt)) = next else { return };
            let text = webhook::prompt(&prompt, &delivery);
            // One key per delivery: a delivery that comes in twice (already refused by its id) never runs twice.
            let key = format!("scheduled-task:{id}:delivery:{}", delivery.id);
            if !self.fire(host, id, &key, ScheduleTrigger::Webhook, &text, profile, now, tz) {
                self.lock().queue.release(id);
            }
        }
    }

    // MARK: Webhooks

    /// What to answer a complete request. Nothing about a task is revealed or changed before the signature is right,
    /// so an unsigned flood cannot fill the logs or use up a task's rate. An accepted delivery waits in the task's
    /// queue; [`Self::drain_webhooks`] starts it.
    pub fn handle_webhook(&self, enabled: bool, request: &Request, now: DateTime<Utc>) -> (u16, String) {
        if request.method != "POST" {
            return (405, "POST only".into());
        }
        let unknown = (404, "unknown hook".to_string());
        let Some(id) = webhook::task_id(&request.path) else { return unknown };
        if !enabled || !self.task(id).is_some_and(|t| t.enabled && t.rule.is_webhook()) {
            return unknown;
        }
        let Some(secret) = self.webhook_secret(id, false) else { return unknown };
        if !webhook::verify(&secret, &request.body, webhook::signature(&request.headers)) {
            return (401, "bad signature".into());
        }
        let Some(delivery_id) = webhook::delivery_id(&request.headers) else {
            return (400, "missing or invalid delivery id".into());
        };
        let mut s = self.lock();
        if !s.rates.entry(id).or_default().admit(now) {
            return (429, "rate limited".into());
        }
        if s.logs.get(&id).is_some_and(|l| l.contains(&delivery_id)) {
            return (409, "duplicate delivery".into());
        }
        if !s.queue.admit(id) {
            return (429, "queue full".into());
        }
        s.logs.entry(id).or_default().record(&delivery_id);
        s.pending.entry(id).or_default().push_back(Delivery {
            id: delivery_id,
            body: request.body.clone(),
            headers: request.headers.clone(),
            received_at: now,
        });
        (202, "accepted".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;
    use crate::workspace::schedule::ScheduleRule;
    use std::collections::BTreeMap;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("nook-scheduler-{}", Uuid::new_v4()));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[derive(Default)]
    struct FakeHost {
        started: Mutex<Vec<NewRunConfig>>,
        sent: Mutex<Vec<(Uuid, String, bool)>>,
        sessions: Mutex<HashMap<Uuid, (RunStatus, PermissionPolicy)>>,
    }

    impl SessionHost for FakeHost {
        fn start_session(&self, config: NewRunConfig) -> Result<Uuid, String> {
            let id = Uuid::new_v4();
            self.sessions.lock().unwrap().insert(id, (RunStatus::Running, config.permission));
            self.started.lock().unwrap().push(config);
            Ok(id)
        }

        fn session(&self, id: Uuid) -> Option<(RunStatus, Option<String>, PermissionPolicy)> {
            self.sessions.lock().unwrap().get(&id).map(|(s, p)| (*s, None, *p))
        }

        fn send_to(&self, id: Uuid, text: &str, fresh: bool, _: &str) -> Result<(), String> {
            self.sent.lock().unwrap().push((id, text.into(), fresh));
            Ok(())
        }
    }

    impl FakeHost {
        fn finish_all(&self) {
            for v in self.sessions.lock().unwrap().values_mut() {
                v.0 = RunStatus::Completed;
            }
        }
    }

    fn scheduler(dir: &Path) -> Scheduler {
        Scheduler::new(dir.join("scheduled-tasks.json"), Arc::new(MemorySecrets::default()), utc("2026-03-02T08:00:00Z"), &Utc)
    }

    fn target() -> ScheduledTaskTarget {
        ScheduledTaskTarget::NewSession { project_path: "/p".into(), provider: RunProvider::Claude, profile_id: None }
    }

    fn profile(p: RunProvider) -> String {
        p.id().into()
    }

    #[test]
    fn nothing_runs_until_scheduled_tasks_are_on() {
        let dir = TempDir::new();
        let s = scheduler(dir.path());
        let now = utc("2026-03-02T08:00:00Z");
        s.save_task(ScheduledTask::new("t", "p", ScheduleRule::Interval { seconds: 60 }, target(), now), now, &Utc);
        let host = FakeHost::default();
        s.tick(&host, false, &profile, utc("2026-03-02T09:00:00Z"), &Utc);
        assert!(host.started.lock().unwrap().is_empty());
        s.tick(&host, true, &profile, utc("2026-03-02T09:00:00Z"), &Utc);
        assert_eq!(host.started.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_due_task_starts_one_session_with_safe_rights_and_waits_for_it() {
        let dir = TempDir::new();
        let s = scheduler(dir.path());
        let now = utc("2026-03-02T08:00:00Z");
        let mut task = ScheduledTask::new("Morning check", "Run the tests", ScheduleRule::Interval { seconds: 600 }, target(), now);
        task.permission = PermissionPolicy::Bypass;
        let task = s.save_task(task, now, &Utc);
        assert_eq!(task.permission, PermissionPolicy::Ask, "full rights are never stored for an unattended task");
        assert_eq!(task.next_run, Some(utc("2026-03-02T08:10:00Z")));
        let host = FakeHost::default();
        s.tick(&host, true, &profile, utc("2026-03-02T08:09:00Z"), &Utc);
        assert!(host.started.lock().unwrap().is_empty());
        s.tick(&host, true, &profile, utc("2026-03-02T08:10:00Z"), &Utc);
        {
            let started = host.started.lock().unwrap();
            assert_eq!(started.len(), 1);
            assert_eq!(started[0].title, "Morning check");
            assert_eq!(started[0].task, "Run the tests");
            assert_eq!(started[0].permission, PermissionPolicy::Ask);
            assert_eq!(started[0].profile_id, "claude");
        }
        assert!(s.is_running(task.id));
        // Still busy at the next tick: no second run piles on.
        s.tick(&host, true, &profile, utc("2026-03-02T08:30:00Z"), &Utc);
        assert_eq!(host.started.lock().unwrap().len(), 1);
        host.finish_all();
        s.tick(&host, true, &profile, utc("2026-03-02T08:31:00Z"), &Utc);
        let row = s.task(task.id).unwrap();
        assert_eq!(row.last_status, Some(ScheduledRunStatus::Succeeded));
        assert_eq!(row.last_run, Some(utc("2026-03-02T08:10:00Z")));
        assert_eq!(row.next_run, Some(utc("2026-03-02T08:41:00Z")), "the interval counts from the end of the run");
        assert!(row.last_session.is_some());
    }

    #[test]
    fn missed_runs_while_asleep() {
        let dir = TempDir::new();
        let s = scheduler(dir.path());
        let now = utc("2026-03-02T08:00:00Z");
        let fixed = s.save_task(
            ScheduledTask::new("daily", "p", ScheduleRule::FixedTime { hour: 9, minute: 0, weekdays: vec![] }, target(), now),
            now,
            &Utc,
        );
        let interval = s.save_task(ScheduledTask::new("every", "p", ScheduleRule::Interval { seconds: 3600 }, target(), now), now, &Utc);
        let once =
            s.save_task(ScheduledTask::new("once", "p", ScheduleRule::Once { at: utc("2026-03-02T09:30:00Z") }, target(), now), now, &Utc);
        // The computer slept from 08:00 until 13:00.
        let host = FakeHost::default();
        let wake = utc("2026-03-02T13:00:00Z");
        s.tick(&host, true, &profile, wake, &Utc);
        let row = s.task(fixed.id).unwrap();
        assert_eq!(row.last_status, Some(ScheduledRunStatus::Skipped));
        assert_eq!(row.last_error.as_deref(), Some(reason::MISSED));
        assert_eq!(row.next_run, Some(utc("2026-03-03T09:00:00Z")));
        // The overdue interval and the once-task each run once, now.
        assert_eq!(host.started.lock().unwrap().len(), 2);
        assert!(s.is_running(interval.id));
        assert!(s.is_running(once.id));
        host.finish_all();
        s.tick(&host, true, &profile, utc("2026-03-02T13:01:00Z"), &Utc);
        assert!(s.task(once.id).unwrap().is_done());
        s.tick(&host, true, &profile, utc("2026-03-05T13:01:00Z"), &Utc);
        assert_eq!(host.started.lock().unwrap().iter().filter(|c| c.title == "once").count(), 1);
    }

    #[test]
    fn existing_session_targets_skip_a_busy_session_and_can_start_fresh() {
        let dir = TempDir::new();
        let s = scheduler(dir.path());
        let now = utc("2026-03-02T08:00:00Z");
        let host = FakeHost::default();
        let session = Uuid::new_v4();
        host.sessions.lock().unwrap().insert(session, (RunStatus::Running, PermissionPolicy::AcceptEdits));
        let task = s.save_task(
            ScheduledTask::new(
                "t",
                "Check again",
                ScheduleRule::Interval { seconds: 60 },
                ScheduledTaskTarget::ExistingSession { id: session, fresh: true },
                now,
            ),
            now,
            &Utc,
        );
        assert_eq!(s.run_now(&host, true, task.id, &profile, now, &Utc), RunNow::Started);
        assert_eq!(s.task(task.id).unwrap().last_error.as_deref(), Some(reason::OVERLAP));
        host.sessions.lock().unwrap().insert(session, (RunStatus::Completed, PermissionPolicy::AcceptEdits));
        assert_eq!(s.run_now(&host, true, task.id, &profile, utc("2026-03-02T08:05:00Z"), &Utc), RunNow::Started);
        assert_eq!(host.sent.lock().unwrap().as_slice(), &[(session, "Check again".to_string(), true)]);
        assert_eq!(s.task(task.id).unwrap().last_status, Some(ScheduledRunStatus::Succeeded));
        assert_eq!(s.run_now(&host, false, task.id, &profile, now, &Utc), RunNow::NotAvailable);
    }

    #[test]
    fn interrupted_runs_and_bad_rows_survive_a_restart() {
        let dir = TempDir::new();
        let file = dir.path().join("scheduled-tasks.json");
        let mut task = ScheduledTask::new("t", "p", ScheduleRule::Interval { seconds: 600 }, target(), utc("2026-03-02T08:00:00Z"));
        task.last_status = Some(ScheduledRunStatus::Running);
        task.last_run = Some(utc("2026-03-02T08:00:00Z"));
        let json = serde_json::json!({"version":1,"tasks":[task, 42, {"title":"no flag"}]});
        std::fs::write(&file, serde_json::to_vec(&json).unwrap()).unwrap();
        let s = Scheduler::new(file.clone(), Arc::new(MemorySecrets::default()), utc("2026-03-02T09:00:00Z"), &Utc);
        let tasks = s.tasks();
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].last_status, Some(ScheduledRunStatus::Failed));
        assert_eq!(tasks[0].next_run, Some(utc("2026-03-02T09:10:00Z")));
        assert!(!tasks[1].enabled);
        // The file was rewritten with the recovered rows.
        let again = Scheduler::new(file, Arc::new(MemorySecrets::default()), utc("2026-03-02T09:00:00Z"), &Utc);
        assert_eq!(again.tasks()[0].last_status, Some(ScheduledRunStatus::Failed));
    }

    fn request(id: Uuid, secret: &str, body: &str, delivery: &str) -> Request {
        let mut headers = BTreeMap::new();
        headers.insert("x-hub-signature-256".to_string(), webhook::sign(secret, body.as_bytes()));
        headers.insert("x-nook-delivery".to_string(), delivery.to_string());
        Request { method: "POST".into(), path: format!("/hooks/{id}"), headers, body: body.as_bytes().to_vec() }
    }

    #[test]
    fn a_signed_webhook_starts_a_session_that_always_asks() {
        let dir = TempDir::new();
        let s = scheduler(dir.path());
        let now = utc("2026-03-02T08:00:00Z");
        let mut task = ScheduledTask::new("hook", "Triage {{body.issue}}", ScheduleRule::Webhook, target(), now);
        task.permission = PermissionPolicy::AcceptEdits;
        let task = s.save_task(task, now, &Utc);
        let secret = s.webhook_secret(task.id, false).expect("a webhook task gets a secret in the secret store");
        assert!(!std::fs::read_to_string(dir.path().join("scheduled-tasks.json")).unwrap().contains(&secret));

        // Off, unknown, unsigned, wrong secret: nothing.
        assert_eq!(s.handle_webhook(false, &request(task.id, &secret, "{}", "d0"), now).0, 404);
        assert_eq!(s.handle_webhook(true, &request(Uuid::new_v4(), &secret, "{}", "d0"), now).0, 404);
        assert_eq!(s.handle_webhook(true, &request(task.id, "wrong", "{}", "d0"), now).0, 401);
        let mut get = request(task.id, &secret, "{}", "d0");
        get.method = "GET".into();
        assert_eq!(s.handle_webhook(true, &get, now).0, 405);
        let mut no_id = request(task.id, &secret, "{}", "d0");
        no_id.headers.remove("x-nook-delivery");
        assert_eq!(s.handle_webhook(true, &no_id, now).0, 400);

        let body = r#"{"issue":"Login broken"}"#;
        assert_eq!(s.handle_webhook(true, &request(task.id, &secret, body, "d1"), now).0, 202);
        assert_eq!(s.handle_webhook(true, &request(task.id, &secret, body, "d1"), now).0, 409, "a replay is refused");
        let host = FakeHost::default();
        s.drain_webhooks(&host, &profile, now, &Utc);
        let started = host.started.lock().unwrap().clone();
        assert_eq!(started.len(), 1);
        assert_eq!(started[0].permission, PermissionPolicy::Ask);
        assert!(started[0].task.contains("<untrusted-webhook-value field=\"body.issue\">Login broken</untrusted-webhook-value>"));

        // A second delivery waits until the first run is over.
        assert_eq!(s.handle_webhook(true, &request(task.id, &secret, body, "d2"), now).0, 202);
        s.drain_webhooks(&host, &profile, now, &Utc);
        assert_eq!(host.started.lock().unwrap().len(), 1);
        host.finish_all();
        s.tick(&host, true, &profile, now, &Utc);
        s.drain_webhooks(&host, &profile, now, &Utc);
        assert_eq!(host.started.lock().unwrap().len(), 2);

        // A new secret: the old one stops working.
        let fresh = s.rotate_secret(task.id).unwrap();
        assert_ne!(fresh, secret);
        assert_eq!(s.handle_webhook(true, &request(task.id, &secret, body, "d3"), now).0, 401);
        s.delete(task.id);
        assert_eq!(s.webhook_secret(task.id, false), None);
    }

    #[test]
    fn webhook_rate_is_limited() {
        let dir = TempDir::new();
        let s = scheduler(dir.path());
        let now = utc("2026-03-02T08:00:00Z");
        let task = s.save_task(ScheduledTask::new("hook", "p", ScheduleRule::Webhook, target(), now), now, &Utc);
        let secret = s.webhook_secret(task.id, false).unwrap();
        let mut codes = vec![];
        for i in 0..25 {
            codes.push(s.handle_webhook(true, &request(task.id, &secret, "{}", &format!("d{i}")), now).0);
        }
        assert_eq!(codes.iter().filter(|c| **c == 202).count(), schedule::MAX_QUEUED_PER_TASK);
        assert!(codes.ends_with(&[429]));
    }

    #[test]
    fn the_webhook_port_is_only_used_when_tasks_are_on() {
        let mut a = AutomationSettings::default();
        assert!(a.auto_titles);
        a.webhook_port = 8787;
        assert_eq!(a.listening_port(), None);
        a.scheduled_tasks = true;
        assert_eq!(a.listening_port(), Some(8787));
        a.webhook_port = 80;
        assert_eq!(a.listening_port(), None);
    }
}
