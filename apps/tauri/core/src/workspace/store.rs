//! Bewaart de werkruimte-sessies op je computer (`RunStore` op de Mac): een lijst sessies en een tijdlijn per sessie.
//! Alleen leesbaar voor de huidige gebruiker; schrijven gebeurt atomair, zodat een crash nooit een half bestand
//! achterlaat. Ook: het gebruiksoverzicht over sessies heen (`UsageReport`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use chrono::{DateTime, Duration, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::models::{EventKind, EventState, RunEvent, RunProvider, RunStatus, WorkspaceRun};
use super::queue::MessageQueue;

/// Zoveel regels per tijdlijn; oudere vallen weg (de agent houdt zelf het hele transcript bij).
pub const EVENT_LIMIT: usize = 4_000;

pub struct RunStore {
    directory: PathBuf,
    lock: Mutex<()>,
}

/// Leest een lijst element voor element: een onleesbaar element wordt overgeslagen, de rest blijft.
fn lossy<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Option<Vec<T>> {
    let list: Vec<Value> = serde_json::from_slice(bytes).ok()?;
    Some(list.into_iter().filter_map(|v| serde_json::from_value(v).ok()).collect())
}

impl RunStore {
    pub fn new(directory: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(directory.join("events"));
        crate::paths::restrict(&directory, 0o700);
        crate::paths::restrict(&directory.join("events"), 0o700);
        Self { directory, lock: Mutex::new(()) }
    }

    fn runs_file(&self) -> PathBuf {
        self.directory.join("runs.json")
    }

    fn events_file(&self, id: Uuid) -> PathBuf {
        self.directory.join("events").join(format!("{id}.json"))
    }

    fn queues_file(&self) -> PathBuf {
        self.directory.join("queues.json")
    }

    fn guard(&self) -> std::sync::MutexGuard<'_, ()> {
        self.lock.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Alle sessies. Wat bij het afsluiten nog "actief" was, heeft geen proces meer: dat wordt "gestopt".
    pub fn load_runs(&self, now: DateTime<Utc>) -> Vec<WorkspaceRun> {
        let _g = self.guard();
        let file = self.runs_file();
        let Ok(bytes) = std::fs::read(&file) else { return vec![] };
        let Some(runs) = lossy::<WorkspaceRun>(&bytes) else {
            // Onleesbaar: apart zetten, zodat de volgende keer opslaan je sessies nooit wist.
            let _ = std::fs::copy(&file, file.with_extension(format!("onleesbaar-{}.json", now.timestamp())));
            return vec![];
        };
        runs.into_iter()
            .map(|mut run| {
                if run.status.is_active() {
                    run.status = run.status.after_relaunch();
                    run.status_detail = Some("interrupted".into());
                    run.turn_started_at = None;
                    run.updated_at = now;
                }
                run
            })
            .collect()
    }

    pub fn save_runs(&self, runs: &[WorkspaceRun]) -> std::io::Result<()> {
        let _g = self.guard();
        write(&self.runs_file(), &serde_json::to_vec(runs).map_err(std::io::Error::other)?)
    }

    pub fn load_events(&self, id: Uuid) -> Vec<RunEvent> {
        let _g = self.guard();
        let Some(mut events) = std::fs::read(self.events_file(id)).ok().and_then(|b| lossy::<RunEvent>(&b)) else { return vec![] };
        // Een tool of vraag die nog liep toen Nook stopte, loopt niet meer.
        for e in events.iter_mut() {
            if matches!(e.state, Some(EventState::Running) | Some(EventState::Pending)) {
                e.state = Some(if e.kind == EventKind::Approval { EventState::Expired } else { EventState::Failed });
            }
        }
        events
    }

    pub fn save_events(&self, id: Uuid, events: &[RunEvent]) -> std::io::Result<()> {
        let _g = self.guard();
        let kept = &events[events.len().saturating_sub(EVENT_LIMIT)..];
        write(&self.events_file(id), &serde_json::to_vec(kept).map_err(std::io::Error::other)?)
    }

    pub fn delete_events(&self, id: Uuid) {
        let _g = self.guard();
        let _ = std::fs::remove_file(self.events_file(id));
    }

    /// De wachtrijen van vervolgberichten blijven over een herstart; ze staan daarna stil tot jij verdergaat.
    pub fn load_queues(&self) -> BTreeMap<Uuid, MessageQueue> {
        let _g = self.guard();
        let mut queues: BTreeMap<Uuid, MessageQueue> =
            std::fs::read(self.queues_file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        for q in queues.values_mut() {
            if !q.is_empty() {
                q.hold();
            }
        }
        queues
    }

    pub fn save_queues(&self, queues: &BTreeMap<Uuid, MessageQueue>) {
        let _g = self.guard();
        if let Ok(bytes) = serde_json::to_vec(queues) {
            let _ = write(&self.queues_file(), &bytes);
        }
    }
}

fn write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    crate::paths::write_atomic(path, bytes)
}

// MARK: Gebruik over sessies heen

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UsageRange {
    Today,
    #[default]
    Week,
    Month,
    All,
}

impl UsageRange {
    pub fn start(self, today: NaiveDate) -> Option<NaiveDate> {
        match self {
            Self::Today => Some(today),
            Self::Week => Some(today - Duration::days(6)),
            Self::Month => Some(today - Duration::days(29)),
            Self::All => None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageFilter {
    pub range: UsageRange,
    pub provider: Option<RunProvider>,
    pub model: Option<String>,
    pub project: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRow {
    pub provider: RunProvider,
    pub model: String,
    pub sessions: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub reported_cost_usd: Option<f64>,
    /// Sessies in deze rij zonder tokens (bijvoorbeeld gestopt voor de eerste melding).
    pub sessions_without_tokens: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageDay {
    pub day: NaiveDate,
    pub provider: RunProvider,
    pub tokens: u64,
}

/// Gebruik over werkruimte-sessies heen. Alleen wat de agents zelf meldden; wat ontbreekt, blijft ontbreken.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageReport {
    pub sessions: u32,
    pub completed: u32,
    pub failed: u32,
    pub running: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    /// De som van de kosten die agents zelf meldden; `None` als geen enkele sessie kosten meldde.
    pub reported_cost_usd: Option<f64>,
    pub sessions_with_cost: u32,
    pub sessions_with_tokens: u32,
    pub rows: Vec<UsageRow>,
    pub days: Vec<UsageDay>,
}

/// Het model in het overzicht: het gemelde of gekozen model, of "standaard".
pub fn display_model(run: &WorkspaceRun) -> String {
    match &run.resolved_model {
        Some(m) if !m.is_empty() => m.clone(),
        _ if run.model.is_empty() => "standaard".into(),
        _ => run.model.clone(),
    }
}

impl UsageReport {
    pub fn make(runs: &[WorkspaceRun], filter: &UsageFilter, today: NaiveDate) -> Self {
        let start = filter.range.start(today);
        let day_of = |d: &DateTime<Utc>| d.with_timezone(&Local).date_naive();
        let mut report = UsageReport::default();
        let mut rows: BTreeMap<String, UsageRow> = BTreeMap::new();
        let mut days: BTreeMap<(NaiveDate, RunProvider), u64> = BTreeMap::new();
        for run in runs {
            if start.is_some_and(|s| day_of(&run.updated_at) < s)
                || filter.provider.is_some_and(|p| p != run.provider)
                || filter.model.as_ref().is_some_and(|m| *m != display_model(run))
                || filter.project.as_ref().is_some_and(|p| *p != run.project_path)
            {
                continue;
            }
            report.sessions += 1;
            match run.status {
                RunStatus::Completed => report.completed += 1,
                RunStatus::Failed => report.failed += 1,
                RunStatus::Preparing | RunStatus::Running | RunStatus::WaitingApproval => report.running += 1,
                RunStatus::Stopped => {}
            }
            let u = &run.usage;
            let has_tokens = u.total_tokens().is_some();
            if has_tokens {
                report.sessions_with_tokens += 1;
            }
            report.input_tokens += u.input_tokens.unwrap_or(0);
            report.output_tokens += u.output_tokens.unwrap_or(0);
            report.cache_read_tokens += u.cache_read_tokens.unwrap_or(0);
            report.cache_write_tokens += u.cache_write_tokens.unwrap_or(0);
            if let Some(c) = u.reported_cost_usd {
                report.reported_cost_usd = Some(report.reported_cost_usd.unwrap_or(0.0) + c);
                report.sessions_with_cost += 1;
            }
            let model = display_model(run);
            let row = rows.entry(format!("{}|{model}", run.provider.id())).or_insert_with(|| UsageRow {
                provider: run.provider,
                model: model.clone(),
                sessions: 0,
                input_tokens: 0,
                output_tokens: 0,
                cache_read_tokens: 0,
                reported_cost_usd: None,
                sessions_without_tokens: 0,
            });
            row.sessions += 1;
            row.input_tokens += u.input_tokens.unwrap_or(0);
            row.output_tokens += u.output_tokens.unwrap_or(0);
            row.cache_read_tokens += u.cache_read_tokens.unwrap_or(0);
            if let Some(c) = u.reported_cost_usd {
                row.reported_cost_usd = Some(row.reported_cost_usd.unwrap_or(0.0) + c);
            }
            if !has_tokens {
                row.sessions_without_tokens += 1;
            }
            if let Some(total) = u.total_tokens() {
                *days.entry((day_of(&run.created_at), run.provider)).or_default() += total;
            }
        }
        let mut rows: Vec<UsageRow> = rows.into_values().collect();
        rows.sort_by(|a, b| {
            let (l, r) = (a.input_tokens + a.output_tokens + a.cache_read_tokens, b.input_tokens + b.output_tokens + b.cache_read_tokens);
            r.cmp(&l).then_with(|| format!("{}|{}", a.provider.id(), a.model).cmp(&format!("{}|{}", b.provider.id(), b.model)))
        });
        report.rows = rows;
        report.days = days.into_iter().map(|((day, provider), tokens)| UsageDay { day, provider, tokens }).collect();
        report
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::models::{ExecutionMode, IsolationMode, PermissionPolicy, RunUsage, TurnUsage};

    fn temp() -> PathBuf {
        std::env::temp_dir().join(format!("nook-runs-{}", Uuid::new_v4()))
    }

    pub fn run(status: RunStatus, provider: RunProvider, model: &str) -> WorkspaceRun {
        let now = Utc::now();
        WorkspaceRun {
            id: Uuid::new_v4(),
            title: "Taak".into(),
            task: "Doe iets".into(),
            provider,
            profile_id: provider.id().into(),
            model: model.into(),
            resolved_model: None,
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::AcceptEdits,
            isolation: IsolationMode::Folder,
            project_path: "/tmp/p".into(),
            working_directory: "/tmp/p".into(),
            repo_root: None,
            branch: None,
            base_branch: None,
            worktree_path: None,
            instructions: String::new(),
            status,
            status_detail: None,
            provider_session_id: None,
            created_at: now,
            updated_at: now,
            archived: false,
            usage: RunUsage::default(),
            turn_started_at: None,
            reviewed_at: None,
            last_change_at: None,
            changed_files: None,
            checkpoints: vec![],
            limited_at: None,
            limit_reset_at: None,
            auto_resume: false,
            effort: None,
            pending_handoff: None,
        }
    }

    #[test]
    fn round_trip_and_recovery_after_relaunch() {
        let dir = temp();
        let store = RunStore::new(dir.clone());
        let mut active = run(RunStatus::Running, RunProvider::Claude, "");
        active.turn_started_at = Some(Utc::now());
        let done = run(RunStatus::Completed, RunProvider::Codex, "");
        store.save_runs(&[active.clone(), done.clone()]).unwrap();
        let loaded = store.load_runs(Utc::now());
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].status, RunStatus::Stopped);
        assert_eq!(loaded[0].status_detail.as_deref(), Some("interrupted"));
        assert!(loaded[0].turn_started_at.is_none());
        assert_eq!(loaded[1].status, RunStatus::Completed);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn events_round_trip_and_running_become_failed() {
        let dir = temp();
        let store = RunStore::new(dir.clone());
        let id = Uuid::new_v4();
        let events = vec![
            RunEvent::new(EventKind::Tool, "Bash · ls").with_state(EventState::Running),
            RunEvent::new(EventKind::Approval, "Bash · rm").with_state(EventState::Pending),
            RunEvent::new(EventKind::Assistant, "klaar").with_state(EventState::Done),
        ];
        store.save_events(id, &events).unwrap();
        let loaded = store.load_events(id);
        assert_eq!(loaded[0].state, Some(EventState::Failed));
        assert_eq!(loaded[1].state, Some(EventState::Expired));
        assert_eq!(loaded[2].state, Some(EventState::Done));
        store.delete_events(id);
        assert!(store.load_events(id).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn unreadable_entries_are_skipped_not_lost() {
        let dir = temp();
        let store = RunStore::new(dir.clone());
        store.save_runs(&[run(RunStatus::Completed, RunProvider::Claude, "")]).unwrap();
        let mut list: Vec<Value> = serde_json::from_slice(&std::fs::read(dir.join("runs.json")).unwrap()).unwrap();
        list.push(serde_json::json!({"kapot": true}));
        std::fs::write(dir.join("runs.json"), serde_json::to_vec(&list).unwrap()).unwrap();
        assert_eq!(store.load_runs(Utc::now()).len(), 1);
        std::fs::write(dir.join("runs.json"), b"{niet goed").unwrap();
        assert!(store.load_runs(Utc::now()).is_empty());
        assert!(std::fs::read_dir(&dir).unwrap().flatten().any(|e| e.file_name().to_string_lossy().contains("onleesbaar")));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn usage_report() {
        let mut a = run(RunStatus::Completed, RunProvider::Claude, "opus");
        a.usage.add(&TurnUsage { input_tokens: Some(100), output_tokens: Some(10), reported_cost_usd: Some(0.5), ..Default::default() });
        let mut b = run(RunStatus::Failed, RunProvider::Codex, "");
        b.usage.add(&TurnUsage { input_tokens: Some(1000), output_tokens: Some(5), cache_read_tokens: Some(50), ..Default::default() });
        let c = run(RunStatus::Running, RunProvider::Claude, "opus");
        let report = UsageReport::make(&[a, b, c], &UsageFilter::default(), Local::now().date_naive());
        assert_eq!((report.sessions, report.completed, report.failed, report.running), (3, 1, 1, 1));
        assert_eq!(report.input_tokens, 1100);
        assert!((report.reported_cost_usd.unwrap() - 0.5).abs() < 1e-9);
        assert_eq!(report.sessions_with_tokens, 2);
        assert_eq!(report.rows[0].provider, RunProvider::Codex, "meeste tokens eerst");
        assert_eq!(report.rows[0].model, "standaard");
        assert_eq!(report.rows[1].sessions_without_tokens, 1);
        let only = UsageReport::make(
            &report_runs(),
            &UsageFilter { provider: Some(RunProvider::Codex), ..Default::default() },
            Local::now().date_naive(),
        );
        assert_eq!(only.sessions, 1);
    }

    fn report_runs() -> Vec<WorkspaceRun> {
        vec![run(RunStatus::Completed, RunProvider::Claude, ""), run(RunStatus::Completed, RunProvider::Codex, "")]
    }
}
